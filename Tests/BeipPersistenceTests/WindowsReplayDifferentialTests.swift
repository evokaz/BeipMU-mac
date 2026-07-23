import BeipAutomation
import BeipCore
import BeipPersistence
import BeipProtocols
import Foundation
import XCTest

/// Release-wide replay differentials against the checked-in Windows v4.331
/// golden capture in `Tests/Golden/windows-v331-replay-*`. One loopback
/// session (Scripts/windows-replay-server.ps1 plus
/// Fixtures/windows-replay-config.txt) drives rendering, trigger gag/spawn/
/// send, alias expansion, plain and HTML logging, the `/@` SetOnReceive hook,
/// and the post-session configuration save through the reference binary; these
/// tests replay the identical fixtures through the portable engines and
/// compare every layer.
final class WindowsReplayDifferentialTests: XCTestCase {
    private struct ReplayTrace: Decodable {
        struct Event: Decodable {
            let direction: String
            let label: String
            let hex: String
        }

        let endpoint: String
        let events: [Event]
    }

    private static func goldenURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Golden")
            .appendingPathComponent(name)
    }

    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private static func data(hex: String) -> Data {
        var bytes: [UInt8] = []
        var iterator = hex.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            bytes.append(UInt8(String([high, low]), radix: 16) ?? 0)
        }
        return Data(bytes)
    }

    private func loadTrace() throws -> ReplayTrace {
        var data = try Data(contentsOf: Self.goldenURL("windows-v331-replay-trace.json"))
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        return try JSONDecoder().decode(ReplayTrace.self, from: data)
    }

    private func replayServerBytes() throws -> (lines: [RenderedLine], prompts: [RenderedLine], transmissions: [Data]) {
        let trace = try loadTrace()
        var pipeline = MUDProtocolPipeline()
        var lines: [RenderedLine] = []
        var prompts: [RenderedLine] = []
        var transmissions: [Data] = []
        for event in trace.events where event.direction == "server-to-client" {
            for output in pipeline.consume(Self.data(hex: event.hex)) {
                switch output {
                case let .line(line): lines.append(line)
                case let .prompt(line): prompts.append(line)
                case let .transmit(data): transmissions.append(data)
                default: break
                }
            }
        }
        return (lines, prompts, transmissions)
    }

    private func loadReplayProjection() throws -> (document: LegacyConfigurationDocument, projection: LegacyConfigurationProjection) {
        let source = try String(contentsOf: Self.fixtureURL("windows-replay-config.txt"), encoding: .utf8)
        let document = try LegacyConfigurationDocument(source: source)
        let projection = try LegacyConfigurationProjection(document: document)
        return (document, projection)
    }

    func testReplayServerBytesRenderIdenticallyToWindowsHTMLLog() throws {
        let replay = try replayServerBytes()

        // The pending GA prompt joins the next rendered line exactly as in the
        // established golden-session replay ("Golden prompt> Golden room"); in
        // the live Windows session the interleaved typed input flushed the
        // prompt first, which the HTML log's separate "Replay prompt>" line
        // pins below.
        XCTAssertEqual(replay.lines.map(\.text), [
            "M5 replay audit server",
            "Red replay line",
            "TRIGGER-GAG: hidden line",
            "TRIGGER-SPAWN: routed spawn line",
            "TRIGGER-SEND: provoke response",
            "Replay prompt> SCRIPT-TARGET: callback line",
            "Replay complete",
        ])
        XCTAssertEqual(replay.prompts.map(\.text), ["Replay prompt> "])

        // The fragmented SGR sequence must land as one red run, matching the
        // #CD0000 span v4.331 wrote into the HTML log for the same line.
        let red = try XCTUnwrap(replay.lines.first { $0.text == "Red replay line" })
        XCTAssertEqual(red.runs.first?.style.foreground, RGBColor(red: 205, green: 0, blue: 0))

        let html = try String(contentsOf: Self.goldenURL("windows-v331-replay-log.html"), encoding: .utf8)
        XCTAssertTrue(html.contains("<span style='color:#CD0000;'>Red replay line</span>"))

        // Every non-gagged rendered line appears in the Windows HTML log in
        // the same order; the gagged line appears nowhere in either log.
        for text in ["M5 replay audit server", "TRIGGER-SPAWN: routed spawn line", "SCRIPT-TARGET: callback line", "Replay complete"] {
            XCTAssertTrue(html.contains(">\(text) </span>"), "missing from Windows HTML log: \(text)")
        }
        XCTAssertFalse(html.contains("TRIGGER-GAG"))
        let plain = try String(contentsOf: Self.goldenURL("windows-v331-replay-log.txt"), encoding: .utf8)
        XCTAssertFalse(plain.contains("TRIGGER-GAG"))
    }

    func testReplayAutomationMatchesWindowsWireBytes() async throws {
        let loaded = try loadReplayProjection()
        let server = try XCTUnwrap(loaded.projection.servers.first)
        XCTAssertEqual(server.profile.name, "M5 Replay")
        XCTAssertEqual(server.profile.host, "127.0.0.1")
        XCTAssertEqual(server.profile.port, 48_740)
        let character = try XCTUnwrap(server.characters.first)
        XCTAssertEqual(character.name, "Audit")
        XCTAssertTrue(character.autoConnect)

        let groups = loaded.projection.automationGroups(for: server.profile, character: character)
        let replay = try replayServerBytes()
        let engine = TriggerEngine()

        var sends: [String] = []
        var sawGag = false
        var sawLogGag = false
        var spawnTitles: [String] = []
        for line in replay.lines {
            let effects = try await engine.process(line, groups: groups.triggers, variables: [:])
            for effect in effects {
                switch effect {
                case let .send(text): sends.append(text)
                case .gagDisplay: sawGag = true
                case .gagLog: sawLogGag = true
                case let .spawn(action, spawnLine, _):
                    spawnTitles.append(action.title)
                    XCTAssertEqual(spawnLine.text, "TRIGGER-SPAWN: routed spawn line")
                    XCTAssertTrue(action.showTab)
                    XCTAssertTrue(action.copy)
                default: break
                }
            }
        }

        XCTAssertTrue(sawGag, "gag trigger must hide the display line")
        XCTAssertTrue(sawLogGag, "Gag.Log=true must gag the log copy as well")
        XCTAssertEqual(spawnTitles, ["Replay Spawn"])
        XCTAssertEqual(sends, ["pose responds deterministically"])

        let alias = try AliasEngine.process("hail", groups: groups.aliases, variables: [:])
        XCTAssertEqual(alias.text, "say Hail, adventurer!")

        // The reference wire trace must contain exactly the trigger send and
        // the alias expansion, in that order, and nothing else.
        let trace = try loadTrace()
        let clientBytes = trace.events
            .filter { $0.direction == "client-to-server" }
            .map { Self.data(hex: $0.hex) }
            .reduce(Data(), +)
        let expected = Data("pose responds deterministically\r\nsay Hail, adventurer!\r\n".utf8)
        XCTAssertEqual(clientBytes, expected)
        XCTAssertEqual(clientBytes.count, 56)
    }

    func testReplayLogsMatchWindowsGoldensAfterNormalization() throws {
        let plain = try String(contentsOf: Self.goldenURL("windows-v331-replay-log.txt"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let plainBody = plain
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.hasPrefix("*") && !$0.hasPrefix("-") && !$0.hasPrefix("Logging ") }
        // `/log` starts "from now": the earlier session lines stay excluded.
        XCTAssertEqual(plainBody, [
            "T>hail",
            "S>say Hail, adventurer!",
            "SCRIPT-HOOK: SCRIPT-TARGET: callback line",
            "SCRIPT-TARGET: callback line",
            "SCRIPT-HOOK: Replay complete",
            "Replay complete",
        ])

        let html = try String(contentsOf: Self.goldenURL("windows-v331-replay-log.html"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let htmlBody = html
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                guard let start = line.range(of: "<span class='line'>") else { return nil }
                let tail = line[start.upperBound...]
                let text = tail
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&amp;", with: "&")
                return text.trimmingCharacters(in: .whitespaces)
            }
        // The character autolog runs from connect, so it also carries the
        // pre-`/log` session lines; the trigger send is logged typed+sent.
        XCTAssertEqual(htmlBody, [
            "M5 replay audit server",
            "Red replay line",
            "TRIGGER-SPAWN: routed spawn line",
            "T>pose responds deterministically",
            "S>pose responds deterministically",
            "TRIGGER-SEND: provoke response",
            "Replay prompt>",
            "T>hail",
            "S>say Hail, adventurer!",
            "SCRIPT-HOOK: SCRIPT-TARGET: callback line",
            "SCRIPT-TARGET: callback line",
            "SCRIPT-HOOK: Replay complete",
            "Replay complete",
        ])

        // The portable renderer produces the same typed/sent bodies with the
        // projected Windows prefixes and no timestamps (TimeFormat=0).
        var options = SessionLogOptions()
        options.logsTypedText = true
        options.typedPrefix = "T>"
        options.logsSentText = true
        options.sentPrefix = "S>"
        options.includesTime = false
        options.includesDate = false
        let renderer = SessionLogRenderer(format: .plainText, options: options, title: "Audit - M5 Replay")
        XCTAssertEqual(renderer.typed("hail").trimmingCharacters(in: .whitespacesAndNewlines), "T>hail")
        XCTAssertEqual(
            renderer.sent("say Hail, adventurer!").trimmingCharacters(in: .whitespacesAndNewlines),
            "S>say Hail, adventurer!"
        )

        let replay = try replayServerBytes()
        let closing = try XCTUnwrap(replay.lines.first { $0.text == "Replay complete" })
        XCTAssertEqual(
            renderer.line(closing).trimmingCharacters(in: .whitespacesAndNewlines),
            "Replay complete"
        )
    }

    func testReplayPostSessionConfigurationRoundTripsAndPinsMutations() throws {
        let url = Self.goldenURL("windows-v331-replay-Config.txt")
        let source = try String(contentsOf: url, encoding: .utf8)
        let document = try LegacyConfigurationDocument(source: source)
        XCTAssertEqual(document.serialized(), source)

        // v4.331 re-emitted the dotted Logging keys as a block, preserved the
        // escaped log path, and recorded the session statistics; BytesSent
        // must equal the exact client-to-server payload in the wire trace.
        XCTAssertEqual(document.value(at: ["Connections", "Logging", "SentPrefix"]), "S>")
        XCTAssertEqual(document.value(at: ["Connections", "Logging", "TypedPrefix"]), "T>")
        XCTAssertEqual(
            document.value(at: ["Connections", "Shortcuts", "M5 Replay", "Characters", "Audit", "LogFileName"]),
            "C:\\M5Audit\\Logs\\replay.html"
        )
        XCTAssertEqual(
            document.value(at: ["Connections", "Shortcuts", "M5 Replay", "Characters", "Audit", "BytesSent"]),
            "56"
        )
        XCTAssertEqual(
            document.value(at: ["Connections", "Shortcuts", "M5 Replay", "Characters", "Audit", "ConnectionCount"]),
            "1"
        )

        let projection = try LegacyConfigurationProjection(document: document)
        let server = try XCTUnwrap(projection.servers.first)
        XCTAssertEqual(server.profile.name, "M5 Replay")
        XCTAssertEqual(server.characters.first?.name, "Audit")
        XCTAssertEqual(server.restoreLogAssignments[0], "M5 Replay - Audit")

        let groups = projection.automationGroups(for: server.profile, character: server.characters.first)
        XCTAssertFalse(groups.aliases.isEmpty, "saved configuration must retain the replay alias")
        XCTAssertFalse(groups.triggers.isEmpty, "saved configuration must retain the replay triggers")
    }
}
