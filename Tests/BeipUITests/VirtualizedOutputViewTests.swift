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

    func testOutputDocumentWidthTracksNarrowScrollViewport() {
        let output = OutputTextView()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 180))
        output.containerView.frame = host.bounds
        host.addSubview(output.containerView)
        host.layoutSubtreeIfNeeded()
        output.containerView.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            output.primaryOutputViewForTesting.bounds.width,
            output.primaryScrollViewForTesting.contentView.bounds.width,
            accuracy: 0.5
        )
        XCTAssertLessThan(output.primaryOutputViewForTesting.bounds.width, 310)
    }

    func testTriggerParagraphUsesPercentageIndentsAndBorderAsContentSpacing() throws {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let text = NSAttributedString(
            string: "Some sample text.\n",
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        view.setItems([.init(
            id: UUID(),
            attributedText: text,
            contentRange: NSRange(location: 0, length: 17),
            assets: [],
            paragraph: .init(
                leftIndent: 1,
                rightIndent: 10,
                topPadding: 2,
                bottomPadding: 2,
                borderWidth: 6,
                borderStyle: .round,
                strokeWidth: 2,
                strokeColor: .white
            )
        )])

        let rendered = try XCTUnwrap(view.renderedAttributedTextForTesting(at: 0))
        let paragraph = try XCTUnwrap(rendered.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.firstLineHeadIndent, 10, accuracy: 0.1)
        XCTAssertEqual(paragraph.tailIndent, -46, accuracy: 0.1)
        XCTAssertEqual(paragraph.paragraphSpacingBefore, 0, accuracy: 0.1)
        XCTAssertEqual(paragraph.paragraphSpacing, 0, accuracy: 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(view.measuredHeightForTesting(at: 0)), 28)

        let decoration = try XCTUnwrap(view.decorationRectForTesting(
            at: 0,
            in: NSRect(x: 0, y: 20, width: 400, height: 30)
        ))
        XCTAssertEqual(decoration.minX, 4, accuracy: 0.1)
        XCTAssertEqual(decoration.maxX, 360, accuracy: 0.1)
        XCTAssertEqual(decoration.minY, 20, accuracy: 0.1)
        XCTAssertEqual(decoration.height, 30, accuracy: 0.1)
    }

    func testTriggerParagraphDecorationFollowsOppositeAsymmetricIndents() throws {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        view.setItems([.init(
            id: UUID(),
            attributedText: NSAttributedString(string: "Some sample text.\n"),
            contentRange: NSRange(location: 0, length: 17),
            assets: [],
            paragraph: .init(leftIndent: 10, rightIndent: 1, borderWidth: 6, strokeWidth: 2)
        )])

        let decoration = try XCTUnwrap(view.decorationRectForTesting(
            at: 0,
            in: NSRect(x: 0, y: 0, width: 400, height: 30)
        ))
        XCTAssertEqual(decoration.minX, 40, accuracy: 0.1)
        XCTAssertEqual(decoration.maxX, 396, accuracy: 0.1)
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

    func testReduceMotionDisablesBlinkTimersAndKeepsContentVisible() {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        view.applyAccessibilityDisplayOptions(.init())
        let text = NSMutableAttributedString(string: "Blinking\n")
        text.addAttribute(
            VirtualizedOutputView.blinkAttribute,
            value: TextStyle.Blink.slow.rawValue,
            range: NSRange(location: 0, length: 8)
        )
        view.setItems([.init(
            id: UUID(),
            attributedText: text,
            contentRange: NSRange(location: 0, length: 8),
            assets: []
        )])
        XCTAssertTrue(view.isBlinkTimerActive)

        view.applyAccessibilityDisplayOptions(.init(reduceMotion: true))

        XCTAssertFalse(view.isBlinkTimerActive)
        XCTAssertFalse(view.isAnimationTimerActive)
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

    func testSplitKeepsUpperScrollbackStationaryWhileLowerOutputFollowsNewText() throws {
        let output = OutputTextView()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        output.containerView.frame = host.bounds
        host.addSubview(output.containerView)
        output.containerView.layoutSubtreeIfNeeded()

        (1...80).forEach { output.append(.init(text: "line \($0)")) }
        XCTAssertGreaterThan(output.primaryScrollViewForTesting.contentView.bounds.origin.y, 0)

        output.toggleSplit()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        output.containerView.layoutSubtreeIfNeeded()

        let upperScrollback = try XCTUnwrap(output.secondaryScrollViewForTesting)
        XCTAssertTrue(output.containerView.subviews.first === upperScrollback)
        XCTAssertEqual(upperScrollback.borderType, .lineBorder)

        let frozenOrigin = upperScrollback.contentView.bounds.origin.y
        let liveOrigin = output.primaryScrollViewForTesting.contentView.bounds.origin.y
        output.append(.init(text: "new live line"))
        output.containerView.layoutSubtreeIfNeeded()

        XCTAssertEqual(upperScrollback.contentView.bounds.origin.y, frozenOrigin, accuracy: 0.5)
        XCTAssertGreaterThan(output.primaryScrollViewForTesting.contentView.bounds.origin.y, liveOrigin)
    }

    func testPageUpAndPageDownNavigateSplitScrollbackAndCloseAtBottom() throws {
        let output = OutputTextView()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        output.containerView.frame = host.bounds
        host.addSubview(output.containerView)
        output.containerView.layoutSubtreeIfNeeded()

        (1...120).forEach { output.append(.init(text: "line \($0)")) }
        let liveBottom = output.primaryScrollViewForTesting.contentView.bounds.origin.y

        XCTAssertTrue(output.performPageUp())
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        output.containerView.layoutSubtreeIfNeeded()

        let upperScrollback = try XCTUnwrap(output.secondaryScrollViewForTesting)
        XCTAssertTrue(output.isSplit)
        let afterPageUp = upperScrollback.contentView.bounds.origin.y
        XCTAssertLessThan(afterPageUp, liveBottom)

        XCTAssertTrue(output.performPageDown())
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        output.containerView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(upperScrollback.contentView.bounds.origin.y, afterPageUp)

        for _ in 0..<20 where output.isSplit && !isAtBottom(upperScrollback) {
            XCTAssertTrue(output.performPageDown())
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(output.isSplit)
        XCTAssertTrue(isAtBottom(upperScrollback))

        XCTAssertTrue(output.performPageDown())
        XCTAssertFalse(output.isSplit)
    }

    func testTextWindowSettingsDriveFontColorsMarginsWrappingAndDates() throws {
        let output = OutputTextView()
        let settings = TextWindowSettings(
            fontName: "Menlo",
            fontSize: 17,
            foregroundHex: "#123456",
            backgroundHex: "#102030",
            webLinkHex: "#ABCDEF",
            usesFanFoldBackgrounds: true,
            fanFoldFirstHex: "#202020",
            fanFoldSecondHex: "#303030",
            historyLimit: 321,
            wrappedLineIndent: 14,
            paragraphSpacing: 5,
            usesFixedWidth: true,
            fixedWidthCharacters: 40,
            marginLeft: 11,
            marginRight: 12,
            marginTop: 13,
            marginBottom: 14,
            showsTime: true,
            uses24HourTime: true,
            showsDate: true,
            showsDateTimeToolTip: false
        )
        output.applySettings(settings)
        output.append(.init(text: "Configured output", timestamp: Date(timeIntervalSince1970: 0)))
        output.selectAll()

        let view = output.primaryOutputViewForTesting
        let selected = try XCTUnwrap(view.selectedAttributedString())
        let contentLocation = (selected.string as NSString).range(of: "Configured output").location
        let attributes = selected.attributes(at: contentLocation, effectiveRange: nil)
        let font = try XCTUnwrap(attributes[.font] as? NSFont)
        let paragraph = try XCTUnwrap(attributes[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(font.pointSize, 17, accuracy: 0.1)
        XCTAssertEqual((attributes[.foregroundColor] as? NSColor)?.hexString, "#123456")
        XCTAssertEqual((attributes[.backgroundColor] as? NSColor)?.hexString, "#202020")
        XCTAssertEqual(paragraph.headIndent, 14, accuracy: 0.1)
        XCTAssertEqual(paragraph.paragraphSpacing, 5, accuracy: 0.1)
        XCTAssertNil(attributes[.toolTip])
        XCTAssertTrue(selected.string.hasPrefix("[1970-01-01 "))
        XCTAssertEqual(output.historyLimit, 321)
        XCTAssertEqual(view.contentInsets.left, 20)
        XCTAssertEqual(view.contentInsets.right, 21)
        XCTAssertEqual(view.contentInsets.top, 20)
        XCTAssertEqual(view.contentInsets.bottom, 21)
        XCTAssertLessThan(view.effectiveContentWidthForTesting, 500)
    }

    func testTextWindowSettingsNormalizeUnsafeNumericValues() {
        let normalized = TextWindowSettings(
            fontSize: -20,
            historyLimit: 1,
            wrappedLineIndent: -3,
            paragraphSpacing: 999,
            fixedWidthCharacters: 2,
            marginLeft: -1,
            marginRight: 999,
            marginTop: -4,
            marginBottom: 999
        ).normalized
        XCTAssertEqual(normalized.fontSize, 6)
        XCTAssertEqual(normalized.historyLimit, 100)
        XCTAssertEqual(normalized.wrappedLineIndent, 0)
        XCTAssertEqual(normalized.paragraphSpacing, 100)
        XCTAssertEqual(normalized.fixedWidthCharacters, 20)
        XCTAssertEqual(normalized.marginLeft, 0)
        XCTAssertEqual(normalized.marginRight, 500)
        XCTAssertEqual(normalized.marginTop, 0)
        XCTAssertEqual(normalized.marginBottom, 500)
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

    private func isAtBottom(_ scrollView: NSScrollView) -> Bool {
        let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentSize.height)
        return maxY - scrollView.contentView.bounds.origin.y <= 1
    }
}
