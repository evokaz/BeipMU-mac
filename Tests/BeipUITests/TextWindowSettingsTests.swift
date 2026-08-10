import BeipPersistence
import AppKit
import BeipCore
@testable import BeipUI
import Foundation
import XCTest

final class TextWindowSettingsTests: XCTestCase {
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
        let isolatedDefaults = try WorkspaceUITestSupport.makeIsolatedDefaults()
        let suiteName = isolatedDefaults.suiteName
        let defaults = isolatedDefaults.defaults
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
                "Delete Line", "Inherit default settings", "Settings…",
            ]
        )
        XCTAssertEqual(menu.item(withTitle: "Inherit default settings")?.state, .on)
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Inherit default settings")).isEnabled)
        XCTAssertEqual(controller.activeTextWindowSettingsScopeForTesting, .global)
    }

    @MainActor
    func testContextSettingsRouteToResolvedScopeAndSeedInheritedTabOverrides() throws {
        let server = ServerProfile(name: "Settings World", host: "example.invalid", port: 8888)
        let character = CharacterProfile(name: "Settings Character")
        let identity = TextWindowSettingsIdentity(
            world: server.name,
            character: character.name,
            tab: "Main"
        )
        var preferences = WorkspacePreferences()
        preferences.globalTextWindowSettings.fontSize = 11
        preferences.globalInputWindowSettings.fontSize = 12
        preferences.characterTextWindowSettings[try XCTUnwrap(identity.characterKey)] = .init(
            usesGlobalSettings: false,
            settings: .init(fontSize: 17)
        )
        preferences.characterInputWindowSettings[try XCTUnwrap(identity.characterKey)] = .init(
            usesGlobalSettings: false,
            settings: .init(fontSize: 18)
        )

        let controller = ClientWindowController(
            profileLibrary: .init(workspace: try .empty(isDirty: false)),
            initialPreferences: preferences
        )
        defer { controller.close() }
        controller.restoreOpenTab(server: server, character: character)

        XCTAssertEqual(controller.activeTextWindowSettingsScopeForTesting, .tab)
        XCTAssertEqual(controller.activeInputWindowSettingsScopeForTesting, .tab)
        XCTAssertEqual(controller.outputContextMenuForTesting().item(withTitle: "Inherit default settings")?.state, .off)
        XCTAssertEqual(controller.inputContextMenuForTesting().item(withTitle: "Inherit default settings")?.state, .off)
        XCTAssertEqual(
            controller.textWindowSettingsEditorStatesForTesting()[.tab]?.override,
            .init(usesGlobalSettings: false, settings: .init(fontSize: 17))
        )
        XCTAssertEqual(
            controller.inputWindowSettingsEditorStatesForTesting()[.tab]?.override,
            .init(usesGlobalSettings: false, settings: .init(fontSize: 18))
        )

        var inheritedPreferences = preferences
        inheritedPreferences.tabTextWindowSettings[try XCTUnwrap(identity.tabKey)] = .init(
            usesGlobalSettings: true,
            settings: .init(fontSize: 99)
        )
        inheritedPreferences.tabInputWindowSettings[try XCTUnwrap(identity.tabKey)] = .init(
            usesGlobalSettings: true,
            settings: .init(fontSize: 99)
        )
        let inheritedController = ClientWindowController(
            profileLibrary: .init(workspace: try .empty(isDirty: false)),
            initialPreferences: inheritedPreferences
        )
        defer { inheritedController.close() }
        inheritedController.restoreOpenTab(server: server, character: character)

        XCTAssertEqual(inheritedController.activeTextWindowSettingsScopeForTesting, .global)
        XCTAssertEqual(inheritedController.activeInputWindowSettingsScopeForTesting, .global)
        XCTAssertEqual(inheritedController.outputContextMenuForTesting().item(withTitle: "Inherit default settings")?.state, .on)
        XCTAssertEqual(inheritedController.inputContextMenuForTesting().item(withTitle: "Inherit default settings")?.state, .on)
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

        input.keyDown(with: try XCTUnwrap(WorkspaceUITestSupport.pageKeyEvent(keyCode: 116)))
        input.keyDown(with: try XCTUnwrap(WorkspaceUITestSupport.pageKeyEvent(keyCode: 121)))

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
            ["Inherit default settings", "Settings…", "Conversion", "Cut"]
        )
        XCTAssertEqual(menu.item(withTitle: "Inherit default settings")?.state, .on)
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "Inherit default settings")).isEnabled)
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
        let identifiers = Set(WorkspaceUITestSupport.recursiveSubviews(of: editor).compactMap { $0.accessibilityIdentifier() })
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
        let views = WorkspaceUITestSupport.recursiveSubviews(of: editor)
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

    @MainActor
    func testTextWindowSettingsEditorCommitsGroupedAndUngroupedHistoryLines() throws {
        let editor = TextWindowSettingsEditorView(
            states: [
                .global: .init(
                    label: "Global",
                    override: .init(
                        usesGlobalSettings: false,
                        settings: .init(historyLimit: 10_000)
                    )
                ),
            ],
            initialScope: .global,
            numberLocale: Locale(identifier: "de_DE")
        )
        let history = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: editor)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "textSettingsHistory" }
        )

        XCTAssertEqual(history.stringValue, "10.000")
        editor.commit()
        XCTAssertEqual(editor.states[.global]?.override.settings.historyLimit, 10_000)

        history.stringValue = "10.0000"
        editor.commit()
        XCTAssertEqual(editor.states[.global]?.override.settings.historyLimit, 100_000)

        history.stringValue = "12345"
        editor.commit()
        XCTAssertEqual(editor.states[.global]?.override.settings.historyLimit, 12_345)
    }
}
