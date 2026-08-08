import AppKit
import Foundation
import BeipCore
import BeipPersistence
@testable import BeipUI
import XCTest

final class WorkspacePreferencesTests: XCTestCase {
    @MainActor
    func testMainWindowSupportsVerticalResize() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        let inputSplit = try XCTUnwrap(
            recursiveSubviews(of: try XCTUnwrap(window.contentView))
                .compactMap { $0 as? NSSplitView }
                .first { $0.accessibilityIdentifier() == "commandInputSplit" }
        )
        XCTAssertFalse(inputSplit.isVertical)
        XCTAssertEqual(inputSplit.subviews.count, 2)
        XCTAssertTrue(
            recursiveSubviews(of: inputSplit.subviews[1])
                .contains { $0.accessibilityLabel() == "Command input" }
        )
        XCTAssertEqual(
            controller.splitView(inputSplit, constrainMinCoordinate: 0, ofSubviewAt: 0),
            80
        )
        // AppKit retains only the title bar's own system minimum after showing.
        XCTAssertLessThanOrEqual(window.minSize.height, 32)
        XCTAssertEqual(window.contentMinSize, .zero)
        window.setFrame(
            NSRect(origin: window.frame.origin, size: NSSize(width: window.frame.width, height: 500)),
            display: false
        )
        window.setFrame(
            NSRect(origin: window.frame.origin, size: NSSize(width: window.frame.width, height: 1_200)),
            display: false
        )
        XCTAssertEqual(window.frame.height, 1_200, accuracy: 1)
        XCTAssertGreaterThan(window.maxSize.height, 1_200)
        XCTAssertGreaterThan(window.contentMaxSize.height, 1_200)
        XCTAssertEqual(window.resizeIncrements.height, 1)
        XCTAssertEqual(window.contentResizeIncrements.height, 1)
        XCTAssertEqual(window.contentAspectRatio, .zero)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertGreaterThan(window.maxFullScreenContentSize.height, 1_200)
    }

    @MainActor
    func testHiddenWindowLayoutDoesNotOverwriteSavedInputHeight() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let inputSplit = try XCTUnwrap(
            recursiveSubviews(of: try XCTUnwrap(window.contentView))
                .compactMap { $0 as? NSSplitView }
                .first { $0.accessibilityIdentifier() == "commandInputSplit" }
        )
        let savedHeight = controller.inputHeightPreferenceForTesting

        inputSplit.setPosition(80, ofDividerAt: 0)
        controller.splitViewDidResizeSubviews(
            Notification(name: NSSplitView.didResizeSubviewsNotification, object: inputSplit)
        )

        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(controller.inputHeightPreferenceForTesting, savedHeight)
    }

    @MainActor
    func testInputHeightCanBeSynchronizedToHiddenTabs() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }
        let inputSplit = try XCTUnwrap(
            recursiveSubviews(of: try XCTUnwrap(controller.window?.contentView))
                .compactMap { $0 as? NSSplitView }
                .first { $0.accessibilityIdentifier() == "commandInputSplit" }
        )

        controller.synchronizeInputHeight(137)

        XCTAssertEqual(controller.inputHeightPreferenceForTesting, 137)
        XCTAssertEqual(inputSplit.subviews[1].frame.height, 137, accuracy: 1)
    }

    @MainActor
    func testFirstShownTabRestoresInputHeightAfterHiddenLayout() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        _ = workspace.addServer(named: "World")
        let server = try XCTUnwrap(workspace.servers.first).profile
        let library = ProfileLibrary(workspace: workspace)
        let preferences = WorkspacePreferences(inputHeight: 137)
        let first = ClientWindowController(
            profileLibrary: library,
            initialPreferences: preferences
        )
        let second = ClientWindowController(
            profileLibrary: library,
            initialPreferences: preferences
        )
        defer {
            first.close()
            second.close()
        }

        first.restoreOpenTab(server: server, character: nil)
        let firstSplit = try XCTUnwrap(
            recursiveSubviews(of: try XCTUnwrap(first.window?.contentView))
                .compactMap { $0 as? NSSplitView }
                .first { $0.accessibilityIdentifier() == "commandInputSplit" }
        )
        firstSplit.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(firstSplit.bounds.height, 0)

        let group = ClientTabGroup(first)
        group.add(second)
        group.select(second, sender: nil)
        firstSplit.setPosition(100, ofDividerAt: 0)
        XCTAssertNotEqual(firstSplit.subviews[1].frame.height, 137, accuracy: 1)

        group.select(first, sender: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        first.window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(firstSplit.subviews[1].frame.height, 137, accuracy: 1)
    }

    @MainActor
    func testAIWindowUsesNativeAccessibleSurfaceAndProfileState() throws {
        let controller = AIWindowController(profileKey: "ai-profile")
        controller.updateEndpoint(URL(string: "https://example.invalid/ai")!)
        controller.showResponse("answer", for: "question")
        controller.showWindow(nil)

        XCTAssertEqual(controller.window?.title, "AI")
        XCTAssertNotNil(controller.window?.contentView)
        let dockedView = controller.contentViewForDocking()
        let descendants = recursiveSubviews(of: dockedView)
        XCTAssertTrue(controller.isDocked)
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "aiPrompt" })
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "aiResponse" })
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "aiEndpoint" })
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "aiStatus" })
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "aiSend" })
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "aiClear" })
        controller.showFloating(nil)
        XCTAssertFalse(controller.isDocked)

        controller.close()
    }

    @MainActor
    func testPuppetWindowAttachesWithoutCreatingASecondNetworkSession() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let master = ClientWindowController(profileLibrary: library)
        let puppetWindow = ClientWindowController(profileLibrary: library)
        let server = ServerProfile(name: "World", host: "example.invalid", port: 8888)
        let puppet = PuppetProfile(name: "Helper", receivePrefix: "Helper> ", sendPrefix: "tell Helper ")
        let character = CharacterProfile(name: "Player", puppets: [puppet])

        puppetWindow.startPuppetSession(
            master: master,
            server: server,
            character: character,
            puppet: puppet
        )

        XCTAssertTrue(puppetWindow.isPuppetAttachment)
        XCTAssertFalse(puppetWindow.ownsNetworkSession)
        XCTAssertTrue(master.puppetController(for: puppet.id) === puppetWindow)

        puppetWindow.disconnect()
        XCTAssertNil(master.puppetController(for: puppet.id))
        master.close()
        puppetWindow.close()
    }

    func testWorkspacePreferencesRoundTrip() throws {
        let suiteName = "WorkspacePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WorkspacePreferences(
            outputHistoryLimit: 2_000,
            showsTimestamps: true,
            usesFanFoldBackgrounds: true,
            outputSplit: true,
            stickyInput: true,
            inputPrefix: "say ",
            inputHeight: 142,
            checksSpelling: false,
            speechVoiceIdentifier: "com.apple.voice.compact.en-US.Samantha",
            theme: .init(mode: .custom, foregroundHex: "#112233", backgroundHex: "#445566", accentHex: "#778899"),
            logging: .init(logsSentText: true, logsTypedText: true, includesTime: true, wrapWidth: 100),
            dockPlacement: .floating,
            lastDockedPlacement: .left,
            dockThickness: 333,
            workspaceLayout: .splitSidebars,
            workspaceLayouts: ["world/character": .stackedBottom],
            characterNotes: ["example": "Remember the hidden door."],
            spawnSurfaces: [
                "world/character": .init(
                    standaloneWindows: ["WHO"],
                    tabGroups: [.init(title: "Channels", tabs: ["Public", "Staff"], selectedTab: "Staff")]
                ),
            ],
            atlasSurfaces: [
                "world/character": .init(
                    filePath: "/tmp/map.atlas", mapIndex: 2,
                    currentMapIndex: 1, currentRoomIndex: 4,
                    scale: 1.75, originX: 120, originY: -30,
                    selectionFilterRaw: AtlasSelectionFilter.rooms.rawValue,
                    liveTracking: true
                ),
            ],
            webViewPanes: [
                "world/character": [try XCTUnwrap(SavedWebViewPane(.init(
                    id: "status",
                    url: try XCTUnwrap(URL(string: "https://example.invalid/status")),
                    dock: .right,
                    width: 480,
                    height: 320
                )))],
            ],
            tileMapEdits: [
                "world/character": ["surface": .init(name: "surface", columns: 2, rows: 1, encoding: .hex8, tiles: [3, 4])],
            ]
        )
        WorkspacePreferencesStore.save(preferences, defaults: defaults)
        XCTAssertEqual(WorkspacePreferencesStore.load(defaults: defaults), preferences)
    }

    func testWorkspacePreferencesUseSafeDefaultsForMissingOrCorruptData() throws {
        let suiteName = "WorkspacePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(WorkspacePreferencesStore.load(defaults: defaults), .init())
        defaults.set(Data("not json".utf8), forKey: "BeipMU.WorkspacePreferences.v1")
        XCTAssertEqual(WorkspacePreferencesStore.load(defaults: defaults), .init())
    }

    func testSessionPreferenceWritesDoNotEraseOtherSessionsSpawnState() throws {
        let suiteName = "WorkspacePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var first = WorkspacePreferences()
        var second = WorkspacePreferences()
        first.spawnSurfaces["world/first"] = .init(standaloneWindows: ["Pages"])
        first.workspaceLayouts["world/first"] = .mainOnly.inserting(.spawn("Pages"), side: .right)
        second.spawnSurfaces["world/second"] = .init(standaloneWindows: ["WHO"])
        second.workspaceLayouts["world/second"] = .mainOnly

        _ = WorkspacePreferencesStore.saveMergingSessionState(
            first,
            sessionKey: "world/first",
            defaults: defaults
        )
        _ = WorkspacePreferencesStore.saveMergingSessionState(
            second,
            sessionKey: "world/second",
            defaults: defaults
        )

        let restored = WorkspacePreferencesStore.load(defaults: defaults)
        XCTAssertEqual(restored.spawnSurfaces["world/first"]?.standaloneWindows, ["Pages"])
        XCTAssertEqual(restored.spawnSurfaces["world/second"]?.standaloneWindows, ["WHO"])
        XCTAssertTrue(restored.workspaceLayouts["world/first"]?.panes.contains(.spawn("Pages")) == true)
    }

    @MainActor
    func testFreshWorldDoesNotInheritGlobalSpawnPane() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer(named: "Fresh World")
        let server = try XCTUnwrap(workspace.servers.first { $0.profile.id == serverID }?.profile)
        let layout = WorkspaceLayoutNode.mainOnly.inserting(.spawn("Pages"), side: .right)
        let controller = ClientWindowController(
            profileLibrary: ProfileLibrary(workspace: workspace),
            runsScriptServices: false,
            initialPreferences: .init(workspaceLayout: layout)
        )
        defer { controller.close() }

        controller.restoreOpenTab(server: server, character: nil)

        XCTAssertTrue(controller.usesWorkspaceLayout(.mainOnly))
        XCTAssertEqual(controller.testingSpawnSurfaceState().standalone, [:])
    }

    @MainActor
    func testSavedWorldSpawnPaneStillRestoresWithItsSurfaceState() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer(named: "Saved World")
        let server = try XCTUnwrap(workspace.servers.first { $0.profile.id == serverID }?.profile)
        let key = try XCTUnwrap(TextWindowSettingsIdentity(world: server.name, character: nil, tab: nil).worldKey)
        let layout = WorkspaceLayoutNode.mainOnly.inserting(.spawn("Pages"), side: .right)
        let preferences = WorkspacePreferences(
            workspaceLayout: .mainOnly,
            workspaceLayouts: [key: layout],
            spawnSurfaces: [key: .init(standaloneWindows: ["Pages"])]
        )
        let controller = ClientWindowController(
            profileLibrary: ProfileLibrary(workspace: workspace),
            runsScriptServices: false,
            initialPreferences: preferences
        )
        defer { controller.close() }

        controller.restoreOpenTab(server: server, character: nil)

        XCTAssertTrue(controller.usesWorkspaceLayout(layout))
        XCTAssertEqual(controller.testingSpawnSurfaceState().standalone, ["Pages": true])
    }

    func testTextWindowSettingsResolveAcrossWorldCharacterAndTabScopes() {
        let identity = TextWindowSettingsIdentity(world: "Example World", character: "Builder", tab: "Main")
        var preferences = WorkspacePreferences()
        preferences.globalTextWindowSettings.fontSize = 12
        preferences.globalTextWindowSettings.showsNewContentMarkers = false
        preferences.worldTextWindowSettings[identity.worldKey!] = .init(
            usesGlobalSettings: false,
            settings: .init(fontSize: 14)
        )
        XCTAssertEqual(preferences.textWindowSettings(for: identity).fontSize, 14)

        preferences.characterTextWindowSettings[identity.characterKey!] = .init(
            usesGlobalSettings: false,
            settings: .init(fontSize: 16)
        )
        XCTAssertEqual(preferences.textWindowSettings(for: identity).fontSize, 16)

        preferences.tabTextWindowSettings[identity.tabKey!] = .init(
            usesGlobalSettings: false,
            settings: .init(fontSize: 18, showsNewContentMarkers: true)
        )
        let tab = preferences.textWindowSettings(for: identity)
        XCTAssertEqual(tab.fontSize, 18)
        XCTAssertFalse(tab.showsNewContentMarkers, "Help options always come from global settings")

        preferences.tabTextWindowSettings[identity.tabKey!]?.usesGlobalSettings = true
        XCTAssertEqual(preferences.textWindowSettings(for: identity).fontSize, 12)
    }

    func testInputWindowSettingsResolveAcrossScopesAndNormalize() {
        let identity = TextWindowSettingsIdentity(world: "Example World", character: "Builder", tab: "Main")
        var preferences = WorkspacePreferences()
        preferences.globalInputWindowSettings = .init(fontSize: 12, localEchoHex: "#112233")
        preferences.worldInputWindowSettings[identity.worldKey!] = .init(
            usesGlobalSettings: false,
            settings: .init(fontSize: 14)
        )
        preferences.characterInputWindowSettings[identity.characterKey!] = .init(
            usesGlobalSettings: false,
            settings: .init(fontSize: 16)
        )
        preferences.tabInputWindowSettings[identity.tabKey!] = .init(
            usesGlobalSettings: false,
            settings: .init(fontSize: 500, minimumLines: 8, maximumLines: 2)
        )

        let tab = preferences.inputWindowSettings(for: identity)
        XCTAssertEqual(tab.fontSize, 96)
        XCTAssertEqual(tab.minimumLines, 8)
        XCTAssertEqual(tab.maximumLines, 8)

        preferences.tabInputWindowSettings[identity.tabKey!]?.usesGlobalSettings = true
        let inherited = preferences.inputWindowSettings(for: identity)
        XCTAssertEqual(inherited.fontSize, 12)
        XCTAssertEqual(inherited.localEchoHex, "#112233")
    }

    func testLegacyStickyInputMigratesToGlobalInputWindowSettings() throws {
        let data = Data(##"{"stickyInput":true,"theme":{"mode":"custom","foregroundHex":"#102030","backgroundHex":"#405060","accentHex":"#708090"}}"##.utf8)
        let preferences = try JSONDecoder().decode(WorkspacePreferences.self, from: data)
        XCTAssertTrue(preferences.globalInputWindowSettings.keepsTextOnSubmit)
        XCTAssertEqual(preferences.globalInputWindowSettings.foregroundHex, "#102030")
        XCTAssertEqual(preferences.globalInputWindowSettings.backgroundHex, "#405060")
    }

    func testTextWindowIdentityKeysAreStableAndNormalized() {
        let first = TextWindowSettingsIdentity(world: "Café", character: "Éowyn", tab: "Main")
        let second = TextWindowSettingsIdentity(world: "CAFE", character: "eowyn", tab: "main")
        XCTAssertEqual(first.worldKey, second.worldKey)
        XCTAssertEqual(first.characterKey, second.characterKey)
        XCTAssertEqual(first.tabKey, second.tabKey)
    }

    func testLegacyOutputPreferencesMigrateIntoGlobalTextWindowSettings() throws {
        let suiteName = "WorkspacePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data(##"{"outputHistoryLimit":2345,"showsTimestamps":true,"usesFanFoldBackgrounds":true,"theme":{"mode":"custom","foregroundHex":"#112233","backgroundHex":"#445566","accentHex":"#778899"}}"##.utf8),
            forKey: "BeipMU.WorkspacePreferences.v1"
        )

        let migrated = WorkspacePreferencesStore.load(defaults: defaults).globalTextWindowSettings
        XCTAssertEqual(migrated.historyLimit, 2_345)
        XCTAssertTrue(migrated.showsTime)
        XCTAssertTrue(migrated.usesFanFoldBackgrounds)
        XCTAssertEqual(migrated.foregroundHex, "#112233")
        XCTAssertEqual(migrated.backgroundHex, "#445566")
        XCTAssertEqual(migrated.webLinkHex, "#778899")
    }

    @MainActor
    func testOutputContextMenuContainsOriginalTextWindowCommands() throws {
        let controller = ClientWindowController(profileLibrary: .init(workspace: try .empty(isDirty: false)))
        defer { controller.close() }
        let menu = controller.outputContextMenuForTesting()
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            [
                "Find…", "Pause", "Split", "Copy screen to clipboard", "Clear",
                "Delete Line", "Use global settings", "Settings…",
            ]
        )
        XCTAssertEqual(menu.item(withTitle: "Use global settings")?.state, .on)
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Use global settings")).isEnabled)
    }

    @MainActor
    func testCommandInputContextMenuContainsConversionCommands() throws {
        let input = CommandInputView()
        let baseMenu = NSMenu()
        baseMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")

        let menu = input.contextMenuForTesting(baseMenu: baseMenu)
        let conversion = try XCTUnwrap(menu.item(withTitle: "Conversion")?.submenu)

        XCTAssertEqual(menu.items.first?.title, "Conversion")
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(
            conversion.items.map(\.title),
            ["Convert Returns to %R", "Convert Tabs to %T", "Convert Spaces to %B"]
        )
    }

    @MainActor
    func testCommandInputForwardsPageKeysToOutputNavigation() throws {
        let input = CommandInputView()
        var pageUps = 0
        var pageDowns = 0
        input.onPageUp = {
            pageUps += 1
            return true
        }
        input.onPageDown = {
            pageDowns += 1
            return true
        }

        input.keyDown(with: try XCTUnwrap(pageKeyEvent(keyCode: 116)))
        input.keyDown(with: try XCTUnwrap(pageKeyEvent(keyCode: 121)))

        XCTAssertEqual(pageUps, 1)
        XCTAssertEqual(pageDowns, 1)
    }

    @MainActor
    func testCommandInputAppliesInputWindowAppearanceMarginsAndAutoHeight() {
        let input = CommandInputView()
        var preferredHeight: CGFloat?
        input.onPreferredHeightChange = { preferredHeight = $0 }
        input.applySettings(.init(
            fontName: "Menlo",
            fontSize: 18,
            foregroundHex: "#123456",
            backgroundHex: "#ABCDEF",
            resizesToFitContents: true,
            minimumLines: 2,
            maximumLines: 4,
            marginLeft: 11,
            marginTop: 12,
            marginRight: 13,
            marginBottom: 14,
            keepsTextOnSubmit: true,
            localEcho: false,
            localEchoHex: "#FEDCBA"
        ))

        XCTAssertEqual(input.font?.pointSize, 18)
        XCTAssertEqual(input.textColor?.hexString, "#123456")
        XCTAssertEqual(input.backgroundColor.hexString, "#ABCDEF")
        XCTAssertEqual(input.containerScrollView.contentInsets.left, 11)
        XCTAssertEqual(input.containerScrollView.contentInsets.top, 12)
        XCTAssertEqual(input.containerScrollView.contentInsets.right, 13)
        XCTAssertEqual(input.containerScrollView.contentInsets.bottom, 14)
        XCTAssertTrue(input.behavior.isSticky)
        XCTAssertNotNil(preferredHeight)
    }

    @MainActor
    func testControllerInputContextMenuContainsSettingsAndGlobalInheritance() throws {
        let controller = ClientWindowController(profileLibrary: .init(workspace: try .empty(isDirty: false)))
        defer { controller.close() }
        let menu = controller.inputContextMenuForTesting()

        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Use global settings", "Settings…", "Conversion", "Cut"]
        )
        XCTAssertEqual(menu.item(withTitle: "Use global settings")?.state, .on)
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Use global settings")).isEnabled)
    }

    @MainActor
    func testInputSettingsEditorExposesAllLegacyControls() {
        let editor = InputWindowSettingsEditorView(
            states: [
                .global: .init(
                    label: "Global",
                    override: .init(usesGlobalSettings: false, settings: .init())
                ),
            ],
            initialScope: .global
        )
        let identifiers = Set(recursiveSubviews(of: editor).compactMap { $0.accessibilityIdentifier() })
        for identifier in [
            "inputSettingsFont", "inputSettingsFontSize", "inputSettingsForeground",
            "inputSettingsBackground", "inputSettingsResizeToFit", "inputSettingsMinimumLines",
            "inputSettingsMaximumLines", "inputSettingsMarginLeft", "inputSettingsMarginTop",
            "inputSettingsMarginRight", "inputSettingsMarginBottom", "inputSettingsKeepText",
            "inputSettingsLocalEcho", "inputSettingsLocalEchoColor",
        ] {
            XCTAssertTrue(identifiers.contains(identifier), "Missing control: \(identifier)")
        }
    }

    @MainActor
    func testTextWindowSettingsEditorPreservesChangesWhenSwitchingScopes() throws {
        let editor = TextWindowSettingsEditorView(
            states: [
                .global: .init(
                    label: "Global",
                    override: .init(usesGlobalSettings: false, settings: .init(fontSize: 12))
                ),
                .tab: .init(
                    label: "Tab — Main",
                    override: .init(usesGlobalSettings: false, settings: .init(fontSize: 18))
                ),
            ],
            initialScope: .global
        )
        let views = recursiveSubviews(of: editor)
        let scope = try XCTUnwrap(
            views.compactMap { $0 as? NSPopUpButton }
                .first { $0.accessibilityIdentifier() == "textSettingsScope" }
        )
        let size = try XCTUnwrap(
            views.compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "textSettingsFontSize" }
        )

        scope.selectItem(at: 1)
        scope.sendAction(scope.action, to: scope.target)
        XCTAssertEqual(size.doubleValue, 18)
        size.doubleValue = 19
        scope.selectItem(at: 0)
        scope.sendAction(scope.action, to: scope.target)
        editor.commit()

        XCTAssertEqual(editor.states[.global]?.override.settings.fontSize, 12)
        XCTAssertEqual(editor.states[.tab]?.override.settings.fontSize, 19)
    }

    func testOlderPreferencesDecodeWithoutWorkspaceLayoutFields() throws {
        let suiteName = "WorkspacePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = #"{"outputHistoryLimit":3000,"showsTimestamps":true,"usesFanFoldBackgrounds":false,"stickyInput":true,"inputPrefix":"pose ","checksSpelling":false}"#
        defaults.set(Data(legacy.utf8), forKey: "BeipMU.WorkspacePreferences.v1")
        let decoded = WorkspacePreferencesStore.load(defaults: defaults)
        XCTAssertEqual(decoded.outputHistoryLimit, 3_000)
        XCTAssertTrue(decoded.showsTimestamps)
        XCTAssertEqual(decoded.inputPrefix, "pose ")
        XCTAssertEqual(decoded.inputHeight, 64)
        XCTAssertEqual(decoded.dockPlacement, .hidden)
        XCTAssertEqual(decoded.lastDockedPlacement, .right)
        XCTAssertFalse(decoded.outputSplit)
        XCTAssertNil(decoded.workspaceLayout)
        XCTAssertEqual(decoded.characterNotes, [:])
        XCTAssertEqual(decoded.spawnSurfaces, [:])
        XCTAssertEqual(decoded.atlasSurfaces, [:])
        XCTAssertEqual(decoded.workspaceLayouts, [:])
        XCTAssertEqual(decoded.webViewPanes, [:])
        XCTAssertEqual(decoded.tileMapEdits, [:])
    }

    func testUnsafeLayoutValuesAreNormalizedOnLoad() throws {
        let suiteName = "WorkspacePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        WorkspacePreferencesStore.save(.init(
            outputHistoryLimit: 1,
            inputHeight: 5_000,
            lastDockedPlacement: .floating,
            dockThickness: 5_000,
            workspaceLayout: .split(
                axis: .columns,
                fraction: 20,
                first: .pane(.main),
                second: .pane(.notes)
            )
        ), defaults: defaults)
        let decoded = WorkspacePreferencesStore.load(defaults: defaults)
        XCTAssertEqual(decoded.outputHistoryLimit, 100)
        XCTAssertEqual(decoded.inputHeight, 1_000)
        XCTAssertEqual(decoded.lastDockedPlacement, .right)
        XCTAssertEqual(decoded.dockThickness, 600)
        guard case let .split(_, fraction, _, _) = decoded.workspaceLayout else {
            return XCTFail("Expected saved split layout")
        }
        XCTAssertEqual(fraction, 0.85)
    }

    func testWorkspaceLayoutPresetsAreValidAndContainEveryPaneOnce() {
        for layout in [
            WorkspaceLayoutNode.tabbedRight,
            .splitSidebars,
            .stackedRight,
            .stackedBottom,
        ] {
            XCTAssertTrue(layout.isValid)
            XCTAssertEqual(Set(layout.panes), Set(WorkspacePaneKind.allCases))
            XCTAssertEqual(layout.panes.count, WorkspacePaneKind.allCases.count)
        }
        XCTAssertTrue(WorkspaceLayoutNode.mainOnly.isValid)
    }

    func testDynamicPaneKindsRoundTripAndRecursiveInsertionRemovesCleanly() throws {
        let web = WorkspacePaneKind.webView("status:α")
        let spawn = WorkspacePaneKind.spawnTabs("Chat / Public")
        let atlas = WorkspacePaneKind.atlas
        var layout = WorkspaceLayoutNode.tabbedRight.inserting(atlas, side: .top)
        layout = layout.inserting(web, side: .left)
        layout = layout.inserting(spawn, side: .bottom)

        XCTAssertTrue(layout.isValid)
        XCTAssertEqual(layout.panes.filter { $0 == .main }.count, 1)
        XCTAssertTrue(layout.panes.contains(web))
        XCTAssertTrue(layout.panes.contains(spawn))
        XCTAssertEqual(layout.dockSide(of: atlas), .top)

        let decoded = try JSONDecoder().decode(
            WorkspaceLayoutNode.self,
            from: JSONEncoder().encode(layout)
        )
        XCTAssertEqual(decoded, layout)
        XCTAssertEqual(decoded.removing(atlas)?.removing(web)?.removing(spawn), .tabbedRight)
    }

    @MainActor
    func testAtlasSurfaceCanDockOnEveryWorkspaceEdge() {
        for side in WebViewDockSide.allCases {
            let owner = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
            owner.contentView = dock.hostView
            let atlas = AtlasWindowController(atlas: Atlas(maps: []))
            let pane = WorkspacePaneKind.atlas

            dock.dockPane(
                pane,
                view: atlas.contentViewForDocking(),
                title: "Atlas",
                side: side
            )

            XCTAssertTrue(atlas.isDocked)
            XCTAssertEqual(dock.currentLayout.dockSide(of: pane), side)
            XCTAssertTrue(dock.currentLayout.panes.contains(pane))
            dock.hostView.layoutSubtreeIfNeeded()
            guard let split = recursiveSubviews(of: dock.hostView)
                .compactMap({ $0 as? NSSplitView }).first else {
                XCTFail("Expected a split view for the docked Atlas")
                continue
            }
            let originalPosition = split.isVertical
                ? split.subviews[0].frame.width
                : split.subviews[0].frame.height
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            let offset: CGFloat = originalPosition < total / 2 ? -40 : 40
            let targetPosition = min(total - 1, max(1, originalPosition + offset))
            split.setPosition(targetPosition, ofDividerAt: 0)
            dock.hostView.layoutSubtreeIfNeeded()
            let resizedPosition = split.isVertical
                ? split.subviews[0].frame.width
                : split.subviews[0].frame.height
            XCTAssertNotEqual(resizedPosition, originalPosition, accuracy: 1)

            dock.undockPane(pane)
            atlas.showFloating(nil)
            XCTAssertFalse(atlas.isDocked)
            atlas.closeSurface()
        }
    }

    @MainActor
    func testDockedAtlasCanShrinkBelowToolbarWidth() throws {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = dock.hostView
        let atlas = AtlasWindowController(atlas: Atlas(maps: []))
        let atlasContent = atlas.contentViewForDocking()
        dock.dockPane(.atlas, view: atlasContent, title: "Atlas", side: .right)
        dock.hostView.layoutSubtreeIfNeeded()

        let split = try XCTUnwrap(
            recursiveSubviews(of: dock.hostView).compactMap { $0 as? NSSplitView }.first
        )
        XCTAssertTrue(split.isVertical)
        split.setPosition(split.bounds.width - 240, ofDividerAt: 0)
        dock.hostView.layoutSubtreeIfNeeded()

        XCTAssertEqual(atlasContent.frame.width, 240, accuracy: 2)
        XCTAssertLessThan(atlasContent.frame.width, 680)
        XCTAssertNotNil(
            recursiveSubviews(of: atlasContent).compactMap { $0 as? NSButton }.first { $0.title == "Open" }
        )
        let overflow = try XCTUnwrap(
            recursiveSubviews(of: atlasContent).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "More Atlas tools"
            }
        )
        XCTAssertFalse(overflow.isHidden)
        XCTAssertEqual(overflow.superview?.frame.width ?? 0, atlasContent.frame.width, accuracy: 1)
        let overflowMenu = atlas.toolbarOverflowMenuForTesting
        XCTAssertEqual(overflowMenu.items.map(\.title), ["Navigation", "Create", "Select", "View"])
        XCTAssertEqual(
            overflowMenu.item(withTitle: "View")?.submenu?.items.map(\.title),
            ["Zoom out", "Actual size", "Zoom in", "Fit map", "Palette", "Export"]
        )
        let findRooms = try XCTUnwrap(
            recursiveSubviews(of: atlasContent).compactMap { $0 as? NSSearchField }.first
        )
        XCTAssertFalse(findRooms.isHidden)
        XCTAssertGreaterThanOrEqual(findRooms.frame.width, 120)
        XCTAssertEqual(findRooms.placeholderString, "Find Rooms")
        let filterOverflow = try XCTUnwrap(
            recursiveSubviews(of: atlasContent).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "More selection filters"
            }
        )
        XCTAssertFalse(filterOverflow.isHidden)
        let filterMenu = atlas.filterOverflowMenuForTesting
        XCTAssertEqual(
            filterMenu.items.map(\.title),
            ["Rooms", "Exits", "Rectangles", "Images", "Labels", "Auto-map"]
        )
        XCTAssertTrue(filterMenu.items.prefix(5).allSatisfy { $0.state == .on })

        split.setPosition(split.bounds.width - 500, ofDividerAt: 0)
        dock.hostView.layoutSubtreeIfNeeded()
        XCTAssertEqual(overflow.superview?.frame.width ?? 0, atlasContent.frame.width, accuracy: 1)
        XCTAssertLessThan(atlas.toolbarOverflowMenuForTesting.items.count, overflowMenu.items.count)

        split.setPosition(50, ofDividerAt: 0)
        dock.hostView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(atlasContent.frame.width, 800)
        XCTAssertTrue(overflow.isHidden)
        XCTAssertTrue(filterOverflow.isHidden)
        XCTAssertTrue(
            recursiveSubviews(of: atlasContent).compactMap { $0 as? NSButton }.filter {
                ["Open", "Save", "Save As", "Locate", "Create room", "Select", "Zoom in", "Export"].contains($0.title)
            }.allSatisfy { !$0.isHidden }
        )
        XCTAssertTrue(
            recursiveSubviews(of: atlasContent).compactMap { $0 as? NSButton }.filter {
                ["Rooms", "Exits", "Rectangles", "Images", "Labels", "Auto-map"].contains($0.title)
            }.allSatisfy { !$0.isHidden }
        )
        atlas.closeSurface()
    }

    func testSavedWebViewPaneKeepsSafeURLFieldsOnly() throws {
        let request = WebViewOpenRequest(
            id: "status",
            url: try XCTUnwrap(URL(string: "https://example.invalid/status")),
            headers: ["Authorization": "secret"],
            dock: .bottom,
            width: 640,
            height: 360
        )
        let saved = try XCTUnwrap(SavedWebViewPane(request))
        XCTAssertEqual(saved.request.id, "status")
        XCTAssertEqual(saved.request.dock, .bottom)
        XCTAssertTrue(saved.request.headers.isEmpty)
        XCTAssertNil(SavedWebViewPane(.init(id: "inline", source: "<p>private</p>", dock: .right)))
        XCTAssertNil(SavedWebViewPane(.init(id: "floating", url: request.url)))
    }

    @MainActor
    func testDockControllerHostsAndUnhostsDynamicPane() {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let main = NSView()
        let dynamic = NSTextField(labelWithString: "Server status")
        let controller = WorkspaceDockController(mainView: main, ownerWindow: owner)
        owner.contentView = controller.hostView
        controller.hostView.frame = owner.contentView?.bounds ?? .zero

        let pane = WorkspacePaneKind.webView("status")
        controller.dockPane(pane, view: dynamic, title: "Status", side: .right)
        XCTAssertTrue(controller.containsPane(pane))
        XCTAssertNotNil(dynamic.window)

        controller.undockPane(pane)
        XCTAssertFalse(controller.containsPane(pane))
        XCTAssertEqual(controller.currentLayout, .mainOnly)
    }

    @MainActor
    func testDockControllerCanHostDynamicPaneWithoutTitleChrome() {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let controller = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = controller.hostView
        let pane = WorkspacePaneKind.spawnTabs("Channels")
        let content = NSTextField(labelWithString: "Embedded tabs")

        controller.dockPane(
            pane,
            view: content,
            title: "Channels",
            side: .right,
            showsTitle: false,
            onUndock: {}
        )

        let descendants = recursiveSubviews(of: controller.hostView)
        XCTAssertFalse(descendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Channels" })
        XCTAssertTrue(descendants.compactMap { $0 as? NSButton }.contains { $0.title == "Pop Out" })
        XCTAssertNotNil(content.window)
    }

    @MainActor
    func testSpawnSurfaceMovesBetweenWindowAndRecursiveDock() {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = dock.hostView
        let spawn = TriggerSpawnWindowController(title: "WHO")
        spawn.append(.init(text: "Player One"))
        let pane = WorkspacePaneKind.spawn("WHO")

        dock.dockPane(pane, view: spawn.contentViewForDocking(), title: "WHO", side: .bottom)
        XCTAssertTrue(spawn.isDocked)
        XCTAssertTrue(dock.containsPane(pane))
        XCTAssertEqual(spawn.retainedLines.map(\.text), ["Player One"])

        dock.undockPane(pane)
        spawn.showFloating(nil)
        XCTAssertFalse(spawn.isDocked)
        XCTAssertNotNil(spawn.window?.contentView)
        spawn.closeSurface()
    }

    @MainActor
    func testClosingOneDockedTriggerPaneLeavesOtherPanesOpen() throws {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = dock.hostView

        let first = TriggerSpawnWindowController(title: "WHO")
        let second = TriggerSpawnWindowController(title: "Pages")
        let firstPane = WorkspacePaneKind.spawn("WHO")
        let secondPane = WorkspacePaneKind.spawn("Pages")
        first.onClose = { dock.undockPane(firstPane) }
        second.onClose = { dock.undockPane(secondPane) }

        dock.dockPaneInVerticalStack(
            firstPane,
            view: first.contentViewForDocking(),
            title: "WHO",
            side: .right,
            matching: isStandaloneSpawnPane,
            onClose: { first.requestClose() }
        )
        dock.dockPaneInVerticalStack(
            secondPane,
            view: second.contentViewForDocking(),
            title: "Pages",
            side: .right,
            matching: isStandaloneSpawnPane,
            onClose: { second.requestClose() }
        )

        let closeButtons = recursiveSubviews(of: dock.hostView).compactMap { view in
            view as? NSButton
        }.filter { $0.accessibilityIdentifier() == "workspacePaneClose" }
        XCTAssertEqual(closeButtons.count, 2)
        closeButtons[0].performClick(nil)

        XCTAssertFalse(dock.containsPane(firstPane))
        XCTAssertTrue(dock.containsPane(secondPane))
        XCTAssertFalse(first.isDocked)
        XCTAssertTrue(second.isDocked)
        second.closeSurface()
    }

    @MainActor
    func testSavedPanePlaceholderCanBeClosed() {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = dock.hostView
        let pane = WorkspacePaneKind.spawnTabs("Pages")

        dock.apply(layout: .mainOnly.inserting(pane, side: .right))
        XCTAssertTrue(dock.containsPane(pane))

        let closeButton = recursiveSubviews(of: dock.hostView)
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "workspacePaneClose" }
        XCTAssertNotNil(closeButton)
        closeButton?.performClick(nil)

        XCTAssertFalse(dock.containsPane(pane))
        XCTAssertEqual(dock.currentLayout, .mainOnly)
    }

    @MainActor
    func testTriggerSpawnContextMenuIncludesClearAndClose() {
        let standalone = TriggerSpawnWindowController(title: "WHO")
        let group = TriggerSpawnTabGroupWindowController(title: "Channels")

        XCTAssertEqual(standalone.contextMenuForTesting.items.map(\.title), ["Copy", "Select All", "", "Clear", "", "Close"])
        XCTAssertEqual(group.contextMenuForTesting.items.map(\.title), ["Copy", "Select All", "", "Clear", "", "Close"])
        standalone.closeSurface()
        group.closeSurface()
    }

    @MainActor
    func testTriggerSpawnClearContextMenuOnlyClearsTargetPane() throws {
        let standalone = TriggerSpawnWindowController(title: "WHO")
        standalone.append(.init(text: "standalone"))
        let standaloneClear = try XCTUnwrap(standalone.contextMenuForTesting.item(withTitle: "Clear"))
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(standaloneClear.action),
            to: standaloneClear.target,
            from: standaloneClear
        ))
        XCTAssertTrue(standalone.retainedLines.isEmpty)

        let group = TriggerSpawnTabGroupWindowController(title: "Channels")
        group.ensureTab(named: "WHO", selected: true)
        group.ensureTab(named: "Pages")
        group.deliver(.init(text: "who line"), to: "WHO", clear: false, showTab: false)
        group.deliver(.init(text: "page line"), to: "Pages", clear: false, showTab: false)
        XCTAssertTrue(group.selectTab(named: "WHO"))

        let groupClear = try XCTUnwrap(group.contextMenuForTesting.item(withTitle: "Clear"))
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(groupClear.action),
            to: groupClear.target,
            from: groupClear
        ))
        XCTAssertTrue(group.retainedLines(in: "WHO").isEmpty)
        XCTAssertEqual(group.retainedLines(in: "Pages").map(\.text), ["page line"])

        standalone.closeSurface()
        group.closeSurface()
    }

    @MainActor
    func testStandaloneTriggerSpawnDockingBuildsVerticalStack() {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = dock.hostView

        let whoPane = WorkspacePaneKind.spawn("WHO")
        let pagesPane = WorkspacePaneKind.spawn("Pages")
        dock.dockPaneInVerticalStack(
            whoPane,
            view: NSTextField(labelWithString: "WHO"),
            title: "WHO",
            side: .right,
            matching: isStandaloneSpawnPane
        )
        dock.dockPaneInVerticalStack(
            pagesPane,
            view: NSTextField(labelWithString: "Pages"),
            title: "Pages",
            side: .right,
            matching: isStandaloneSpawnPane
        )

        guard case let .split(.columns, _, .pane(.main), stack) = dock.currentLayout,
              case let .split(.rows, _, .pane(first), .pane(second)) = stack else {
            return XCTFail("Expected standalone spawns to dock as a vertical stack beside the main session")
        }
        XCTAssertEqual(first, whoPane)
        XCTAssertEqual(second, pagesPane)
    }

    func testStandaloneTriggerSpawnStackOrderCanBeRewritten() {
        let whoPane = WorkspacePaneKind.spawn("WHO")
        let pagesPane = WorkspacePaneKind.spawn("Pages")
        let layout = WorkspaceLayoutNode.mainOnly
            .insertingVerticalStack(whoPane, side: .right, matching: isStandaloneSpawnPane)
            .insertingVerticalStack(pagesPane, side: .right, matching: isStandaloneSpawnPane)

        let reordered = layout.insertingVerticalStack(
            pagesPane,
            side: .right,
            matching: isStandaloneSpawnPane,
            relativeTo: whoPane,
            before: true
        )

        XCTAssertEqual(reordered.panes, [.main, pagesPane, whoPane])
    }

    func testStandaloneTriggerSpawnStacksAreIndependentPerSide() {
        let pagesPane = WorkspacePaneKind.spawn("Pages")
        let whoPane = WorkspacePaneKind.spawn("WHO")
        let mapPane = WorkspacePaneKind.spawn("Map")
        let layout = WorkspaceLayoutNode.mainOnly
            .insertingVerticalStack(pagesPane, side: .right, matching: isStandaloneSpawnPane)
            .insertingVerticalStack(whoPane, side: .left, matching: isStandaloneSpawnPane)
            .insertingVerticalStack(mapPane, side: .right, matching: isStandaloneSpawnPane)

        XCTAssertEqual(layout.dockSide(of: pagesPane), .right)
        XCTAssertEqual(layout.dockSide(of: mapPane), .right)
        XCTAssertEqual(layout.dockSide(of: whoPane), .left)
        XCTAssertEqual(layout.panes, [whoPane, .main, pagesPane, mapPane])

        let moved = layout.insertingVerticalStack(
            pagesPane,
            side: .left,
            matching: isStandaloneSpawnPane,
            relativeTo: whoPane,
            before: false
        )

        XCTAssertEqual(moved.dockSide(of: pagesPane), .left)
        XCTAssertEqual(moved.dockSide(of: whoPane), .left)
        XCTAssertEqual(moved.dockSide(of: mapPane), .right)
        XCTAssertEqual(moved.panes, [whoPane, pagesPane, .main, mapPane])
    }

    @MainActor
    func testDockSideResolverSnapsFloatingSpawnNearHostEdges() {
        let host = NSRect(x: 100, y: 100, width: 900, height: 600)

        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 108, y: 260, width: 260, height: 180),
                near: host
            ),
            .left
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: -160, y: 260, width: 260, height: 180),
                near: host
            ),
            .left
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: -240, y: 260, width: 260, height: 180),
                near: host,
                threshold: 120,
                allowedSides: [.left, .right]
            ),
            .left
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 732, y: 260, width: 260, height: 180),
                near: host
            ),
            .right
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 1_000, y: 260, width: 260, height: 180),
                near: host
            ),
            .right
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 1_080, y: 260, width: 260, height: 180),
                near: host,
                threshold: 120,
                allowedSides: [.left, .right]
            ),
            .right
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 430, y: 522, width: 260, height: 180),
                near: host
            ),
            .top
        )
        XCTAssertNil(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 430, y: 522, width: 260, height: 180),
                near: host,
                allowedSides: [.left, .right]
            )
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forScreenPoint: NSPoint(x: 35, y: 320),
                in: host,
                threshold: 96,
                allowedSides: [.left, .right]
            ),
            .left
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forScreenPoint: NSPoint(x: 1_065, y: 320),
                in: host,
                threshold: 96,
                allowedSides: [.left, .right]
            ),
            .right
        )
        XCTAssertNil(
            WorkspaceDockController.dockSide(
                forScreenPoint: NSPoint(x: 430, y: 755),
                in: host,
                threshold: 96,
                allowedSides: [.left, .right]
            )
        )
        XCTAssertNil(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 420, y: 280, width: 260, height: 180),
                near: host
            )
        )
    }

    @MainActor
    func testRestoredOpenTabRecreatesFloatingAndDockedTriggerSpawns() throws {
        let server = ServerProfile(name: "Spawn World", host: "example.invalid", port: 8888)
        let key = "Spawn World".folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let dockedSpawn = WorkspacePaneKind.spawn("Docked")
        let dockedTabGroup = WorkspacePaneKind.spawnTabs("Channels")
        let layout = WorkspaceLayoutNode.mainOnly
            .inserting(dockedSpawn, side: .right)
            .inserting(dockedTabGroup, side: .bottom)
        let preferences = WorkspacePreferences(
            workspaceLayouts: [key: layout],
            spawnSurfaces: [
                key: .init(
                    standaloneWindows: ["Docked", "Floating"],
                    tabGroups: [.init(title: "Channels", tabs: ["Public"], selectedTab: "Public")]
                ),
            ]
        )
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(
            profileLibrary: library,
            runsScriptServices: false,
            initialPreferences: preferences
        )
        defer { controller.close() }

        controller.restoreOpenTab(server: server, character: nil)

        let state = controller.testingSpawnSurfaceState()
        XCTAssertEqual(state.standalone["Docked"], true)
        XCTAssertEqual(state.standalone["Floating"], false)
        XCTAssertEqual(state.tabGroups["Channels"], true)
        let views = recursiveSubviews(of: try XCTUnwrap(controller.window?.contentView))
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Channels" })
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Spawn tabs" })
    }

    func testWorkspaceLayoutUpdatesNestedDividerWithoutChangingOtherBranches() {
        let updated = WorkspaceLayoutNode.splitSidebars.replacingSplitFraction(
            at: [.second],
            with: 0.61
        )
        guard case let .split(_, outerFraction, first, second) = updated,
              case let .split(_, innerFraction, _, _) = second else {
            return XCTFail("Expected nested split layout")
        }
        XCTAssertEqual(outerFraction, 0.22)
        XCTAssertEqual(first, .pane(.notes))
        XCTAssertEqual(innerFraction, 0.61)
        XCTAssertTrue(updated.hasSameTopology(as: .splitSidebars))
        XCTAssertFalse(updated.hasSameTopology(as: .stackedRight))
    }

    func testInvalidWorkspaceLayoutFallsBackToSafeTabbedLayout() {
        let invalid = WorkspaceLayoutNode.split(
            axis: .rows,
            fraction: .nan,
            first: .pane(.main),
            second: .tabs(panes: [.notes, .notes], selected: .notes)
        )
        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(invalid.normalized, .tabbedRight)
    }

    @MainActor
    func testDockControllerBuildsIndependentMultiPaneTree() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let main = NSView()
        main.setAccessibilityIdentifier("mainSession")
        let controller = WorkspaceDockController(mainView: main, ownerWindow: window)
        window.contentView = controller.hostView
        controller.apply(layout: .splitSidebars)
        controller.hostView.layoutSubtreeIfNeeded()

        let descendants = recursiveSubviews(of: controller.hostView)
        XCTAssertEqual(descendants.compactMap { $0 as? NSSplitView }.count, 2)
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "mainSession" })
        XCTAssertTrue(descendants.contains { $0.accessibilityLabel() == "Character notes" })
        XCTAssertTrue(descendants.contains { $0.accessibilityLabel() == "Session diagnostics" })
        XCTAssertEqual(controller.currentLayout, .splitSidebars)
    }

    @MainActor
    private func recursiveSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(recursiveSubviews(of:))
    }

    private func isStandaloneSpawnPane(_ pane: WorkspacePaneKind) -> Bool {
        if case .spawn = pane { return true }
        return false
    }

    func testKeyboardShortcutParsingDisplayAndPersistence() throws {
        XCTAssertEqual(KeyboardShortcut.parse("⌘⇧P")?.displayString, "⇧⌘P")
        XCTAssertEqual(KeyboardShortcut.parse("Command+Shift+P")?.displayString, "⇧⌘P")
        XCTAssertEqual(KeyboardShortcut.parse("Shift+F2")?.displayString, "⇧F2")
        XCTAssertNil(KeyboardShortcut.parse("Command+Many+P"))

        let custom = KeyboardShortcut.parse("Option+K")!
        let serialized = KeyboardShortcutStore.serialized([.clearOutput: custom])
        XCTAssertEqual(serialized, ["clearOutput": "⌥K"])
        let loaded = KeyboardShortcutStore.load(from: serialized)
        XCTAssertEqual(loaded[.clearOutput], custom)
        XCTAssertEqual(loaded[.newWindow], ShortcutAction.newWindow.defaultShortcut)
        XCTAssertEqual(loaded[.toggleInputHistory], .init(keyEquivalent: "h", modifiers: [.command]))
        XCTAssertEqual(KeyboardShortcutStore.load()[.clearOutput], ShortcutAction.clearOutput.defaultShortcut)
    }

    @MainActor
    func testCustomThemePaletteUsesSavedColorsAndAppearance() {
        let settings = WorkspaceThemeSettings(
            mode: .custom,
            foregroundHex: "#102030",
            backgroundHex: "#F0E0D0",
            accentHex: "#4080C0"
        )
        XCTAssertEqual(settings.palette.foreground.hexString, "#102030")
        XCTAssertEqual(settings.palette.background.hexString, "#F0E0D0")
        XCTAssertEqual(settings.palette.accent.hexString, "#4080C0")
        XCTAssertEqual(settings.palette.appearance?.name, .aqua)

        let lowContrast = WorkspaceThemeSettings(
            mode: .custom,
            foregroundHex: "#777777",
            backgroundHex: "#777777",
            accentHex: "#777777"
        ).palette(displayOptions: .init(increaseContrast: true))
        XCTAssertGreaterThanOrEqual(lowContrast.foreground.contrastRatio(against: lowContrast.background), 7)
        XCTAssertGreaterThanOrEqual(lowContrast.accent.contrastRatio(against: lowContrast.background), 4.5)

        let imageViewer = ImageViewerWindowController()
        imageViewer.applyAccessibilityDisplayOptions(.init(reduceMotion: true))
        XCTAssertFalse(imageViewer.imageAnimationEnabled)
        imageViewer.close()
    }

    @MainActor
    func testAdvancedGMCPPanesExposeNativeAccessibleContent() throws {
        let stats = GMCPStatisticsWindowController(title: "Player")
        stats.update(.init(
            title: "Player",
            background: .rgb(.init(red: 0, green: 32, blue: 64)),
            values: [
                "0_Health": .init(
                    key: "0_Health",
                    prefixLength: 2,
                    value: .range(.init(value: 80, lower: 0, upper: 100))
                ),
            ]
        ))
        let statsContent = try XCTUnwrap(stats.window?.contentView)
        statsContent.layoutSubtreeIfNeeded()
        let statsViews = recursiveSubviews(of: statsContent)
        XCTAssertTrue(statsViews.contains { $0.accessibilityLabel() == "Health: 80 [0…100]" })
        XCTAssertTrue(statsViews.contains { $0.accessibilityLabel() == "Progress" })

        let tileMap = TileMapWindowController(title: "Castle")
        let tileMapWindow = try XCTUnwrap(tileMap.window)
        XCTAssertEqual(tileMapWindow.minSize, NSSize(width: 320, height: 220))
        tileMap.update(.init(
            name: "Castle",
            tileWidth: 16,
            tileHeight: 16,
            columns: 4,
            rows: 3,
            encoding: .hex4,
            tiles: Array(repeating: 0, count: 12)
        ))
        let mapContent = try XCTUnwrap(tileMap.window?.contentView)
        let mapViews = recursiveSubviews(of: mapContent)
        XCTAssertTrue(mapViews.contains { $0.accessibilityLabel() == "Tile map Castle" })
        XCTAssertTrue(mapViews.contains { ($0.accessibilityValue() as? String) == "4 columns by 3 rows" })
        XCTAssertTrue(mapViews.contains { $0.accessibilityIdentifier() == "tileMapEditMode" })
        XCTAssertTrue(mapViews.contains { $0.accessibilityIdentifier() == "tileMapEncoding" })
        XCTAssertTrue(mapViews.contains { $0.accessibilityLabel() == "Tile picker" })
    }

    @MainActor
    func testMCPStatusSurfaceAndEmptyMediaStateAreAccessibleAndSafe() throws {
        let status = MCPStatusWindowController()
        status.update("Connected as Builder")
        let content = try XCTUnwrap(status.window?.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(recursiveSubviews(of: content).contains { $0.accessibilityLabel() == "MCP status: Connected as Builder" })

        let media = ClientMediaController()
        XCTAssertEqual(media.information, "No Client.Media assets are loaded.")
        media.stop(name: nil)
        media.flush()
    }

    @MainActor
    func testEmbeddedHelpFiltersCommandsAndIsAccessible() throws {
        let help = EmbeddedHelpWindowController()
        help.show(topic: "switchtab")
        let content = try XCTUnwrap(help.window?.contentView)
        let views = recursiveSubviews(of: content)
        XCTAssertTrue(views.contains { $0.accessibilityIdentifier() == "embeddedHelpSearch" })
        let text = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(text.string.contains("/switchtab"))
        XCTAssertFalse(text.string.contains("/connect "))
    }

    @MainActor
    func testWebViewBridgeRoutesCommandsAndTracksDisplayCaptureAndGMCPHooks() throws {
        let controller = WebViewWindowController(id: "Character editor")
        defer { controller.close() }
        var commands: [WebViewBridgeCommand] = []
        controller.onCommand = { command in
            commands.append(command)
            if command == .isConnected { return true }
            if case let .property(name) = command { return name == "ID" ? "Character editor" : nil }
            return true
        }
        XCTAssertEqual(try controller.handleBridge(method: "isConnected", arguments: [:]) as? Bool, true)
        _ = try controller.handleBridge(method: "send", arguments: ["text": "look", "processAliases": true])
        XCTAssertTrue(commands.contains(.send(text: "look", processAliases: true)))
        XCTAssertEqual(try controller.handleBridge(method: "getPropertyString", arguments: ["property": "ID"]) as? String, "Character editor")

        _ = try controller.handleBridge(method: "setOnDisplay", arguments: ["id": 7, "regex": "^HP:", "gag": true])
        XCTAssertTrue(controller.observeDisplay(.init(text: "HP: 10")))
        XCTAssertFalse(controller.observeDisplay(.init(text: "Mana: 5")))
        _ = try controller.handleBridge(method: "clearOnDisplay", arguments: ["id": 7])
        XCTAssertFalse(controller.observeDisplay(.init(text: "HP: 10")))

        _ = try controller.handleBridge(method: "setOnDisplayCapture", arguments: ["id": 3, "begin": "^BEGIN$", "end": "^END$"])
        XCTAssertTrue(controller.observeDisplay(.init(text: "BEGIN")))
        XCTAssertTrue(controller.observeDisplay(.init(text: "inside")))
        XCTAssertTrue(controller.observeDisplay(.init(text: "END")))
        XCTAssertEqual(try controller.handleBridge(method: "clearOnDisplayCapture", arguments: ["id": 3]) as? Bool, true)

        _ = try controller.handleBridge(method: "setOnGMCP", arguments: ["prefix": "Char"])
        controller.observeGMCP(.init(package: "Char.Vitals", payload: #"{"hp":10}"#))
        XCTAssertEqual(try controller.handleBridge(method: "clearOnGMCP", arguments: ["prefix": "Char"]) as? Bool, true)
        XCTAssertThrowsError(try controller.handleBridge(method: "setOnDisplay", arguments: ["id": 1, "regex": "["]))
        XCTAssertEqual(controller.webView.accessibilityLabel(), "Web content: Character editor")
    }

    @MainActor
    func testWebViewMovesIntoDockAndReleasesToSavedPlaceholder() {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = dock.hostView
        let web = WebViewWindowController(id: "status")
        let pane = WorkspacePaneKind.webView("status")

        dock.dockPane(pane, view: web.contentViewForDocking(), title: "Status", side: .left)
        XCTAssertTrue(web.isDocked)
        XCTAssertTrue(dock.containsPane(pane))
        XCTAssertTrue(web.webView.window === owner)

        dock.releasePane(pane)
        XCTAssertTrue(dock.containsPane(pane))
        web.closeSurface()
    }

    @MainActor
    func testWebViewInjectedCompatibilityObjectCallsNativeBridge() async throws {
        let controller = WebViewWindowController(id: "Bridge conformance")
        defer { controller.close() }
        controller.onCommand = { command in
            if command == .isConnected { return true }
            if case let .property(name) = command { return name == "ID" ? "Bridge conformance" : nil }
            return nil
        }
        let loaded = expectation(description: "web content loaded")
        controller.onNavigationFinished = { loaded.fulfill() }
        controller.apply(.init(source: "<title>Bridge Test</title><main>Ready</main><iframe srcdoc='<p>isolated</p>'></iframe>"))
        await fulfillment(of: [loaded], timeout: 3)

        let shape = try await controller.webView.callAsyncJavaScript(
            "return [typeof window.beipClient, typeof window.chrome.webview.hostObjects.client.SendGMCP, typeof window.beipClient.setOnDisplay]",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? [String]
        XCTAssertEqual(shape, ["object", "function", "function"])
        let connected = try await controller.webView.callAsyncJavaScript(
            "return await window.beipClient.isConnected()",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? Bool
        XCTAssertEqual(connected, true)
        let identifier = try await controller.webView.callAsyncJavaScript(
            "return await window.chrome.webview.hostObjects.client.GetPropertyString('ID')",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        XCTAssertEqual(identifier, "Bridge conformance")
        let subframeBridge = try await controller.webView.callAsyncJavaScript(
            "return typeof document.querySelector('iframe').contentWindow.beipClient",
            arguments: [:], in: nil, contentWorld: .page
        ) as? String
        XCTAssertEqual(subframeBridge, "undefined")
    }

    @MainActor
    func testSpawnTabGroupRetainsRoutesHighlightsReordersAndClosesTabs() throws {
        let group = TriggerSpawnTabGroupWindowController(title: "Channels")
        let publicLine = RenderedLine(
            text: "[Public] hello",
            runs: [.init(range: 0..<8, style: .init(foreground: .init(red: 0, green: 255, blue: 0)))]
        )
        group.deliver(publicLine, to: "Public", clear: false, showTab: false)
        group.deliver(.init(text: "[Private] secret"), to: "Private", clear: false, showTab: false)

        XCTAssertEqual(group.tabTitles, ["Public", "Private"])
        XCTAssertEqual(group.selectedTitle, "Public")
        XCTAssertEqual(group.highlightedTitles, ["Private"])
        XCTAssertEqual(group.retainedLines(in: "Public"), [publicLine])

        XCTAssertTrue(group.selectTab(named: "Private"))
        XCTAssertEqual(group.selectedTitle, "Private")
        XCTAssertTrue(group.highlightedTitles.isEmpty)
        group.deliver(.init(text: "replacement"), to: "Private", clear: true, showTab: false)
        XCTAssertEqual(group.retainedLines(in: "Private").map(\.text), ["replacement"])

        group.moveTab(from: 1, to: 0)
        XCTAssertEqual(group.tabTitles, ["Private", "Public"])
        XCTAssertTrue(group.closeTab(named: "Private"))
        XCTAssertEqual(group.tabTitles, ["Public"])
        XCTAssertEqual(group.selectedTitle, "Public")

        let content = try XCTUnwrap(group.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let views = recursiveSubviews(of: content)
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Spawn tabs" })
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Close Public" })
        let scrollView = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first)
        XCTAssertEqual(scrollView.frame.height, content.bounds.height - 32, accuracy: 1)
    }

    @MainActor
    func testAtlasEditorIntegratesRoomInfoAndExposesNativeAccessibleControls() throws {
        let controller = AtlasWindowController(atlas: Atlas(maps: []))
        controller.editor.liveTracking = true
        controller.integrate(.init(
            id: "dock",
            area: "Harbor",
            name: "Moonlit Dock",
            coordinates: .init(floor: 0, x: 20, y: 30),
            size: .init(x: 100, y: 70)
        ))

        XCTAssertEqual(controller.editor.currentLocation, .init(mapIndex: 0, roomIndex: 0))
        XCTAssertEqual(controller.editor.currentMap?.name, "Harbor")
        XCTAssertEqual(controller.lookDescription(), "Location: Moonlit Dock\nExits: (none)")
        try controller.restore(.init(
            mapIndex: 0, currentMapIndex: 0, currentRoomIndex: 0,
            scale: 1.5, originX: 44, originY: -12,
            selectionFilterRaw: AtlasSelectionFilter.rooms.rawValue,
            liveTracking: true
        ))
        XCTAssertEqual(controller.editor.viewport, .init(scale: 1.5, origin: .init(x: 44, y: -12)))
        XCTAssertEqual(controller.editor.selectionFilter, .rooms)
        XCTAssertTrue(controller.editor.liveTracking)
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let views = recursiveSubviews(of: content)
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Atlas map canvas" })
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Atlas editing tool" })
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Atlas map" })
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Known exits" })
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Map zoom" })
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Automatic mapping" })
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.title == "Palette" })
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.title == "Export" })
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.title == "Zoom in" })
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.title == "Fit map" })
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.title == "Create room" })
        for group in ["File", "Navigation", "Create", "Select", "View"] {
            XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == group })
        }
        XCTAssertTrue(content.wantsLayer)
        let openButton = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Open" })
        XCTAssertTrue(openButton.wantsLayer)
        let openButtonParent = try XCTUnwrap(openButton.superview)
        XCTAssertFalse(sequence(first: openButtonParent, next: \.superview).contains { $0 is NSClipView })
        for title in ["Open", "Save", "Save As", "Locate", "Create room", "Select", "Add map", "Remove map", "Zoom in", "Fit map", "Palette", "Export"] {
            let button = try XCTUnwrap(
                views.compactMap { $0 as? NSButton }.first { $0.title == title },
                "Missing Atlas toolbar button: \(title)"
            )
            XCTAssertGreaterThan(button.image?.size.width ?? 0, 0, "Missing icon for Atlas toolbar button: \(title)")
            XCTAssertGreaterThan(button.frame.width, 0, "Atlas toolbar button has no width: \(title)")
            XCTAssertGreaterThan(button.frame.height, 0, "Atlas toolbar button has no height: \(title)")
        }
        let canvas = try XCTUnwrap(views.first { $0.accessibilityLabel() == "Atlas map canvas" })
        let mapBarLabel = try XCTUnwrap(views.first { $0.accessibilityLabel() == "Map zoom" })
        XCTAssertGreaterThan(mapBarLabel.superview?.layer?.zPosition ?? 0, canvas.layer?.zPosition ?? 0)

        let location = try XCTUnwrap(controller.editor.currentLocation)
        let roomID = try XCTUnwrap(controller.editor.objectID(for: location))
        controller.editor.selection = [roomID]
        XCTAssertTrue(controller.copySelection())
        XCTAssertTrue(controller.pasteSelection())
        XCTAssertEqual(controller.editor.atlas.maps[0].rooms.count, 2)

        XCTAssertTrue(controller.addRoomAndExit(name: "Harbor Road", outward: "east", returnCommand: "west"))
        var sentCommands: [String] = []
        controller.onSendCommands = { sentCommands += $0 }
        let exits = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "Known exits"
        })
        XCTAssertTrue(exits.isEnabled)
        XCTAssertEqual(exits.numberOfItems, 2)
        exits.selectItem(at: 1)
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(exits.action), to: exits.target, from: exits))
        XCTAssertEqual(sentCommands, ["east"])
    }

    private func pageKeyEvent(keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
