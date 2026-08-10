import BeipPersistence
import AppKit
import BeipCore
@testable import BeipUI
import Foundation
import XCTest

final class KeyboardThemeTests: XCTestCase {
    func testKeyboardShortcutParsingDisplayAndPersistence() throws {
        XCTAssertEqual(KeyboardShortcut.parse("⌘⇧P")?.displayString, "⇧⌘P")
        XCTAssertEqual(KeyboardShortcut.parse("Command+Shift+P")?.displayString, "⇧⌘P")
        XCTAssertEqual(KeyboardShortcut.parse("Shift+F2")?.displayString, "⇧F2")
        XCTAssertNil(KeyboardShortcut.parse("Command+Many+P"))

        let custom = KeyboardShortcut.parse("Option+K")!
        let customTrigger = KeyboardShortcut.parse("Command+Shift+G")!
        let serialized = KeyboardShortcutStore.serialized([
            .clearOutput: custom,
            .triggers: customTrigger,
            .connect: .init(keyEquivalent: "[", modifiers: [.command]),
        ])
        XCTAssertEqual(serialized, [
            "clearOutput": "⌥K",
            "connect": "⌘[",
            "triggers": "⇧⌘G",
        ])
        let loaded = KeyboardShortcutStore.load(from: serialized)
        XCTAssertEqual(loaded[.clearOutput], custom)
        XCTAssertEqual(loaded[.triggers], customTrigger)
        XCTAssertEqual(loaded[.connect], .init(keyEquivalent: "[", modifiers: [.command]))
        XCTAssertEqual(loaded[.newWindow], ShortcutAction.newWindow.defaultShortcut)
        XCTAssertEqual(loaded[.toggleInputHistory], .init(keyEquivalent: "h", modifiers: [.control]))
        XCTAssertEqual(loaded[.macros], ShortcutAction.macros.defaultShortcut)
        XCTAssertEqual(loaded[.aliases], ShortcutAction.aliases.defaultShortcut)
        XCTAssertEqual(loaded[.smartPaste], ShortcutAction.smartPaste.defaultShortcut)
        XCTAssertEqual(KeyboardShortcutStore.load()[.clearOutput], ShortcutAction.clearOutput.defaultShortcut)
        XCTAssertEqual(
            KeyboardShortcut.parse(KeyboardShortcut(keyEquivalent: "[", modifiers: [.command]).displayString),
            .init(keyEquivalent: "[", modifiers: [.command])
        )
        XCTAssertEqual(FixedShortcut.settings, .init(keyEquivalent: ",", modifiers: [.command]))
        XCTAssertEqual(FixedShortcut.help, .init(keyEquivalent: "?", modifiers: [.command]))
        XCTAssertEqual(FixedShortcut.quit, .init(keyEquivalent: "q", modifiers: [.command]))
    }

    func testKeyboardShortcutCanBeClearedWithoutFallingBackToDefault() {
        let loaded = KeyboardShortcutStore.load(from: ["newTab": ""])
        XCTAssertEqual(loaded[.newTab], .unbound)
        XCTAssertEqual(KeyboardShortcutStore.serialized([.newTab: .unbound]), ["newTab": ""])
    }

    @MainActor
    func testClearedShortcutRemovesItsMenuAccelerator() throws {
        let menu = ApplicationMenuBuilder.makeMenu(
            shortcuts: KeyboardShortcutStore.load(from: ["newTab": ""])
        )
        let windowsMenu = try XCTUnwrap(menu.item(withTitle: "Windows")?.submenu)
        let newTab = try XCTUnwrap(windowsMenu.item(withTitle: "New Tab"))
        XCTAssertEqual(newTab.keyEquivalent, "")
        XCTAssertEqual(newTab.keyEquivalentModifierMask, [])
    }

    func testKeyboardShortcutDefaultsCoverEveryAuthoritativeAction() {
        XCTAssertEqual(
            KeyboardShortcutStore.load(),
            [
                .newWindow: .init(keyEquivalent: "n", modifiers: [.command]),
                .newTab: .init(keyEquivalent: "t", modifiers: [.command]),
                .connect: .init(keyEquivalent: "[", modifiers: [.command]),
                .disconnect: .init(keyEquivalent: "]", modifiers: [.command]),
                .logging: .init(keyEquivalent: "l", modifiers: [.command]),
                .findOutput: .init(keyEquivalent: "f", modifiers: [.command]),
                .clearOutput: .init(keyEquivalent: "k", modifiers: [.command]),
                .pauseOutput: .init(keyEquivalent: "p", modifiers: [.command, .shift]),
                .toggleInputHistory: .init(keyEquivalent: "h", modifiers: [.control]),
                .triggers: .init(keyEquivalent: "t", modifiers: [.control, .shift]),
                .macros: .init(keyEquivalent: "m", modifiers: [.control, .shift]),
                .aliases: .init(keyEquivalent: "a", modifiers: [.control, .shift]),
                .smartPaste: .init(keyEquivalent: "v", modifiers: [.control, .shift]),
                .convertReturns: .functionKey(1),
                .convertTabs: .functionKey(1, modifiers: [.shift]),
                .convertSpaces: .functionKey(2, modifiers: [.shift]),
            ]
        )
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

    }
}
