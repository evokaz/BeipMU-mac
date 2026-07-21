import Foundation
@testable import BeipUI
import XCTest

final class WorkspacePreferencesTests: XCTestCase {
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
            checksSpelling: false,
            theme: .init(mode: .custom, foregroundHex: "#112233", backgroundHex: "#445566", accentHex: "#778899"),
            logging: .init(logsSentText: true, logsTypedText: true, includesTime: true, wrapWidth: 100),
            dockPlacement: .floating,
            lastDockedPlacement: .left,
            dockThickness: 333,
            workspaceLayout: .splitSidebars,
            characterNotes: ["example": "Remember the hidden door."]
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
        XCTAssertEqual(decoded.dockPlacement, .hidden)
        XCTAssertEqual(decoded.lastDockedPlacement, .right)
        XCTAssertFalse(decoded.outputSplit)
        XCTAssertNil(decoded.workspaceLayout)
        XCTAssertEqual(decoded.characterNotes, [:])
    }

    func testUnsafeLayoutValuesAreNormalizedOnLoad() throws {
        let suiteName = "WorkspacePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        WorkspacePreferencesStore.save(.init(
            outputHistoryLimit: 1,
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
    }
}
