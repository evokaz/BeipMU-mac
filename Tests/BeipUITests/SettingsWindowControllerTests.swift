import AppKit
import BeipPersistence
import XCTest
@testable import BeipUI

final class SettingsWindowControllerTests: XCTestCase {
    @MainActor
    func testRetainedWindowHasSixDestinationsAndExpectedSizing() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = SettingsWindowController(
            profileLibrary: library,
            shortcutsProvider: { KeyboardShortcutStore.load() },
            context: .init(
                section: .appearance,
                initialScope: nil,
                identity: .init(world: "World", character: "Character", tab: "Main")
            ),
            onPreferencesMutation: {},
            onShortcutsMutation: { _ in }
        )
        defer { controller.close() }

        XCTAssertEqual(controller.window?.title, "Settings")
        XCTAssertEqual(controller.window?.minSize, NSSize(width: 760, height: 560))
        XCTAssertEqual(controller.sidebarTitlesForTesting, ["Appearance", "Output", "Input", "Scripting", "Shortcuts", "Advanced"])
        XCTAssertEqual(controller.selectedSectionForTesting, .appearance)
        XCTAssertNotNil(findView(withIdentifier: "settingsSidebar", in: controller.window?.contentView))
        XCTAssertNotNil(findView(withIdentifier: "settingsContent", in: controller.window?.contentView))
    }

    @MainActor
    func testPresentationReusesWindowAndDeepLinksScopes() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = SettingsWindowController(
            profileLibrary: library,
            shortcutsProvider: { KeyboardShortcutStore.load() },
            context: .init(
                section: .appearance,
                initialScope: nil,
                identity: .init(world: "World", character: "Character", tab: "Main")
            ),
            onPreferencesMutation: {},
            onShortcutsMutation: { _ in }
        )
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)

        controller.present(context: .init(
            section: .output,
            initialScope: .tab,
            identity: .init(world: "World", character: "Character", tab: "Main")
        ))

        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(controller.selectedSectionForTesting, .output)
        XCTAssertEqual(controller.presentationContextForTesting.initialScope, .tab)
        XCTAssertNotNil(findView(withIdentifier: "outputSettingsScope", in: window.contentView))
        XCTAssertNotNil(findView(withIdentifier: "showInlineImagePreviews", in: window.contentView))
    }

    @MainActor
    func testInputScriptingAndShortcutDestinationsExposeExpectedControls() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = SettingsWindowController(
            profileLibrary: library,
            shortcutsProvider: { KeyboardShortcutStore.load() },
            context: .init(
                section: .input,
                initialScope: nil,
                identity: .init(world: "World", character: "Character", tab: "Main")
            ),
            onPreferencesMutation: {},
            onShortcutsMutation: { _ in }
        )
        defer { controller.close() }

        let expected: [(SettingsSection, [String])] = [
            (.input, ["inputSettingsScope", "inputSettingsKeepText", "checkSpelling"]),
            (.scripting, ["scriptStartupPath", "scriptChoose", "scriptDebugEnabled"]),
            (.shortcuts, ["shortcut.newTab", "shortcutRestoreDefaults"]),
        ]
        for (section, identifiers) in expected {
            controller.present(context: .init(
                section: section,
                initialScope: nil,
                identity: .init(world: "World", character: "Character", tab: "Main")
            ))
            for identifier in identifiers {
                XCTAssertNotNil(
                    findView(withIdentifier: identifier, in: controller.window?.contentView),
                    "Missing (identifier) in (section.rawValue)"
                )
            }
        }
    }

    @MainActor
    func testAdvancedSectionExposesFactoryResetCopyAndRoutesThroughCallback() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        var requests = 0
        let controller = SettingsWindowController(
            profileLibrary: library,
            shortcutsProvider: { KeyboardShortcutStore.load() },
            context: .init(
                section: .advanced,
                initialScope: nil,
                identity: .init(world: "World", character: "Character", tab: "Main")
            ),
            onPreferencesMutation: {},
            onShortcutsMutation: { _ in },
            onFactoryResetRequest: { requests += 1 }
        )
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        let reset = try XCTUnwrap(findView(withIdentifier: "resetConfigurationButton", in: content) as? NSButton)
        XCTAssertNotNil(findView(withIdentifier: "resetConfigurationExplanation", in: content))
        reset.performClick(nil)
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testSidebarCanNavigateFromOutputToEveryDestination() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = SettingsWindowController(
            profileLibrary: library,
            shortcutsProvider: { KeyboardShortcutStore.load() },
            context: .init(
                section: .appearance,
                initialScope: nil,
                identity: .init(world: "World", character: "Character", tab: "Main")
            ),
            onPreferencesMutation: {},
            onShortcutsMutation: { _ in }
        )
        defer { controller.close() }
        let sidebar = try XCTUnwrap(findView(withIdentifier: "settingsSidebar", in: controller.window?.contentView) as? NSTableView)

        for section in SettingsSection.allCases {
            let row = try XCTUnwrap(SettingsSection.allCases.firstIndex(of: section))
            sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            XCTAssertEqual(controller.selectedSectionForTesting, section)
        }
    }

    @MainActor
    func testSidebarReusesCategoryViewsAfterFirstVisit() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        var preferenceLoads = 0
        let controller = SettingsWindowController(
            profileLibrary: library,
            preferencesProvider: {
                preferenceLoads += 1
                return WorkspacePreferences()
            },
            shortcutsProvider: { KeyboardShortcutStore.load() },
            context: .init(
                section: .appearance,
                initialScope: nil,
                identity: .init(world: "World", character: "Character", tab: "Main")
            ),
            onPreferencesMutation: {},
            onShortcutsMutation: { _ in }
        )
        defer { controller.close() }
        let sidebar = try XCTUnwrap(findView(withIdentifier: "settingsSidebar", in: controller.window?.contentView) as? NSTableView)
        let appearance = try XCTUnwrap(findView(withIdentifier: "settings.appearance.group", in: controller.window?.contentView))
        XCTAssertEqual(preferenceLoads, 1)

        sidebar.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let appearanceAgain = try XCTUnwrap(findView(withIdentifier: "settings.appearance.group", in: controller.window?.contentView))
        XCTAssertTrue(appearance === appearanceAgain)
        XCTAssertEqual(preferenceLoads, 1)
    }

    @MainActor
    func testContentOverflowCueTracksSectionAndWindowSize() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = SettingsWindowController(
            profileLibrary: library,
            shortcutsProvider: { KeyboardShortcutStore.load() },
            context: .init(
                section: .appearance,
                initialScope: nil,
                identity: .init(world: "World", character: "Character", tab: "Main")
            ),
            onPreferencesMutation: {},
            onShortcutsMutation: { _ in }
        )
        defer { controller.close() }

        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let contentScroll = try XCTUnwrap(
            findView(withIdentifier: "settingsContentScroll", in: window.contentView) as? NSScrollView
        )
        XCTAssertEqual(contentScroll.accessibilityLabel(), "Settings content")
        XCTAssertFalse(controller.contentIsOverflowingForTesting)
        XCTAssertFalse(controller.contentScrollShowsVerticalScrollerForTesting)
        XCTAssertTrue(contentScroll.autohidesScrollers)
        XCTAssertFalse(controller.contentScrollCueIsVisibleForTesting)

        controller.present(context: .init(
            section: .output,
            initialScope: nil,
            identity: .init(world: "World", character: "Character", tab: "Main")
        ))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.contentIsOverflowingForTesting)
        XCTAssertTrue(controller.contentScrollShowsVerticalScrollerForTesting)
        XCTAssertFalse(contentScroll.autohidesScrollers)
        XCTAssertTrue(controller.contentScrollCueIsVisibleForTesting)

        let documentHeight = contentScroll.documentView?.bounds.height ?? 0
        let viewportHeight = contentScroll.contentView.bounds.height
        contentScroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, documentHeight - viewportHeight)))
        contentScroll.reflectScrolledClipView(contentScroll.contentView)
        XCTAssertFalse(controller.contentScrollCueIsVisibleForTesting)
        contentScroll.contentView.scroll(to: .zero)
        contentScroll.reflectScrolledClipView(contentScroll.contentView)
        XCTAssertTrue(controller.contentScrollCueIsVisibleForTesting)

        window.setContentSize(NSSize(width: 840, height: 400))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.contentIsOverflowingForTesting)
        XCTAssertTrue(controller.contentScrollShowsVerticalScrollerForTesting)
        XCTAssertFalse(contentScroll.autohidesScrollers)
        XCTAssertTrue(controller.contentScrollCueIsVisibleForTesting)

        window.setContentSize(NSSize(width: 840, height: 680))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.contentIsOverflowingForTesting)
        XCTAssertTrue(controller.contentScrollShowsVerticalScrollerForTesting)
        XCTAssertTrue(controller.contentScrollCueIsVisibleForTesting)

        controller.present(context: .init(
            section: .scripting,
            initialScope: nil,
            identity: .init(world: "World", character: "Character", tab: "Main")
        ))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.contentIsOverflowingForTesting)
        XCTAssertFalse(controller.contentScrollShowsVerticalScrollerForTesting)
        XCTAssertTrue(contentScroll.autohidesScrollers)
        XCTAssertFalse(controller.contentScrollCueIsVisibleForTesting)
    }

    @MainActor
    func testShortcutConflictIsPresentedAndNotPersisted() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        var prompts: [String] = []
        let controller = SettingsWindowController(
            profileLibrary: library,
            shortcutsProvider: { KeyboardShortcutStore.load() },
            context: .init(
                section: .shortcuts,
                initialScope: nil,
                identity: .init(world: "World", character: "Character", tab: "Main")
            ),
            onPreferencesMutation: {},
            onShortcutsMutation: { _ in },
            nativeShortcutConflict: { values in
                values[.newTab]?.keyEquivalent == "o"
                    ? "Conflicts with the native menu command \"Import Config…\"."
                    : nil
            },
            presentShortcutConflict: { prompts.append($0) }
        )
        defer { controller.close() }

        controller.setShortcutValueForTesting("Command+O", for: .newTab)

        XCTAssertEqual(prompts, ["Conflicts with the native menu command \"Import Config…\"."])
        XCTAssertNil(library.keyEquivalents["newTab"])
    }

    @MainActor
    func testDuplicateShortcutIsPresentedAndNotPersisted() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        var prompts: [String] = []
        let controller = SettingsWindowController(
            profileLibrary: library,
            shortcutsProvider: { KeyboardShortcutStore.load() },
            context: .init(
                section: .shortcuts,
                initialScope: nil,
                identity: .init(world: "World", character: "Character", tab: "Main")
            ),
            onPreferencesMutation: {},
            onShortcutsMutation: { _ in },
            presentShortcutConflict: { prompts.append($0) }
        )
        defer { controller.close() }

        controller.setShortcutValueForTesting("Command+N", for: .newTab)

        XCTAssertEqual(prompts, ["This shortcut is already assigned to New Window."])
        XCTAssertNil(library.keyEquivalents["newTab"])
    }

    @MainActor
    func testEmptyShortcutIsPersistedAsUnbound() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        var mutation: [ShortcutAction: KeyboardShortcut]?
        let controller = SettingsWindowController(
            profileLibrary: library,
            shortcutsProvider: { KeyboardShortcutStore.load() },
            context: .init(
                section: .shortcuts,
                initialScope: nil,
                identity: .init(world: "World", character: "Character", tab: "Main")
            ),
            onPreferencesMutation: {},
            onShortcutsMutation: { mutation = $0 }
        )
        defer { controller.close() }

        controller.setShortcutValueForTesting("", for: .newTab)

        XCTAssertEqual(mutation?[.newTab], .unbound)
        XCTAssertEqual(library.keyEquivalents["newTab"], "")
    }

    @MainActor
    func testShortcutFieldCapturesCommandEquivalentInsteadOfInvokingMenuAction() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        var mutation: [ShortcutAction: KeyboardShortcut]?
        let controller = SettingsWindowController(
            profileLibrary: library,
            shortcutsProvider: { KeyboardShortcutStore.load() },
            context: .init(
                section: .shortcuts,
                initialScope: nil,
                identity: .init(world: "World", character: "Character", tab: "Main")
            ),
            onPreferencesMutation: {},
            onShortcutsMutation: { mutation = $0 }
        )
        defer { controller.close() }

        let window = try XCTUnwrap(controller.window)
        let field = try XCTUnwrap(
            findView(withIdentifier: "shortcut.newTab", in: window.contentView) as? NSTextField
        )
        XCTAssertTrue(window.makeFirstResponder(field))

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "o",
            charactersIgnoringModifiers: "o",
            isARepeat: false,
            keyCode: 31
        ))

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(field.stringValue, "⌘O")
        XCTAssertEqual(mutation?[.newTab], .init(keyEquivalent: "o", modifiers: [.command]))
    }

    @MainActor
    private func findView(withIdentifier identifier: String, in root: NSView?) -> NSView? {
        guard let root else { return nil }
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let match = findView(withIdentifier: identifier, in: child) { return match }
        }
        return nil
    }
}
