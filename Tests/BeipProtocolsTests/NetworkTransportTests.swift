@preconcurrency import Network
import BeipCore
import BeipProtocols
import BeipTestSupport
import Foundation
import Security
import XCTest

final class NetworkTransportTests: XCTestCase {
    func testProtocolMatrixScriptCanEmitAllMilestoneServerStimuli() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/protocol-matrix.json")
        let script = try MUServerScript.load(from: fixtureURL)
        let server = try ScriptedMUServer()
        let port = try await server.start()
        defer { server.stop() }

        let transport = NetworkTransport()
        let stream = await transport.events()
        let recorder = TransportEventRecorder()
        let disconnected = expectation(description: "matrix script disconnected")
        let eventTask = Task {
            for await event in stream {
                await recorder.append(event)
                if case .state(.disconnected) = event { disconnected.fulfill() }
            }
        }
        defer { eventTask.cancel() }

        try await transport.connect(to: .init(server: .init(name: "matrix", host: "127.0.0.1", port: port)))
        let scriptTask = Task { try await server.run(script) }
        await fulfillment(of: [disconnected], timeout: 3)
        try await scriptTask.value

        let received = await recorder.receivedBytes()
        XCTAssertTrue(received.starts(with: Data("Prompt> ".utf8) + Data([255, 249])))
        XCTAssertTrue(received.range(of: Data([255, 250, 201]) + Data("Core.Ping {}".utf8) + Data([255, 240])) != nil)
        XCTAssertTrue(received.range(of: Data("#$#mcp version: 2.1 to: 2.1\r\n".utf8)) != nil)
        XCTAssertTrue(received.range(of: Data("<PUEBLO><A XCH_CMD='look'>Room</A>\r\n".utf8)) != nil)
        XCTAssertEqual(received.suffix(5), Data([255, 250, 255, 0, 240]))
    }

    func testJSONScriptDrivesFragmentedSessionScenario() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/basic-session.json")
        let script = try MUServerScript.load(from: fixtureURL)
        let server = try ScriptedMUServer()
        let port = try await server.start()
        defer { server.stop() }

        let session = SessionActor(transport: NetworkTransport(), processor: MUDProtocolPipeline())
        let stream = await session.events()
        let welcome = expectation(description: "scripted welcome")
        let room = expectation(description: "scripted ANSI room")
        let disconnected = expectation(description: "scripted disconnect")
        let recorder = SessionEventRecorder()
        let eventTask = Task {
            for await event in stream {
                await recorder.append(event)
                switch event {
                case let .renderedLine(line) where line.text == "Welcome, traveler!": welcome.fulfill()
                case let .renderedLine(line) where line.text == "A room full of green light.": room.fulfill()
                case .state(.disconnected): disconnected.fulfill()
                default: break
                }
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: .init(name: "script", host: "127.0.0.1", port: port)))
        let scriptTask = Task { try await server.run(script) }
        await fulfillment(of: [welcome], timeout: 3)
        await session.send("look")
        await fulfillment(of: [room, disconnected], timeout: 3)
        try await scriptTask.value

        let lines = await recorder.renderedLines()
        XCTAssertEqual(lines.map(\.text), ["Welcome, traveler!", "A room full of green light."])
        XCTAssertEqual(lines.last?.runs.last?.style.foreground, RGBColor(red: 0, green: 205, blue: 0))
    }

    func testTLSWithCertificateVerificationEnabledRejectsSelfSignedServer() async throws {
        let server = try FakeTCPServer(tlsIdentity: try testTLSIdentity())
        let port = try await server.start()
        defer { server.stop() }

        let transport = NetworkTransport()
        let stream = await transport.events()
        let rejected = expectation(description: "self-signed TLS rejected")
        let eventTask = Task {
            for await event in stream {
                if case .state(.failed) = event {
                    rejected.fulfill()
                    return
                }
            }
        }
        defer { eventTask.cancel() }

        try await transport.connect(to: .init(server: .init(
            name: "TLS verification fixture",
            host: "127.0.0.1",
            port: port,
            usesTLS: true,
            verifiesCertificate: true
        )))
        _ = try await server.nextConnection()
        await fulfillment(of: [rejected], timeout: 3)
    }

    func testTLSWithCertificateVerificationDisabledExchangesData() async throws {
        let server = try FakeTCPServer(tlsIdentity: try testTLSIdentity())
        let port = try await server.start()
        defer { server.stop() }

        let transport = NetworkTransport()
        let stream = await transport.events()
        let connected = expectation(description: "TLS connected")
        let received = expectation(description: "TLS payload received")
        let recorder = TransportEventRecorder()
        let eventTask = Task {
            for await event in stream {
                await recorder.append(event)
                if case .state(.connected) = event { connected.fulfill() }
                if case .received = event { received.fulfill() }
            }
        }
        defer { eventTask.cancel() }

        try await transport.connect(to: .init(server: .init(
            name: "TLS fixture",
            host: "127.0.0.1",
            port: port,
            usesTLS: true,
            verifiesCertificate: false
        )))
        let peer = try await server.nextConnection()
        await fulfillment(of: [connected], timeout: 3)

        try await peer.send(Data("secure server".utf8))
        await fulfillment(of: [received], timeout: 3)
        let events = await recorder.events()
        XCTAssertTrue(events.contains(.received(Data("secure server".utf8))))

        try await transport.send(Data("secure client".utf8))
        let clientPayload = try await peer.receive(atLeast: 13)
        XCTAssertEqual(clientPayload, Data("secure client".utf8))
        await transport.disconnect()
    }

    func testLiveSessionNegotiatesNAWSAndExchangesText() async throws {
        let server = try FakeTCPServer()
        let port = try await server.start()
        defer { server.stop() }

        let session = SessionActor(transport: NetworkTransport(), processor: MUDProtocolPipeline())
        let stream = await session.events()
        let recorder = SessionEventRecorder()
        let connected = expectation(description: "session connected")
        let rendered = expectation(description: "ANSI line rendered")
        let disconnected = expectation(description: "remote close observed")
        let eventTask = Task {
            for await event in stream {
                await recorder.append(event)
                switch event {
                case .state(.connected): connected.fulfill()
                case .state(.disconnected): disconnected.fulfill()
                case .renderedLine: rendered.fulfill()
                default: break
                }
            }
        }
        defer { eventTask.cancel() }

        await session.updateWindowSize(columns: 100, rows: 40)
        await session.connect(.init(server: .init(
            name: "fixture",
            host: "127.0.0.1",
            port: port,
            sendNAWSOnResize: true
        )))
        let peer = try await server.nextConnection()
        await fulfillment(of: [connected], timeout: 3)

        try await peer.send(Data([255, 253]))
        try await peer.send(Data([31]) + Data("\u{1b}[31mhel".utf8))
        try await peer.send(Data("lo\u{1b}[0m\r\n".utf8))

        let negotiation = try await peer.receive(atLeast: 12)
        XCTAssertEqual(
            negotiation,
            Data([255, 251, 31, 255, 250, 31, 0, 100, 0, 40, 255, 240])
        )

        await session.updateWindowSize(columns: 120, rows: 50)
        let resized = try await peer.receive(atLeast: 9)
        XCTAssertEqual(resized, Data([255, 250, 31, 0, 120, 0, 50, 255, 240]))
        await fulfillment(of: [rendered], timeout: 3)

        let lines = await recorder.renderedLines()
        XCTAssertEqual(lines.map(\.text), ["hello"])
        XCTAssertEqual(lines.first?.runs.last?.style.foreground, RGBColor(red: 205, green: 0, blue: 0))

        await session.send("look")
        let sentText = try await peer.receive(atLeast: 6)
        XCTAssertEqual(sentText, Data("look\r\n".utf8))

        try await peer.finish()
        await fulfillment(of: [disconnected], timeout: 3)

        let states = await recorder.states()
        let resolving = try XCTUnwrap(states.firstIndex(of: .resolving))
        let connecting = try XCTUnwrap(states.firstIndex(of: .connecting))
        let didConnect = try XCTUnwrap(states.firstIndex(of: .connected))
        let didDisconnect = try XCTUnwrap(states.firstIndex(of: .disconnected))
        XCTAssertLessThan(resolving, connecting)
        XCTAssertLessThan(connecting, didConnect)
        XCTAssertLessThan(didConnect, didDisconnect)
    }
}

private actor TransportEventRecorder {
    private var recorded: [TransportEvent] = []

    func append(_ event: TransportEvent) { recorded.append(event) }
    func events() -> [TransportEvent] { recorded }
    func receivedBytes() -> Data {
        recorded.reduce(into: Data()) { result, event in
            if case let .received(data) = event { result.append(data) }
        }
    }
}

private actor SessionEventRecorder {
    private var events: [SessionEvent] = []

    func append(_ event: SessionEvent) { events.append(event) }

    func renderedLines() -> [RenderedLine] {
        events.compactMap {
            guard case let .renderedLine(line) = $0 else { return nil }
            return line
        }
    }

    func states() -> [ConnectionState] {
        events.compactMap {
            guard case let .state(state) = $0 else { return nil }
            return state
        }
    }
}

private final class FakeTCPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.beipmu.tests.fake-server")
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var connectionContinuation: CheckedContinuation<FakeServerConnection, Error>?
    private var pendingConnections: [FakeServerConnection] = []
    private var allConnections: [FakeServerConnection] = []

    init(tlsIdentity: sec_identity_t? = nil) throws {
        let parameters: NWParameters
        if let tlsIdentity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, tlsIdentity)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port?.rawValue else {
                    self.completeStart(.failure(FakeServerError.missingPort))
                    return
                }
                self.completeStart(.success(port))
            case let .failed(error):
                self.completeStart(.failure(error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let peer = FakeServerConnection(connection: connection, queue: self.queue)
            connection.start(queue: self.queue)
            self.deliver(peer)
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { startContinuation = continuation }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.completeStart(.failure(FakeServerError.timeout("listener readiness")))
            }
        }
    }

    func nextConnection() async throws -> FakeServerConnection {
        try await withCheckedThrowingContinuation { continuation in
            let pending = lock.withLock { () -> FakeServerConnection? in
                if !pendingConnections.isEmpty { return pendingConnections.removeFirst() }
                connectionContinuation = continuation
                return nil
            }
            if let pending { continuation.resume(returning: pending) }
            else {
                queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.completeConnection(.failure(FakeServerError.timeout("client connection")))
                }
            }
        }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        let connections = lock.withLock { allConnections }
        connections.forEach { $0.cancel() }
        completeStart(.failure(FakeServerError.closed))
        completeConnection(.failure(FakeServerError.closed))
    }

    private func deliver(_ connection: FakeServerConnection) {
        let continuation = lock.withLock { () -> CheckedContinuation<FakeServerConnection, Error>? in
            allConnections.append(connection)
            if let continuation = connectionContinuation {
                connectionContinuation = nil
                return continuation
            }
            pendingConnections.append(connection)
            return nil
        }
        continuation?.resume(returning: connection)
    }

    private func completeStart(_ result: Result<UInt16, Error>) {
        let continuation = lock.withLock {
            defer { startContinuation = nil }
            return startContinuation
        }
        continuation?.resume(with: result)
    }

    private func completeConnection(_ result: Result<FakeServerConnection, Error>) {
        let continuation = lock.withLock {
            defer { connectionContinuation = nil }
            return connectionContinuation
        }
        continuation?.resume(with: result)
    }
}

private func testTLSIdentity() throws -> sec_identity_t {
    let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/tls-identity.p12.base64")
    let encoded = try String(contentsOf: fixture, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: encoded) else { throw FakeServerError.invalidTLSIdentity }

    var imported: CFArray?
    let options = [kSecImportExportPassphrase as String: "beipmu-tests"] as CFDictionary
    guard SecPKCS12Import(data as CFData, options, &imported) == errSecSuccess,
          let item = (imported as? [[String: Any]])?.first,
          let identity = item[kSecImportItemIdentity as String] as! SecIdentity?,
          let protocolIdentity = sec_identity_create(identity)
    else { throw FakeServerError.invalidTLSIdentity }
    return protocolIdentity
}

private final class FakeServerConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate(continuation)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { gate.resume(.failure(error)) }
                else { gate.resume(.success(())) }
            })
            queue.asyncAfter(deadline: .now() + 3) {
                gate.resume(.failure(FakeServerError.timeout("server send")))
            }
        }
    }

    func receive(atLeast minimumLength: Int) async throws -> Data {
        var result = Data()
        while result.count < minimumLength {
            result.append(try await receiveOnce())
        }
        return result
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ContinuationGate(continuation)
            connection.send(
                content: nil,
                contentContext: .defaultStream,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error { gate.resume(.failure(error)) }
                    else { gate.resume(.success(())) }
                }
            )
            queue.asyncAfter(deadline: .now() + 3) {
                gate.resume(.failure(FakeServerError.timeout("server close")))
            }
        }
    }

    func cancel() { connection.cancel() }

    private func receiveOnce() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { gate.resume(.failure(error)) }
                else if let data, !data.isEmpty { gate.resume(.success(data)) }
                else if complete { gate.resume(.failure(FakeServerError.closed)) }
                else { gate.resume(.failure(FakeServerError.emptyRead)) }
            }
            queue.asyncAfter(deadline: .now() + 3) {
                gate.resume(.failure(FakeServerError.timeout("server receive")))
            }
        }
    }
}

private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Value, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

private enum FakeServerError: LocalizedError {
    case closed
    case emptyRead
    case invalidTLSIdentity
    case missingPort
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .closed: "The fake server connection closed."
        case .emptyRead: "The fake server received an empty, incomplete read."
        case .invalidTLSIdentity: "The fake server TLS identity is invalid."
        case .missingPort: "The fake server listener did not expose its assigned port."
        case let .timeout(operation): "Timed out waiting for \(operation)."
        }
    }
}
