import AppKit
import BeipCore
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class ConfigurationManagerWindowControllerTests: XCTestCase {
    func testSwitchingFromLongCharacterFormKeepsWorldFormTopVisible() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer()
        _ = try workspace.addCharacter(toServerID: serverID)
        let controller = ConfigurationManagerWindowController(library: ProfileLibrary(workspace: workspace))
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let table = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSTableView }
                .first
        )
        let detailScroll = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSScrollView }
                .first { $0.accessibilityIdentifier() == "profileDetailScroll" }
        )

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        content.layoutSubtreeIfNeeded()
        detailScroll.contentView.scroll(to: NSPoint(x: 0, y: 500))

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        content.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(
            detailScroll.frame.height,
            content.bounds.height - 80,
            "The profile detail pane should consume the window height above the fixed footer."
        )
        let worldName = try XCTUnwrap(
            recursiveSubviews(of: content)
                .first { $0.accessibilityIdentifier() == "worldName" }
        )
        XCTAssertEqual(detailScroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        XCTAssertTrue(detailScroll.contentView.bounds.intersects(
            detailScroll.contentView.convert(worldName.bounds, from: worldName)
        ))
        let identifiers = Set(recursiveSubviews(of: content).compactMap { $0.accessibilityIdentifier() })
        XCTAssertFalse(identifiers.contains("worldAIEndpoint"))
        XCTAssertFalse(identifiers.contains("worldAIModel"))
    }

    func testCharacterFormUsesAccessibleNativeControls() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer()
        _ = try workspace.addCharacter(toServerID: serverID)
        let controller = ConfigurationManagerWindowController(library: ProfileLibrary(workspace: workspace))
        defer { controller.close() }

        let table = try XCTUnwrap(
            recursiveSubviews(of: controller.window?.contentView)
                .compactMap { $0 as? NSTableView }
                .first
        )
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))

        let views = recursiveSubviews(of: controller.window?.contentView)
        let identifiers = Set(views.compactMap { $0.accessibilityIdentifier() })
        XCTAssertEqual(controller.window?.title, "Worlds & Characters — Edited")
        XCTAssertEqual(controller.window?.accessibilityIdentifier(), "configurationManager")
        XCTAssertTrue(identifiers.contains("characterName"))
        XCTAssertTrue(identifiers.contains("characterPassword"))
        XCTAssertTrue(identifiers.contains("showCharacterPassword"))
        XCTAssertTrue(identifiers.contains("characterConnectText"))
        XCTAssertTrue(identifiers.contains("characterInfo"))
        XCTAssertTrue(identifiers.contains("autoConnect"))
        XCTAssertTrue(identifiers.contains("idleEnabled"))
        XCTAssertTrue(identifiers.contains("characterIdleMinutes"))
        XCTAssertTrue(identifiers.contains("characterIdleText"))
        XCTAssertTrue(identifiers.contains("characterLogFilename"))
        XCTAssertTrue(identifiers.contains("chooseCharacterLogFile"))
        XCTAssertTrue(identifiers.contains("characterLogDate"))
        XCTAssertTrue(identifiers.contains("applyProfileChanges"))

        let idleMinutes = try XCTUnwrap(
            views.compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "characterIdleMinutes" }
        )
        XCTAssertFalse(idleMinutes.isEnabled)

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let profileList = try XCTUnwrap(
            views.compactMap { $0 as? NSTableView }
                .first { $0.accessibilityIdentifier() == "configurationProfileList" }
        )
        let form = try XCTUnwrap(
            views.first { $0.accessibilityIdentifier() == "characterForm" }
        )
        let behavior = try XCTUnwrap(
            views.first { $0.accessibilityIdentifier() == "characterBehavior" }
        )
        let listFrame = content.convert(profileList.bounds, from: profileList)
        let formFrame = content.convert(form.bounds, from: form)
        let behaviorFrame = content.convert(behavior.bounds, from: behavior)
        XCTAssertLessThan(listFrame.minX, 40)
        XCTAssertLessThan(listFrame.width, 300)
        XCTAssertGreaterThan(formFrame.minX, 300)
        XCTAssertLessThan(formFrame.maxX, content.bounds.maxX)
        XCTAssertLessThan(formFrame.height, 400)
        XCTAssertLessThan(behaviorFrame.maxY, formFrame.minY)
        XCTAssertLessThan(behaviorFrame.maxX, content.bounds.maxX)
        XCTAssertLessThan(behaviorFrame.height, 220)
    }

    func testNewCharacterDisplaysItsCreationDate() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer()
        let characterID = try workspace.addCharacter(toServerID: serverID)
        let expectedDate = try XCTUnwrap(
            workspace.servers.first(where: { $0.profile.id == serverID })?
                .characters.first(where: { $0.id == characterID })?.created
        )
        let controller = ConfigurationManagerWindowController(library: ProfileLibrary(workspace: workspace))
        defer { controller.close() }

        let table = try XCTUnwrap(
            recursiveSubviews(of: controller.window?.contentView)
                .compactMap { $0 as? NSTableView }
                .first
        )
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))

        let dateField = try XCTUnwrap(
            recursiveSubviews(of: controller.window?.contentView)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "characterDateCreated" }
        )
        XCTAssertFalse(expectedDate.isEmpty)
        XCTAssertEqual(dateField.stringValue, expectedDate)
    }

    func testCopyingWorldAndCharacterAddsCopySuffix() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer(named: "World")
        _ = try workspace.addCharacter(toServerID: serverID, named: "Hero")
        let library = ProfileLibrary(workspace: workspace)
        let controller = ConfigurationManagerWindowController(library: library)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let table = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "configurationProfileList" }
        )
        let copy = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "copyWorld" }
        )

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        copy.performClick(nil)

        XCTAssertEqual(library.workspace.servers.map(\.profile.name), ["World", "World - copy"])

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        copy.performClick(nil)

        XCTAssertEqual(
            library.workspace.servers.first?.characters.map(\.name),
            ["Hero", "Hero - copy"]
        )
    }

    func testDoneAppliesPendingChanges() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer()
        let characterID = try workspace.addCharacter(toServerID: serverID)
        let library = ProfileLibrary(workspace: workspace)
        let controller = ConfigurationManagerWindowController(library: library)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let table = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSTableView }
                .first
        )
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))

        let characterName = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "characterName" }
        )
        characterName.stringValue = "Updated Character"

        let done = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "Done" }
        )
        done.performClick(nil)

        let character = try XCTUnwrap(
            library.workspace.servers.first(where: { $0.profile.id == serverID })?
                .characters.first(where: { $0.id == characterID })
        )
        XCTAssertEqual(character.name, "Updated Character")
    }

    func testApplyKeepsWindowOpenAndPersistsBeforeSwitchingEntries() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer()
        let firstCharacterID = try workspace.addCharacter(toServerID: serverID)
        _ = try workspace.addCharacter(toServerID: serverID)
        let library = ProfileLibrary(workspace: workspace)
        let controller = ConfigurationManagerWindowController(library: library)
        defer { controller.close() }
        controller.showWindow(nil)

        let content = try XCTUnwrap(controller.window?.contentView)
        let table = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "configurationProfileList" }
        )
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))

        let nameField = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "characterName" }
        )
        nameField.stringValue = "Updated Character"
        let apply = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "applyWorldChanges" }
        )

        apply.performClick(nil)

        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertEqual(
            library.workspace.servers.first?.characters.first(where: { $0.id == firstCharacterID })?.name,
            "Updated Character"
        )

        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))

        let reloadedNameField = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "characterName" }
        )
        XCTAssertEqual(reloadedNameField.stringValue, "Updated Character")
    }

    func testTabMovesBetweenWorldTextFields() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        _ = workspace.addServer()
        let controller = ConfigurationManagerWindowController(library: ProfileLibrary(workspace: workspace))
        defer { controller.close() }

        let views = recursiveSubviews(of: controller.window?.contentView)
        let name = try XCTUnwrap(
            views.first { $0.accessibilityIdentifier() == "worldName" } as? NSTextField
        )
        let host = try XCTUnwrap(
            views.first { $0.accessibilityIdentifier() == "worldHost" } as? NSTextField
        )
        let port = try XCTUnwrap(
            views.first { $0.accessibilityIdentifier() == "worldPort" } as? NSTextField
        )

        XCTAssertEqual(name.nextValidKeyView, host)
        XCTAssertEqual(host.nextValidKeyView, port)
    }

    func testTabAndShiftTabLeaveCharacterMultilineFields() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer()
        _ = try workspace.addCharacter(toServerID: serverID)
        let controller = ConfigurationManagerWindowController(library: ProfileLibrary(workspace: workspace))
        defer { controller.close() }

        let table = try XCTUnwrap(
            recursiveSubviews(of: controller.window?.contentView)
                .compactMap { $0 as? NSTableView }
                .first
        )
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))

        let views = recursiveSubviews(of: controller.window?.contentView)
        let connect = try XCTUnwrap(
            views.first { $0.accessibilityIdentifier() == "characterConnectText" } as? NSTextView
        )
        let info = try XCTUnwrap(
            views.first { $0.accessibilityIdentifier() == "characterInfo" } as? NSTextView
        )
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)

        XCTAssertTrue(window.makeFirstResponder(connect))
        connect.insertTab(nil)
        XCTAssertTrue(isFirstResponder(info, in: window))

        info.insertBacktab(nil)
        XCTAssertTrue(isFirstResponder(connect, in: window))
    }

    private func isFirstResponder(_ view: NSView, in window: NSWindow) -> Bool {
        if window.firstResponder === view { return true }
        guard let editor = window.firstResponder as? NSTextView else { return false }
        return editor.delegate as AnyObject === view
    }

    private func recursiveSubviews(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { recursiveSubviews(of: $0) }
    }
}
