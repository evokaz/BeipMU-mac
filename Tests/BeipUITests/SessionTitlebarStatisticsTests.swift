import AppKit
import BeipCore
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
    func testCalendarDayChangeNotificationCanArriveFromBackgroundQueue() async throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }

        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
                continuation.resume()
            }
        }
        await Task.yield()
    }

    @MainActor
    func testDailyHTMLLogRollsOverToNewTokenizedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyLogRolloverTests-\(UUID().uuidString)", isDirectory: true)
        let template = directory
            .appendingPathComponent("%server% - %character% - %date%.html")
            .path
        let controller = ClientWindowController(
            profileLibrary: ProfileLibrary(workspace: try .empty(isDirty: false))
        )
        defer {
            controller.close()
            try? FileManager.default.removeItem(at: directory)
        }

        controller.startDailyLogForTesting(template: template)
        XCTAssertEqual(controller.activeLogURLsForTesting.count, 1)
        let originalURL = try XCTUnwrap(controller.activeLogURLsForTesting.first)
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: Date()))

        controller.rollOverLogsForTesting(at: tomorrow)

        XCTAssertEqual(controller.activeLogURLsForTesting.count, 1)
        let replacementURL = try XCTUnwrap(controller.activeLogURLsForTesting.first)
        XCTAssertNotEqual(replacementURL, originalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementURL.path))
        XCTAssertTrue(try String(contentsOf: originalURL, encoding: .utf8).contains("Logging stopped"))
        XCTAssertTrue(try String(contentsOf: replacementURL, encoding: .utf8).contains("Logging started"))
        XCTAssertTrue(controller.hasDailyLogRolloverTimerForTesting)
    }

    func testWorldTabDragInsertionUsesTabMidpoints() {
        XCTAssertEqual(WorldTabDragInsertion.index(midpoints: [40, 100, 160], x: 10), 0)
        XCTAssertEqual(WorldTabDragInsertion.index(midpoints: [40, 100, 160], x: 100), 2)
        XCTAssertEqual(WorldTabDragInsertion.index(midpoints: [40, 100, 160], x: 220), 3)
    }

    func testSessionTabScrollOffsetCombinesAxesAndClampsToContent() {
        XCTAssertEqual(
            SessionTabScrollOffset.clamped(
                current: 100,
                horizontalDelta: 0,
                verticalDelta: 20,
                contentWidth: 600,
                viewportWidth: 200
            ),
            80
        )
        XCTAssertEqual(
            SessionTabScrollOffset.clamped(
                current: 100,
                horizontalDelta: 12,
                verticalDelta: 8,
                contentWidth: 600,
                viewportWidth: 200
            ),
            80
        )
        XCTAssertEqual(
            SessionTabScrollOffset.clamped(
                current: 20,
                horizontalDelta: 100,
                verticalDelta: 100,
                contentWidth: 600,
                viewportWidth: 200
            ),
            0
        )
        XCTAssertEqual(
            SessionTabScrollOffset.clamped(
                current: 380,
                horizontalDelta: -100,
                verticalDelta: -100,
                contentWidth: 600,
                viewportWidth: 200
            ),
            400
        )
    }

    func testSessionTabScrollOffsetDoesNothingWhenTabsFitViewport() {
        XCTAssertEqual(
            SessionTabScrollOffset.clamped(
                current: 0,
                horizontalDelta: 0,
                verticalDelta: 20,
                contentWidth: 180,
                viewportWidth: 200
            ),
            0
        )
    }

    @MainActor
    func testWorldTabGroupReordersWithoutChangingSelection() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let first = ClientWindowController(profileLibrary: library)
        let second = ClientWindowController(profileLibrary: library)
        let third = ClientWindowController(profileLibrary: library)
        defer {
            first.close()
            second.close()
            third.close()
        }

        let group = ClientTabGroup(first)
        group.add(second)
        group.add(third)
        group.select(second, sender: nil)

        group.reorder(first, to: 3)
        XCTAssertTrue(group.controllers[0] === second)
        XCTAssertTrue(group.controllers[1] === third)
        XCTAssertTrue(group.controllers[2] === first)
        XCTAssertTrue(group.selectedController === second)

        group.reorder(first, to: 0)
        XCTAssertTrue(group.controllers[0] === first)
        XCTAssertTrue(group.controllers[1] === second)
        XCTAssertTrue(group.controllers[2] === third)
        XCTAssertTrue(group.selectedController === second)
    }

    @MainActor
    func testWorldTabGroupDetachesAndDissolvesWithoutClosingControllers() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let first = ClientWindowController(profileLibrary: library)
        let second = ClientWindowController(profileLibrary: library)
        let third = ClientWindowController(profileLibrary: library)
        defer {
            first.close()
            second.close()
            third.close()
        }

        let group = ClientTabGroup(first)
        group.add(second)
        group.add(third)
        group.select(second, sender: nil)

        XCTAssertTrue(group.detach(first))
        XCTAssertEqual(group.controllers.count, 2)
        XCTAssertTrue(group.controllers[0] === second)
        XCTAssertTrue(group.controllers[1] === third)
        XCTAssertTrue(group.selectedController === second)
        XCTAssertNil(first.sessionTabGroup)

        XCTAssertTrue(group.detach(second))
        XCTAssertEqual(group.controllers.count, 1)
        XCTAssertTrue(group.controllers[0] === third)
        XCTAssertNil(second.sessionTabGroup)
        XCTAssertNil(third.sessionTabGroup)
    }

    @MainActor
    func testWorldTabGroupIndexedInsertTransfersAnExistingController() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let first = ClientWindowController(profileLibrary: library)
        let second = ClientWindowController(profileLibrary: library)
        let third = ClientWindowController(profileLibrary: library)
        let fourth = ClientWindowController(profileLibrary: library)
        defer {
            first.close()
            second.close()
            third.close()
            fourth.close()
        }

        let source = ClientTabGroup(first)
        source.add(second)
        let destination = ClientTabGroup(third)
        destination.add(fourth)

        XCTAssertTrue(source.detach(second))
        destination.insert(second, at: 1)

        XCTAssertEqual(source.controllers.count, 1)
        XCTAssertNil(first.sessionTabGroup)
        XCTAssertEqual(destination.controllers.count, 3)
        XCTAssertTrue(destination.controllers[0] === third)
        XCTAssertTrue(destination.controllers[1] === second)
        XCTAssertTrue(destination.controllers[2] === fourth)
        XCTAssertTrue(destination.selectedController === second)
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
    func testLastTabReplacementOnlyAppliesToLastOpenClientWindow() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let first = ClientWindowController(profileLibrary: library)
        let second = ClientWindowController(profileLibrary: library)
        defer {
            first.closeForTabReplacement()
            second.closeForTabReplacement()
        }

        XCTAssertTrue(
            ClientWindowClosePolicy.shouldReplaceLastTab(first, among: [first])
        )
        XCTAssertFalse(
            ClientWindowClosePolicy.shouldReplaceLastTab(first, among: [first, second])
        )

        first.onRequestCloseLastTab = { controller in
            ClientWindowClosePolicy.shouldReplaceLastTab(
                controller,
                among: [first, second]
            )
        }
        XCTAssertTrue(first.windowShouldClose(try XCTUnwrap(first.window)))
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
    func testInputHistoryTogglesDockedPaneAboveCommandInput() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        window.setFrame(
            NSRect(origin: window.frame.origin, size: NSSize(width: window.frame.width, height: 360)),
            display: false
        )

        XCTAssertFalse(controller.inputSplitArrangedIdentifiersForTesting.contains("inputHistoryPane"))
        XCTAssertFalse(controller.isInputHistoryPaneVisibleForTesting)

        controller.addInputHistoryEntryForTesting("test")
        controller.addInputHistoryEntryForTesting("test 2")
        controller.toggleInputHistoryWindow()
        XCTAssertTrue(controller.isInputHistoryPaneVisibleForTesting)
        XCTAssertTrue(controller.inputSplitArrangedIdentifiersForTesting.contains("inputHistoryPane"))
        window.contentView?.layoutSubtreeIfNeeded()
        let inputSplit = try XCTUnwrap(
            recursiveSubviews(of: window.contentView)
                .compactMap { $0 as? NSSplitView }
                .first { $0.accessibilityIdentifier() == "commandInputSplit" }
        )
        XCTAssertEqual(inputSplit.subviews.count, 3)
        XCTAssertLessThanOrEqual(inputSplit.subviews[0].frame.maxY, inputSplit.subviews[1].frame.minY)
        XCTAssertLessThanOrEqual(inputSplit.subviews[1].frame.maxY, inputSplit.subviews[2].frame.minY)
        let historyPane = try XCTUnwrap(
            recursiveSubviews(of: inputSplit)
                .first { $0.accessibilityIdentifier() == "inputHistoryPane" }
        )
        let historyScroll = try XCTUnwrap(
            recursiveSubviews(of: historyPane)
                .compactMap { $0 as? NSScrollView }
                .first
        )
        let historyText = try XCTUnwrap(
            recursiveSubviews(of: historyPane)
                .compactMap { $0 as? NSTextView }
                .first { $0.accessibilityIdentifier() == "inputHistoryText" }
        )
        XCTAssertEqual(historyText.string, "test\ntest 2")
        XCTAssertGreaterThanOrEqual(historyPane.frame.width, inputSplit.bounds.width - 1)
        XCTAssertGreaterThanOrEqual(historyPane.frame.height, 80)
        XCTAssertEqual(historyPane.layer?.borderWidth, 1)
        XCTAssertNotNil(historyPane.layer?.borderColor)
        let initialHistoryHeight = historyPane.frame.height
        XCTAssertEqual(historyScroll.frame.minX, historyPane.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(historyScroll.frame.maxX, historyPane.bounds.maxX, accuracy: 0.5)
        XCTAssertEqual(historyScroll.frame.minY, historyPane.bounds.minY, accuracy: 0.5)
        XCTAssertEqual(historyScroll.frame.maxY, historyPane.bounds.maxY, accuracy: 0.5)

        controller.addInputHistoryEntryForTesting("test 3")
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(historyText.string, "test\ntest 2\ntest 3")
        XCTAssertEqual(historyPane.frame.height, initialHistoryHeight, accuracy: 0.5)

        controller.toggleInputHistoryWindow()
        XCTAssertFalse(controller.isInputHistoryPaneVisibleForTesting)
        XCTAssertFalse(controller.inputSplitArrangedIdentifiersForTesting.contains("inputHistoryPane"))
    }

    @MainActor
    func testSessionTabTitleDoesNotOverlapCloseButton() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer(named: "MyRhost With A Long World Name")
        let characterID = try workspace.addCharacter(toServerID: serverID, named: "Wizard")
        let savedServer = try XCTUnwrap(workspace.servers.first)
        let savedCharacter = try XCTUnwrap(savedServer.characters.first { $0.id == characterID })

        let controller = ClientWindowController(profileLibrary: ProfileLibrary(workspace: workspace))
        defer { controller.close() }
        controller.restoreOpenTab(server: savedServer.profile, character: savedCharacter)
        controller.showWindow(nil)

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let activeTab = try XCTUnwrap(
            recursiveSubviews(of: content)
                .first { $0.accessibilityIdentifier() == "activeSessionTab" }
        )
        activeTab.layoutSubtreeIfNeeded()

        let closeButton = try XCTUnwrap(
            recursiveSubviews(of: activeTab)
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "sessionTabClose" }
        )
        let titleLabel = try XCTUnwrap(
            recursiveSubviews(of: activeTab)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "sessionTabTitle" }
        )

        XCTAssertFalse(closeButton.isHidden)
        XCTAssertGreaterThanOrEqual(titleLabel.frame.minX, closeButton.frame.maxX + 4.5)
        XCTAssertLessThanOrEqual(titleLabel.frame.maxX, activeTab.bounds.maxX - 9.5)
        XCTAssertEqual(titleLabel.lineBreakMode, .byClipping)
        XCTAssertEqual(titleLabel.stringValue, "Wizard @ MyRhost With A Long World Name")
    }

    @MainActor
    func testActiveSessionTabKeepsLoggingIndicatorVisibleBesideTruncatedTitle() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer(named: "MyRhost With A Very Long World Name")
        let characterID = try workspace.addCharacter(toServerID: serverID, named: "Wizard")
        let savedServer = try XCTUnwrap(workspace.servers.first)
        let savedCharacter = try XCTUnwrap(savedServer.characters.first { $0.id == characterID })
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")

        let controller = ClientWindowController(profileLibrary: ProfileLibrary(workspace: workspace))
        defer {
            controller.close()
            try? FileManager.default.removeItem(at: logURL)
        }
        controller.restoreOpenTab(server: savedServer.profile, character: savedCharacter)
        controller.startLogForTesting(at: logURL)
        controller.showWindow(nil)

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let activeTab = try XCTUnwrap(
            recursiveSubviews(of: content)
                .first { $0.accessibilityIdentifier() == "activeSessionTab" }
        )
        activeTab.layoutSubtreeIfNeeded()

        let titleLabel = try XCTUnwrap(
            recursiveSubviews(of: activeTab)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "sessionTabTitle" }
        )
        let indicators = try XCTUnwrap(
            recursiveSubviews(of: activeTab)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "sessionTabIndicators" }
        )

        XCTAssertEqual(indicators.stringValue, "⚡️ 📝")
        XCTAssertFalse(indicators.isHidden)
        XCTAssertGreaterThan(indicators.frame.width, 0)
        XCTAssertLessThanOrEqual(titleLabel.frame.maxX, indicators.frame.minX - 4.5)
        XCTAssertLessThanOrEqual(indicators.frame.maxX, activeTab.bounds.maxX - 9.5)
    }

    @MainActor
    func testWorldTabConnectionIndicatorTracksTerminalStatesWithoutChangingWindowTitle() async throws {
        let controller = ClientWindowController(
            profileLibrary: ProfileLibrary(workspace: try .empty(isDirty: false))
        )
        defer { controller.close() }
        controller.restoreOpenTab(
            server: .init(name: "Indicator World", host: "example.invalid", port: 8888),
            character: nil
        )

        XCTAssertEqual(controller.sessionTabIndicatorsForTesting, ["⚡️"])
        XCTAssertEqual(controller.sessionTabAccessibilityLabelsForTesting, ["Indicator World tab, disconnected"])
        XCTAssertEqual(controller.window?.title, "Indicator World")

        for state in [
            ConnectionState.resolving,
            .connecting,
            .connected,
            .disconnecting,
        ] {
            await controller.applyConnectionStateForTesting(state)
            XCTAssertEqual(controller.sessionTabIndicatorsForTesting, [""])
            XCTAssertEqual(controller.sessionTabAccessibilityLabelsForTesting, ["Indicator World tab"])
            XCTAssertFalse(controller.window?.title.contains("⚡️") ?? true)
        }

        await controller.applyConnectionStateForTesting(.disconnected)
        XCTAssertEqual(controller.sessionTabIndicatorsForTesting, ["⚡️"])
        XCTAssertEqual(controller.sessionTabAccessibilityLabelsForTesting, ["Indicator World tab, disconnected"])

        await controller.applyConnectionStateForTesting(.failed("No route"))
        XCTAssertEqual(controller.sessionTabIndicatorsForTesting, ["⚡️"])
        XCTAssertEqual(controller.sessionTabAccessibilityLabelsForTesting, ["Indicator World tab, disconnected"])
        XCTAssertEqual(controller.window?.title, "Indicator World")
    }

    @MainActor
    func testDisconnectedIndicatorPrecedesMuteAndLoggingIndicators() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        let controller = ClientWindowController(
            profileLibrary: ProfileLibrary(workspace: try .empty(isDirty: false))
        )
        defer {
            controller.close()
            try? FileManager.default.removeItem(at: logURL)
        }
        controller.restoreOpenTab(
            server: .init(name: "Indicator World", host: "example.invalid", port: 8888),
            character: nil
        )

        controller.toggleMute()
        controller.startLogForTesting(at: logURL)

        XCTAssertEqual(controller.sessionTabIndicatorsForTesting, ["⚡️ 🔇 📝"])
        XCTAssertEqual(controller.window?.title, "Indicator World 🔇 📝")
    }

    @MainActor
    func testInactiveConnectionStateRefreshesEveryCopyOfGroupedTabs() async throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let first = ClientWindowController(profileLibrary: library)
        let second = ClientWindowController(profileLibrary: library)
        defer {
            first.close()
            second.close()
        }
        first.restoreOpenTab(
            server: .init(name: "First", host: "first.invalid", port: 8888),
            character: nil
        )
        second.restoreOpenTab(
            server: .init(name: "Second", host: "second.invalid", port: 8888),
            character: nil
        )
        await first.applyConnectionStateForTesting(.connected)
        await second.applyConnectionStateForTesting(.connected)
        let group = ClientTabGroup(first)
        group.add(second)
        group.select(first, sender: nil)

        await second.applyConnectionStateForTesting(.failed("No route"))

        XCTAssertEqual(first.sessionTabIndicatorsForTesting, ["", "⚡️"])
        XCTAssertEqual(second.sessionTabIndicatorsForTesting, ["", "⚡️"])
        XCTAssertEqual(
            first.sessionTabAccessibilityLabelsForTesting,
            ["First tab", "Second tab, disconnected"]
        )
        XCTAssertEqual(
            second.sessionTabAccessibilityLabelsForTesting,
            ["First tab", "Second tab, disconnected"]
        )
    }

    @MainActor
    func testSavedProfileRenamesRefreshGroupedTitlesAndPersistedTabs() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let worldID = workspace.addServer(named: "Old World")
        let characterID = try workspace.addCharacter(toServerID: worldID, named: "Old Character")
        let otherWorldID = workspace.addServer(named: "Other World")
        let savedWorld = try XCTUnwrap(workspace.servers.first { $0.profile.id == worldID })
        let savedCharacter = try XCTUnwrap(savedWorld.characters.first { $0.id == characterID })
        let otherWorld = try XCTUnwrap(workspace.servers.first { $0.profile.id == otherWorldID })

        let library = ProfileLibrary(workspace: workspace)
        let first = ClientWindowController(profileLibrary: library)
        let second = ClientWindowController(profileLibrary: library)
        defer {
            first.close()
            second.close()
        }
        first.restoreOpenTab(server: savedWorld.profile, character: savedCharacter)
        second.restoreOpenTab(server: otherWorld.profile, character: nil)
        let group = ClientTabGroup(first)
        group.add(second)
        group.select(second, sender: nil)

        var persistedSnapshots: [[MacConfigurationSidecar.OpenTab]] = []
        let recordPersistedTabs = {
            persistedSnapshots.append([first.persistedOpenTab, second.persistedOpenTab])
        }
        first.onTabStateChange = recordPersistedTabs
        second.onTabStateChange = recordPersistedTabs

        try library.mutate { workspace in
            try workspace.updateCharacter(id: characterID, inServerID: worldID) {
                $0.name = "New Character"
            }
        }

        XCTAssertEqual(first.window?.title, "New Character @ Old World")
        XCTAssertEqual(
            first.sessionTabAccessibilityLabelsForTesting,
            ["New Character @ Old World tab, disconnected", "Other World tab, disconnected"]
        )
        XCTAssertEqual(
            second.sessionTabAccessibilityLabelsForTesting,
            ["New Character @ Old World tab, disconnected", "Other World tab, disconnected"]
        )

        try library.mutate { workspace in
            try workspace.updateServer(id: worldID) { $0.profile.name = "New World" }
        }

        XCTAssertEqual(first.window?.title, "New Character @ New World")
        XCTAssertEqual(
            first.sessionTabAccessibilityLabelsForTesting,
            ["New Character @ New World tab, disconnected", "Other World tab, disconnected"]
        )
        XCTAssertEqual(
            second.sessionTabAccessibilityLabelsForTesting,
            ["New Character @ New World tab, disconnected", "Other World tab, disconnected"]
        )
        XCTAssertEqual(
            first.sessionTabTooltipsForTesting,
            ["New Character @ New World", "Other World"]
        )
        let finalTabs = try XCTUnwrap(persistedSnapshots.last)
        XCTAssertEqual(finalTabs[0].serverName, "New World")
        XCTAssertEqual(finalTabs[0].characterName, "New Character")
        XCTAssertEqual(finalTabs[1].serverName, "Other World")
        XCTAssertNil(finalTabs[1].characterName)
    }

    @MainActor
    func testDeletedSavedProfilesKeepTheExistingWindowTitle() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let worldID = workspace.addServer(named: "World")
        let characterID = try workspace.addCharacter(toServerID: worldID, named: "Character")
        let savedWorld = try XCTUnwrap(workspace.servers.first { $0.profile.id == worldID })
        let savedCharacter = try XCTUnwrap(savedWorld.characters.first { $0.id == characterID })
        let library = ProfileLibrary(workspace: workspace)
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }
        controller.restoreOpenTab(server: savedWorld.profile, character: savedCharacter)

        try library.mutate { workspace in
            try workspace.removeCharacter(id: characterID, fromServerID: worldID)
        }
        XCTAssertEqual(controller.window?.title, "Character @ World")
        XCTAssertEqual(controller.sessionTabTextForTabStrip, "Character @ World")

        try library.mutate { workspace in try workspace.removeServer(id: worldID) }
        XCTAssertEqual(controller.window?.title, "Character @ World")
        XCTAssertEqual(controller.sessionTabTextForTabStrip, "Character @ World")
    }

    @MainActor
    func testPuppetTabMirrorsMasterTerminalConnectionIndicator() async throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let master = ClientWindowController(profileLibrary: library)
        let puppetWindow = ClientWindowController(profileLibrary: library)
        defer {
            master.close()
            puppetWindow.close()
        }
        let server = ServerProfile(name: "World", host: "example.invalid", port: 8888)
        let puppet = PuppetProfile(name: "Helper", receivePrefix: "Helper> ", sendPrefix: "tell Helper ")
        let character = CharacterProfile(name: "Player", puppets: [puppet])
        puppetWindow.startPuppetSession(
            master: master,
            server: server,
            character: character,
            puppet: puppet
        )

        XCTAssertEqual(puppetWindow.sessionTabIndicatorsForTesting, ["⚡️"])
        await master.applyConnectionStateForTesting(.connecting)
        XCTAssertEqual(puppetWindow.sessionTabIndicatorsForTesting, [""])
        await master.applyConnectionStateForTesting(.failed("No route"))
        XCTAssertEqual(puppetWindow.sessionTabIndicatorsForTesting, ["⚡️"])
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
                "Global Output Settings…",
                "Global Input Settings…",
                "Help",
                "Close all Windows and Exit",
            ]
        )
        XCTAssertNotNil(menu.item(withTitle: "Help")?.submenu)
        XCTAssertEqual(menu.item(withTitle: "Settings…")?.keyEquivalent, FixedShortcut.settings.keyEquivalent)
        XCTAssertEqual(menu.item(withTitle: "Settings…")?.keyEquivalentModifierMask, FixedShortcut.settings.modifiers)
        let helpMenu = try XCTUnwrap(menu.item(withTitle: "Help")?.submenu)
        XCTAssertEqual(helpMenu.items.map(\.title), ["BeipMU Help", "", "About…"])
        XCTAssertTrue(helpMenu.items[1].isSeparatorItem)
        XCTAssertEqual(
            helpMenu.item(withTitle: "About…")?.action,
            #selector(ApplicationDelegate.showAbout(_:))
        )
        XCTAssertEqual(
            helpMenu.item(withTitle: "BeipMU Help")?.action,
            #selector(ApplicationDelegate.showHelp(_:))
        )
        XCTAssertEqual(
            helpMenu.item(withTitle: "BeipMU Help")?.keyEquivalent,
            FixedShortcut.help.keyEquivalent
        )
        XCTAssertEqual(
            helpMenu.item(withTitle: "BeipMU Help")?.keyEquivalentModifierMask,
            FixedShortcut.help.modifiers
        )
        XCTAssertEqual(menu.item(withTitle: "Close all Windows and Exit")?.keyEquivalent, FixedShortcut.quit.keyEquivalent)
        XCTAssertEqual(
            menu.item(withTitle: "Close all Windows and Exit")?.keyEquivalentModifierMask,
            FixedShortcut.quit.modifiers
        )
        XCTAssertEqual(menu.item(withTitle: "Logging…")?.keyEquivalent, "l")
        XCTAssertEqual(
            menu.item(withTitle: "Logging…")?.keyEquivalentModifierMask,
            [.command]
        )
        XCTAssertEqual(
            menu.item(withTitle: "Global Output Settings…")?.action,
            #selector(ApplicationDelegate.globalTextWindowSettings(_:))
        )
        XCTAssertEqual(
            menu.item(withTitle: "Global Input Settings…")?.action,
            #selector(ApplicationDelegate.globalInputWindowSettings(_:))
        )

        let windowsMenu = try XCTUnwrap(menu.item(withTitle: "Windows")?.submenu)
        XCTAssertEqual(
            windowsMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                "New Tab",
                "New Window",
                "New Input Window",
                "New Edit Window",
                "Toggle Input History",
                "Toggle Map Window",
                "Toggle Character Notes Window",
                "Copy all window settings",
                "Paste all window settings",
                "Show Hidden Captions",
            ]
        )
        XCTAssertEqual(windowsMenu.item(withTitle: "New Tab")?.action, #selector(ApplicationDelegate.newTab(_:)))
        XCTAssertEqual(windowsMenu.item(withTitle: "New Window")?.action, #selector(ApplicationDelegate.newWindow(_:)))
        XCTAssertEqual(windowsMenu.item(withTitle: "New Input Window")?.action, #selector(ApplicationDelegate.newInputWindow(_:)))
        XCTAssertEqual(windowsMenu.item(withTitle: "New Edit Window")?.action, #selector(ApplicationDelegate.newEditWindow(_:)))
        XCTAssertEqual(
            windowsMenu.item(withTitle: "Toggle Input History")?.action,
            #selector(ApplicationDelegate.toggleInputHistoryWindow(_:))
        )
        XCTAssertEqual(windowsMenu.item(withTitle: "Toggle Map Window")?.action, #selector(ApplicationDelegate.toggleMapWindow(_:)))
        XCTAssertEqual(
            windowsMenu.item(withTitle: "Toggle Character Notes Window")?.action,
            #selector(ApplicationDelegate.toggleCharacterNotesWindow(_:))
        )
        XCTAssertEqual(windowsMenu.item(withTitle: "Copy all window settings")?.action, #selector(ApplicationDelegate.copyAllWindowSettings(_:)))
        XCTAssertEqual(windowsMenu.item(withTitle: "Paste all window settings")?.action, #selector(ApplicationDelegate.pasteAllWindowSettings(_:)))
        XCTAssertEqual(windowsMenu.item(withTitle: "Show Hidden Captions")?.action, #selector(ApplicationDelegate.showHiddenCaptions(_:)))
        XCTAssertEqual(windowsMenu.item(withTitle: "New Tab")?.keyEquivalent, "t")
        XCTAssertEqual(windowsMenu.item(withTitle: "New Window")?.keyEquivalent, "n")
        XCTAssertEqual(windowsMenu.item(withTitle: "Toggle Input History")?.keyEquivalent, "h")
        XCTAssertEqual(windowsMenu.item(withTitle: "New Tab")?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(windowsMenu.item(withTitle: "New Window")?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(windowsMenu.item(withTitle: "Toggle Input History")?.keyEquivalentModifierMask, [.control])

        let toolsMenu = try XCTUnwrap(menu.item(withTitle: "Tools")?.submenu)
        XCTAssertEqual(
            toolsMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                "Triggers…",
                "Macros…",
                "Aliases…",
                "Trigger Debugger",
                "Alias Debugger",
                "Network Debugger",
                "Smart Paste…",
            ]
        )
        XCTAssertEqual(toolsMenu.item(withTitle: "Triggers…")?.action, #selector(ApplicationDelegate.editTriggers(_:)))
        XCTAssertEqual(toolsMenu.item(withTitle: "Macros…")?.action, #selector(ApplicationDelegate.editMacros(_:)))
        XCTAssertEqual(toolsMenu.item(withTitle: "Aliases…")?.action, #selector(ApplicationDelegate.editAliases(_:)))
        XCTAssertEqual(toolsMenu.item(withTitle: "Trigger Debugger")?.action, #selector(ApplicationDelegate.debugTriggers(_:)))
        XCTAssertEqual(toolsMenu.item(withTitle: "Alias Debugger")?.action, #selector(ApplicationDelegate.debugAliases(_:)))
        XCTAssertEqual(toolsMenu.item(withTitle: "Network Debugger")?.action, #selector(ApplicationDelegate.debugNetwork(_:)))
        XCTAssertEqual(toolsMenu.item(withTitle: "Smart Paste…")?.action, #selector(ApplicationDelegate.smartPaste(_:)))
        XCTAssertEqual(toolsMenu.item(withTitle: "Triggers…")?.keyEquivalent, "t")
        XCTAssertEqual(toolsMenu.item(withTitle: "Macros…")?.keyEquivalent, "m")
        XCTAssertEqual(toolsMenu.item(withTitle: "Aliases…")?.keyEquivalent, "a")
        XCTAssertEqual(toolsMenu.item(withTitle: "Smart Paste…")?.keyEquivalent, "v")
        XCTAssertEqual(toolsMenu.item(withTitle: "Triggers…")?.keyEquivalentModifierMask, [.control, .shift])
        XCTAssertEqual(toolsMenu.item(withTitle: "Macros…")?.keyEquivalentModifierMask, [.control, .shift])
        XCTAssertEqual(toolsMenu.item(withTitle: "Aliases…")?.keyEquivalentModifierMask, [.control, .shift])
        XCTAssertEqual(toolsMenu.item(withTitle: "Smart Paste…")?.keyEquivalentModifierMask, [.control, .shift])
    }

    @MainActor
    func testApplicationButtonMenuUsesPersistedShortcutMapWhenOpened() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        try library.saveKeyEquivalents(KeyboardShortcutStore.serialized([
            .newTab: .init(keyEquivalent: "1", modifiers: [.option]),
            .newWindow: .init(keyEquivalent: "2", modifiers: [.option]),
            .toggleInputHistory: .init(keyEquivalent: "3", modifiers: [.option]),
            .logging: .init(keyEquivalent: "4", modifiers: [.option]),
            .triggers: .init(keyEquivalent: "5", modifiers: [.option]),
        ]))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }

        let menu = controller.tabBarApplicationMenuForTesting
        let windowsMenu = try XCTUnwrap(menu.item(withTitle: "Windows")?.submenu)
        XCTAssertEqual(windowsMenu.item(withTitle: "New Tab")?.keyEquivalent, "1")
        XCTAssertEqual(windowsMenu.item(withTitle: "New Tab")?.keyEquivalentModifierMask, [.option])
        XCTAssertEqual(windowsMenu.item(withTitle: "New Window")?.keyEquivalent, "2")
        XCTAssertEqual(windowsMenu.item(withTitle: "New Window")?.keyEquivalentModifierMask, [.option])
        XCTAssertEqual(windowsMenu.item(withTitle: "Toggle Input History")?.keyEquivalent, "3")
        XCTAssertEqual(windowsMenu.item(withTitle: "Toggle Input History")?.keyEquivalentModifierMask, [.option])
        XCTAssertEqual(menu.item(withTitle: "Logging…")?.keyEquivalent, "4")
        XCTAssertEqual(menu.item(withTitle: "Logging…")?.keyEquivalentModifierMask, [.option])
        let toolsMenu = try XCTUnwrap(menu.item(withTitle: "Tools")?.submenu)
        XCTAssertEqual(toolsMenu.item(withTitle: "Triggers…")?.keyEquivalent, "5")
        XCTAssertEqual(toolsMenu.item(withTitle: "Triggers…")?.keyEquivalentModifierMask, [.option])
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
    func testPlayerQuickConnectSelectsDisconnectedCharacterTabWhenItAlreadyExists() throws {
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
        group.select(controller, sender: nil)

        var quickConnectRequested = false
        controller.onQuickConnectProfile = { _, _, _ in
            quickConnectRequested = true
        }

        let item = try XCTUnwrap(controller.quickConnectMenuForTesting.item(withTitle: "Single World — Hero"))
        let action = try XCTUnwrap(item.action)

        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
        XCTAssertFalse(quickConnectRequested)
        XCTAssertEqual(group.controllers.count, 2)
        XCTAssertTrue(group.selectedController === existing)
    }

    @MainActor
    func testSessionTabContextMenuTargetsTheRightClickedTab() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let world = workspace.addServer(named: "Single World")
        _ = try workspace.addCharacter(toServerID: world, named: "Hero")
        let saved = try XCTUnwrap(workspace.servers.first)
        let character = try XCTUnwrap(saved.characters.first)
        let library = ProfileLibrary(workspace: workspace)
        let first = ClientWindowController(profileLibrary: library)
        let second = ClientWindowController(profileLibrary: library)
        defer {
            first.close()
            second.close()
        }

        first.restoreOpenTab(server: saved.profile, character: character)
        let group = ClientTabGroup(first)
        group.add(second)
        group.select(second, sender: nil)

        let menu = first.sessionTabContextMenuForTesting
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Disconnect", "Reconnect", "Close Tab", "Menu Strip at Top", "Menu Strip at Bottom"]
        )

        for item in menu.items where !item.isSeparatorItem {
            XCTAssertTrue(item.target as AnyObject === first)
        }
        XCTAssertFalse(menu.item(withTitle: "Disconnect")?.isEnabled ?? true)
        XCTAssertTrue(menu.item(withTitle: "Reconnect")?.isEnabled ?? false)
    }

    @MainActor
    func testSessionTabContextMenuClosesBackgroundTab() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let first = ClientWindowController(profileLibrary: library)
        let second = ClientWindowController(profileLibrary: library)
        defer {
            first.close()
            second.close()
        }
        let group = ClientTabGroup(first)
        group.add(second)
        group.select(second, sender: nil)

        let closeItem = try XCTUnwrap(first.sessionTabContextMenuForTesting.item(withTitle: "Close Tab"))
        let action = try XCTUnwrap(closeItem.action)

        XCTAssertTrue(NSApplication.shared.sendAction(action, to: closeItem.target, from: closeItem))
        XCTAssertEqual(group.controllers.count, 1)
        XCTAssertTrue(group.controllers.first === second)
        XCTAssertNil(group.selectedController)
        XCTAssertNil(second.sessionTabGroup)
    }

    @MainActor
    private func recursiveSubviews(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { recursiveSubviews(of: $0) }
    }
}
