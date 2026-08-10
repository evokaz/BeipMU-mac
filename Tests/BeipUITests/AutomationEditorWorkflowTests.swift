import BeipAutomation
import AppKit
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class AutomationEditorWorkflowTests: XCTestCase {
    func testAutomationDebuggerDisplaysTriggerSkipReasons() throws {
        let controller = AutomationDebugWindowController(kind: .triggers)
        defer { controller.close() }

        controller.append([
            .init(
                engine: .trigger,
                description: "Cooldown",
                pattern: "alert",
                input: "alert",
                matchCount: 0,
                output: "alert",
                reason: "Skipped: cooldown active"
            ),
        ])

        let text = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: controller.window?.contentView)
                .compactMap { $0 as? NSTextView }
                .first { $0.accessibilityIdentifier() == "triggersDebuggerLog" }
        )
        XCTAssertTrue(text.string.contains("reason: Skipped: cooldown active"))
    }

    func testTriggerSelectionPromptSavesDetailAndScopeValuesBeforeSwitching() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspace(
            """
            Version=331
            Connections {
              Triggers { Active=true AfterCount=2
                { Description="First" FindString { MatchText="one" } }
                { Description="Second" FindString { MatchText="two" } }
              }
            }
            """
        ))
        var decisions: [SettingsPromptDecision] = [.save]
        let controller = AutomationEditorWindowController(
            library: library,
            kind: .triggers,
            promptDecisionProvider: { _ in decisions.removeFirst() }
        )
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        let outline = try AutomationEditorTestSupport.triggerOutline(in: content)
        let firstRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "First", in: outline))
        let secondRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Second", in: outline))
        outline.selectRowIndexes(.init(integer: firstRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        try AutomationEditorTestSupport.textField(identifier: "triggerDescription", in: content).stringValue = "Edited First"
        try AutomationEditorTestSupport.textField(identifier: "triggerScopeAfterCount", in: content).stringValue = "7"
        outline.selectRowIndexes(.init(integer: secondRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        XCTAssertEqual(library.workspace.trigger(at: [0], in: .global)?.description, "Edited First")
        XCTAssertEqual(library.workspace.triggerGroup(in: .global).afterCount, 7)
        XCTAssertEqual(try AutomationEditorTestSupport.textField(identifier: "triggerDescription", in: content).stringValue, "Second")
    }

    func testAliasSelectionPromptCancelRestoresDetailValues() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspace(
            """
            Version=331
            Connections {
              Aliases {
                { Description="First" Replace="one" FindString.MatchText="one" }
                { Description="Second" Replace="two" FindString.MatchText="two" }
              }
            }
            """
        ))
        var decisions: [SettingsPromptDecision] = [.cancel]
        let controller = AutomationEditorWindowController(
            library: library,
            kind: .aliases,
            promptDecisionProvider: { _ in decisions.removeFirst() }
        )
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        let outline = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "aliasScopeOutline" }
        )
        let firstRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "First", in: outline))
        let secondRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Second", in: outline))
        outline.selectRowIndexes(.init(integer: firstRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try AutomationEditorTestSupport.textField(identifier: "aliasDescription", in: content).stringValue = "Edited First"

        outline.selectRowIndexes(.init(integer: secondRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        XCTAssertEqual(try AutomationEditorTestSupport.textField(identifier: "aliasDescription", in: content).stringValue, "Edited First")
        XCTAssertEqual(library.workspace.alias(at: [0], in: .global)?.description, "First")
        XCTAssertEqual(outline.selectedRow, firstRow)
    }

    func testMacroSelectionPromptSavesDetailsBeforeSwitching() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspace(
            """
            Version=331
            Connections {
              KeyboardMacros2 { Active=true
                { Description="First" Macro="one" key=Control+Option+1 }
                { Description="Second" Macro="two" key=Control+Option+2 }
              }
            }
            """
        ))
        var decisions: [SettingsPromptDecision] = [.save]
        let controller = AutomationEditorWindowController(
            library: library,
            kind: .macros,
            promptDecisionProvider: { _ in decisions.removeFirst() }
        )
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        let outline = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "macroScopeOutline" }
        )
        let firstRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "First", in: outline))
        let secondRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Second", in: outline))
        outline.selectRowIndexes(.init(integer: firstRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try AutomationEditorTestSupport.textField(identifier: "macroDescription", in: content).stringValue = "Edited First"

        outline.selectRowIndexes(.init(integer: secondRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        XCTAssertEqual(library.workspace.macro(at: [0], in: .global)?.description, "Edited First")
        XCTAssertEqual(try AutomationEditorTestSupport.textField(identifier: "macroDescription", in: content).stringValue, "Second")
    }
}
