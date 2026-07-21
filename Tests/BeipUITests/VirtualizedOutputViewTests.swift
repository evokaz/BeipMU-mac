import AppKit
import BeipCore
@testable import BeipUI
import XCTest

@MainActor
final class VirtualizedOutputViewTests: XCTestCase {
    func testLargeHistoryKeepsViewportPaintSetBounded() {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let items = (0..<10_000).map { index in
            VirtualizedOutputView.Item(
                id: UUID(),
                attributedText: NSAttributedString(string: "Line \(index)\n", attributes: attributes),
                contentRange: NSRange(location: 0, length: "Line \(index)".utf16.count),
                assets: []
            )
        }
        view.setItems(items)

        XCTAssertEqual(view.itemCount, 10_000)
        XCTAssertLessThan(view.visibleItemCount(in: NSRect(x: 0, y: 120_000, width: 800, height: 700)), 50)
    }

    func testSelectionSurvivesUnrelatedAppendAndProducesAttributedCopy() throws {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let firstID = UUID()
        view.setItems([
            .init(
                id: firstID,
                attributedText: NSAttributedString(string: "Hello world\n"),
                contentRange: NSRange(location: 0, length: 11),
                assets: []
            ),
        ])
        XCTAssertTrue(view.select(itemID: firstID, range: NSRange(location: 6, length: 5)))
        view.append(.init(
            id: UUID(),
            attributedText: NSAttributedString(string: "Next\n"),
            contentRange: NSRange(location: 0, length: 4),
            assets: []
        ))

        XCTAssertEqual(view.selectedString(), "world")
        XCTAssertEqual(try XCTUnwrap(view.selectedAttributedString()).length, 5)
    }

    func testMarkerStateUsesStableLineIdentity() {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let id = UUID()
        view.setItems([.init(
            id: id,
            attributedText: NSAttributedString(string: "Marked\n"),
            contentRange: NSRange(location: 0, length: 6),
            assets: []
        )])
        view.toggleMarker(itemID: id)
        XCTAssertTrue(view.isMarked(itemID: id))
        view.toggleMarker(itemID: id)
        XCTAssertFalse(view.isMarked(itemID: id))
    }

    func testSelectionAndIdentityMapSurvivePrefixCompaction() {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let items = (0..<2_200).map { index in
            VirtualizedOutputView.Item(
                id: UUID(),
                attributedText: NSAttributedString(string: "\(index)\n"),
                contentRange: NSRange(location: 0, length: String(index).utf16.count),
                assets: []
            )
        }
        view.setItems(items)
        XCTAssertTrue(view.select(itemID: items[1_500].id, range: NSRange(location: 0, length: 4)))

        view.removeFirst(1_200)

        XCTAssertEqual(view.itemCount, 1_000)
        XCTAssertEqual(view.selectedString(), "1500")
        XCTAssertTrue(view.select(itemID: items[2_199].id, range: NSRange(location: 0, length: 4)))
        XCTAssertEqual(view.selectedString(), "2199")
    }

    func testEditWindowCaptureTakesNewestLinesAndSkipsTail() {
        let output = OutputTextView()
        (1...6).forEach { output.append(.init(text: "line \($0)")) }
        XCTAssertEqual(output.capturedText(lineCount: 3, skipping: 1), "line 3\nline 4\nline 5\n")
        XCTAssertEqual(output.capturedText(lineCount: 20, skipping: 5), "line 1\n")
        XCTAssertEqual(output.capturedText(lineCount: 3, skipping: 99), "")
    }

    func testSessionLogWriterAppendsHistoryLiveTextAndStopMarker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLogWriterTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("session.html")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try SessionLogWriter(
            url: url,
            options: .init(logsSentText: true, logsTypedText: true),
            title: "Test Session",
            foregroundHex: "#FFFFFF",
            backgroundHex: "#000000",
            history: [.init(text: "history <line>")]
        )
        try writer.append(.init(text: "live line"))
        try writer.appendTyped("look")
        try writer.appendSent("north")
        try writer.stop()

        let result = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(result.contains("Logging started"))
        XCTAssertTrue(result.contains("history &lt;line&gt;"))
        XCTAssertTrue(result.contains("live line"))
        XCTAssertTrue(result.contains("Typed&gt;look"))
        XCTAssertTrue(result.contains("Sent&gt;north"))
        XCTAssertTrue(result.contains("Logging stopped"))
    }
}
