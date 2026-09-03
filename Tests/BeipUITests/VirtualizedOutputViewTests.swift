import AppKit
import BeipCore
import BeipTestSupport
import CoreText
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

    func testOutputQueuesAt256LinesAndFlushesRemainingItemsOnDemand() {
        let output = OutputTextView()

        for index in 0..<255 {
            output.append(.init(text: "line \(index)"))
        }

        XCTAssertEqual(output.visibleLineCount, 255)
        XCTAssertEqual(output.renderedLineCount, 0)
        XCTAssertEqual(output.pendingOutputLineCountForTesting, 255)
        XCTAssertEqual(output.pendingOutputItemCountForTesting, 255)
        XCTAssertEqual(output.batchMutationCountForTesting, 0)

        output.append(.init(text: "line 255"))

        XCTAssertEqual(output.renderedLineCount, 0)
        XCTAssertEqual(output.pendingOutputLineCountForTesting, 256)
        XCTAssertEqual(output.pendingOutputItemCountForTesting, 256)
        XCTAssertEqual(output.batchMutationCountForTesting, 0)

        output.append(.init(text: "line 256"))
        XCTAssertEqual(output.renderedLineCount, 0)
        XCTAssertEqual(output.pendingOutputLineCountForTesting, 257)

        output.flushPendingOutput()
        XCTAssertEqual(output.renderedLineCount, 257)
        XCTAssertEqual(output.batchMutationCountForTesting, 2)
        XCTAssertEqual(output.maxLinesPerSliceForTesting, 256)
    }

    func testOutputFlushesAQuietBurstAfterOneDisplayFrame() async throws {
        let output = OutputTextView()
        output.append(.init(text: "quiet burst"))

        XCTAssertEqual(output.renderedLineCount, 0)
        try await Task.sleep(for: .milliseconds(32))

        XCTAssertEqual(output.renderedLineCount, 1)
        XCTAssertEqual(output.pendingOutputLineCountForTesting, 0)
        XCTAssertEqual(output.batchMutationCountForTesting, 1)
    }

    func testTerminalSizeDoesNotFlushQueuedOutput() {
        let output = OutputTextView()

        for index in 0..<700 {
            output.append(.init(text: "sized \(index)"))
        }

        let pendingBefore = output.pendingOutputItemCountForTesting
        let renderedBefore = output.renderedLineCount
        let size = output.terminalSize

        XCTAssertEqual(output.pendingOutputItemCountForTesting, pendingBefore)
        XCTAssertEqual(output.renderedLineCount, renderedBefore)
        XCTAssertGreaterThanOrEqual(size.columns, 1)
        XCTAssertLessThanOrEqual(size.columns, UInt16.max)
        XCTAssertGreaterThanOrEqual(size.rows, 1)
        XCTAssertLessThanOrEqual(size.rows, UInt16.max)
    }

    func testClearDiscardsQueuedOutputWithoutDelayedRendering() async throws {
        let output = OutputTextView()

        for index in 0..<700 {
            output.append(.init(text: "clear \(index)"))
        }

        output.clear()

        XCTAssertTrue(output.retainedLines.isEmpty)
        XCTAssertEqual(output.renderedLineCount, 0)
        XCTAssertEqual(output.pendingOutputItemCountForTesting, 0)
        let slicesAfterClear = output.sliceCountForTesting

        try await Task.sleep(for: .milliseconds(32))

        XCTAssertTrue(output.retainedLines.isEmpty)
        XCTAssertEqual(output.renderedLineCount, 0)
        XCTAssertEqual(output.pendingOutputItemCountForTesting, 0)
        XCTAssertEqual(output.sliceCountForTesting, slicesAfterClear)
    }

    func testPrepareForTeardownDiscardsQueuedOutputWithoutDelayedRendering() async throws {
        let output = OutputTextView()

        for index in 0..<700 {
            output.append(.init(text: "teardown \(index)"))
        }

        let renderedBefore = output.renderedLineCount
        let slicesBefore = output.sliceCountForTesting
        output.prepareForTeardown()

        XCTAssertEqual(output.pendingOutputItemCountForTesting, 0)
        XCTAssertEqual(output.renderedLineCount, renderedBefore)
        XCTAssertEqual(output.sliceCountForTesting, slicesBefore)

        try await Task.sleep(for: .milliseconds(32))

        XCTAssertEqual(output.pendingOutputItemCountForTesting, 0)
        XCTAssertEqual(output.renderedLineCount, renderedBefore)
        XCTAssertEqual(output.sliceCountForTesting, slicesBefore)
    }

    func testAutomaticDrainUsesMultipleBoundedSlicesAndPreservesOrder() async throws {
        let output = OutputTextView()

        for index in 0..<700 {
            output.append(.init(text: "ordered \(index)"))
        }

        XCTAssertEqual(output.renderedLineCount, 0)
        XCTAssertEqual(output.pendingOutputLineCountForTesting, 700)

        try await eventuallyOnMainActor("automatic output drain", timeout: .seconds(3)) {
            output.pendingOutputLineCountForTesting == 0
        }

        XCTAssertGreaterThan(output.sliceCountForTesting, 1)
        XCTAssertLessThanOrEqual(output.maxLinesPerSliceForTesting, 256)
        XCTAssertEqual(output.renderedLineCount, 700)
        XCTAssertEqual(
            (0..<700).compactMap {
                output.primaryOutputViewForTesting.renderedAttributedTextForTesting(at: $0)?.string
            },
            (0..<700).map { "ordered \($0)\n" }
        )
    }

    func testHistoryEvictionSpansRenderedAndPendingSlices() {
        let output = OutputTextView()
        output.historyLimit = 100

        for index in 0..<80 { output.append(.init(text: "history \(index)")) }
        output.flushPendingOutput()

        for index in 80..<780 { output.append(.init(text: "history \(index)")) }
        XCTAssertEqual(output.visibleLineCount, 100)
        XCTAssertEqual(output.pendingOutputLineCountForTesting, 100)

        output.flushPendingOutput()

        XCTAssertEqual(output.renderedLineCount, 100)
        XCTAssertEqual(output.retainedLines.map(\.text), (680..<780).map { "history \($0)" })
        XCTAssertEqual(
            (0..<100).compactMap {
                output.primaryOutputViewForTesting.renderedAttributedTextForTesting(at: $0)?.string
            },
            (680..<780).map { "history \($0)\n" }
        )
        XCTAssertLessThanOrEqual(output.maxLinesPerSliceForTesting, 256)
    }

    func testPreparedHeightsAreReusedOnlyWhenEffectiveWidthsMatch() {
        let primary = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let secondary = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let items = [VirtualizedOutputView.Item(
            id: UUID(),
            attributedText: NSAttributedString(string: String(repeating: "wrapped ", count: 30)),
            contentRange: NSRange(location: 0, length: 240),
            assets: []
        )]

        primary.setItems(items)
        let prepared = primary.preparedHeightsForCurrentItems()
        let measurementsBeforeReuse = secondary.heightMeasurementCountForTesting
        secondary.setItems(
            items,
            preparedHeights: prepared.heights,
            measuredAtWidth: prepared.width
        )

        XCTAssertEqual(secondary.heightMeasurementCountForTesting, measurementsBeforeReuse)
        XCTAssertEqual(primary.measuredHeightForTesting(at: 0), secondary.measuredHeightForTesting(at: 0))

        secondary.setFrameSize(NSSize(width: 300, height: 200))
        secondary.setItems(
            items,
            preparedHeights: prepared.heights,
            measuredAtWidth: prepared.width
        )
        XCTAssertGreaterThan(secondary.heightMeasurementCountForTesting, measurementsBeforeReuse)
    }

    func testPendingItemsDiscardHistoryEvictionsBeforeRendererFlush() {
        let output = OutputTextView()
        output.historyLimit = 10

        for index in 0..<10 { output.append(.init(text: "line \(index)")) }
        output.flushPendingOutput()
        let firstRetainedID = output.retainedLines.first?.id
        let batchesBeforeBurst = output.batchMutationCountForTesting

        for index in 10..<40 { output.append(.init(text: "line \(index)")) }

        XCTAssertEqual(output.visibleLineCount, 10)
        XCTAssertEqual(output.retainedLines.first?.text, "line 30")
        XCTAssertEqual(output.pendingOutputItemCountForTesting, 10)
        XCTAssertEqual(output.renderedLineCount, 10)
        XCTAssertEqual(output.primaryOutputViewForTesting.itemID(at: 0), firstRetainedID)

        output.flushPendingOutput()

        XCTAssertEqual(output.renderedLineCount, 10)
        XCTAssertEqual(output.primaryOutputViewForTesting.itemID(at: 0), output.retainedLines.first?.id)
        XCTAssertEqual(output.primaryOutputViewForTesting.renderedAttributedTextForTesting(at: 0)?.string, "line 30\n")
        XCTAssertEqual(output.batchMutationCountForTesting, batchesBeforeBurst + 1)
    }

    func testOneOutputFlushDoesNotDrainAnotherOutputsBurst() {
        let sustained = OutputTextView()
        let local = OutputTextView()

        for index in 0..<128 {
            sustained.append(.init(text: "sustained \(index)"))
        }
        local.append(.init(text: "local output"))

        XCTAssertEqual(sustained.renderedLineCount, 0)
        XCTAssertEqual(local.renderedLineCount, 0)

        local.selectAll()

        XCTAssertEqual(local.renderedLineCount, 1)
        XCTAssertEqual(local.pendingOutputLineCountForTesting, 0)
        XCTAssertEqual(sustained.renderedLineCount, 0)
        XCTAssertEqual(sustained.pendingOutputLineCountForTesting, 128)

        sustained.flushPendingOutput()
        XCTAssertEqual(sustained.renderedLineCount, 128)
    }

    func testSmoothScrollCatchesUpSustainedOutputAndAnimatesIsolatedOutput() async throws {
        let output = OutputTextView()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
        output.containerView.frame = host.bounds
        host.addSubview(output.containerView)
        output.containerView.layoutSubtreeIfNeeded()
        output.applySettings(.init(smoothScrolling: true))

        for index in 0..<512 {
            output.append(.init(text: "smooth \(index)"))
        }

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        XCTAssertEqual(output.batchMutationCountForTesting, 0)
        try await eventuallyOnMainActor("smooth output catch-up", timeout: .seconds(3)) {
            output.pendingOutputLineCountForTesting == 0
        }
        XCTAssertGreaterThan(output.batchMutationCountForTesting, 1)
        XCTAssertEqual(output.sliceCountForTesting, output.batchMutationCountForTesting)
        XCTAssertEqual(output.maxLinesPerSliceForTesting, 256)
        XCTAssertGreaterThan(output.catchUpScrollsForTesting, 0)
        XCTAssertEqual(output.primaryOutputViewForTesting.scrollAnimationTargetUpdateCountForTesting, 0)
        XCTAssertTrue(isAtBottom(output.primaryScrollViewForTesting))

        try? await Task.sleep(for: .milliseconds(140))
        output.append(.init(text: "isolated smooth"))
        output.flushPendingOutput()
        XCTAssertEqual(output.primaryOutputViewForTesting.scrollAnimationTargetUpdateCountForTesting, 1)

        let catchUpsBeforeOverlap = output.catchUpScrollsForTesting
        output.append(.init(text: "arrives during animation"))
        output.flushPendingOutput()
        XCTAssertEqual(output.primaryOutputViewForTesting.scrollAnimationTargetUpdateCountForTesting, 1)
        XCTAssertGreaterThan(output.catchUpScrollsForTesting, catchUpsBeforeOverlap)

        try? await Task.sleep(for: .milliseconds(140))
        output.append(.init(text: "smooth after quiet"))
        output.flushPendingOutput()
        XCTAssertEqual(output.primaryOutputViewForTesting.scrollAnimationTargetUpdateCountForTesting, 2)
    }

    func testPauseFlushesVisibleOutputAndResumeRebuildsBufferedHistory() {
        let output = OutputTextView()
        output.append(.init(text: "before pause"))

        output.setPaused(true)
        XCTAssertEqual(output.renderedLineCount, 1)

        output.append(.init(text: "buffered one"))
        output.append(.init(text: "buffered two"))
        XCTAssertEqual(output.visibleLineCount, 1)
        XCTAssertEqual(output.pendingLineCount, 2)
        XCTAssertEqual(output.renderedLineCount, 1)

        output.setPaused(false)

        XCTAssertEqual(output.pendingLineCount, 0)
        XCTAssertEqual(output.visibleLineCount, 3)
        XCTAssertEqual(output.renderedLineCount, 3)
        XCTAssertEqual(output.retainedLines.map(\.text), ["before pause", "buffered one", "buffered two"])
    }

    func testSearchFlushesPendingOutputBeforeSelectingIt() throws {
        let output = OutputTextView()
        output.append(.init(text: "searchable output"))

        XCTAssertTrue(try output.find("searchable"))
        XCTAssertEqual(output.renderedLineCount, 1)
        XCTAssertEqual(output.primaryOutputViewForTesting.selectedString(), "searchable")
    }

    func testUnterminatedPromptAppendsWithoutRebuildingFullHistoryAndCanBeRemoved() throws {
        let output = OutputTextView()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 180))
        output.containerView.translatesAutoresizingMaskIntoConstraints = true
        output.containerView.frame = host.bounds
        host.addSubview(output.containerView)
        host.layoutSubtreeIfNeeded()
        output.containerView.layoutSubtreeIfNeeded()

        for index in 0..<10_000 {
            output.append(.init(text: "History line \(index)"))
        }
        output.flushPendingOutput()
        let retainedBeforePrompt = output.retainedLines
        let selectedLine = try XCTUnwrap(retainedBeforePrompt[5_000])
        XCTAssertTrue(output.primaryOutputViewForTesting.select(
            itemID: selectedLine.id,
            range: NSRange(location: 0, length: selectedLine.text.utf16.count)
        ))
        output.primaryOutputViewForTesting.scrollToEnd()
        let scrollOriginBeforePrompt = output.primaryScrollViewForTesting.contentView.bounds.origin
        let rebuildGeneration = output.rebuildGenerationForTesting

        output.setWindowFocused(false)
        let prompt = RenderedLine(text: "Name: ", source: .prompt)
        output.append(prompt, terminator: "")
        output.flushPendingOutput()

        XCTAssertEqual(output.rebuildGenerationForTesting, rebuildGeneration)
        XCTAssertEqual(output.visibleLineCount, 10_000)
        XCTAssertEqual(output.renderedLineCount, 10_000)
        XCTAssertEqual(output.retainedLines.last?.id, prompt.id)
        XCTAssertEqual(output.primaryOutputViewForTesting.renderedAttributedTextForTesting(at: 9_999)?.string, "Name: ")
        XCTAssertEqual(output.primaryOutputViewForTesting.selectedString(), selectedLine.text)
        XCTAssertEqual(output.newContentBoundaryPositionForTesting, 9_999)
        XCTAssertEqual(output.primaryScrollViewForTesting.contentView.bounds.origin.y, scrollOriginBeforePrompt.y, accuracy: 0.5)

        output.removeLastLine()

        XCTAssertEqual(output.visibleLineCount, 9_999)
        XCTAssertEqual(output.renderedLineCount, 9_999)
        XCTAssertEqual(output.primaryOutputViewForTesting.selectedString(), selectedLine.text)
        XCTAssertEqual(output.newContentBoundaryPositionForTesting, 9_999)
        XCTAssertNil(output.newContentBoundaryIDForTesting)
    }

    func testAtomicEvictionKeepsPrimaryAtBottomAndSplitScrollbackStationary() async throws {
        let output = OutputTextView()
        output.historyLimit = 100
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 320))
        output.containerView.translatesAutoresizingMaskIntoConstraints = true
        output.containerView.frame = host.bounds
        host.addSubview(output.containerView)
        output.containerView.layoutSubtreeIfNeeded()

        for index in 0..<100 { output.append(.init(text: "Line \(index)")) }
        output.flushPendingOutput()
        output.toggleSplit()
        await awaitMainActorQuiescence()
        output.containerView.layoutSubtreeIfNeeded()
        let upper = try XCTUnwrap(output.secondaryScrollViewForTesting)
        let upperView = try XCTUnwrap(upper.documentView as? VirtualizedOutputView)
        let scrollbackOrigin = max(0, upper.contentView.bounds.origin.y - 54)
        upper.contentView.scroll(to: NSPoint(x: 0, y: scrollbackOrigin))
        upper.reflectScrolledClipView(upper.contentView)
        let stationaryItemID = upperView.firstVisibleItemID

        output.append(.init(text: "Line 100"))
        output.flushPendingOutput()

        XCTAssertEqual(output.visibleLineCount, 100)
        XCTAssertEqual(output.renderedLineCount, 100)
        XCTAssertTrue(isAtBottom(output.primaryScrollViewForTesting))
        XCTAssertEqual(upperView.firstVisibleItemID, stationaryItemID)
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

    func testOutputScrollViewsUseOverlayAutohidingScrollers() throws {
        let output = OutputTextView()
        let primary = output.primaryScrollViewForTesting

        XCTAssertEqual(primary.scrollerStyle, .overlay)
        XCTAssertTrue(primary.hasVerticalScroller)
        XCTAssertTrue(primary.autohidesScrollers)
        let primaryScroller = try XCTUnwrap(primary.verticalScroller)
        XCTAssertTrue(type(of: primaryScroller).isCompatibleWithOverlayScrollers)
        XCTAssertEqual(primaryScroller.scrollerStyle, .overlay)
        primary.scrollerStyle = .legacy
        XCTAssertEqual(primary.scrollerStyle, .overlay)

        output.toggleSplit()
        let secondary = try XCTUnwrap(output.secondaryScrollViewForTesting)
        XCTAssertEqual(secondary.scrollerStyle, .overlay)
        XCTAssertTrue(secondary.hasVerticalScroller)
        XCTAssertTrue(secondary.autohidesScrollers)
        let secondaryScroller = try XCTUnwrap(secondary.verticalScroller)
        XCTAssertTrue(type(of: secondaryScroller).isCompatibleWithOverlayScrollers)
        XCTAssertEqual(secondaryScroller.scrollerStyle, .overlay)
        secondary.scrollerStyle = .legacy
        XCTAssertEqual(secondary.scrollerStyle, .overlay)
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

    func testInactiveOutputMarksFirstNewLineAndUserScrollToBottomClearsIt() async {
        let output = OutputTextView()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 80))
        output.containerView.frame = host.bounds
        host.addSubview(output.containerView)
        output.containerView.layoutSubtreeIfNeeded()

        output.setWindowFocused(false)
        let firstNewLine = RenderedLine(text: "first inactive line")
        output.append(firstNewLine)
        (2...20).forEach { output.append(.init(text: "inactive line \($0)")) }
        output.flushPendingOutput()

        XCTAssertEqual(output.newContentBoundaryIDForTesting, firstNewLine.id)
        XCTAssertEqual(output.primaryOutputViewForTesting.newContentBoundaryItemIDForTesting, firstNewLine.id)

        output.primaryOutputViewForTesting.scrollToEnd()
        await awaitMainActorQuiescence()

        XCTAssertNil(output.newContentBoundaryIDForTesting)
        XCTAssertNil(output.primaryOutputViewForTesting.newContentBoundaryItemIDForTesting)
    }

    func testAutomaticFollowScrollDoesNotClearInactiveBoundary() {
        let output = OutputTextView()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 80))
        output.containerView.frame = host.bounds
        host.addSubview(output.containerView)
        output.containerView.layoutSubtreeIfNeeded()

        output.setWindowFocused(false)
        let firstNewLine = RenderedLine(text: "first followed line")
        output.append(firstNewLine)
        (2...20).forEach { output.append(.init(text: "followed line \($0)")) }

        XCTAssertEqual(output.newContentBoundaryIDForTesting, firstNewLine.id)
    }

    func testUpwardUserScrollFromBottomPreservesUnreadBoundaryUntilDownwardReturn() {
        let coordinator = SharedUnreadBoundaryCoordinator()
        let main = OutputTextView()
        let coordinated = OutputTextView()
        main.setUnreadBoundaryCoordinator(coordinator)
        coordinated.setUnreadBoundaryCoordinator(coordinator)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 80))
        main.containerView.frame = host.bounds
        host.addSubview(main.containerView)
        main.containerView.layoutSubtreeIfNeeded()

        main.setWindowFocused(false)
        coordinated.setWindowFocused(false)
        (1...40).forEach { main.append(.init(text: "inactive line \($0)")) }
        main.flushPendingOutput()

        let scrollView = main.primaryScrollViewForTesting
        let bottomY = scrollView.contentView.bounds.origin.y
        XCTAssertGreaterThan(bottomY, 0)
        XCTAssertNotNil(main.newContentBoundaryPositionForTesting)
        XCTAssertNotNil(coordinated.newContentBoundaryPositionForTesting)

        let upwardY = max(0, bottomY - 40)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: upwardY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        main.reportUserScrollForTesting(from: bottomY, to: upwardY)

        XCTAssertNotNil(main.newContentBoundaryPositionForTesting)
        XCTAssertNotNil(coordinated.newContentBoundaryPositionForTesting)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottomY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        main.reportUserScrollForTesting(from: upwardY, to: bottomY)

        XCTAssertNil(main.newContentBoundaryPositionForTesting)
        XCTAssertNil(coordinated.newContentBoundaryPositionForTesting)
    }

    func testBoundaryTracksLogicalInsertionPositionAtOutputEndAndAfterEviction() {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let items = (0..<3).map { index in
            VirtualizedOutputView.Item(
                id: UUID(),
                attributedText: NSAttributedString(string: "Line \(index)\n"),
                contentRange: NSRange(location: 0, length: 7),
                assets: []
            )
        }
        view.setItems(items)
        view.setNewContentBoundary(position: items.count)

        XCTAssertEqual(view.newContentBoundaryPositionForTesting, 3)
        XCTAssertNil(view.newContentBoundaryItemIDForTesting)

        let appendedID = UUID()
        view.append(.init(
            id: appendedID,
            attributedText: NSAttributedString(string: "Below\n"),
            contentRange: NSRange(location: 0, length: 6),
            assets: []
        ))
        XCTAssertEqual(view.newContentBoundaryPositionForTesting, 3)

        view.removeFirst(1)
        XCTAssertEqual(view.newContentBoundaryPositionForTesting, 2)
        XCTAssertEqual(view.newContentBoundaryItemIDForTesting, appendedID)
    }

    func testSharedUnreadCycleCoversEmptyMembersAndClearsTogether() async {
        let coordinator = SharedUnreadBoundaryCoordinator()
        let main = OutputTextView()
        let spawn = OutputTextView()
        main.setUnreadBoundaryCoordinator(coordinator)
        spawn.setUnreadBoundaryCoordinator(coordinator)
        main.setWindowFocused(true)
        spawn.setWindowFocused(false)

        main.append(.init(text: "existing"))
        spawn.append(.init(text: "first inactive"))

        XCTAssertEqual(main.newContentBoundaryPositionForTesting, 1)
        XCTAssertEqual(spawn.newContentBoundaryPositionForTesting, 0)

        main.append(.init(text: "below boundary"))
        XCTAssertEqual(main.newContentBoundaryPositionForTesting, 1)

        let registeredDuringCycle = OutputTextView()
        registeredDuringCycle.setUnreadBoundaryCoordinator(coordinator)
        registeredDuringCycle.setWindowFocused(false)
        XCTAssertEqual(registeredDuringCycle.newContentBoundaryPositionForTesting, 0)
        registeredDuringCycle.append(.init(text: "registered content"))
        XCTAssertEqual(registeredDuringCycle.newContentBoundaryPositionForTesting, 0)

        spawn.clear()
        XCTAssertEqual(spawn.newContentBoundaryPositionForTesting, 0)
        XCTAssertEqual(main.newContentBoundaryPositionForTesting, 1)

        spawn.primaryOutputViewForTesting.scrollToEnd()
        await awaitMainActorQuiescence()
        XCTAssertNil(main.newContentBoundaryPositionForTesting)
        XCTAssertNil(registeredDuringCycle.newContentBoundaryPositionForTesting)
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

    func testBlinkIntervalCanBeUpdatedWhileBlinking() {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let text = NSMutableAttributedString(string: "Blinking\n")
        text.addAttribute(
            VirtualizedOutputView.blinkAttribute,
            value: TextStyle.Blink.slow.rawValue,
            range: NSRange(location: 0, length: 8)
        )
        view.setItems([.init(id: UUID(), attributedText: text, contentRange: NSRange(location: 0, length: 8), assets: [])])
        XCTAssertEqual(view.blinkIntervalForTesting, 0.55)
        XCTAssertEqual(view.blinkTimerCreationCountForTesting, 1)

        view.blinkInterval = 0.25

        XCTAssertEqual(view.blinkIntervalForTesting, 0.25)
        XCTAssertTrue(view.isBlinkTimerActive)
        XCTAssertEqual(view.blinkTimerCreationCountForTesting, 2)

        view.applyAccessibilityDisplayOptions(.init(reduceMotion: true))
        XCTAssertFalse(view.isBlinkTimerActive)
    }

    func testOutputBlinkIntervalPropagatesToSplitView() throws {
        let output = OutputTextView()
        output.applyBlinkInterval(0.25)
        output.toggleSplit()

        XCTAssertEqual(output.primaryOutputViewForTesting.blinkIntervalForTesting, 0.25)
        let secondary = try XCTUnwrap(output.secondaryScrollViewForTesting?.documentView as? VirtualizedOutputView)
        XCTAssertEqual(secondary.blinkIntervalForTesting, 0.25)
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

    func testSplitKeepsUpperScrollbackStationaryWhileLowerOutputFollowsNewText() async throws {
        let output = OutputTextView()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        output.containerView.frame = host.bounds
        host.addSubview(output.containerView)
        output.containerView.layoutSubtreeIfNeeded()

        (1...80).forEach { output.append(.init(text: "line \($0)")) }
        output.flushPendingOutput()
        XCTAssertGreaterThan(output.primaryScrollViewForTesting.contentView.bounds.origin.y, 0)

        output.toggleSplit()
        await awaitMainActorQuiescence()
        output.containerView.layoutSubtreeIfNeeded()

        let upperScrollback = try XCTUnwrap(output.secondaryScrollViewForTesting)
        XCTAssertTrue(output.containerView.subviews.first === upperScrollback)
        XCTAssertEqual(upperScrollback.borderType, .lineBorder)

        let frozenOrigin = upperScrollback.contentView.bounds.origin.y
        let liveOrigin = output.primaryScrollViewForTesting.contentView.bounds.origin.y
        output.append(.init(text: "new live line"))
        output.flushPendingOutput()
        output.containerView.layoutSubtreeIfNeeded()

        XCTAssertEqual(upperScrollback.contentView.bounds.origin.y, frozenOrigin, accuracy: 0.5)
        XCTAssertGreaterThan(output.primaryScrollViewForTesting.contentView.bounds.origin.y, liveOrigin)
    }

    func testSplitOutputMirrorsSharedBoundaryAndUserScrollClearsIt() async throws {
        let output = OutputTextView()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        output.containerView.frame = host.bounds
        host.addSubview(output.containerView)
        output.containerView.layoutSubtreeIfNeeded()
        output.setWindowFocused(false)
        (1...40).forEach { output.append(.init(text: "line \($0)")) }

        output.toggleSplit()
        await awaitMainActorQuiescence()
        let upper = try XCTUnwrap(output.secondaryScrollViewForTesting)
        XCTAssertEqual(output.newContentBoundaryPositionForTesting, 0)
        XCTAssertEqual(output.primaryOutputViewForTesting.newContentBoundaryPositionForTesting, 0)
        XCTAssertEqual(try XCTUnwrap(output.secondaryScrollViewForTesting?.documentView as? VirtualizedOutputView)
            .newContentBoundaryPositionForTesting, 0)

        try XCTUnwrap(upper.documentView as? VirtualizedOutputView).scrollToEnd()
        await awaitMainActorQuiescence()
        XCTAssertNil(output.newContentBoundaryPositionForTesting)
    }

    func testPageUpAndPageDownNavigateSplitScrollbackAndCloseAtBottom() async throws {
        let output = OutputTextView()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        output.containerView.frame = host.bounds
        host.addSubview(output.containerView)
        output.containerView.layoutSubtreeIfNeeded()

        (1...120).forEach { output.append(.init(text: "line \($0)")) }
        output.flushPendingOutput()
        let liveBottom = output.primaryScrollViewForTesting.contentView.bounds.origin.y

        XCTAssertTrue(output.performPageUp())
        await awaitMainActorQuiescence()
        output.containerView.layoutSubtreeIfNeeded()

        let upperScrollback = try XCTUnwrap(output.secondaryScrollViewForTesting)
        XCTAssertTrue(output.isSplit)
        let afterPageUp = upperScrollback.contentView.bounds.origin.y
        XCTAssertLessThan(afterPageUp, liveBottom)

        XCTAssertTrue(output.performPageDown())
        await awaitMainActorQuiescence()
        output.containerView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(upperScrollback.contentView.bounds.origin.y, afterPageUp)

        for _ in 0..<20 where output.isSplit && !isAtBottom(upperScrollback) {
            XCTAssertTrue(output.performPageDown())
            await awaitMainActorQuiescence()
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

    func testOrdinaryOutputIsDarkerThanXTermWhite() throws {
        let output = OutputTextView()
        output.applySettings(TextWindowSettings())
        output.append(.init(text: "ordinary"))
        output.append(.init(
            text: "white",
            runs: [.init(
                range: 0..<5,
                style: .init(foreground: ANSIPalettePreset.xTerm.colors[.white])
            )]
        ))
        output.flushPendingOutput()

        let ordinary = try XCTUnwrap(output.primaryOutputViewForTesting.renderedAttributedTextForTesting(at: 0))
        let white = try XCTUnwrap(output.primaryOutputViewForTesting.renderedAttributedTextForTesting(at: 1))
        let ordinaryColor = try XCTUnwrap(ordinary.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let whiteColor = try XCTUnwrap(white.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(ordinaryColor.hexString, "#C0C0C0")
        XCTAssertEqual(ANSIPalettePreset.xTerm.colors[.white], RGBColor(red: 229, green: 229, blue: 229))
        XCTAssertGreaterThan(whiteColor.redComponent, ordinaryColor.redComponent)
    }

    func testApplyingTimestampAndFanFoldSettingsRebuildsHistoryOnce() {
        let output = OutputTextView()
        output.append(.init(text: "Existing output", timestamp: Date(timeIntervalSince1970: 0)))
        let generationBeforeSettings = output.rebuildGenerationForTesting
        XCTAssertEqual(output.renderedLineCount, 0)

        output.applySettings(TextWindowSettings(
            usesFanFoldBackgrounds: true,
            showsTime: true
        ))

        XCTAssertEqual(output.rebuildGenerationForTesting, generationBeforeSettings + 1)
        XCTAssertEqual(output.renderedLineCount, 1)
    }

    func testOutputParagraphUsesEightConfiguredFontCellsForTabs() throws {
        let output = OutputTextView()
        let settings = TextWindowSettings(fontName: "Menlo", fontSize: 17)
        output.applySettings(settings)
        output.append(.init(text: "\t1tab"))
        output.flushPendingOutput()

        let rendered = try XCTUnwrap(output.primaryOutputViewForTesting.renderedAttributedTextForTesting(at: 0))
        let paragraph = try XCTUnwrap(rendered.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let font = try XCTUnwrap(NSFont(name: settings.fontName, size: settings.fontSize))
        let cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width

        XCTAssertTrue(paragraph.tabStops.isEmpty)
        XCTAssertEqual(paragraph.defaultTabInterval, 8 * cellWidth, accuracy: 0.01)
    }

    func testCoreTextPlacesTabsOnEightColumnBoundaries() throws {
        let output = OutputTextView()
        let settings = TextWindowSettings(fontName: "Menlo", fontSize: 17)
        output.applySettings(settings)
        output.append(.init(text: "\t1tab"))
        output.append(.init(text: "\t\t2tab"))
        output.append(.init(text: "12\t1234\t123456\t12345678\tEnd"))
        output.flushPendingOutput()

        let font = try XCTUnwrap(NSFont(name: settings.fontName, size: settings.fontSize))
        let interval = 8 * ("M" as NSString).size(withAttributes: [.font: font]).width

        func offset(in item: Int, for substring: String) throws -> CGFloat {
            let rendered = try XCTUnwrap(
                output.primaryOutputViewForTesting.renderedAttributedTextForTesting(at: item)
            )
            let range = (rendered.string as NSString).range(of: substring)
            XCTAssertNotEqual(range.location, NSNotFound)
            let line = CTLineCreateWithAttributedString(rendered)
            return CTLineGetOffsetForStringIndex(line, range.location, nil)
        }

        XCTAssertEqual(try offset(in: 0, for: "1tab"), interval, accuracy: 0.1)
        XCTAssertEqual(try offset(in: 1, for: "2tab"), 2 * interval, accuracy: 0.1)

        let fixture = try XCTUnwrap(
            output.primaryOutputViewForTesting.renderedAttributedTextForTesting(at: 2)
        )
        let fixtureLine = CTLineCreateWithAttributedString(fixture)
        let fixtureText = fixture.string as NSString
        let tokenStarts = ["1234", "123456", "12345678", "End"].map {
            fixtureText.range(of: $0).location
        }
        let expectedOffsets = [interval, 2 * interval, 3 * interval, 5 * interval]
        for (index, expected) in zip(tokenStarts, expectedOffsets) {
            XCTAssertNotEqual(index, NSNotFound)
            XCTAssertEqual(CTLineGetOffsetForStringIndex(fixtureLine, index, nil), expected, accuracy: 0.1)
        }
    }

    func testChangingOutputFontRecalculatesTabInterval() throws {
        let output = OutputTextView()
        output.append(.init(text: "\tretained text"))
        output.flushPendingOutput()
        output.toggleSplit()
        let secondary = try XCTUnwrap(
            output.secondaryScrollViewForTesting?.documentView as? VirtualizedOutputView
        )

        func tabInterval(fontName: String, size: Double) throws -> CGFloat {
            output.applySettings(TextWindowSettings(fontName: fontName, fontSize: size))
            let font = try XCTUnwrap(NSFont(name: fontName, size: size))
            let expected = 8 * ("M" as NSString).size(withAttributes: [.font: font]).width
            for view in [output.primaryOutputViewForTesting, secondary] {
                let rendered = try XCTUnwrap(view.renderedAttributedTextForTesting(at: 0))
                let paragraph = try XCTUnwrap(rendered.attribute(
                    .paragraphStyle,
                    at: 0,
                    effectiveRange: nil
                ) as? NSParagraphStyle)
                XCTAssertEqual(paragraph.defaultTabInterval, expected, accuracy: 0.01)
            }
            return expected
        }

        let menloInterval = try tabInterval(fontName: "Menlo", size: 13)
        let largerMenloInterval = try tabInterval(fontName: "Menlo", size: 21)
        let monacoInterval = try tabInterval(fontName: "Monaco", size: 21)

        XCTAssertNotEqual(menloInterval, largerMenloInterval, accuracy: 0.01)
        XCTAssertNotEqual(largerMenloInterval, monacoInterval, accuracy: 0.01)
    }

    func testLiteralTabsRemainInCapturedAndSelectedPlainText() async throws {
        let output = OutputTextView()
        let text = "12\t1234\tEnd"
        output.append(.init(text: text))
        await awaitMainActorQuiescence()
        output.selectAll()
        await awaitMainActorQuiescence()

        XCTAssertEqual(output.capturedText(lineCount: 1, skipping: 0), text + "\n")
        XCTAssertEqual(output.primaryOutputViewForTesting.selectedString(), text + "\n")
        output.copySelectionAsPlainText()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), text + "\n")
    }

    func testAutomaticWebLinksUseHTTPPrefixesAndExcludeTrailingPunctuation() throws {
        let output = OutputTextView()
        output.applySettings(TextWindowSettings(webLinkHex: "#ABCDEF"))
        let text = "Visit https://example.com/path, then http://example.org! www.example.net email@example.net ftp://example.org"
        output.append(.init(text: text))
        output.selectAll()

        let selected = try XCTUnwrap(output.primaryOutputViewForTesting.selectedAttributedString())
        let linkRange = (selected.string as NSString).range(of: "https://example.com/path")
        let attributes = selected.attributes(at: linkRange.location, effectiveRange: nil)
        XCTAssertEqual((attributes[.link] as? URL)?.absoluteString, "https://example.com/path")
        XCTAssertTrue((attributes[.cursor] as? NSCursor) === NSCursor.pointingHand)
        XCTAssertEqual((attributes[.foregroundColor] as? NSColor)?.hexString, "#ABCDEF")
        XCTAssertNil(selected.attribute(.link, at: NSMaxRange(linkRange), effectiveRange: nil))

        for value in ["www.example.net", "email@example.net", "ftp://example.org"] {
            let range = (selected.string as NSString).range(of: value)
            XCTAssertNotEqual(range.location, NSNotFound)
            XCTAssertNil(selected.attribute(.link, at: range.location, effectiveRange: nil), value)
        }
    }

    func testAutomaticWebLinksUnderlineOnlyWhileHovered() throws {
        let output = OutputTextView()
        output.append(.init(text: "Visit https://example.com/path"))
        output.flushPendingOutput()

        let view = output.primaryOutputViewForTesting
        view.selectAllContent()
        let selected = try XCTUnwrap(view.selectedAttributedString())
        let linkRange = (selected.string as NSString).range(of: "https://example.com/path")
        let lineID = try XCTUnwrap(output.retainedLines.first?.id)

        let beforeHover = try XCTUnwrap(view.drawnAttributedTextForTesting(at: 0))
        XCTAssertNil(beforeHover.attribute(.underlineStyle, at: linkRange.location, effectiveRange: nil))

        view.setHoveredLinkForTesting(itemID: lineID, range: linkRange)
        let whileHovered = try XCTUnwrap(view.drawnAttributedTextForTesting(at: 0))
        XCTAssertEqual(
            whileHovered.attribute(.underlineStyle, at: linkRange.location, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )

        view.setHoveredLinkForTesting(itemID: nil)
        let afterHover = try XCTUnwrap(view.drawnAttributedTextForTesting(at: 0))
        XCTAssertNil(afterHover.attribute(.underlineStyle, at: linkRange.location, effectiveRange: nil))
    }

    func testBrowserLinksRequireCommandClick() throws {
        let output = OutputTextView()
        output.append(.init(text: "https://example.com"))
        output.flushPendingOutput()
        let view = output.primaryOutputViewForTesting
        view.selectAllContent()
        let selected = try XCTUnwrap(view.selectedAttributedString())
        let linkRange = (selected.string as NSString).range(of: "https://example.com")
        let lineID = try XCTUnwrap(output.retainedLines.first?.id)
        var openedURL: URL?
        view.onLink = { openedURL = $0 }

        view.activateLinkForTesting(itemID: lineID, at: linkRange.location, modifierFlags: [])
        XCTAssertNil(openedURL)

        view.activateLinkForTesting(itemID: lineID, at: linkRange.location, modifierFlags: [.command])
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com")
    }

    func testInlinePreviewsDiscoverVisibleImageURLsAndDeduplicateInSourceOrder() throws {
        let output = OutputTextView()
        let explicit = URL(string: "https://example.test/explicit")!
        let duplicate = URL(string: "https://example.test/duplicate.png")!
        let line = RenderedLine(
            text: "\(duplicate.absoluteString) https://example.test/second.JPEG?size=2#hero ftp://example.test/no.png",
            assets: [
                .init(kind: .image, source: explicit, altText: "Explicit", characterOffset: 200),
                .init(kind: .image, source: duplicate, altText: "Duplicate", characterOffset: 0),
                .init(kind: .avatar, source: URL(string: "https://example.test/avatar.png")!, altText: "Avatar", characterOffset: 0),
            ]
        )

        output.append(line)
        XCTAssertEqual(output.primaryOutputViewForTesting.inlinePreviewSourcesForTesting(at: 0), [])

        output.showsInlineImagePreviews = true
        XCTAssertEqual(
            output.primaryOutputViewForTesting.inlinePreviewSourcesForTesting(at: 0),
            [duplicate, URL(string: "https://example.test/second.JPEG?size=2#hero")!, explicit]
        )
        XCTAssertEqual(output.primaryOutputViewForTesting.previewDownloadCountForTesting, 0)
    }

    func testInlinePreviewBoxesAreCappedStackedAndShrinkWithNarrowOutput() {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        view.showsInlineImagePreviews = true
        let previews = [
            VirtualizedOutputView.InlinePreview(source: URL(string: "https://example.test/one.png")!),
            VirtualizedOutputView.InlinePreview(source: URL(string: "https://example.test/two.png")!),
        ]
        view.setItems([.init(
            id: UUID(),
            attributedText: NSAttributedString(string: "line\n"),
            contentRange: NSRange(location: 0, length: 4),
            assets: [],
            previews: previews
        )])

        var rects = view.previewRectsForTesting(at: 0)
        XCTAssertEqual(rects.count, 2)
        XCTAssertEqual(rects[0].width, 240, accuracy: 0.1)
        XCTAssertEqual(rects[0].height, 160, accuracy: 0.1)
        XCTAssertEqual(rects[1].minY - rects[0].maxY, 6, accuracy: 0.1)
        XCTAssertGreaterThan(view.measuredHeightForTesting(at: 0) ?? 0, 320)

        view.setFrameSize(NSSize(width: 100, height: 200))
        rects = view.previewRectsForTesting(at: 0)
        XCTAssertLessThan(rects[0].width, 100)
        XCTAssertEqual(rects[0].height / rects[0].width, 160.0 / 240.0, accuracy: 0.01)
    }

    func testInlinePreviewBoxesStayInsideTriggerParagraphContentBounds() throws {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        view.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        view.showsInlineImagePreviews = true
        view.setItems([.init(
            id: UUID(),
            attributedText: NSAttributedString(string: "line\n"),
            contentRange: NSRange(location: 0, length: 4),
            assets: [],
            previews: [.init(source: URL(string: "https://example.test/image.png")!)],
            paragraph: .init(leftIndent: 20, rightIndent: 30, borderWidth: 8)
        )])

        let preview = try XCTUnwrap(view.previewRectsForTesting(at: 0).first)
        XCTAssertEqual(preview.minX, 108, accuracy: 0.1)
        XCTAssertEqual(preview.maxX, 342, accuracy: 0.1)
        XCTAssertEqual(preview.width, 234, accuracy: 0.1)
        XCTAssertEqual(preview.height / preview.width, 160.0 / 240.0, accuracy: 0.01)
    }

    func testInlinePreviewClicksRequireCommandModifier() {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.showsInlineImagePreviews = true
        let id = UUID()
        let url = URL(string: "https://example.test/image.webp")!
        view.setItems([.init(
            id: id,
            attributedText: NSAttributedString(string: "source\n"),
            contentRange: NSRange(location: 0, length: 6),
            assets: [],
            previews: [.init(source: url)]
        )])
        var opened: URL?
        view.onLink = { opened = $0 }

        view.activatePreviewForTesting(itemID: id, source: url, modifierFlags: [])
        XCTAssertNil(opened)
        view.activatePreviewForTesting(itemID: id, source: url, modifierFlags: [.command])
        XCTAssertEqual(opened, url)
    }

    func testExplicitLinkActionsTakePrecedenceOverAutomaticWebLinks() throws {
        let output = OutputTextView()
        let text = "https://example.com"
        let run = StyleRun(
            range: 0..<text.utf16.count,
            style: TextStyle(link: .send("look", hints: ["urgent"]))
        )
        output.append(.init(text: text, runs: [run]))
        output.selectAll()

        let selected = try XCTUnwrap(output.primaryOutputViewForTesting.selectedAttributedString())
        let link = try XCTUnwrap(selected.attribute(.link, at: 0, effectiveRange: nil) as? URL)
        let components = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false))
        XCTAssertEqual(link.scheme, "beipmu-action")
        XCTAssertEqual(components.host, "send")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "value" })?.value, "look")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "hint" })?.value, "urgent")
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
        writer.append(.init(text: "live line"))
        writer.appendTyped("look")
        writer.appendSent("north")
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
