import Foundation
import XCTest
@testable import BeipCore

/// Milestone 8 Windows differential: replays the exact hostile GMCP
/// `webview.open`/`webview.close` frames v4.331 received during the
/// `Invoke-M8WebViewHostileServer.ps1` capture
/// (`windows-m8-webview-hostile-trace.json`) through the portable
/// `WebViewProtocolState`, and cross-checks the documented behavioral
/// difference from `WEBVIEW_HOSTILE.md`: v4.331 always raises its "Allow
/// WebView?" confirmation with the raw requested URL/scheme (even for
/// `javascript:`, `file:`, and `ftp:`, and without visibly bounding id/header
/// size), while the portable engine structurally rejects those cases before
/// any prompt is possible.
final class Milestone8WebViewHostileReplayTests: XCTestCase {
    private struct CaptureTrace: Decodable {
        struct Event: Decodable {
            let direction: String
            let label: String
            let ascii: String
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

    private func loadTrace() throws -> CaptureTrace {
        var data = try Data(contentsOf: Self.evidenceURL("windows-m8-webview-hostile-trace.json"))
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        return try JSONDecoder().decode(CaptureTrace.self, from: data)
    }

    /// Extracts `("webview.open", "{...json...}")` from the recorded ASCII,
    /// which is framed as `...webview.open {json}..` (the leading/trailing
    /// dots are the IAC SB GMCP / IAC SE control bytes rendered as `.` by the
    /// capture server's non-printable-byte substitution).
    private func gmcpPayload(from ascii: String) -> (package: String, payload: String)? {
        let trimmed = ascii.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let spaceIndex = trimmed.firstIndex(of: " ") else { return nil }
        let package = String(trimmed[trimmed.startIndex..<spaceIndex])
        let payload = String(trimmed[trimmed.index(after: spaceIndex)...])
        return (package, payload)
    }

    private func event(labeled label: String) throws -> (package: String, payload: String) {
        let trace = try loadTrace()
        let match = try XCTUnwrap(trace.events.first { $0.direction == "server-to-client" && $0.label == label })
        return try XCTUnwrap(gmcpPayload(from: match.ascii))
    }

    func testTraceContainsExactlyTheDocumentedFourteenWebViewFrames() throws {
        let trace = try loadTrace()
        let webViewFrames = trace.events.filter {
            $0.direction == "server-to-client" && $0.ascii.contains("webview.")
        }
        // Ten `webview.open` frames that raised the "Allow WebView?" dialog on
        // v4.331 (three unsafe schemes, two size-limit cases, redirect,
        // subframe, two update-in-place opens, and the unreachable port),
        // one `webview.open` with malformed JSON that raised no dialog, and
        // three `webview.close` frames (open id, already-closed id,
        // never-opened id).
        XCTAssertEqual(webViewFrames.count, 14)
    }

    func testUnsafeSchemesAreStructurallyRejectedByThePortableEngineUnlikeWindows() throws {
        var state = WebViewProtocolState()
        for label in ["unsafe javascript: scheme", "unsafe file: scheme", "unsafe ftp: scheme"] {
            let frame = try event(labeled: label)
            XCTAssertThrowsError(try state.consume(.init(package: frame.package, payload: frame.payload)), label) {
                guard case .invalidServerURL = $0 as? WebViewProtocolError else {
                    return XCTFail("\(label): expected invalidServerURL, got \($0)")
                }
            }
        }
    }

    /// v4.331's "Allow WebView?" dialog showed the oversized id verbatim
    /// (`windows-m8-webview-hostile-prompt-03.png`) with no visible rejection;
    /// the portable engine enforces the documented 512-byte cap and throws.
    func testOversizedIDIsRejectedByThePortableEngineUnlikeWindows() throws {
        var state = WebViewProtocolState()
        let frame = try event(labeled: "oversized id field")
        XCTAssertThrowsError(try state.consume(.init(package: frame.package, payload: frame.payload))) {
            XCTAssertEqual($0 as? WebViewProtocolError, .valueTooLarge("id"))
        }
    }

    /// v4.331 prompted normally for the oversized-headers case
    /// (`windows-m8-webview-hostile-prompt-04.png`); the portable engine
    /// enforces the documented 64-entry cap.
    func testOversizedHeadersAreRejectedByThePortableEngineUnlikeWindows() throws {
        var state = WebViewProtocolState()
        let frame = try event(labeled: "oversized headers object")
        XCTAssertThrowsError(try state.consume(.init(package: frame.package, payload: frame.payload))) {
            XCTAssertEqual($0 as? WebViewProtocolError, .valueTooLarge("http-request-headers"))
        }
    }

    /// The malformed/truncated JSON frame raised no dialog on v4.331 at all
    /// (silently discarded, per `WEBVIEW_HOSTILE.md`); the portable parser
    /// must likewise fail safely (throw, not crash) rather than accept it.
    func testMalformedJSONFailsSafelyMatchingWindowsSilentDiscard() throws {
        var state = WebViewProtocolState()
        // The captured payload's trailing bytes were truncated by the IAC SE
        // marker in the wire capture; construct the exact truncated JSON body
        // v4.331 received to prove the parser degrades safely either way.
        XCTAssertThrowsError(try state.consume(.init(package: "webview.open", payload: #"{"id":"malformed","url":"#)))
    }

    /// The redirect, subframe, and both update-in-place opens were all
    /// well-formed same-origin loopback URLs that v4.331 prompted for
    /// normally; the portable engine must accept them identically (this is
    /// the case where both engines agree).
    func testWellFormedHostileCasesAreAcceptedIdenticallyToWindows() throws {
        var state = WebViewProtocolState()
        for (label, expectedID, expectedPath) in [
            ("redirecting URL", "redirect", "/redirect"),
            ("page with subframe", "subframe", "/subframe-outer"),
            ("update-in-place: first open", "update", "/update-a"),
            ("update-in-place: reopen same id", "update", "/update-b"),
        ] {
            let frame = try event(labeled: label)
            let outcome = try state.consume(.init(package: frame.package, payload: frame.payload))
            guard case let .open(request) = outcome else { return XCTFail("\(label): expected an open event") }
            XCTAssertEqual(request.id, expectedID, label)
            XCTAssertEqual(request.url?.path, expectedPath, label)
        }
    }

    /// The unreachable-port case is a well-formed http:// URL; the portable
    /// engine accepts the open request identically to v4.331 (which
    /// prompted for it in `windows-m8-webview-hostile-prompt-09.png`) —
    /// navigation failure happens inside the WebView's own load, not at the
    /// protocol-consume layer, matching v4.331.
    func testUnreachablePortIsAcceptedAtTheProtocolLayerMatchingWindows() throws {
        var state = WebViewProtocolState()
        let frame = try event(labeled: "unreachable port (connection refused)")
        let outcome = try state.consume(.init(package: frame.package, payload: frame.payload))
        guard case let .open(request) = outcome else { return XCTFail("expected an open event") }
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:1/")
    }

    /// Closing an already-closed id and a never-opened id must both be
    /// accepted as no-ops by the portable engine, matching v4.331's silent
    /// no-dialog behavior for all three close frames in the trace.
    func testCloseOrderIsAcceptedAsANoOpMatchingWindows() throws {
        var state = WebViewProtocolState()
        for label in ["close open id", "close already-closed id", "close never-opened id"] {
            let frame = try event(labeled: label)
            let outcome = try state.consume(.init(package: frame.package, payload: frame.payload))
            guard case .close = outcome else { return XCTFail("\(label): expected a close event") }
        }
    }
}
