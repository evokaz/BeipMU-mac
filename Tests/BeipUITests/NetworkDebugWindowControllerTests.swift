import AppKit
@testable import BeipUI
import XCTest

@MainActor
final class NetworkDebugWindowControllerTests: XCTestCase {
    func testWindowExposesAccessibleControlsAndFormatsBothDirections() throws {
        let controller = NetworkDebugWindowController(title: "Example")
        defer { controller.close() }

        XCTAssertEqual(controller.window?.title, "Network Debugger - Example")
        XCTAssertEqual(controller.window?.accessibilityIdentifier(), "networkDebugger")

        controller.append(Data([255, 251]), received: true)
        controller.append(Data([201]), received: true)
        controller.append(Data([255, 253, 24]), received: false)

        XCTAssertTrue(controller.displayedText.contains("Received 2 bytes"))
        XCTAssertTrue(controller.displayedText.contains("IAC WILL"))
        XCTAssertTrue(controller.displayedText.contains("GMCP(201)"))
        XCTAssertTrue(controller.displayedText.contains("Sent 3 bytes"))
        XCTAssertTrue(controller.displayedText.contains("IAC DO"))
        XCTAssertTrue(controller.displayedText.contains("TTYPE(24)"))

        let identifiers = recursiveSubviews(of: controller.window?.contentView)
            .compactMap { $0.accessibilityIdentifier() }
        XCTAssertTrue(identifiers.contains("networkDebuggerLog"))
        XCTAssertTrue(identifiers.contains("networkDebuggerShowHex"))
        XCTAssertTrue(identifiers.contains("networkDebuggerShowTelnet"))
        XCTAssertTrue(identifiers.contains("networkDebuggerPause"))
        XCTAssertTrue(identifiers.contains("networkDebuggerCopy"))
        XCTAssertTrue(identifiers.contains("networkDebuggerClear"))
    }

    func testHexOnlyViewAndClear() {
        let controller = NetworkDebugWindowController(title: "Example")
        defer { controller.close() }
        controller.clear()
        controller.setShowHex(true)
        controller.setShowTelnet(false)

        controller.append(Data([0, 15, 255]), received: true)

        XCTAssertTrue(controller.displayedText.contains("00 0F FF"))
        XCTAssertFalse(controller.displayedText.contains("IAC"))
        controller.clear()
        XCTAssertEqual(controller.displayedText, "")
    }

    func testPauseBuffersEntriesWithoutLosingTelnetChunkState() {
        let controller = NetworkDebugWindowController(title: "Example")
        defer { controller.close() }
        controller.clear()
        controller.setPaused(true)

        controller.append(Data([255, 251]), received: true)
        controller.append(Data([201]), received: true)

        XCTAssertTrue(controller.paused)
        XCTAssertEqual(controller.pendingEntryCount, 2)
        XCTAssertEqual(controller.displayedText, "")

        controller.setPaused(false)

        XCTAssertFalse(controller.paused)
        XCTAssertEqual(controller.pendingEntryCount, 0)
        XCTAssertTrue(controller.displayedText.contains("IAC WILL"))
        XCTAssertTrue(controller.displayedText.contains("GMCP(201)"))
    }

    private func recursiveSubviews(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { recursiveSubviews(of: $0) }
    }
}
