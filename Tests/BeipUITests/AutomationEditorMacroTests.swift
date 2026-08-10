import BeipAutomation
import AppKit
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class AutomationEditorMacroTests: XCTestCase {
    func testMacroEditorUsesWindowsLayoutAndStagesApply() throws {
        let workspace = try AutomationEditorTestSupport.workspace(
            """
            Version=331
            Connections {
              KeyboardMacros2 { Active=true
                { Description="Folder" Folder=true Custom="keep"
                  KeyboardMacros2 { { Description="Child" Macro="north" key=Control+Alt+N Type=true } }
                }
              }
            }
            """
        )
        let library = ProfileLibrary(workspace: workspace)
        let controller = AutomationEditorWindowController(library: library, kind: .macros)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).width, 760, accuracy: 2)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height, 525, accuracy: 25)
        let outline = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "macroScopeOutline" }
        )
        XCTAssertNotNil(try? AutomationEditorTestSupport.button(identifier: "macroApply", in: content))
        XCTAssertNotNil(try? AutomationEditorTestSupport.button(identifier: "macroOK", in: content))
        XCTAssertNotNil(try? AutomationEditorTestSupport.button(identifier: "macroCancel", in: content))
        XCTAssertNotNil(try? AutomationEditorTestSupport.button(identifier: "macroHelp", in: content))

        let childRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Child", in: outline))
        outline.selectRowIndexes(.init(integer: childRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        let keyField = try AutomationEditorTestSupport.textField(identifier: "macroKeyCapture", in: content)
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        keyField.mouseDown(with: click)
        XCTAssertTrue(controller.window?.firstResponder === keyField)
        keyField.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .shift],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "m",
            charactersIgnoringModifiers: "m",
            isARepeat: false,
            keyCode: 46
        )))
        XCTAssertEqual(keyField.stringValue, "Control + Shift + M")
        XCTAssertEqual(keyField.accessibilityValue(), "Control + Shift + M")

        let description = try AutomationEditorTestSupport.textField(identifier: "macroDescription", in: content)
        description.stringValue = "Edited Child"
        try AutomationEditorTestSupport.button(identifier: "macroApply", in: content).performClick(nil)

        XCTAssertEqual(library.workspace.macro(at: [0, 0], in: .global)?.description, "Edited Child")
        XCTAssertEqual(library.workspace.macro(at: [0, 0], in: .global)?.key, "Control+Shift+M")
        XCTAssertTrue(try library.workspace.renderedDocument().serialized().contains("Custom=\"keep\""))
        XCTAssertTrue(try library.workspace.renderedDocument().serialized().contains("Type=true"))
    }

    func testMacroEditorIndentAndOutdentUseWorkspaceMovementAPIs() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspace(
            """
            Version=331
            Connections {
              KeyboardMacros2 { Active=true
                { Description="Folder" Folder=true
                  KeyboardMacros2 { { Description="Child" Macro="north" key=F1 } }
                }
                { Description="Second" Macro="south" key=F2 }
              }
            }
            """
        ))
        let controller = AutomationEditorWindowController(library: library, kind: .macros)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        let outline = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "macroScopeOutline" }
        )

        let secondRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Second", in: outline))
        outline.selectRowIndexes(.init(integer: secondRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try AutomationEditorTestSupport.button(identifier: "macroMoveIn", in: content).performClick(nil)
        try AutomationEditorTestSupport.button(identifier: "macroApply", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.macro(at: [0, 1], in: .global)?.description, "Second")

        let indentedRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Second", in: outline))
        outline.selectRowIndexes(.init(integer: indentedRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try AutomationEditorTestSupport.button(identifier: "macroMoveOut", in: content).performClick(nil)
        try AutomationEditorTestSupport.button(identifier: "macroApply", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.macro(at: [1], in: .global)?.description, "Second")
    }
}
