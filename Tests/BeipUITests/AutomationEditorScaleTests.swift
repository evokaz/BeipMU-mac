import BeipAutomation
import AppKit
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class AutomationEditorScaleTests: XCTestCase {
    func testTriggerEditorHandlesVeryLongStringsAndLargeTriggerTrees() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let longMatch = String(repeating: "very-long-match-", count: 600)
        let longSend = String(repeating: "send-long-action ", count: 600)
        for index in 0..<240 {
            try workspace.addTrigger(
                in: .global,
                trigger: Trigger(
                    description: "Bulk \(index)",
                    match: .init(text: index == 239 ? longMatch : "match-\(index)"),
                    actions: [.send(index == 239 ? longSend : "send-\(index)", captureIndex: 0, expandVariables: false)]
                )
            )
        }
        let library = ProfileLibrary(workspace: workspace)
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try AutomationEditorTestSupport.triggerOutline(in: content)

        let bulkRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Bulk 239", in: outline))
        outline.selectRowIndexes(.init(integer: bulkRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        XCTAssertEqual(try AutomationEditorTestSupport.textField(identifier: "triggerMatch", in: content).stringValue, longMatch)

        let description = try AutomationEditorTestSupport.textField(identifier: "triggerDescription", in: content)
        description.stringValue = "Bulk 239 Edited"
        try AutomationEditorTestSupport.button(identifier: "triggerApply", in: content).performClick(nil)

        XCTAssertEqual(library.workspace.triggers(in: .global).count, 240)
        XCTAssertEqual(library.workspace.trigger(at: [239], in: .global)?.description, "Bulk 239 Edited")
    }
}
