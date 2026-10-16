import BeipCore
import Foundation
import XCTest

final class SessionActorConnectTextTests: XCTestCase {
    func testConnectStringWaitsForGreetingAndSendsOnceWithoutLocalEcho() async throws {
        let transport = RecordingTransport()
        let session = SessionActor(transport: transport, processor: UTF8Processor(), localEcho: true)
        let recorder = SessionEventRecorder()
        let stream = await session.events()
        let transportConnected = expectation(description: "transport connected before greeting")
        let startupReady = expectation(description: "startup ready after Connect String send")
        let negotiationReceived = expectation(description: "telnet negotiation received")
        let partialGreetingReceived = expectation(description: "partial greeting received")
        let completeGreetingReceived = expectation(description: "complete greeting received")
        let greeting = expectation(description: "displayable greeting rendered")
        let sent = expectation(description: "Connect String sent")
        let eventTask = Task {
            var receiveCount = 0
            for await event in stream {
                await recorder.append(event)
                switch event {
                case .transportConnected: transportConnected.fulfill()
                case .state(.connected): startupReady.fulfill()
                case .received:
                    receiveCount += 1
                    if receiveCount == 1 { negotiationReceived.fulfill() }
                    if receiveCount == 2 { partialGreetingReceived.fulfill() }
                    if receiveCount == 3 { completeGreetingReceived.fulfill() }
                case let .renderedLine(line) where line.text == "Welcome!": greeting.fulfill()
                case .sent: sent.fulfill()
                default: break
                }
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: Self.server, character: Self.character))
        await fulfillment(of: [transportConnected], timeout: 1)
        var sentData = await transport.sentData()
        XCTAssertEqual(sentData, [])

        await transport.emit(Data([255, 251, 1]))
        await fulfillment(of: [negotiationReceived], timeout: 1)
        sentData = await transport.sentData()
        XCTAssertEqual(sentData, [], "Telnet negotiation alone must not trigger automatic login")

        await transport.emit(Data("Wel".utf8))
        await fulfillment(of: [partialGreetingReceived], timeout: 1)
        sentData = await transport.sentData()
        XCTAssertEqual(sentData, [], "A partial line is not a displayable greeting")

        await transport.emit(Data("LINE:Welcome!".utf8))
        await fulfillment(of: [completeGreetingReceived], timeout: 1)
        await fulfillment(of: [greeting, sent], timeout: 1)
        await fulfillment(of: [startupReady], timeout: 1)
        sentData = await transport.sentData()
        XCTAssertEqual(sentData, [Data("connect Hero swordfish\r\n".utf8)])

        let recordedEvents = await recorder.snapshot()
        let greetingIndex = try XCTUnwrap(recordedEvents.firstIndex {
            if case let .renderedLine(line) = $0 { return line.text == "Welcome!" }
            return false
        })
        let sentIndex = try XCTUnwrap(recordedEvents.firstIndex {
            if case .sent = $0 { return true }
            return false
        })
        XCTAssertLessThan(greetingIndex, sentIndex, "The greeting must be emitted before the automatic command is sent")
        let earlyIndex = try XCTUnwrap(recordedEvents.firstIndex(of: .transportConnected))
        let readyIndex = try XCTUnwrap(recordedEvents.firstIndex(of: .state(.connected)))
        XCTAssertLessThan(earlyIndex, greetingIndex)
        XCTAssertGreaterThan(readyIndex, greetingIndex)
        let completedSends = await transport.completedSendCount()
        XCTAssertEqual(completedSends, 1)
        let localEchoLines = await recorder.localEchoLines()
        XCTAssertEqual(localEchoLines, [])
    }

    func testPromptTriggersConnectString() async throws {
        let transport = RecordingTransport()
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let recorder = SessionEventRecorder()
        let stream = await session.events()
        let prompt = expectation(description: "prompt rendered")
        let sent = expectation(description: "Connect String sent after prompt")
        let eventTask = Task {
            for await event in stream {
                await recorder.append(event)
                if case let .prompt(line) = event, line.text == "Login> " { prompt.fulfill() }
                if case .sent = event { sent.fulfill() }
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: Self.server, character: Self.character))
        await transport.emit(Data("!prompt!".utf8))
        await fulfillment(of: [prompt, sent], timeout: 1)

        let sentData = await transport.sentData()
        XCTAssertEqual(sentData, [Data("connect Hero swordfish\r\n".utf8)])
    }

    func testUnterminatedGreetingEventuallySendsConnectString() async throws {
        let transport = RecordingTransport()
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let stream = await session.events()
        let ready = expectation(description: "startup ready after buffered prompt")
        let eventTask = Task {
            for await event in stream where event == .state(.connected) { ready.fulfill() }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: Self.server, character: Self.character))
        await transport.emit(Data("PARTIAL:Password: ".utf8))
        await fulfillment(of: [ready], timeout: 2)
        let sends = await transport.sendAttempts()
        XCTAssertEqual(sends, [Data("connect Hero swordfish\r\n".utf8)])
    }

    func testMultilineEchoesAreSuppressedOnceAndLaterMatchingOutputIsShown() async throws {
        let transport = RecordingTransport()
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let recorder = SessionEventRecorder()
        let stream = await session.events()
        let marker = expectation(description: "later output rendered")
        let eventTask = Task {
            for await event in stream {
                await recorder.append(event)
                if case let .renderedLine(line) = event, line.text == "After login" { marker.fulfill() }
            }
        }
        defer { eventTask.cancel() }

        let character = CharacterProfile(
            name: "Hero", connectText: "login %NAME%\nswordfish %PASSWORD%", password: "secret"
        )
        await session.connect(.init(server: Self.server, character: character))
        await transport.emit(Data("LINE:Welcome".utf8))
        await transport.emit(Data("LINE:login Hero".utf8))
        await transport.emit(Data("LINE:swordfish secret".utf8))
        await transport.emit(Data("LINE:login Hero".utf8))
        await transport.emit(Data("LINE:After login".utf8))
        await fulfillment(of: [marker], timeout: 1)

        let lines = await recorder.snapshot().compactMap { event -> String? in
            guard case let .renderedLine(line) = event else { return nil }
            return line.text
        }
        XCTAssertEqual(lines, ["Welcome", "login Hero", "After login"])
    }

    func testUnechoedConnectStringDoesNotHideLaterMatchingOutput() async throws {
        let transport = RecordingTransport()
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let recorder = SessionEventRecorder()
        let stream = await session.events()
        let ready = expectation(description: "Connect String sent")
        let laterOutput = expectation(description: "matching output rendered")
        let eventTask = Task {
            for await event in stream {
                await recorder.append(event)
                if event == .state(.connected) { ready.fulfill() }
                if case let .renderedLine(line) = event, line.text == "connect Hero swordfish" {
                    laterOutput.fulfill()
                }
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: Self.server, character: Self.character))
        await transport.emit(Data("LINE:Welcome".utf8))
        await fulfillment(of: [ready], timeout: 1)
        await transport.emit(Data("LINE:Login successful".utf8))
        await transport.emit(Data("LINE:connect Hero swordfish".utf8))
        await fulfillment(of: [laterOutput], timeout: 1)

        let lines = await recorder.snapshot().compactMap { event -> String? in
            guard case let .renderedLine(line) = event else { return nil }
            return line.text
        }
        XCTAssertEqual(lines, ["Welcome", "Login successful", "connect Hero swordfish"])
    }

    func testEchoSuppressionExpiresWithoutServerReply() async throws {
        let transport = RecordingTransport()
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let stream = await session.events()
        let ready = expectation(description: "Connect String sent")
        let laterOutput = expectation(description: "late matching output rendered")
        let eventTask = Task {
            for await event in stream {
                if event == .state(.connected) { ready.fulfill() }
                if case let .renderedLine(line) = event, line.text == "connect Hero swordfish" {
                    laterOutput.fulfill()
                }
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: Self.server, character: Self.character))
        await transport.emit(Data("LINE:Welcome".utf8))
        await fulfillment(of: [ready], timeout: 1)
        try await Task.sleep(for: .milliseconds(2_100))
        await transport.emit(Data("LINE:connect Hero swordfish".utf8))
        await fulfillment(of: [laterOutput], timeout: 1)
    }

    func testDisconnectBeforeGreetingClearsPendingTextAndReconnectUsesCurrentCharacter() async throws {
        let transport = RecordingTransport()
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let recorder = SessionEventRecorder()
        let stream = await session.events()
        let firstConnected = expectation(description: "first transport connection")
        let disconnected = expectation(description: "disconnected before greeting")
        let secondConnected = expectation(description: "reconnected transport")
        let newGreeting = expectation(description: "new greeting rendered")
        let sent = expectation(description: "new Connect String sent")
        let eventTask = Task {
            var connectionCount = 0
            for await event in stream {
                await recorder.append(event)
                switch event {
                case .transportConnected:
                    connectionCount += 1
                    if connectionCount == 1 { firstConnected.fulfill() }
                    if connectionCount == 2 { secondConnected.fulfill() }
                case .state(.disconnected): disconnected.fulfill()
                case let .renderedLine(line) where line.text == "New welcome": newGreeting.fulfill()
                case .sent: sent.fulfill()
                default: break
                }
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: Self.server, character: Self.character))
        await fulfillment(of: [firstConnected], timeout: 1)
        await session.disconnect()
        await fulfillment(of: [disconnected], timeout: 1)
        await transport.emit(Data("LINE:Late welcome".utf8))
        try await Task.sleep(for: .milliseconds(30))
        var sentData = await transport.sentData()
        XCTAssertEqual(sentData, [], "Disconnecting before a greeting must discard the pending command")

        let nextCharacter = CharacterProfile(
            name: "Ranger",
            connectText: "login %NAME% %PASSWORD%",
            password: "new-secret"
        )
        await session.connect(.init(server: Self.server, character: nextCharacter))
        await fulfillment(of: [secondConnected], timeout: 1)
        await transport.emit(Data("LINE:New welcome".utf8))
        await fulfillment(of: [newGreeting, sent], timeout: 1)
        sentData = await transport.sentData()
        XCTAssertEqual(sentData, [Data("login Ranger new-secret\r\n".utf8)])
    }

    func testEmptyConnectStringPublishesConnectedWithoutSending() async throws {
        let transport = RecordingTransport()
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let recorder = SessionEventRecorder()
        let stream = await session.events()
        let connected = expectation(description: "connected without Connect String")
        let eventTask = Task {
            for await event in stream {
                await recorder.append(event)
                if event == .state(.connected) { connected.fulfill() }
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
        let events = await recorder.snapshot()
        let earlyIndex = try XCTUnwrap(events.firstIndex(of: .transportConnected))
        let readyIndex = try XCTUnwrap(events.firstIndex(of: .state(.connected)))
        XCTAssertEqual(readyIndex, earlyIndex + 1)
    }

    func testStartupReadyWaitsUntilConnectStringSendCompletes() async throws {
        let transport = RecordingTransport(suspendsFirstSend: true)
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let recorder = SessionEventRecorder()
        let stream = await session.events()
        let transportConnected = expectation(description: "transport connected")
        let startupReady = expectation(description: "startup ready after send")
        let eventTask = Task {
            for await event in stream {
                await recorder.append(event)
                if event == .transportConnected { transportConnected.fulfill() }
                if event == .state(.connected) { startupReady.fulfill() }
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: Self.server, character: Self.character))
        await fulfillment(of: [transportConnected], timeout: 1)
        await transport.emit(Data("LINE:Welcome".utf8))
        await transport.waitForFirstSend()

        let beforeCompletion = await recorder.snapshot()
        XCTAssertFalse(beforeCompletion.contains(.state(.connected)))
        let sendsBeforeCompletion = await transport.completedSendCount()
        XCTAssertEqual(sendsBeforeCompletion, 0)

        await transport.releaseFirstSend()
        await fulfillment(of: [startupReady], timeout: 1)
        let completedSends = await transport.completedSendCount()
        XCTAssertEqual(completedSends, 1)
    }

    func testConnectCallbackCommandFollowsSuccessfulLoginSend() async throws {
        let transport = RecordingTransport()
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let stream = await session.events()
        let callbackCommandSent = expectation(description: "connect callback command sent")
        let eventTask = Task {
            for await event in stream where event == .state(.connected) {
                do {
                    try await transport.send(Data("connect-callback\r\n".utf8))
                    callbackCommandSent.fulfill()
                } catch {
                    XCTFail("Could not record callback command: \(error)")
                }
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: Self.server, character: Self.character))
        await transport.emit(Data("LINE:Welcome".utf8))
        await fulfillment(of: [callbackCommandSent], timeout: 1)

        let sends = await transport.sendAttempts()
        XCTAssertEqual(sends, [
            Data("connect Hero swordfish\r\n".utf8),
            Data("connect-callback\r\n".utf8),
        ])
    }

    func testIdleCommandCannotPrecedeDelayedConnectString() async throws {
        let transport = RecordingTransport()
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        await session.configureIdle(interval: 0.01, text: "idle-command")
        let stream = await session.events()
        let transportConnected = expectation(description: "transport connected")
        let idleSent = expectation(description: "idle command follows startup")
        let eventTask = Task {
            for await event in stream {
                if event == .transportConnected { transportConnected.fulfill() }
                if case let .sent(data) = event, data == Data("idle-command\r\n".utf8) {
                    idleSent.fulfill()
                }
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: Self.server, character: Self.character))
        await fulfillment(of: [transportConnected], timeout: 1)
        try await Task.sleep(for: .milliseconds(40))
        var sends = await transport.sendAttempts()
        XCTAssertEqual(sends, [], "Idle actions wait until startup is ready")

        await transport.emit(Data("LINE:Welcome".utf8))
        await fulfillment(of: [idleSent], timeout: 1)
        sends = await transport.sendAttempts()
        XCTAssertEqual(sends.first, Data("connect Hero swordfish\r\n".utf8))
        XCTAssertEqual(sends.dropFirst().first, Data("idle-command\r\n".utf8))
    }

    func testConnectStringSendFailureReportsErrorAndWithholdsStartupReady() async throws {
        let transport = RecordingTransport(failsFirstSend: true)
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let recorder = SessionEventRecorder()
        let stream = await session.events()
        let sendError = expectation(description: "Connect String send error")
        let eventTask = Task {
            for await event in stream {
                await recorder.append(event)
                if case let .error(message) = event, message == "recorded send failure" {
                    sendError.fulfill()
                }
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: Self.server, character: Self.character))
        await transport.emit(Data("LINE:Welcome".utf8))
        await fulfillment(of: [sendError], timeout: 1)
        try await Task.sleep(for: .milliseconds(30))

        let events = await recorder.snapshot()
        XCTAssertFalse(events.contains(.state(.connected)))
        let attempts = await transport.sendAttempts()
        XCTAssertEqual(attempts, [Data("connect Hero swordfish\r\n".utf8)])
        let completedSends = await transport.completedSendCount()
        XCTAssertEqual(completedSends, 0)
    }

    func testReconnectDuringLoginSendDoesNotPublishStaleStartupReady() async throws {
        let transport = RecordingTransport(suspendsFirstSend: true)
        let session = SessionActor(transport: transport, processor: UTF8Processor())
        let recorder = SessionEventRecorder()
        let stream = await session.events()
        let firstTransportConnection = expectation(description: "first transport connection")
        let secondTransportConnection = expectation(description: "second transport connection")
        let startupReady = expectation(description: "current connection becomes ready")
        let eventTask = Task {
            var connectionCount = 0
            for await event in stream {
                await recorder.append(event)
                if event == .transportConnected {
                    connectionCount += 1
                    if connectionCount == 1 { firstTransportConnection.fulfill() }
                    if connectionCount == 2 { secondTransportConnection.fulfill() }
                }
                if event == .state(.connected) { startupReady.fulfill() }
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: Self.server, character: Self.character))
        await fulfillment(of: [firstTransportConnection], timeout: 1)
        await transport.emit(Data("LINE:First welcome".utf8))
        await transport.waitForFirstSend()
        await session.reconnect()
        await fulfillment(of: [secondTransportConnection], timeout: 1)
        await transport.releaseFirstSend()
        try await Task.sleep(for: .milliseconds(30))

        var events = await recorder.snapshot()
        XCTAssertFalse(events.contains(.state(.connected)))
        await transport.emit(Data("LINE:Second welcome".utf8))
        await fulfillment(of: [startupReady], timeout: 1)
        events = await recorder.snapshot()
        XCTAssertEqual(events.filter { $0 == .state(.connected) }.count, 1)
        let attempts = await transport.sendAttempts()
        XCTAssertEqual(attempts, [
            Data("connect Hero swordfish\r\n".utf8),
            Data("connect Hero swordfish\r\n".utf8),
        ])
    }

    private static let server = ServerProfile(name: "Test", host: "test.invalid", port: 1)
    private static let character = CharacterProfile(
        name: "Hero",
        connectText: "connect %NAME% %PASSWORD%",
        password: "swordfish"
    )
}

private actor RecordingTransport: SessionTransport {
    private var eventContinuation: AsyncStream<TransportEvent>.Continuation?
    private var sent: [Data] = []
    private let suspendsFirstSend: Bool
    private let failsFirstSend: Bool
    private var firstSendStarted = false
    private var firstSendWaiter: CheckedContinuation<Void, Never>?
    private var releaseFirstSendWaiter: CheckedContinuation<Void, Never>?
    private var completedSends = 0

    init(suspendsFirstSend: Bool = false, failsFirstSend: Bool = false) {
        self.suspendsFirstSend = suspendsFirstSend
        self.failsFirstSend = failsFirstSend
    }

    func connect(to request: ConnectionRequest) async throws {
        eventContinuation?.yield(.state(.connected))
    }

    func send(_ data: Data) async throws {
        sent.append(data)
        if sent.count == 1, failsFirstSend { throw RecordedSendError.failed }
        if sent.count == 1, suspendsFirstSend {
            firstSendStarted = true
            firstSendWaiter?.resume()
            firstSendWaiter = nil
            await withCheckedContinuation { releaseFirstSendWaiter = $0 }
        }
        completedSends += 1
        eventContinuation?.yield(.sent(data))
    }

    func disconnect() async {
        eventContinuation?.yield(.state(.disconnecting))
        eventContinuation?.yield(.state(.disconnected))
    }

    func events() async -> AsyncStream<TransportEvent> {
        AsyncStream { eventContinuation = $0 }
    }

    func emit(_ data: Data) {
        eventContinuation?.yield(.received(data))
    }

    func sentData() -> [Data] { sent }
    func sendAttempts() -> [Data] { sent }
    func completedSendCount() -> Int { completedSends }

    func waitForFirstSend() async {
        guard !firstSendStarted else { return }
        await withCheckedContinuation { firstSendWaiter = $0 }
    }

    func releaseFirstSend() {
        releaseFirstSendWaiter?.resume()
        releaseFirstSendWaiter = nil
    }
}

private enum RecordedSendError: LocalizedError {
    case failed
    var errorDescription: String? { "recorded send failure" }
}

private struct UTF8Processor: ByteStreamProcessor {
    private var bufferedText = false
    var hasBufferedDisplayableText: Bool { bufferedText }
    mutating func reset() { bufferedText = false }
    mutating func configureANSI(_ settings: ANSISettings) {}
    mutating func setTerminalType(_ value: String) {}

    mutating func consume(_ data: Data) -> [ProtocolOutput] {
        if data.first == 255 { return [] }
        if data == Data("!prompt!".utf8) {
            bufferedText = false
            return [.prompt(.init(text: "Login> "))]
        }
        let text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("PARTIAL:") {
            bufferedText = true
            return []
        }
        guard text.hasPrefix("LINE:") else { return [] }
        bufferedText = false
        return [.line(.init(text: String(text.dropFirst("LINE:".count))))]
    }

    mutating func encode(_ text: String) throws -> Data { Data(text.utf8) }
    mutating func encodeMCP(_ message: MCPMessage) -> [Data] { [] }
}

private actor SessionEventRecorder {
    private var recordedEvents: [SessionEvent] = []

    func append(_ event: SessionEvent) { recordedEvents.append(event) }
    func snapshot() -> [SessionEvent] { recordedEvents }
    func localEchoLines() -> [RenderedLine] {
        recordedEvents.compactMap {
            guard case let .renderedLine(line) = $0, line.source == .localEcho else { return nil }
            return line
        }
    }
}
