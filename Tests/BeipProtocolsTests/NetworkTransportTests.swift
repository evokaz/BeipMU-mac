@preconcurrency import Network
import BeipCore
import BeipProtocols
import BeipTestSupport
import Foundation
import Security
import XCTest

final class NetworkTransportTests: XCTestCase {
    func testDNSHostnameResolutionWithForcedIPv4Connects() async throws {
        let server = try FakeTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let transport = NetworkTransport()
        let stream = await transport.events()
        let connected = expectation(description: "DNS-resolved IPv4 connection")
        let task = Task {
            for await event in stream {
                if event == .state(.connected) { connected.fulfill(); return }
            }
        }
        defer { task.cancel() }

        try await transport.connect(to: .init(server: .init(
            name: "DNS fixture",
            host: "localhost",
            port: port,
            forceIPv4: true
        )))
        _ = try await server.nextConnection()
        await fulfillment(of: [connected], timeout: 3)
        await transport.disconnect()
    }

    func testFailedInitialConnectionRetriesAccordingToPolicy() async throws {
        let temporaryServer = try FakeTCPServer()
        let closedPort = try await temporaryServer.start()
        temporaryServer.stop()
        // NWListener cancellation is asynchronous. Wait for the ephemeral port
        // to leave LISTEN so this remains an initial-connect failure even when
        // the full suite puts the Network framework queues under load.
        try await Task.sleep(for: .milliseconds(100))

        let transport = NetworkTransport()
        let stream = await transport.events()
        let secondAttempt = expectation(description: "second connection attempt")
        let recorder = TransportEventRecorder()
        let task = Task {
            var resolvingCount = 0
            for await event in stream {
                await recorder.append(event)
                if case .state(.resolving) = event {
                    resolvingCount += 1
                    if resolvingCount == 2 { secondAttempt.fulfill(); return }
                }
            }
        }
        defer { task.cancel() }

        try await transport.connect(to: .init(
            server: .init(name: "retry", host: "127.0.0.1", port: closedPort, forceIPv4: true),
            policy: .init(connectTimeoutMilliseconds: 1_000, retryCount: 2)
        ))
        await fulfillment(of: [secondAttempt], timeout: 4)
        let events = await recorder.events()
        XCTAssertGreaterThanOrEqual(events.filter { $0 == .state(.resolving) }.count, 2, "\(events)")
        let notices = await recorder.connectionNotices()
        XCTAssertTrue(notices.contains(.retryScheduled(seconds: "1")), "\(notices)")
        XCTAssertTrue(notices.contains(.retrying(attempt: 2, limit: "2")), "\(notices)")
        XCTAssertEqual(notices.filter { notice in
            if case .lookingUp = notice { return true }
            return false
        }.count, 2, "\(notices)")
        await transport.disconnect()
    }

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

    func testConcurrentScriptedSessionsKeepTrafficAndStateIsolated() async throws {
        let firstServer = try ScriptedMUServer()
        let secondServer = try ScriptedMUServer()
        let firstPort = try await firstServer.start()
        let secondPort = try await secondServer.start()
        defer {
            firstServer.stop()
            secondServer.stop()
        }

        let firstSession = SessionActor(transport: NetworkTransport(), processor: MUDProtocolPipeline())
        let secondSession = SessionActor(transport: NetworkTransport(), processor: MUDProtocolPipeline())
        let firstRecorder = SessionEventRecorder()
        let secondRecorder = SessionEventRecorder()
        let firstLine = expectation(description: "first isolated line")
        let secondLine = expectation(description: "second isolated line")
        let firstDisconnected = expectation(description: "first isolated disconnect")
        let secondDisconnected = expectation(description: "second isolated disconnect")

        let firstEvents = await firstSession.events()
        let secondEvents = await secondSession.events()
        let firstEventTask = Task {
            for await event in firstEvents {
                await firstRecorder.append(event)
                if case let .renderedLine(line) = event, line.text == "alpha" { firstLine.fulfill() }
                if case .state(.disconnected) = event { firstDisconnected.fulfill(); return }
            }
        }
        let secondEventTask = Task {
            for await event in secondEvents {
                await secondRecorder.append(event)
                if case let .renderedLine(line) = event, line.text == "beta" { secondLine.fulfill() }
                if case .state(.disconnected) = event { secondDisconnected.fulfill(); return }
            }
        }
        defer {
            firstEventTask.cancel()
            secondEventTask.cancel()
        }

        await firstSession.connect(.init(server: .init(name: "first", host: "127.0.0.1", port: firstPort)))
        await secondSession.connect(.init(server: .init(name: "second", host: "127.0.0.1", port: secondPort)))
        let firstScript = MUServerScript(actions: [
            .init(send: "alpha\n", chunks: [1, 2, 3]),
            .init(expect: "one\r\n"),
            .init(disconnect: true),
        ])
        let secondScript = MUServerScript(actions: [
            .init(send: "beta\n", chunks: [2, 1, 2]),
            .init(expect: "two\r\n"),
            .init(disconnect: true),
        ])
        let firstScriptTask = Task { try await firstServer.run(firstScript) }
        let secondScriptTask = Task { try await secondServer.run(secondScript) }

        await fulfillment(of: [firstLine, secondLine], timeout: 3)
        await firstSession.send("one")
        await secondSession.send("two")
        await fulfillment(of: [firstDisconnected, secondDisconnected], timeout: 3)
        try await firstScriptTask.value
        try await secondScriptTask.value

        let firstLines = await firstRecorder.renderedLines()
        let secondLines = await secondRecorder.renderedLines()
        XCTAssertEqual(firstLines.map(\.text), ["alpha"])
        XCTAssertEqual(secondLines.map(\.text), ["beta"])
        XCTAssertFalse(firstLines.contains { $0.text == "beta" })
        XCTAssertFalse(secondLines.contains { $0.text == "alpha" })
    }

    func testScriptedServerRoutesFragmentedWebViewAndMediaGMCPIntoPortableStates() async throws {
        func gmcpAction(package: String, payload: String) -> MUServerAction {
            let data = Data([255, 250, 201]) + Data("\(package) \(payload)".utf8) + Data([255, 240])
            return .init(
                sendHex: data.map { String(format: "%02x", $0) }.joined(),
                chunks: [1, 2, data.count - 3]
            )
        }

        let server = try ScriptedMUServer()
        let port = try await server.start()
        defer { server.stop() }
        let session = SessionActor(transport: NetworkTransport(), processor: MUDProtocolPipeline())
        let recorder = SessionEventRecorder()
        let messages = expectation(description: "fragmented WebView and media GMCP")
        messages.expectedFulfillmentCount = 3
        let disconnected = expectation(description: "fragmented GMCP disconnect")
        let stream = await session.events()
        let eventTask = Task {
            for await event in stream {
                await recorder.append(event)
                if case .gmcp = event { messages.fulfill() }
                if case .state(.disconnected) = event { disconnected.fulfill(); return }
            }
        }
        defer { eventTask.cancel() }

        await session.connect(.init(server: .init(name: "gmcp", host: "127.0.0.1", port: port)))
        let script = MUServerScript(actions: [
            gmcpAction(
                package: "WebView.Open",
                payload: #"{"id":"status","source":"<b>Ready</b>","dock":"right"}"#
            ),
            gmcpAction(
                package: "Client.Media.Default",
                payload: #"{"url":"https://media.example/base/"}"#
            ),
            gmcpAction(
                package: "Client.Media.Play",
                payload: #"{"name":"theme.ogg","volume":75}"#
            ),
            .init(disconnect: true),
        ])
        let scriptTask = Task { try await server.run(script) }
        await fulfillment(of: [messages, disconnected], timeout: 3)
        try await scriptTask.value

        let received = await recorder.gmcpMessages()
        XCTAssertEqual(received.map(\.package), ["WebView.Open", "Client.Media.Default", "Client.Media.Play"])
        var webView = WebViewProtocolState()
        guard case let .open(request) = try webView.consume(received[0]) else {
            return XCTFail("missing WebView open")
        }
        XCTAssertEqual(request.id, "status")
        XCTAssertEqual(request.source, "<b>Ready</b>")
        XCTAssertEqual(request.dock, .right)
        var media = ClientMediaState()
        XCTAssertTrue(try media.consume(received[1]).isEmpty)
        guard case let .play(item) = try media.consume(received[2]).first else {
            return XCTFail("missing Client.Media play")
        }
        XCTAssertEqual(item.source.absoluteString, "https://media.example/base/theme.ogg")
        XCTAssertEqual(item.volume, 0.75, accuracy: 0.0001)
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

        let notices = await recorder.connectionNotices()
        XCTAssertTrue(notices.contains(.lookingUp(host: "127.0.0.1", port: port)), "\(notices)")
        XCTAssertTrue(notices.contains(.connecting(host: "127.0.0.1", port: port)), "\(notices)")
        XCTAssertTrue(notices.contains(.connected), "\(notices)")

        let statistics = await session.statistics()
        XCTAssertEqual(statistics.connectionCount, 1)
        XCTAssertGreaterThanOrEqual(statistics.bytesReceived, UInt64(18))
        XCTAssertGreaterThanOrEqual(statistics.bytesSent, UInt64(27))
    }

    func testCharacterIdleActionWaitsForIdlePeriodAfterActivity() async throws {
        let server = try FakeTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let session = SessionActor(transport: NetworkTransport(), processor: MUDProtocolPipeline())
        let character = CharacterProfile(name: "Idle", idleTimeout: 0.25, idleText: "IDLE")

        await session.connect(.init(
            server: .init(name: "idle", host: "127.0.0.1", port: port),
            character: character,
            policy: .init(connectTimeoutMilliseconds: 1_000, retryCount: 1, keepAlive: false, noDelay: false)
        ))
        let peer = try await server.nextConnection()
        try await Task.sleep(for: .milliseconds(150))
        await session.send("look")
        let command = try await peer.receive(atLeast: 6)
        XCTAssertEqual(command, Data("look\r\n".utf8))

        try await Task.sleep(for: .milliseconds(150))
        var receivedIdleTooEarly = false
        do {
            _ = try await peer.receive(atLeast: 6, timeout: 0.05)
            receivedIdleTooEarly = true
        } catch { }
        XCTAssertFalse(receivedIdleTooEarly)

        let idle = try await peer.receive(atLeast: 6)
        XCTAssertEqual(idle, Data("IDLE\r\n".utf8))
        await session.disconnect()
    }

    func testHeadlessSessionLocalEchoCanBeToggled() async throws {
        let server = try FakeTCPServer()
        let port = try await server.start()
        defer { server.stop() }
        let session = SessionActor(
            transport: NetworkTransport(),
            processor: MUDProtocolPipeline(),
            localEcho: true
        )
        let stream = await session.events()
        let recorder = SessionEventRecorder()
        let echoed = expectation(description: "headless local echo")
        let task = Task {
            for await event in stream {
                await recorder.append(event)
                if case let .renderedLine(line) = event, line.source == .localEcho { echoed.fulfill() }
            }
        }
        defer { task.cancel() }

        await session.connect(.init(server: .init(name: "echo", host: "127.0.0.1", port: port)))
        let peer = try await server.nextConnection()
        await session.configureLocalEcho(true, color: .init(red: 0x12, green: 0x34, blue: 0x56))
        await session.send("look")
        let lookPayload = try await peer.receive(atLeast: 6)
        XCTAssertEqual(lookPayload, Data("look\r\n".utf8))
        await fulfillment(of: [echoed], timeout: 3)
        let lines = await recorder.renderedLines()
        XCTAssertEqual(lines.last?.text, "look")
        XCTAssertEqual(lines.last?.source, .localEcho)
        XCTAssertEqual(lines.last?.runs.first?.style.foreground, .init(red: 0x12, green: 0x34, blue: 0x56))

        await session.configureLocalEcho(false)
        await session.send("quiet")
        let quietPayload = try await peer.receive(atLeast: 7)
        XCTAssertEqual(quietPayload, Data("quiet\r\n".utf8))
        try await Task.sleep(for: .milliseconds(20))
        let finalLines = await recorder.renderedLines()
        XCTAssertEqual(finalLines.filter { $0.source == .localEcho }.count, 1)
        await session.disconnect()
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

    func connectionNotices() -> [ConnectionNotice] {
        recorded.compactMap {
            guard case let .notice(notice) = $0 else { return nil }
            return notice
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

    func gmcpMessages() -> [GMCPMessage] {
        events.compactMap {
            guard case let .gmcp(message) = $0 else { return nil }
            return message
        }
    }

    func states() -> [ConnectionState] {
        events.compactMap {
            guard case let .state(state) = $0 else { return nil }
            return state
        }
    }

    func connectionNotices() -> [ConnectionNotice] {
        events.compactMap {
            guard case let .connectionNotice(notice) = $0 else { return nil }
            return notice
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
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("BeipMU-TLS-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? fileManager.removeItem(at: directory) }

    let key = directory.appendingPathComponent("key.pem")
    let certificate = directory.appendingPathComponent("certificate.pem")
    let bundle = directory.appendingPathComponent("identity.p12")
    let passphrase = UUID().uuidString
    let openssl = try testOpenSSLExecutable()

    try runOpenSSL(openssl, arguments: [
        "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", key.path,
        "-out", certificate.path,
        "-days", "1",
        "-subj", "/CN=localhost",
    ])
    try runOpenSSL(openssl, arguments: [
        "pkcs12", "-export",
        "-out", bundle.path,
        "-inkey", key.path,
        "-in", certificate.path,
        "-passout", "pass:\(passphrase)",
        "-name", "BeipMU TLS test",
    ])

    let data = try Data(contentsOf: bundle)

    var imported: CFArray?
    let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
    guard SecPKCS12Import(data as CFData, options, &imported) == errSecSuccess,
          let item = (imported as? [[String: Any]])?.first,
          let identity = item[kSecImportItemIdentity as String] as! SecIdentity?,
          let protocolIdentity = sec_identity_create(identity)
    else { throw FakeServerError.invalidTLSIdentity }
    return protocolIdentity
}

private func testOpenSSLExecutable() throws -> URL {
    let candidates = [
        ProcessInfo.processInfo.environment["OPENSSL_BIN"],
        "/usr/bin/openssl",
        "/opt/homebrew/bin/openssl",
        "/usr/local/bin/openssl",
    ].compactMap { value -> URL? in
        guard let value, !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value)
    }

    guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
        throw FakeServerError.tlsToolUnavailable
    }
    return executable
}

private func runOpenSSL(_ executable: URL, arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let details = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        throw FakeServerError.tlsToolFailed(details ?? "exit status \(process.terminationStatus)")
    }
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

    func receive(atLeast minimumLength: Int, timeout: TimeInterval = 3) async throws -> Data {
        var result = Data()
        while result.count < minimumLength {
            result.append(try await receiveOnce(timeout: timeout))
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

    private func receiveOnce(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { gate.resume(.failure(error)) }
                else if let data, !data.isEmpty { gate.resume(.success(data)) }
                else if complete { gate.resume(.failure(FakeServerError.closed)) }
                else { gate.resume(.failure(FakeServerError.emptyRead)) }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
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
    case tlsToolFailed(String)
    case tlsToolUnavailable
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .closed: "The fake server connection closed."
        case .emptyRead: "The fake server received an empty, incomplete read."
        case .invalidTLSIdentity: "The fake server TLS identity is invalid."
        case .missingPort: "The fake server listener did not expose its assigned port."
        case let .tlsToolFailed(details): "The fake server could not generate its TLS identity: \(details)"
        case .tlsToolUnavailable: "OpenSSL is required to generate the fake server TLS identity. Set OPENSSL_BIN to its executable path."
        case let .timeout(operation): "Timed out waiting for \(operation)."
        }
    }
}
