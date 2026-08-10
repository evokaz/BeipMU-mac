import BeipAutomation
import AppKit
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class AutomationEditorAliasTests: XCTestCase {
    func testAliasEditorRendersReferenceLayoutAndEditsNestedAlias() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspaceWithNestedGlobalAlias())
        let controller = AutomationEditorWindowController(library: library, kind: .aliases)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let outline = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "aliasScopeOutline" }
        )
        XCTAssertNotNil(try? AutomationEditorTestSupport.button(identifier: "aliasApply", in: content))
        XCTAssertNotNil(try? AutomationEditorTestSupport.button(identifier: "aliasHelp", in: content))

        let childRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Child", in: outline))
        outline.selectRowIndexes(.init(integer: childRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let description = try AutomationEditorTestSupport.textField(identifier: "aliasDescription", in: content)
        description.stringValue = "Edited Child"
        let example = try AutomationEditorTestSupport.textView(identifier: "aliasTestString", in: content)
        example.string = "x"
        let replacement = try AutomationEditorTestSupport.textView(identifier: "aliasReplacement", in: content)
        replacement.string = "edited"
        try AutomationEditorTestSupport.button(identifier: "aliasApply", in: content).performClick(nil)

        let edited = try XCTUnwrap(library.workspace.alias(at: [0, 0], in: .global))
        XCTAssertEqual(edited.description, "Edited Child")
        XCTAssertEqual(edited.example, "x")
        XCTAssertEqual(edited.replacement, "edited")
    }

    func testAliasProcessingOptionsBelongToSelectedAliasAndPersist() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspaceWithNestedGlobalAlias())
        let controller = AutomationEditorWindowController(library: library, kind: .aliases)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "aliasScopeOutline" }
        )
        let childRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Child", in: outline))
        outline.selectRowIndexes(.init(integer: childRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let process = try AutomationEditorTestSupport.button(identifier: "aliasProcessAliases", in: content)
        let echo = try AutomationEditorTestSupport.button(identifier: "aliasEcho", in: content)
        let commands = try AutomationEditorTestSupport.button(identifier: "aliasProcessCommands", in: content)
        XCTAssertEqual(process.state, .on)
        XCTAssertEqual(echo.state, .on)
        XCTAssertEqual(commands.state, .off)

        process.performClick(nil)
        echo.performClick(nil)
        commands.performClick(nil)
        XCTAssertEqual(process.state, .off)
        XCTAssertEqual(echo.state, .off)
        XCTAssertEqual(commands.state, .on)
        try AutomationEditorTestSupport.button(identifier: "aliasApply", in: content).performClick(nil)

        let edited = try XCTUnwrap(library.workspace.alias(at: [0, 0], in: .global))
        XCTAssertFalse(edited.active)
        XCTAssertFalse(edited.echo)
        XCTAssertTrue(edited.processCommands)
        XCTAssertTrue(try library.workspace.renderedDocument().serialized().contains("ProcessCommands=true"))
    }

    func testAliasFolderDisablesProcessingControlsAndSamplesCopyIndependently() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspaceWithNestedGlobalAlias())
        let controller = AutomationEditorWindowController(library: library, kind: .aliases)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "aliasScopeOutline" }
        )
        let folderRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Folder", in: outline))
        outline.selectRowIndexes(.init(integer: folderRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        XCTAssertEqual(try AutomationEditorTestSupport.button(identifier: "aliasFolder", in: content).state, .on)
        XCTAssertFalse(try AutomationEditorTestSupport.button(identifier: "aliasRegularExpression", in: content).isEnabled)
        XCTAssertFalse(try AutomationEditorTestSupport.textView(identifier: "aliasTestString", in: content).isEditable)
        XCTAssertFalse(try AutomationEditorTestSupport.textView(identifier: "aliasReplacement", in: content).isEditable)

        let samples = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "aliasSamplesOutline" }
        )
        let sampleRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Repeat 'buy torch' command n times", in: samples))
        samples.selectRowIndexes(.init(integer: sampleRow), byExtendingSelection: false)
        try AutomationEditorTestSupport.button(identifier: "aliasCopy", in: content).performClick(nil)

        XCTAssertEqual(library.workspace.alias(at: [0, 1], in: .global)?.description, "Repeat 'buy torch' command n times")
        XCTAssertEqual(library.workspace.alias(at: [0, 1], in: .global)?.example, "bt 5")
    }
}
