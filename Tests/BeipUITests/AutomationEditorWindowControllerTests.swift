import AppKit
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class AutomationEditorWindowControllerTests: XCTestCase {
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
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "triggerScopeOutline" }
        )
        let characterRow = try XCTUnwrap(row(titled: "Wizard", in: outline))
        outline.selectRowIndexes(.init(integer: characterRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let new = try XCTUnwrap(
            recursiveSubviews(of: content)
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

    private func row(titled title: String, in outline: NSOutlineView) -> Int? {
        for row in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  cell.textField?.stringValue == title else { continue }
            return row
        }
        return nil
    }

    private func recursiveSubviews(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { recursiveSubviews(of: $0) }
    }
}
