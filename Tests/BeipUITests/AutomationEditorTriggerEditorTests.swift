import BeipAutomation
import AppKit
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class AutomationEditorTriggerEditorTests: XCTestCase {
    func testTriggerOutlineNewTargetsSelectedCharacterScope() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer(named: "TestServer")
        let characterID = try workspace.addCharacter(toServerID: serverID, named: "Wizard")
        let library = ProfileLibrary(workspace: workspace)
        let characterScope = LegacyConfigurationWorkspace.AutomationScope.character(
            server: serverID,
            character: characterID
        )
        let controller = AutomationEditorWindowController(
            library: library,
            kind: .triggers,
            scope: characterScope
        )
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "triggerScopeOutline" }
        )
        let characterRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Wizard", in: outline))
        outline.selectRowIndexes(.init(integer: characterRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let new = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: content)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "New" }
        )
        new.performClick(nil)

        let savedServer = try XCTUnwrap(
            library.workspace.servers.first { $0.profile.name == "TestServer" }
        )
        let savedCharacter = try XCTUnwrap(
            savedServer.characters.first { $0.name == "Wizard" }
        )
        let savedCharacterScope = LegacyConfigurationWorkspace.AutomationScope.character(
            server: savedServer.profile.id,
            character: savedCharacter.id
        )
        XCTAssertEqual(library.workspace.triggers(in: savedCharacterScope).count, 1)
        XCTAssertEqual(library.workspace.globalTriggers.count, 0)
    }

    func testTriggerOutlineRendersAndEditsNestedChildren() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspaceWithNestedGlobalTrigger())
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try AutomationEditorTestSupport.triggerOutline(in: content)
        let childRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Child", in: outline))
        outline.selectRowIndexes(.init(integer: childRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let description = try AutomationEditorTestSupport.textField(identifier: "triggerDescription", in: content)
        description.stringValue = "Edited Child"
        let apply = try AutomationEditorTestSupport.button(titled: "Apply", in: content)
        apply.performClick(nil)

        XCTAssertEqual(library.workspace.trigger(at: [0, 0], in: .global)?.description, "Edited Child")
        XCTAssertEqual(library.workspace.trigger(at: [0], in: .global)?.description, "Parent")
    }

    func testTriggerOutlineNewCopyAndDeleteWorkAtNestedDepth() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspaceWithNestedGlobalTrigger())
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try AutomationEditorTestSupport.triggerOutline(in: content)
        let parentRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Parent", in: outline))
        outline.selectRowIndexes(.init(integer: parentRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        try AutomationEditorTestSupport.button(titled: "New", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).first?.children.count, 2)
        XCTAssertEqual(library.workspace.trigger(at: [0, 1], in: .global)?.description, "New Trigger")

        let newRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "New Trigger", in: outline))
        outline.selectRowIndexes(.init(integer: newRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try AutomationEditorTestSupport.button(titled: "Copy", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).first?.children.count, 3)
        XCTAssertEqual(library.workspace.trigger(at: [0, 2], in: .global)?.description, "Copy of New Trigger")

        let copiedRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Copy of New Trigger", in: outline))
        outline.selectRowIndexes(.init(integer: copiedRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try AutomationEditorTestSupport.button(titled: "Delete", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).first?.children.count, 2)
        XCTAssertNil(library.workspace.trigger(at: [0, 2], in: .global))
    }

    func testTriggerSamplesRenderAndCopyIntoSelectedScope() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspace(
            """
            Version=331
            Connections {
              Triggers { Active=true }
            }
            """
        ))
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let editable = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "triggerScopeOutline" }
        )
        let samples = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "triggerSamplesOutline" }
        )

        for title in [
            "Activity Sound",
            "Speak all text",
            "Highlight words",
            "Censor bad words",
            "Rainbow Text (Hash coloring)",
        ] {
            XCTAssertNotNil(AutomationEditorTestSupport.row(titled: title, in: samples), "Missing trigger sample: \(title)")
        }

        let globalRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Global", in: editable))
        editable.selectRowIndexes(.init(integer: globalRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: editable
        ))
        let sampleRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Rainbow Text (Hash coloring)", in: samples))
        samples.selectRowIndexes(.init(integer: sampleRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: samples
        ))

        try AutomationEditorTestSupport.button(identifier: "triggerCopy", in: content).performClick(nil)

        let copied = try XCTUnwrap(library.workspace.trigger(at: [0], in: .global))
        XCTAssertEqual(copied.description, "Rainbow Text (Hash coloring)")
        XCTAssertTrue(copied.actions.contains(.colorHash(foreground: true, background: false, wholeLine: true)))
    }

    func testTriggerOutlineMoveButtonsReorderIndentAndOutdent() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspace(
            """
            Version=331
            Connections {
              Triggers {
                Active=true
                { Description="Parent" Folder=true FindString { MatchText="parent" }
                  Triggers { { Description="Child" FindString { MatchText="child" } } }
                }
                { Description="Second" FindString { MatchText="second" } }
                { Description="Third" FindString { MatchText="third" } }
              }
            }
            """
        ))
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try AutomationEditorTestSupport.triggerOutline(in: content)

        outline.selectRowIndexes(.init(integer: try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Second", in: outline))), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try AutomationEditorTestSupport.button(titled: "Up", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).map(\.description), ["Second", "Parent", "Third"])

        outline.selectRowIndexes(.init(integer: try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Third", in: outline))), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try AutomationEditorTestSupport.button(titled: "In", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).map(\.description), ["Second", "Parent"])
        XCTAssertEqual(library.workspace.trigger(at: [1], in: .global)?.children.map(\.description), ["Child", "Third"])

        outline.selectRowIndexes(.init(integer: try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Third", in: outline))), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try AutomationEditorTestSupport.button(titled: "Out", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).map(\.description), ["Second", "Parent", "Third"])
        XCTAssertEqual(library.workspace.trigger(at: [1], in: .global)?.children.map(\.description), ["Child"])

        outline.selectRowIndexes(.init(integer: try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Second", in: outline))), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try AutomationEditorTestSupport.button(titled: "Down", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).map(\.description), ["Parent", "Second", "Third"])
    }

    func testTriggerOutlinePreservesSelectionByIdentityAfterReloadedReorder() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspace(
            """
            Version=331
            Connections {
              Triggers {
                Active=true
                { Description="First" FindString { MatchText="first" } }
                { Description="Second" FindString { MatchText="second" } }
              }
            }
            """
        ))
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try AutomationEditorTestSupport.triggerOutline(in: content)
        outline.selectRowIndexes(.init(integer: try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Second", in: outline))), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        XCTAssertEqual(try AutomationEditorTestSupport.textField(identifier: "triggerDescription", in: content).stringValue, "Second")

        try library.mutate {
            _ = try $0.moveTrigger(at: [1], in: .global, toParentPath: [], index: 0)
        }
        let afterCount = try AutomationEditorTestSupport.textField(identifier: "triggerScopeAfterCount", in: content)
        afterCount.stringValue = "1"
        try AutomationEditorTestSupport.button(titled: "Save Post Count", in: content).performClick(nil)

        XCTAssertEqual(library.workspace.triggers(in: .global).map(\.description), ["Second", "First"])
        XCTAssertEqual(try AutomationEditorTestSupport.textField(identifier: "triggerDescription", in: content).stringValue, "Second")
        let selectedRow = outline.selectedRow
        let selectedCell = outline.view(atColumn: 0, row: selectedRow, makeIfNecessary: true) as? NSTableCellView
        XCTAssertEqual(selectedCell?.textField?.stringValue, "Second")
    }

    func testTriggerOutlineIncludesPuppetScopes() throws {
        let workspace = try AutomationEditorTestSupport.workspace(
            """
            Version=331
            Connections {
              Shortcuts {
                World {
                  Host="world.example:8888"
                  Characters {
                    Hero {
                      Puppets {
                        Bot {
                          Triggers { Active=true { Description="Puppet Trigger" FindString { MatchText="bot" } } }
                        }
                      }
                    }
                  }
                }
              }
            }
            """
        )
        let controller = AutomationEditorWindowController(library: ProfileLibrary(workspace: workspace), kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try AutomationEditorTestSupport.triggerOutline(in: content)

        XCTAssertNotNil(AutomationEditorTestSupport.row(titled: "Bot", in: outline))
        XCTAssertNotNil(AutomationEditorTestSupport.row(titled: "Puppet Trigger", in: outline))
    }

    func testTriggerEditorKeepsScopeActiveAndPersistsAfterCount() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspaceWithNestedGlobalTrigger())
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try AutomationEditorTestSupport.triggerOutline(in: content)
        let globalRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Global", in: outline))
        outline.selectRowIndexes(.init(integer: globalRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let afterCount = try AutomationEditorTestSupport.textField(identifier: "triggerScopeAfterCount", in: content)
        afterCount.stringValue = "1"
        try AutomationEditorTestSupport.button(titled: "Save Post Count", in: content).performClick(nil)

        let group = library.workspace.triggerGroup(in: .global)
        XCTAssertTrue(group.active)
        XCTAssertEqual(group.afterCount, 1)
    }

    func testTriggerEditorPersistsFolderCheckbox() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspaceWithNestedGlobalTrigger())
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try AutomationEditorTestSupport.triggerOutline(in: content)
        let parentRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Parent", in: outline))
        outline.selectRowIndexes(.init(integer: parentRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let folder = try AutomationEditorTestSupport.button(titled: "Folder", in: content)
        folder.state = .on
        try AutomationEditorTestSupport.button(titled: "Apply", in: content).performClick(nil)

        XCTAssertTrue(library.workspace.trigger(at: [0], in: .global)?.folder == true)
        XCTAssertEqual(library.workspace.trigger(at: [0], in: .global)?.children.first?.description, "Child")
    }

    func testTriggerEditorProvidesKeyboardReachableOutlineControlsAndApply() throws {
        let library = ProfileLibrary(workspace: try AutomationEditorTestSupport.workspaceWithNestedGlobalTrigger())
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let outline = try AutomationEditorTestSupport.triggerOutline(in: content)
        XCTAssertTrue(outline.acceptsFirstResponder)
        let childRow = try XCTUnwrap(AutomationEditorTestSupport.row(titled: "Child", in: outline))
        outline.selectRowIndexes(.init(integer: childRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let apply = try AutomationEditorTestSupport.button(identifier: "triggerApply", in: content)
        XCTAssertEqual(apply.keyEquivalent, "\r")
        for identifier in [
            "triggerNew",
            "triggerCopy",
            "triggerDelete",
            "triggerMoveUp",
            "triggerMoveDown",
            "triggerMoveIn",
            "triggerMoveOut",
            "triggerScopeApply",
        ] {
            XCTAssertNotNil(try? AutomationEditorTestSupport.button(identifier: identifier, in: content), "Missing keyboard-reachable control: \(identifier)")
        }
    }
}
