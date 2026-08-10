import BeipCore
import BeipProtocols
import BeipTestSupport
import Foundation
import XCTest

final class ConnectionScaleTests: XCTestCase {
    func testConnectionScaleEightConcurrentScriptedSessionsReconnectWithoutContamination() async throws {
        let fixture = try JSONDecoder().decode(
            ConnectionFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        XCTAssertEqual(fixture.seed, 10_010)
        XCTAssertEqual(fixture.sessionCount, 8)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU-Scale-Connections-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let results = try await withThrowingTaskGroup(
            of: ConnectionResult.self,
            returning: [ConnectionResult].self
        ) { group in
            for specification in fixture.sessions {
                group.addTask {
                    try await Self.run(specification, logDirectory: directory)
                }
            }
            var values: [ConnectionResult] = []
            for try await value in group { values.append(value) }
            return values.sorted { $0.id < $1.id }
        }

        XCTAssertEqual(results.count, 8)
        for (index, result) in results.enumerated() {
            XCTAssertEqual(result.id, String(format: "session-%02d", index))
            XCTAssertEqual(result.connectionCount, 3)
            XCTAssertEqual(result.styledLineCount, 750)
            XCTAssertEqual(result.mediaEventCount, 6)
            XCTAssertEqual(result.webViewEventCount, 6)
            XCTAssertEqual(result.eorNegotiationCount, 3)
            XCTAssertEqual(result.gmcpNegotiationCount, 3)
            XCTAssertEqual(result.finalState, .disconnected)
            XCTAssertEqual(result.logLineCount, 768)
            XCTAssertFalse(result.lines.contains { line in
                (0..<8).contains { other in
                    other != index && line.contains("[Scale:\(other):")
                }
            })
        }
        XCTAssertEqual(results.flatMap(\.markers).count, 8 * 750)
        XCTAssertEqual(Set(results.flatMap(\.markers)).count, 8 * 250)
    }

    static func run(
        _ specification: ConnectionFixture.Session,
        logDirectory: URL
    ) async throws -> ConnectionResult {
        let server = try ScriptedMUServer()
        let port = try await server.start()
        defer { server.stop() }
        let session = SessionActor(transport: NetworkTransport(), processor: MUDProtocolPipeline())
        let recorder = ScaleSessionRecorder()
        let events = await session.events()
        let eventTask = Task {
            for await event in events { await recorder.append(event) }
        }
        defer { eventTask.cancel() }
        let script = MUServerScript(actions: specification.actions.map { action in
            var value = action
            if action.expectHex != nil {
                value.expectHex = expectedNegotiation.map {
                    String(format: "%02x", $0)
                }.joined()
            }
            // Fragmentation has dedicated parser/network coverage. This gate
            // keeps all 250 fixture sends per connection while avoiding tens
            // of thousands of Network.framework completion round-trips.
            value.chunks = nil
            return value
        })
        let expectedLinesPerConnection = 256

        for attempt in 0...specification.reconnects {
            let baseline = await recorder.lineCount()
            let scriptTask = Task { try await server.run(script) }
            await session.connect(.init(server: .init(
                name: "\(specification.id)-\(attempt)",
                host: "127.0.0.1",
                port: port,
                forceIPv4: true
            )))
            try await eventually("styled traffic for \(specification.id) reconnect \(attempt)") {
                await recorder.lineCount() >= baseline + expectedLinesPerConnection
            }
            await session.send("quit-\(specification.id.suffix(1))")
            try await scriptTask.value
            try await eventually("disconnect for \(specification.id) reconnect \(attempt)") {
                await recorder.lastState() == .disconnected
            }
        }

        let lines = await recorder.lines()
        let sent = await recorder.sentBytes()
        let renderedLog = lines.map(\.text).joined(separator: "\n") + "\n"
        let logURL = logDirectory.appendingPathComponent("\(specification.logStem).log")
        try renderedLog.write(to: logURL, atomically: true, encoding: .utf8)
        let reloadedLog = try String(contentsOf: logURL, encoding: .utf8)
        let markers = lines.compactMap { line -> String? in
            let text = line.text
            guard text.contains("styled payload"),
                  let close = text.firstIndex(of: "]") else { return nil }
            return String(text[...close])
        }
        let statistics = await session.statistics()
        return .init(
            id: specification.id,
            connectionCount: statistics.connectionCount,
            styledLineCount: lines.count { $0.text.contains("styled payload") },
            mediaEventCount: lines.count { $0.text.hasPrefix("Client.Media.Play ") },
            webViewEventCount: lines.count { $0.text.hasPrefix("WebView.Open ") },
            eorNegotiationCount: sent.nonoverlappingCount(of: Data([255, 253, 25])),
            gmcpNegotiationCount: sent.nonoverlappingCount(of: Data([255, 253, 201])),
            finalState: await recorder.lastState(),
            logLineCount: reloadedLog.split(separator: "\n").count,
            lines: lines.map(\.text),
            markers: markers
        )
    }

    static var expectedNegotiation: Data {
        func gmcp(_ value: String) -> Data {
            Data([255, 250, 201]) + Data(value.utf8) + Data([255, 240])
        }
        return Data([255, 253, 25, 255, 253, 201])
            + gmcp(#"Core.Hello {"client":"Beip", "version":"331"}"#)
            + gmcp(#"Core.Supports.Set [ "WebView 1", "Beip.Stats 1", "Beip.Tilemap 1", "Beip.Id 1", "Client.Media 1" ]"#)
    }

    var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Scale/concurrent-connections.json")
    }
}

struct ConnectionFixture: Decodable {
    struct Session: Decodable, Sendable {
        var id: String
        var reconnects: Int
        var logStem: String
        var actions: [MUServerAction]
    }

    var seed: Int
    var sessionCount: Int
    var sessions: [Session]
}

struct ConnectionResult: Sendable {
    var id: String
    var connectionCount: UInt64
    var styledLineCount: Int
    var mediaEventCount: Int
    var webViewEventCount: Int
    var eorNegotiationCount: Int
    var gmcpNegotiationCount: Int
    var finalState: ConnectionState?
    var logLineCount: Int
    var lines: [String]
    var markers: [String]
}

actor ScaleSessionRecorder {
    private var recordedLines: [RenderedLine] = []
    private var sent = Data()
    private var state: ConnectionState?

    func append(_ event: SessionEvent) {
        switch event {
        case let .renderedLine(line): recordedLines.append(line)
        case let .sent(data): sent.append(data)
        case let .state(value): state = value
        default: break
        }
    }

    func lineCount() -> Int { recordedLines.count }
    func lines() -> [RenderedLine] { recordedLines }
    func sentBytes() -> Data { sent }
    func lastState() -> ConnectionState? { state }
}

extension Data {
    func nonoverlappingCount(of needle: Data) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = startIndex..<endIndex
        while let range = range(of: needle, in: search) {
            count += 1
            search = range.upperBound..<endIndex
        }
        return count
    }
}
