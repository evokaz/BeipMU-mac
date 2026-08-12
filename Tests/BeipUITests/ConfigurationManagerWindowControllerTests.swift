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
        notifySelectionChange(table, controller: controller)
        content.layoutSubtreeIfNeeded()
        detailScroll.contentView.scroll(to: NSPoint(x: 0, y: 500))

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        notifySelectionChange(table, controller: controller)
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
        notifySelectionChange(table, controller: controller)

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
        notifySelectionChange(table, controller: controller)

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
        notifySelectionChange(table, controller: controller)
        copy.performClick(nil)

        XCTAssertEqual(library.workspace.servers.map(\.profile.name), ["World", "World - copy"])

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        notifySelectionChange(table, controller: controller)
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
        notifySelectionChange(table, controller: controller)

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
        notifySelectionChange(table, controller: controller)

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
        notifySelectionChange(table, controller: controller)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        notifySelectionChange(table, controller: controller)

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
        notifySelectionChange(table, controller: controller)

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

    func testReturnAndKeypadEnterInsertNewlinesInEveryMultilineField() throws {
        let fields: [(identifier: String, row: Int)] = [
            ("worldInfo", 0),
            ("characterConnectText", 1),
            ("characterInfo", 1),
        ]

        for fieldCase in fields {
            var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
            let serverID = workspace.addServer()
            _ = try workspace.addCharacter(toServerID: serverID)
            let library = ProfileLibrary(workspace: workspace)
            var connectCount = 0
            let controller = ConfigurationManagerWindowController(
                library: library,
                onConnectProfile: { _, _ in connectCount += 1 }
            )
            controller.showWindow(nil)

            let content = try XCTUnwrap(controller.window?.contentView)
            let table = try XCTUnwrap(
                recursiveSubviews(of: content)
                    .compactMap { $0 as? NSOutlineView }
                    .first { $0.accessibilityIdentifier() == "configurationProfileList" }
            )
            if fieldCase.row == 1 {
                table.selectRowIndexes(.init(integer: fieldCase.row), byExtendingSelection: false)
                notifySelectionChange(table, controller: controller)
            }

            let field = try XCTUnwrap(
                recursiveSubviews(of: content)
                    .first { $0.accessibilityIdentifier() == fieldCase.identifier } as? NSTextView
            )
            let window = try XCTUnwrap(controller.window)
            window.makeKeyAndOrderFront(nil)

            for keyCode in [UInt16(36), UInt16(76)] {
                field.string = "before"
                field.setSelectedRange(NSRange(location: field.string.utf16.count, length: 0))
                XCTAssertTrue(window.makeFirstResponder(field))
                let event = try XCTUnwrap(keyEvent(keyCode: keyCode, in: window))

                window.sendEvent(event)
                XCTAssertEqual(field.string, "before\n")
                XCTAssertTrue(window.isVisible)
                XCTAssertEqual(connectCount, 0)
            }

            controller.prepareForFactoryReset()
            controller.close()
        }
    }

    func testReturnInWorldSelectionConnectsAndPersistsPendingEdits() throws {
        for keyCode in [UInt16(36), UInt16(76)] {
            var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
            let serverID = workspace.addServer()
            let library = ProfileLibrary(workspace: workspace)
            var receivedProfile: (ServerProfile, CharacterProfile?)?
            let controller = ConfigurationManagerWindowController(
                library: library,
                onConnectProfile: { server, character in
                    receivedProfile = (server, character)
                }
            )
            controller.showWindow(nil)

            let content = try XCTUnwrap(controller.window?.contentView)
            let name = try XCTUnwrap(
                recursiveSubviews(of: content)
                    .first { $0.accessibilityIdentifier() == "worldName" } as? NSTextField
            )
            let window = try XCTUnwrap(controller.window)
            window.makeKeyAndOrderFront(nil)
            name.stringValue = "Edited World"
            XCTAssertTrue(window.makeFirstResponder(name))
            let event = try XCTUnwrap(keyEvent(keyCode: keyCode, in: window))
            window.sendEvent(event)
            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(
                library.workspace.servers.first(where: { $0.profile.id == serverID })?.profile.name,
                "Edited World"
            )
            XCTAssertEqual(receivedProfile?.0.name, "Edited World")
            XCTAssertNil(receivedProfile?.1)
            controller.close()
        }
    }

    func testReturnInCharacterSelectionConnectsAndPersistsPendingEdits() throws {
        for keyCode in [UInt16(36), UInt16(76)] {
            var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
            let serverID = workspace.addServer()
            let characterID = try workspace.addCharacter(toServerID: serverID)
            let library = ProfileLibrary(workspace: workspace)
            var receivedProfile: (ServerProfile, CharacterProfile?)?
            let controller = ConfigurationManagerWindowController(
                library: library,
                onConnectProfile: { server, character in
                    receivedProfile = (server, character)
                }
            )
            controller.showWindow(nil)

            let content = try XCTUnwrap(controller.window?.contentView)
            let table = try XCTUnwrap(
                recursiveSubviews(of: content)
                    .compactMap { $0 as? NSOutlineView }
                    .first { $0.accessibilityIdentifier() == "configurationProfileList" }
            )
            table.selectRowIndexes(.init(integer: 1), byExtendingSelection: false)
            notifySelectionChange(table, controller: controller)
            let name = try XCTUnwrap(
                recursiveSubviews(of: content)
                    .first { $0.accessibilityIdentifier() == "characterName" } as? NSTextField
            )
            let window = try XCTUnwrap(controller.window)
            window.makeKeyAndOrderFront(nil)
            name.stringValue = "Edited Character"
            XCTAssertTrue(window.makeFirstResponder(name))
            let event = try XCTUnwrap(keyEvent(keyCode: keyCode, in: window))
            window.sendEvent(event)

            XCTAssertFalse(window.isVisible)
            let character = try XCTUnwrap(
                library.workspace.servers.first(where: { $0.profile.id == serverID })?.characters
                    .first(where: { $0.id == characterID })
            )
            XCTAssertEqual(character.name, "Edited Character")
            XCTAssertEqual(receivedProfile?.0.id, serverID)
            XCTAssertEqual(receivedProfile?.1?.id, characterID)
            XCTAssertEqual(receivedProfile?.1?.name, "Edited Character")
            controller.close()
        }
    }

    func testButtonsKeepConnectExplicitAndOKSaveOnly() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        _ = workspace.addServer()
        let library = ProfileLibrary(workspace: workspace)
        var connectCount = 0
        let controller = ConfigurationManagerWindowController(
            library: library,
            onConnectProfile: { _, _ in connectCount += 1 }
        )
        defer { controller.close() }

        let buttons = recursiveSubviews(of: controller.window?.contentView)
            .compactMap { $0 as? NSButton }
        XCTAssertTrue(buttons.filter { $0.keyEquivalent == "\r" }.isEmpty)

        let connect = try XCTUnwrap(
            buttons.first { $0.accessibilityIdentifier() == "connectWorld" }
        )
        controller.showWindow(nil)
        connect.performClick(nil)
        XCTAssertEqual(connectCount, 1)
        XCTAssertTrue(controller.window?.isVisible == true)

        let name = try XCTUnwrap(
            recursiveSubviews(of: controller.window?.contentView)
                .first { $0.accessibilityIdentifier() == "worldName" } as? NSTextField
        )
        name.stringValue = "Saved By OK"
        let ok = try XCTUnwrap(
            buttons.first { $0.accessibilityIdentifier() == "applyProfileChanges" }
        )
        ok.performClick(nil)
        XCTAssertFalse(controller.window?.isVisible == true)
        XCTAssertEqual(library.workspace.servers.first?.profile.name, "Saved By OK")
        XCTAssertEqual(connectCount, 1)
    }

    func testSelectionPromptSavePersistsWorldBeforeSwitching() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        _ = workspace.addServer(named: "First")
        _ = workspace.addServer(named: "Second")
        let library = ProfileLibrary(workspace: workspace)
        var decisions: [SettingsPromptDecision] = [.save]
        let controller = ConfigurationManagerWindowController(
            library: library,
            promptDecisionProvider: { _ in decisions.removeFirst() }
        )
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let table = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "configurationProfileList" }
        )
        let name = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "worldName" }
        )
        name.stringValue = "Edited First"
        table.selectRowIndexes(.init(integer: 1), byExtendingSelection: false)
        notifySelectionChange(table, controller: controller)

        XCTAssertEqual(library.workspace.servers.first?.profile.name, "Edited First")
        XCTAssertEqual(table.selectedRow, 1)
    }

    func testSelectionPromptCancelRestoresWorldSelectionAndValues() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        _ = workspace.addServer(named: "First")
        _ = workspace.addServer(named: "Second")
        let library = ProfileLibrary(workspace: workspace)
        var decisions: [SettingsPromptDecision] = [.cancel]
        let controller = ConfigurationManagerWindowController(
            library: library,
            promptDecisionProvider: { _ in decisions.removeFirst() }
        )
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let table = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "configurationProfileList" }
        )
        let name = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "worldName" }
        )
        name.stringValue = "Edited First"
        table.selectRowIndexes(.init(integer: 1), byExtendingSelection: false)
        notifySelectionChange(table, controller: controller)

        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertEqual(name.stringValue, "Edited First")
        XCTAssertEqual(library.workspace.servers.first?.profile.name, "First")
    }

    func testWindowClosePromptDontSaveLeavesWorldUnchanged() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        _ = workspace.addServer(named: "First")
        let library = ProfileLibrary(workspace: workspace)
        var decisions: [SettingsPromptDecision] = [.dontSave]
        let controller = ConfigurationManagerWindowController(
            library: library,
            promptDecisionProvider: { _ in decisions.removeFirst() }
        )
        defer { controller.close() }

        let name = try XCTUnwrap(
            recursiveSubviews(of: controller.window?.contentView)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "worldName" }
        )
        name.stringValue = "Edited First"

        XCTAssertTrue(controller.windowShouldClose(try XCTUnwrap(controller.window)))
        XCTAssertEqual(library.workspace.servers.first?.profile.name, "First")
    }

    private func isFirstResponder(_ view: NSView, in window: NSWindow) -> Bool {
        if window.firstResponder === view { return true }
        guard let editor = window.firstResponder as? NSTextView else { return false }
        return editor.delegate as AnyObject === view
    }

    private func keyEvent(keyCode: UInt16, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func notifySelectionChange(
        _ tableView: NSTableView,
        controller: ConfigurationManagerWindowController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let outlineView = tableView as? NSOutlineView else {
            XCTFail("Expected the configuration profile list to be an NSOutlineView", file: file, line: line)
            return
        }
        controller.outlineViewSelectionDidChange(Notification(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outlineView
        ))
    }

    private func recursiveSubviews(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { recursiveSubviews(of: $0) }
    }
}
