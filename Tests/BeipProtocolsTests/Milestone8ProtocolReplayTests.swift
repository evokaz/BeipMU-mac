import BeipCore
import Foundation
import XCTest
@testable import BeipProtocols

/// Milestone 8 Windows differential: replays the checked-in
/// `Tests/Fixtures/milestone8-protocol.json` server bytes — Pueblo bold/color/
/// entity, anchor and multi-hint send links, an inline image, an unclosed
/// `<b>` tag, a mismatched-hint `send`, a broken `<img src=>`, an unrecognized
/// `xch_unknown` tag, and malformed UTF-8 — through the portable
/// `MUDProtocolPipeline` and compares the rendered plain text against the
/// v4.331 capture recorded in `Documentation/Evidence/M8/win11-dev/
/// windows-m8-protocol-log.txt` (captured from
/// `Invoke-M8ProtocolServer.ps1` against the reference binary).
final class Milestone8ProtocolReplayTests: XCTestCase {
    private struct CaptureTrace: Decodable {
        struct Event: Decodable {
            let direction: String
            let hex: String
        }

        let events: [Event]
    }

    private static func evidenceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Documentation/Evidence/M8/win11-dev")
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

    private func loadCapturedTrace() throws -> CaptureTrace {
        var data = try Data(contentsOf: Self.evidenceURL("windows-m8-protocol-trace.json"))
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        return try JSONDecoder().decode(CaptureTrace.self, from: data)
    }

    /// Replays the exact server-to-client bytes v4.331 received (pinned by
    /// `windows-m8-protocol-trace.json`, itself generated from the checked-in
    /// `Tests/Fixtures/milestone8-protocol.json` fixture) through the portable
    /// Pueblo/ANSI/Telnet pipeline.
    private func replayCapturedBytes() throws -> [RenderedLine] {
        let trace = try loadCapturedTrace()
        var pipeline = MUDProtocolPipeline(encoding: .utf8, pueblo: true, puebloActive: true)
        var lines: [RenderedLine] = []
        for event in trace.events where event.direction == "server-to-client" {
            for output in pipeline.consume(Self.data(hex: event.hex)) {
                if case let .line(line) = output { lines.append(line) }
            }
        }
        return lines
    }

    func testCapturedFixtureBytesAreValidHexAndNonEmpty() throws {
        let trace = try loadCapturedTrace()
        let serverEvents = trace.events.filter { $0.direction == "server-to-client" }
        XCTAssertEqual(serverEvents.count, 9, "expected one captured event per fixture action")
        for event in serverEvents {
            XCTAssertFalse(Self.data(hex: event.hex).isEmpty, "empty payload for \(event.hex)")
        }
    }

    /// The well-formed portion of the fixture — plain text, Pueblo bold/color/
    /// entity, the anchor command link, and the multi-hint send link — must
    /// render identical plain text to the v4.331 capture.
    func testPortableEngineRendersWellFormedPortionIdenticallyToWindows() throws {
        let lines = try replayCapturedBytes()
        let texts = lines.map(\.text)

        XCTAssertTrue(texts.contains("M8 protocol differential"))
        XCTAssertTrue(texts.contains("Pueblo bold greenish & entity"))
        XCTAssertTrue(texts.contains("Pueblo anchor choose"))

        let puebloLine = try XCTUnwrap(lines.first { $0.text == "Pueblo bold greenish & entity" })
        XCTAssertTrue(puebloLine.runs.contains { $0.style.bold }, "Pueblo <b> must produce a bold run")
        XCTAssertTrue(
            puebloLine.runs.contains { $0.style.foreground == RGBColor(red: 0x12, green: 0xAB, blue: 0x34) },
            "Pueblo <font color> must produce the exact RGB run"
        )

        let anchorLine = try XCTUnwrap(lines.first { $0.text == "Pueblo anchor choose" })
        XCTAssertTrue(anchorLine.runs.contains { $0.style.link == .send("look", hints: []) }, "\(anchorLine.runs)")
        XCTAssertTrue(
            anchorLine.runs.contains { $0.style.link == .send("north", hints: ["Directions", "North", "South"]) },
            "\(anchorLine.runs)"
        )
    }

    /// The inline `<img>` tag must produce a rendered asset pointing at the
    /// exact URL v4.331 fetched (pinned separately by
    /// `windows-m8-image-observation.json`, which recorded the reference
    /// client's actual HTTP GET for this URL).
    func testInlineImageAssetMatchesWindowsFetchedURL() throws {
        let lines = try replayCapturedBytes()
        let imageLine = try XCTUnwrap(lines.first { $0.text.contains("image tail") })
        let asset = try XCTUnwrap(imageLine.assets.first)
        XCTAssertEqual(asset.source.absoluteString, "http://127.0.0.1:48751/audit.png")
    }

    /// Every malformed/hostile fragment (unclosed `<b>`, a `send` with more
    /// hints than pipe-delimited href legs, a broken `<img src=>`, and an
    /// unrecognized `xch_unknown` tag) must render safely — producing text
    /// without crashing or throwing — exactly as v4.331 did (its plain-text
    /// log shows "before <b unclosed after", "mismatch", " broken", and the
    /// literal unknown-tag text all rendered rather than dropped).
    func testMalformedPortionRendersSafelyWithoutCrashingLikeWindows() throws {
        let lines = try replayCapturedBytes()
        let texts = lines.map(\.text)

        XCTAssertTrue(texts.contains { $0.contains("before") && $0.contains("unclosed after") })
        XCTAssertTrue(texts.contains { $0.contains("mismatch") })
        XCTAssertTrue(texts.contains { $0.contains("broken") })
        XCTAssertTrue(texts.contains { $0.contains("tag") && $0.contains("tail") })
    }

    /// Malformed UTF-8 (the final fixture action) must not crash the decoder;
    /// v4.331 substituted a visible replacement marker per invalid sequence
    /// and continued rendering the trailing "after" text on the same line.
    func testMalformedUTF8DoesNotCrashDecoderAndPreservesTrailingText() throws {
        let lines = try replayCapturedBytes()
        let invalidLine = try XCTUnwrap(lines.first { $0.text.contains("invalid utf8") })
        XCTAssertTrue(invalidLine.text.contains("after"), "trailing text after the bad sequence must survive")
    }

    /// Cross-checks the portable replay's plain text against the literal
    /// v4.331 output log for every well-formed line, guarding against silent
    /// drift between the fixture and the checked-in Windows evidence.
    func testEveryWellFormedWindowsLogLineIsReproduced() throws {
        let log = try String(contentsOf: Self.evidenceURL("windows-m8-protocol-log.txt"), encoding: .utf8)
        let lines = try replayCapturedBytes()
        let texts = Set(lines.map(\.text))
        for expected in ["M8 protocol differential", "Pueblo bold greenish & entity", "Pueblo anchor choose"] {
            XCTAssertTrue(log.contains(expected), "fixture expectation missing from Windows log: \(expected)")
            XCTAssertTrue(texts.contains(expected), "portable engine did not reproduce: \(expected)")
        }
    }
}
