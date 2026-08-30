import AppKit
import BeipCore
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class OutputRenderingScaleTests: XCTestCase {
    func testOutputRenderingScaleKeepsRetentionAndPaintWorkBounded() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let output = OutputTextView()
        output.historyLimit = 5_000
        window.contentView = output.containerView
        output.containerView.layoutSubtreeIfNeeded()

        for index in 0..<25_000 {
            output.append(.init(text: "Sustained output \(index) — UTF-8 ✓"))
        }
        XCTAssertLessThanOrEqual(output.pendingOutputLineCountForTesting, 5_000)
        XCTAssertEqual(output.renderedLineCount, 0)
        output.flushPendingOutput()

        XCTAssertEqual(output.visibleLineCount, 5_000)
        XCTAssertEqual(output.renderedLineCount, 5_000)
        XCTAssertLessThan(output.visiblePaintCandidateCount, 100)
        XCTAssertGreaterThan(output.sliceCountForTesting, 1)
        XCTAssertLessThanOrEqual(output.maxLinesPerSliceForTesting, 256)
        XCTAssertEqual(output.pendingOutputLineCountForTesting, 0)
        XCTAssertTrue(isAtBottom(output.primaryScrollViewForTesting))
    }

    func testOutputRenderingScaleReleasesRetainedHistory() {
        weak var releasedOutput: OutputTextView?
        weak var releasedContainer: NSSplitView?
        autoreleasepool {
            let output = OutputTextView()
            output.historyLimit = 1_000
            for index in 0..<5_000 {
                output.append(.init(text: "Lifecycle output \(index)"))
            }
            output.flushPendingOutput()
            releasedOutput = output
            releasedContainer = output.containerView
        }

        XCTAssertNil(releasedOutput)
        XCTAssertNil(releasedContainer)
    }

    func testGroupedBackgroundTabBurstRendersInOrderAndReachesBottom() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let selected = ClientWindowController(profileLibrary: library)
        let background = ClientWindowController(profileLibrary: library)
        defer {
            selected.close()
            background.close()
        }
        let group = ClientTabGroup(selected)
        group.add(background)
        group.select(selected, sender: nil)
        background.clearOutput()
        let output = background.outputForTesting
        let selectedRebuilds = selected.sessionTabRebuildCountForTesting

        for index in 0..<2_000 {
            output.append(.init(text: "Grouped burst \(index)"))
            background.markActivityForTesting()
        }
        background.presentPendingActivityForTesting()
        output.flushPendingOutput()

        XCTAssertEqual(
            output.retainedLines.map(\.text),
            (0..<2_000).map { "Grouped burst \($0)" }
        )
        XCTAssertEqual(background.unreadCountForTesting, 2_000)
        XCTAssertEqual(background.activityPresentationCountForTesting, 1)
        XCTAssertEqual(selected.sessionTabRebuildCountForTesting, selectedRebuilds + 1)
        XCTAssertTrue(isAtBottom(output.primaryScrollViewForTesting))
    }

    private func isAtBottom(_ scrollView: NSScrollView) -> Bool {
        let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentSize.height)
        return maxY - scrollView.contentView.bounds.origin.y <= 1
    }
}
