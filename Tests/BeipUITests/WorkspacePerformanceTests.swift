import AppKit
import BeipCore
@testable import BeipUI
import XCTest

@MainActor
final class WorkspacePerformanceTests: XCTestCase {
    func testSustainedRendererKeepsRetentionAndPaintWorkBounded() {
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

        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<25_000 {
            output.append(.init(text: "Sustained output \(index) — UTF-8 ✓"))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertEqual(output.visibleLineCount, 5_000)
        XCTAssertEqual(output.renderedLineCount, 5_000)
        XCTAssertLessThan(output.visiblePaintCandidateCount, 100)
        XCTAssertLessThan(elapsed, 15, "Debug renderer throughput regressed below the Milestone 3 budget")
    }

    func testRendererAndRetainedHistoryReleaseAfterSustainedUse() {
        weak var releasedOutput: OutputTextView?
        weak var releasedContainer: NSSplitView?
        autoreleasepool {
            let output = OutputTextView()
            output.historyLimit = 1_000
            for index in 0..<5_000 {
                output.append(.init(text: "Lifecycle output \(index)"))
            }
            releasedOutput = output
            releasedContainer = output.containerView
        }

        XCTAssertNil(releasedOutput)
        XCTAssertNil(releasedContainer)
    }
}
