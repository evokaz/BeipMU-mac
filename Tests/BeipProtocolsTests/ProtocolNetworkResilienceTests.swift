import BeipCore
import BeipProtocols
import BeipTestSupport
import Foundation
import XCTest

final class ProtocolNetworkResilienceTests: XCTestCase {
    func testMalformedAndOversizedProtocolInputsAreBoundedAndRecoveryContinues() throws {
        var telnet = TelnetParser()
        let oversizedLine = Data(repeating: 65, count: TelnetParser.maximumLineBytes + 1)
            + Data("\nrecovered\n".utf8)
        let lineEvents = telnet.consume(oversizedLine)
        XCTAssertTrue(lineEvents.contains {
            guard case let .diagnostic(message) = $0 else { return false }
            return message.contains("line exceeded")
        })
        XCTAssertEqual(lineEvents.compactMap {
            guard case let .line(data) = $0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        }, ["recovered"])

        telnet.reset()
        let oversizedGMCP = Data([255, 250, 201])
            + Data(repeating: 66, count: TelnetParser.maximumSubnegotiationBytes + 1)
            + Data([255, 240])
            + Data("still usable\n".utf8)
        let gmcpEvents = telnet.consume(oversizedGMCP)
        XCTAssertTrue(gmcpEvents.contains {
            guard case let .diagnostic(message) = $0 else { return false }
            return message.contains("subnegotiation exceeded")
        })
        XCTAssertFalse(gmcpEvents.contains {
            if case .gmcp = $0 { return true }
            return false
        })
        XCTAssertEqual(gmcpEvents.compactMap {
            guard case let .line(data) = $0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        }, ["still usable"])

        var mcp = MCPParser(authenticationKey: "m9-key")
        _ = mcp.consume("#$#mcp version: 2.1 to: 2.1")
        for index in 0..<MCPParser.maximumPendingMessages {
            XCTAssertTrue(mcp.consume(
                "#$#dns-org-mud-moo-simpleedit m9-key content*: \"\" _data-tag: tag\(index)"
            ).isEmpty)
        }
        let overflow = mcp.consume(
            "#$#dns-org-mud-moo-simpleedit m9-key content*: \"\" _data-tag: overflow"
        )
        XCTAssertTrue(overflow.contains {
            guard case let .diagnostic(message) = $0 else { return false }
            return message.contains("too many pending")
        })
        mcp.reset()
        _ = mcp.consume("#$#mcp version: 2.1 to: 2.1")
        XCTAssertTrue(mcp.consume(
            "#$#dns-org-mud-moo-simpleedit m9-key content*: \"\" _data-tag: large"
        ).isEmpty)
        let multilineOverflow = mcp.consume(
            "#$#* large content: " + String(repeating: "x", count: MCPParser.maximumMultilineBytes)
        )
        XCTAssertTrue(multilineOverflow.contains {
            guard case let .diagnostic(message) = $0 else { return false }
            return message.contains("multiline message exceeded")
        })
        mcp.reset()
        XCTAssertTrue(mcp.consume("ordinary after reset").contains(.display("ordinary after reset")))
    }

    func testDisconnectAtEveryProtocolBoundaryThenReconnectsCleanly() async throws {
        struct Boundary {
            var name: String
            var payload: Data
        }

        let malformedWebView = Self.gmcp(
            package: "WebView.Open",
            payload: #"{"id":"broken","url":"#
        )
        let malformedMedia = Self.gmcp(
            package: "Client.Media.Play",
            payload: #"{"name":"broken.ogg""#
        )
        let boundaries = [
            Boundary(name: "telnet", payload: Data([255])),
            Boundary(name: "ansi", payload: Data("\u{1b}[38;2;255".utf8)),
            Boundary(
                name: "pueblo",
                payload: Data("This world is Pueblo 2.50\n</xch_mudtext>\n<A XCH_CMD='look'\n".utf8)
            ),
            Boundary(
                name: "mcp",
                payload: Data(
                    """
                    #$#mcp version: 2.1 to: 2.1
                    #$#dns-org-mud-moo-simpleedit m9-key content*: "" _data-tag: pending
                    #$#* pending content: partial
                    """.utf8
                )
            ),
            Boundary(name: "gmcp", payload: Data([255, 250, 201]) + Data("Core.Bad {".utf8)),
            Boundary(name: "webview", payload: malformedWebView),
            Boundary(name: "client-media", payload: malformedMedia),
        ]

        let server = try ScriptedMUServer()
        let port = try await server.start()
        defer { server.stop() }
        let session = SessionActor(
            transport: NetworkTransport(),
            processor: MUDProtocolPipeline(
                mcp: true,
                mcpAuthenticationKey: "m9-key",
                pueblo: true
            )
        )
        let recorder = M9SessionRecorder()
        let stream = await session.events()
        let eventTask = Task {
            for await event in stream { await recorder.append(event) }
        }
        defer { eventTask.cancel() }
        let request = ConnectionRequest(server: .init(name: "M9 boundaries", host: "127.0.0.1", port: port))

        for boundary in boundaries {
            let connectedBefore = await recorder.connectedCount()
            let terminalBefore = await recorder.terminalCount()
            await session.connect(request)
            let boundaryTask = Task {
                try await server.run(.init(actions: [
                    .init(
                        sendHex: boundary.payload.hex,
                        chunks: Array(repeating: 1, count: boundary.payload.count)
                    ),
                    .init(disconnect: true),
                ]))
            }
            try await eventually("\(boundary.name) connect") {
                await recorder.connectedCount() == connectedBefore + 1
            }
            try await eventually("\(boundary.name) disconnect") {
                await recorder.terminalCount() == terminalBefore + 1
            }
            try await boundaryTask.value

            let recovery = "recovered-\(boundary.name)"
            let recoveryConnectedBefore = await recorder.connectedCount()
            let recoveryTerminalBefore = await recorder.terminalCount()
            await session.connect(request)
            let recoveryTask = Task {
                try await server.run(.init(actions: [
                    .init(send: recovery + "\n", chunks: [1, recovery.utf8.count]),
                    .init(expect: "probe-\(boundary.name)\r\n"),
                    .init(disconnect: true),
                ]))
            }
            try await eventually("\(boundary.name) recovery connect") {
                await recorder.connectedCount() == recoveryConnectedBefore + 1
            }
            await session.send("probe-\(boundary.name)")
            try await eventually("\(boundary.name) recovery line") {
                await recorder.containsLine(recovery)
            }
            try await eventually("\(boundary.name) recovery disconnect") {
                await recorder.terminalCount() == recoveryTerminalBefore + 1
            }
            try await recoveryTask.value
        }

        let lines = await recorder.lines()
        for boundary in boundaries {
            XCTAssertEqual(lines.filter { $0 == "recovered-\(boundary.name)" }.count, 1)
        }
        let messages = await recorder.gmcpMessages()
        let webViewMessage = try XCTUnwrap(messages.first { $0.package == "WebView.Open" })
        let mediaMessage = try XCTUnwrap(messages.first { $0.package == "Client.Media.Play" })
        var webView = WebViewProtocolState()
        var media = ClientMediaState()
        XCTAssertThrowsError(try webView.consume(webViewMessage))
        XCTAssertThrowsError(try media.consume(mediaMessage))
        let statistics = await session.statistics()
        let expectedConnectionCount = UInt64(boundaries.count * 2)
        XCTAssertEqual(statistics.connectionCount, expectedConnectionCount)
    }

    func testStallPendingReconnectAbruptLossAndDisconnectRaceRemainUsable() async throws {
        let server = try ScriptedMUServer()
        let port = try await server.start()
        defer { server.stop() }
        let session = SessionActor(transport: NetworkTransport(), processor: MUDProtocolPipeline())
        let recorder = M9SessionRecorder()
        let stream = await session.events()
        let eventTask = Task {
            for await event in stream { await recorder.append(event) }
        }
        defer { eventTask.cancel() }
        let request = ConnectionRequest(server: .init(name: "M9 lifecycle", host: "127.0.0.1", port: port))

        await session.connect(request)
        let stalledTask = Task {
            try await server.run(.init(actions: [
                .init(delayMilliseconds: 300),
                .init(send: "stale\n"),
                .init(disconnect: true),
            ]))
        }
        try await eventually("initial stalled connection") {
            await recorder.connectedCount() == 1
        }

        await session.reconnect()
        let reconnectTask = Task {
            try await server.run(.init(actions: [
                .init(send: "fresh\n", chunks: [1, 2, 3]),
                .init(expect: "ready\r\n"),
                .init(disconnect: true),
            ]))
        }
        try await eventually("pending reconnect") {
            await recorder.connectedCount() == 2
        }
        await session.send("ready")
        try await eventually("fresh response after stalled reconnect") {
            await recorder.containsLine("fresh")
        }
        try await reconnectTask.value
        _ = try? await stalledTask.value
        let linesAfterReconnect = await recorder.lines()
        XCTAssertFalse(linesAfterReconnect.contains("stale"))

        let terminalBeforeLoss = await recorder.terminalCount()
        await session.connect(request)
        let lossTask = Task {
            try await server.run(.init(actions: [
                .init(send: "before-loss\n"),
                .init(abort: true),
            ]))
        }
        try await eventually("abrupt-loss payload") {
            await recorder.containsLine("before-loss")
        }
        try await eventually("abrupt-loss terminal state") {
            await recorder.terminalCount() == terminalBeforeLoss + 1
        }
        try await lossTask.value

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await session.disconnect() }
            }
        }

        let finalConnectedBefore = await recorder.connectedCount()
        await session.connect(request)
        let finalTask = Task {
            try await server.run(.init(actions: [
                .init(send: "usable-after-races\n"),
                .init(expect: "final\r\n"),
                .init(disconnect: true),
            ]))
        }
        try await eventually("final connection") {
            await recorder.connectedCount() == finalConnectedBefore + 1
        }
        await session.send("final")
        try await eventually("final usability") {
            await recorder.containsLine("usable-after-races")
        }
        try await finalTask.value
    }

    func testConcurrentSessionSurvivesPeerSessionNetworkLossWithoutContamination() async throws {
        let failedServer = try ScriptedMUServer()
        let healthyServer = try ScriptedMUServer()
        let failedPort = try await failedServer.start()
        let healthyPort = try await healthyServer.start()
        defer {
            failedServer.stop()
            healthyServer.stop()
        }
        let failedSession = SessionActor(transport: NetworkTransport(), processor: MUDProtocolPipeline())
        let healthySession = SessionActor(transport: NetworkTransport(), processor: MUDProtocolPipeline())
        let failedRecorder = M9SessionRecorder()
        let healthyRecorder = M9SessionRecorder()
        let failedStream = await failedSession.events()
        let healthyStream = await healthySession.events()
        let failedEvents = Task {
            for await event in failedStream { await failedRecorder.append(event) }
        }
        let healthyEvents = Task {
            for await event in healthyStream { await healthyRecorder.append(event) }
        }
        defer {
            failedEvents.cancel()
            healthyEvents.cancel()
        }

        await failedSession.connect(.init(server: .init(name: "failed", host: "127.0.0.1", port: failedPort)))
        await healthySession.connect(.init(server: .init(name: "healthy", host: "127.0.0.1", port: healthyPort)))
        let failedTask = Task {
            try await failedServer.run(.init(actions: [
                .init(send: "only-failed\n"),
                .init(abort: true),
            ]))
        }
        let healthyTask = Task {
            try await healthyServer.run(.init(actions: [
                .init(send: "only-healthy\n"),
                .init(expect: "healthy-reply\r\n"),
                .init(send: "healthy-continued\n"),
                .init(disconnect: true),
            ]))
        }
        try await eventually("concurrent lines") {
            let failedReady = await failedRecorder.containsLine("only-failed")
            let healthyReady = await healthyRecorder.containsLine("only-healthy")
            return failedReady && healthyReady
        }
        await healthySession.send("healthy-reply")
        try await eventually("healthy continued after peer loss") {
            await healthyRecorder.containsLine("healthy-continued")
        }
        try await failedTask.value
        try await healthyTask.value

        let failedLines = await failedRecorder.lines()
        let healthyLines = await healthyRecorder.lines()
        XCTAssertFalse(failedLines.contains { $0.hasPrefix("only-healthy") })
        XCTAssertFalse(healthyLines.contains("only-failed"))
    }

    private static func gmcp(package: String, payload: String) -> Data {
        Data([255, 250, 201]) + Data("\(package) \(payload)".utf8) + Data([255, 240])
    }
}

private actor M9SessionRecorder {
    private var events: [SessionEvent] = []

    func append(_ event: SessionEvent) { events.append(event) }

    func connectedCount() -> Int {
        events.filter { $0 == .state(.connected) }.count
    }

    func terminalCount() -> Int {
        events.filter {
            switch $0 {
            case .state(.disconnected), .state(.failed): true
            default: false
            }
        }.count
    }

    func containsLine(_ text: String) -> Bool { lines().contains(text) }

    func lines() -> [String] {
        events.compactMap {
            guard case let .renderedLine(line) = $0 else { return nil }
            return line.text
        }
    }

    func gmcpMessages() -> [GMCPMessage] {
        events.compactMap {
            guard case let .gmcp(message) = $0 else { return nil }
            return message
        }
    }
}

private enum M9ResilienceTestError: LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case let .timeout(operation): "Timed out waiting for \(operation)"
        }
    }
}

private func eventually(
    _ operation: String,
    timeout: Duration = .seconds(3),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw M9ResilienceTestError.timeout(operation)
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
