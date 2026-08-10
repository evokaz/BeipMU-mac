@testable import BeipAutomation
import BeipCore
import BeipTestSupport
import Foundation
import XCTest

final class KeyboardMacroTests: XCTestCase {
    func testKeyboardMacrosUseWindowsScopePrecedenceAndNestedFolders() {
        let global = KeyboardMacroGroup(macros: [
            .init(macro: "global", key: "Control+Alt+N"),
        ])
        let server = KeyboardMacroGroup(macros: [
            .init(macro: "server", key: "Control+Alt+N"),
        ])
        let character = KeyboardMacroGroup(macros: [
            .init(macro: "", key: "", folder: true, children: [
                .init(macro: "character", key: "Control+Alt+N", typeIntoInput: true),
            ]),
        ])

        let match = KeyboardMacroEngine.macro(for: "Control+Alt+N", groups: [character, server, global])
        XCTAssertEqual(match?.macro, "character")
        XCTAssertTrue(match?.typeIntoInput == true)
        XCTAssertNil(KeyboardMacroEngine.macro(for: "Control+N", groups: [character, server, global]))
    }

    func testKeyboardMacroKeysCanonicalizeWildcardsAndExtendedVocabulary() {
        XCTAssertEqual(KeyboardMacroKey.canonical("ctrl+option+f01"), "Control+Alt+F1")
        XCTAssertEqual(KeyboardMacroKey.canonical("Control+Option+Shift+M"), "Control+Alt+Shift+M")
        XCTAssertEqual(KeyboardMacroKey.pressedKey(key: "M", control: true, shift: true), "Control+Shift+M")
        XCTAssertEqual(KeyboardMacroKey.canonical("?Control+Alt+A"), "?Control+Alt+A")
        XCTAssertEqual(KeyboardMacroKey.displayString("?Control+Alt+NumPad8"), "Control + Option + NumPad8")
        XCTAssertTrue(KeyboardMacroKey.isSupportedKey("NumPadAdd"))
        XCTAssertTrue(KeyboardMacroKey.isSupportedKey("PageDown"))
        XCTAssertFalse(KeyboardMacroKey.isSupportedKey("Command"))
        XCTAssertFalse(KeyboardMacroKey.matches(configured: "Command+A", pressed: "A"))
        XCTAssertTrue(KeyboardMacroKey.matches(configured: "?Control+Alt+A", pressed: "Alt+A"))
        XCTAssertTrue(KeyboardMacroKey.matches(configured: "A", pressed: "A"))
        XCTAssertTrue(KeyboardMacroKey.parse("Control+Alt+A")?.isConcrete == true)
        XCTAssertFalse(KeyboardMacroKey.parse("?Control+Alt+A")?.isConcrete == true)
    }

    func testKeyboardMacroInactiveFolderGroupDoesNotMatchChildren() {
        let folder = KeyboardMacro(
            macro: "",
            key: "",
            folder: true,
            children: [.init(macro: "north", key: "N")],
            childrenActive: false
        )
        XCTAssertNil(KeyboardMacroEngine.macro(for: "N", groups: [.init(macros: [folder])]))
    }
}
