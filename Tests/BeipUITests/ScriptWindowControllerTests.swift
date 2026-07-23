import AppKit
import BeipScriptRuntime
@testable import BeipUI
import XCTest

@MainActor
final class ScriptWindowControllerTests: XCTestCase {
    func testFixedTextWindowIsAccessibleAndAppliesReplayOperations() {
        let create = ScriptWindowOperation(
            identifier: "fixed-1",
            kind: "fixed",
            action: "create",
            numbers: [20, 4]
        )
        let controller = ScriptWindowController(operation: create)
        controller.apply(.init(identifier: "fixed-1", kind: "fixed", action: "title", strings: ["HUD"]), relativeTo: nil)
        controller.apply(.init(identifier: "fixed-1", kind: "fixed", action: "writeAt", strings: ["HP: 42"], numbers: [2, 1]), relativeTo: nil)

        XCTAssertEqual(controller.window?.title, "HUD")
        XCTAssertEqual(controller.window?.accessibilityIdentifier(), "scriptFixedWindow")
        let text = recursiveSubviews(of: controller.window?.contentView).compactMap { $0 as? NSTextView }.first
        XCTAssertTrue(text?.string.contains("  HP: 42") == true)
        XCTAssertEqual(text?.accessibilityLabel(), "Script fixed text")
        controller.close()
    }

    func testGraphicsWindowExposesCanvasAccessibility() {
        let controller = ScriptWindowController(operation: .init(
            identifier: "graphics-1",
            kind: "graphics",
            action: "create",
            numbers: [320, 200]
        ))
        controller.apply(.init(identifier: "graphics-1", kind: "graphics", action: "pixel", numbers: [1, 2, 255]), relativeTo: nil)

        XCTAssertEqual(controller.window?.contentView?.accessibilityLabel(), "Script graphics canvas")
        controller.close()
    }

    private func recursiveSubviews(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { recursiveSubviews(of: $0) }
    }
}
