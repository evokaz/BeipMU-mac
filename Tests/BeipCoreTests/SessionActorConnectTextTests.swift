import BeipCore
import Foundation
import XCTest

final class SessionActorConnectTextTests: XCTestCase {
    func testConnectStringIsSentBeforeConnectedStateWithoutLocalEcho() async throws {
        let transport = GatedTransport(suspendsFirstSend: true)
        let session = SessionActor(transport: transport, processor: UTF8Processor(), localEcho: true)
        let recorder = SessionEventRecorder()
        let stream = await session.events()
        let connected = expectation(description: "connected after Connect String")
        let eventTask = Task {
            for await event in stream {
                await recorder.append(event)
                if event == .state(.connected) { connected.fulfill() }
            }
        }
        defer { eventTask.cancel() }

        let character = CharacterProfile(
            name: "Hero",
            connectText: "connect %NAME% %PASSWORD%",
            password: "swordfish"
        )
        await session.connect(.init(server: Self.server, character: character))
        await transport.waitForFirstSend()

        let sentData = await transport.sentData()
        let connectedCount = await recorder.connectedCount()
        let localEchoLines = await recorder.localEchoLines()
        XCTAssertEqual(sentData, [Data("connect Hero swordfish\r\n".utf8)])
        XCTAssertEqual(connectedCount, 0)
        XCTAssertEqual(localEchoLines, [])

        await transport.releaseFirstSend()
        await fulfillment(of: [connected], timeout: 1)
    }

    func testDisconnectDuringSuspendedConnectStringDoesNotPublishConnected() async throws {
        let transport = GatedTransport(suspendsFirstSend: true)
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let recorder = SessionEventRecorder()
        let stream = await session.events()
        let eventTask = Task { for await event in stream { await recorder.append(event) } }
        defer { eventTask.cancel() }

        await session.connect(.init(server: Self.server, character: Self.character))
        await transport.waitForFirstSend()
        await session.disconnect()
        await transport.releaseFirstSend()
        try await Task.sleep(for: .milliseconds(50))

        let connectedCount = await recorder.connectedCount()
        XCTAssertEqual(connectedCount, 0)
    }

    func testReconnectDuringSuspendedConnectStringOnlyPublishesCurrentConnection() async throws {
        let transport = GatedTransport(suspendsFirstSend: true)
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let recorder = SessionEventRecorder()
        let stream = await session.events()
        let connected = expectation(description: "reconnected")
        let eventTask = Task {
            for await event in stream {
                await recorder.append(event)
                if event == .state(.connected) { connected.fulfill() }
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: Self.server, character: Self.character))
        await transport.waitForFirstSend()
        await session.reconnect()
        await fulfillment(of: [connected], timeout: 1)
        await transport.releaseFirstSend()
        try await Task.sleep(for: .milliseconds(50))

        let sentData = await transport.sentData()
        let connectedCount = await recorder.connectedCount()
        XCTAssertEqual(sentData.count, 2)
        XCTAssertEqual(connectedCount, 1)
    }

    func testEmptyConnectStringStillPublishesConnectedWithoutSending() async throws {
        let transport = GatedTransport(suspendsFirstSend: false)
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let stream = await session.events()
        let connected = expectation(description: "connected without Connect String")
        let eventTask = Task {
            for await event in stream where event == .state(.connected) {
                connected.fulfill()
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(
            server: Self.server,
            character: .init(name: "Hero", connectText: "")
        ))
        await fulfillment(of: [connected], timeout: 1)

        let sentData = await transport.sentData()
        XCTAssertEqual(sentData, [])
    }

    private static let server = ServerProfile(name: "Test", host: "test.invalid", port: 1)
    private static let character = CharacterProfile(
        name: "Hero",
        connectText: "connect %NAME% %PASSWORD%",
        password: "swordfish"
    )
}

private actor GatedTransport: SessionTransport {
    private var eventContinuation: AsyncStream<TransportEvent>.Continuation?
    private let suspendsFirstSend: Bool
    private var didSuspendFirstSend = false
    private var firstSendStarted = false
    private var firstSendWaiter: CheckedContinuation<Void, Never>?
    private var releaseFirstSendWaiter: CheckedContinuation<Void, Never>?
    private var sent: [Data] = []

    init(suspendsFirstSend: Bool) {
        self.suspendsFirstSend = suspendsFirstSend
    }

    func connect(to request: ConnectionRequest) async throws {
        eventContinuation?.yield(.state(.connected))
    }

    func send(_ data: Data) async throws {
        sent.append(data)
        if suspendsFirstSend, !didSuspendFirstSend {
            didSuspendFirstSend = true
            firstSendStarted = true
            firstSendWaiter?.resume()
            firstSendWaiter = nil
            await withCheckedContinuation { releaseFirstSendWaiter = $0 }
        }
        eventContinuation?.yield(.sent(data))
    }

    func disconnect() async {
        eventContinuation?.yield(.state(.disconnecting))
        eventContinuation?.yield(.state(.disconnected))
    }

    func events() async -> AsyncStream<TransportEvent> {
        AsyncStream { eventContinuation = $0 }
    }

    func waitForFirstSend() async {
        guard !firstSendStarted else { return }
        await withCheckedContinuation { firstSendWaiter = $0 }
    }

    func releaseFirstSend() {
        releaseFirstSendWaiter?.resume()
        releaseFirstSendWaiter = nil
    }

    func sentData() -> [Data] { sent }
}

private struct UTF8Processor: ByteStreamProcessor {
    mutating func reset() {}
    mutating func configureANSI(_ settings: ANSISettings) {}
    mutating func setTerminalType(_ value: String) {}
    mutating func consume(_ data: Data) -> [ProtocolOutput] { [] }
    mutating func encode(_ text: String) throws -> Data { Data(text.utf8) }
}

private actor SessionEventRecorder {
    private var events: [SessionEvent] = []

    func append(_ event: SessionEvent) { events.append(event) }
    func connectedCount() -> Int { events.filter { $0 == .state(.connected) }.count }
    func localEchoLines() -> [RenderedLine] {
        events.compactMap {
            guard case let .renderedLine(line) = $0, line.source == .localEcho else { return nil }
            return line
        }
    }
}
