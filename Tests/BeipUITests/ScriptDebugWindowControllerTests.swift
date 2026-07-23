import AppKit
@testable import BeipUI
import XCTest

@MainActor
final class ScriptDebugWindowControllerTests: XCTestCase {
    func testDebuggerDisplaysCategorizedEntriesAndAccessibleControls() {
        let controller = ScriptDebugWindowController(title: "Example")
        defer { controller.close() }
        controller.replace(with: [
            .init(kind: .text, message: "value"),
            .init(kind: .html, message: "<b>value</b>"),
            .init(kind: .error, message: "boom"),
        ])

        XCTAssertEqual(controller.window?.title, "Script Debugger - Example")
        XCTAssertEqual(controller.window?.accessibilityIdentifier(), "scriptDebugger")
        XCTAssertTrue(controller.displayedText.contains("[Debug] value"))
        XCTAssertTrue(controller.displayedText.contains("[Debug HTML] <b>value</b>"))
        XCTAssertTrue(controller.displayedText.contains("[Error] boom"))

        let identifiers = recursiveSubviews(of: controller.window?.contentView)
            .compactMap { $0.accessibilityIdentifier() }
        XCTAssertTrue(identifiers.contains("scriptDebuggerLog"))
        XCTAssertTrue(identifiers.contains("scriptDebuggerReset"))
        XCTAssertTrue(identifiers.contains("scriptDebuggerClear"))
    }

    func testClearAndResetCallback() throws {
        let controller = ScriptDebugWindowController(title: "Example")
        defer { controller.close() }
        controller.append(.init(kind: .runtime, message: "ready"))
        controller.clear()
        XCTAssertEqual(controller.displayedText, "")

        var reset = false
        controller.onReset = { reset = true }
        let button = try XCTUnwrap(recursiveSubviews(of: controller.window?.contentView)
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "scriptDebuggerReset" })
        button.performClick(nil)
        XCTAssertTrue(reset)
    }

    private func recursiveSubviews(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { recursiveSubviews(of: $0) }
    }
}
