import AppKit
import BeipPersistence
import XCTest
@testable import BeipUI

final class SessionTitlebarStatisticsTests: XCTestCase {
    func testCompactDurationFormatting() {
        XCTAssertEqual(SessionTitlebarStatisticsFormatter.duration(0), "0s")
        XCTAssertEqual(SessionTitlebarStatisticsFormatter.duration(71), "1m 11s")
        XCTAssertEqual(SessionTitlebarStatisticsFormatter.duration(14_411), "4h 0m")
        XCTAssertEqual(SessionTitlebarStatisticsFormatter.duration(104_400), "1d 5h")
    }

    func testDurationFormattingClampsNegativeValues() {
        XCTAssertEqual(SessionTitlebarStatisticsFormatter.duration(-1), "0s")
    }

    @MainActor
    func testCustomSessionStripSuppressesNativeTabBar() async throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let first = ClientWindowController(profileLibrary: library)
        let second = ClientWindowController(profileLibrary: library)
        defer {
            first.close()
            second.close()
        }
        let firstWindow = try XCTUnwrap(first.window)
        let secondWindow = try XCTUnwrap(second.window)
        first.showWindow(nil)
        let group = ClientTabGroup(first)
        group.add(second)
        group.select(second, sender: nil)
        await Task.yield()

        XCTAssertEqual(group.controllers.count, 2)
        XCTAssertTrue(group.selectedController === second)
        XCTAssertTrue(second.isCommandInputFocusedForTesting)
        XCTAssertNil(firstWindow.tabbedWindows)
        XCTAssertNil(secondWindow.tabbedWindows)

        group.prepareToClose(second)
        XCTAssertTrue(group.selectedController === first)
        XCTAssertTrue(first.isCommandInputFocusedForTesting)
    }

    @MainActor
    func testClosingOnlyTabRequestsFreshReplacementInsteadOfClosingWindow() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.closeForTabReplacement() }
        let window = try XCTUnwrap(controller.window)
        var replacementRequested = false
        controller.onRequestCloseLastTab = { requestedController in
            replacementRequested = requestedController === controller
            return true
        }

        XCTAssertFalse(controller.windowShouldClose(window))
        XCTAssertTrue(replacementRequested)
    }

    @MainActor
    func testPermanentTabBarControlsLeadTheSessionTabs() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }

        XCTAssertEqual(
            controller.tabBarControlIdentifiersForTesting,
            ["tabBarApplicationMenu", "tabBarQuickConnect", "tabBarWorldsAndCharacters"]
        )
        XCTAssertEqual(
            Array(controller.tabBarArrangedIdentifiersForTesting.prefix(4)),
            [
                "tabBarApplicationMenu",
                "tabBarQuickConnect",
                "tabBarWorldsAndCharacters",
                "sessionTabs",
            ]
        )
    }

    @MainActor
    func testApplicationButtonMenuMatchesLegacyNavigation() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }

        let menu = controller.tabBarApplicationMenuForTesting
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                "Windows",
                "Tools",
                "Logging…",
                "Settings…",
                "Help",
                "Close all Windows and Exit",
            ]
        )
        XCTAssertNotNil(menu.item(withTitle: "Windows")?.submenu)
        XCTAssertNotNil(menu.item(withTitle: "Tools")?.submenu)
        XCTAssertNotNil(menu.item(withTitle: "Help")?.submenu)
        XCTAssertEqual(menu.item(withTitle: "Logging…")?.keyEquivalent, "l")
        XCTAssertEqual(
            menu.item(withTitle: "Logging…")?.keyEquivalentModifierMask,
            [.control]
        )
    }

    @MainActor
    func testPlayerQuickConnectListsWorldsAndGroupsMultipleCharacters() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        _ = workspace.addServer(named: "Empty World")
        let single = workspace.addServer(named: "Single World")
        _ = try workspace.addCharacter(toServerID: single, named: "Hero")
        let multiple = workspace.addServer(named: "Many World")
        _ = try workspace.addCharacter(toServerID: multiple, named: "Wizard")
        _ = try workspace.addCharacter(toServerID: multiple, named: "Tester1")
        _ = try workspace.addCharacter(toServerID: multiple, named: "Tester2")

        let controller = ClientWindowController(profileLibrary: ProfileLibrary(workspace: workspace))
        defer { controller.close() }
        let menu = controller.quickConnectMenuForTesting

        XCTAssertEqual(
            menu.items.map(\.title),
            ["Empty World", "Single World — Hero", "Many World"]
        )
        XCTAssertEqual(
            menu.item(withTitle: "Many World")?.submenu?.items.map(\.title),
            ["Wizard", "Tester1", "Tester2"]
        )
    }

    @MainActor
    func testPlayerQuickConnectHandsSavedProfileToNewTabCreator() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let world = workspace.addServer(named: "Single World")
        _ = try workspace.addCharacter(toServerID: world, named: "Hero")

        let controller = ClientWindowController(profileLibrary: ProfileLibrary(workspace: workspace))
        defer { controller.close() }

        var sourceController: ClientWindowController?
        var selectedServerName: String?
        var selectedCharacterName: String?
        controller.onQuickConnectProfile = { source, server, character in
            sourceController = source
            selectedServerName = server.name
            selectedCharacterName = character?.name
        }

        let item = try XCTUnwrap(controller.quickConnectMenuForTesting.item(withTitle: "Single World — Hero"))
        let action = try XCTUnwrap(item.action)

        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
        XCTAssertTrue(sourceController === controller)
        XCTAssertEqual(selectedServerName, "Single World")
        XCTAssertEqual(selectedCharacterName, "Hero")
        XCTAssertNil(controller.persistedOpenTab.serverID)
        XCTAssertNil(controller.persistedOpenTab.characterID)
    }

    @MainActor
    func testPlayerQuickConnectDoesNothingWhenCharacterTabAlreadyExists() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let world = workspace.addServer(named: "Single World")
        _ = try workspace.addCharacter(toServerID: world, named: "Hero")
        let saved = try XCTUnwrap(workspace.servers.first)
        let character = try XCTUnwrap(saved.characters.first)

        let library = ProfileLibrary(workspace: workspace)
        let controller = ClientWindowController(profileLibrary: library)
        let existing = ClientWindowController(profileLibrary: library)
        defer {
            controller.close()
            existing.close()
        }
        existing.restoreOpenTab(server: saved.profile, character: character)
        let group = ClientTabGroup(controller)
        group.add(existing)

        var quickConnectRequested = false
        controller.onQuickConnectProfile = { _, _, _ in
            quickConnectRequested = true
        }

        let item = try XCTUnwrap(controller.quickConnectMenuForTesting.item(withTitle: "Single World — Hero"))
        let action = try XCTUnwrap(item.action)

        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
        XCTAssertFalse(quickConnectRequested)
        XCTAssertEqual(group.controllers.count, 2)
    }
}
