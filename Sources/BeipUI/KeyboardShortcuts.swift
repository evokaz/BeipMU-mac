import AppKit
import Foundation

enum ShortcutAction: String, CaseIterable, Codable {
    case newWindow
    case newTab
    case connect
    case disconnect
    case logging
    case findOutput
    case clearOutput
    case pauseOutput
    case toggleInputHistory
    case triggers
    case macros
    case aliases
    case smartPaste
    case convertReturns
    case convertTabs
    case convertSpaces

    var title: String {
        switch self {
        case .newWindow: "New Window"
        case .newTab: "New Tab"
        case .connect: "Connect"
        case .disconnect: "Disconnect"
        case .logging: "Logging"
        case .findOutput: "Find in Output"
        case .clearOutput: "Clear Output"
        case .pauseOutput: "Pause Output"
        case .toggleInputHistory: "Toggle Input History"
        case .triggers: "Triggers"
        case .macros: "Macros"
        case .aliases: "Aliases"
        case .smartPaste: "Smart Paste"
        case .convertReturns: "Convert Returns to %R"
        case .convertTabs: "Convert Tabs to %T"
        case .convertSpaces: "Convert Spaces to %B"
        }
    }

    var defaultShortcut: KeyboardShortcut {
        switch self {
        case .newWindow: .init(keyEquivalent: "n", modifiers: [.command])
        case .newTab: .init(keyEquivalent: "t", modifiers: [.command])
        case .connect: .init(keyEquivalent: "[", modifiers: [.command])
        case .disconnect: .init(keyEquivalent: "]", modifiers: [.command])
        case .logging: .init(keyEquivalent: "l", modifiers: [.command])
        case .findOutput: .init(keyEquivalent: "f", modifiers: [.command])
        case .clearOutput: .init(keyEquivalent: "k", modifiers: [.command])
        case .pauseOutput: .init(keyEquivalent: "p", modifiers: [.command, .shift])
        case .toggleInputHistory: .init(keyEquivalent: "h", modifiers: [.control])
        case .triggers: .init(keyEquivalent: "t", modifiers: [.control, .shift])
        case .macros: .init(keyEquivalent: "m", modifiers: [.control, .shift])
        case .aliases: .init(keyEquivalent: "a", modifiers: [.control, .shift])
        case .smartPaste: .init(keyEquivalent: "v", modifiers: [.control, .shift])
        case .convertReturns: .functionKey(1)
        case .convertTabs: .functionKey(1, modifiers: [.shift])
        case .convertSpaces: .functionKey(2, modifiers: [.shift])
        }
    }
}

/// Standard macOS commands shared by the native menu and the tab-bar menu.
/// These are intentionally not part of `ShortcutAction`: they are fixed
/// commands and must not appear in the customization dialog.
enum FixedShortcut {
    static let settings = KeyboardShortcut(keyEquivalent: ",", modifiers: [.command])
    static let help = KeyboardShortcut(keyEquivalent: "?", modifiers: [.command])
    static let quit = KeyboardShortcut(keyEquivalent: "q", modifiers: [.command])
}

struct KeyboardShortcut: Codable, Equatable {
    var keyEquivalent: String
    var modifierRawValue: UInt

    var modifiers: NSEvent.ModifierFlags { .init(rawValue: modifierRawValue) }

    static let unbound = KeyboardShortcut()

    init() {
        keyEquivalent = ""
        modifierRawValue = 0
    }

    init(keyEquivalent: String, modifiers: NSEvent.ModifierFlags = []) {
        self.keyEquivalent = keyEquivalent
        modifierRawValue = modifiers.rawValue
    }

    static func functionKey(_ number: Int, modifiers: NSEvent.ModifierFlags = []) -> KeyboardShortcut {
        let scalar = UnicodeScalar(0xF704 + max(1, min(20, number)) - 1)!
        return .init(keyEquivalent: String(Character(scalar)), modifiers: modifiers)
    }

    static func capture(from event: NSEvent) -> KeyboardShortcut? {
        guard let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let key = characters.first.map(String.init) else {
            return nil
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        return .init(keyEquivalent: canonicalKeyEquivalent(for: key.lowercased()), modifiers: modifiers)
    }

    static func parse(_ source: String) -> KeyboardShortcut? {
        var remainder = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []

        let symbols: [(Character, NSEvent.ModifierFlags)] = [
            ("⌘", .command), ("⇧", .shift), ("⌥", .option), ("⌃", .control),
        ]
        while let first = remainder.first, let match = symbols.first(where: { $0.0 == first }) {
            modifiers.insert(match.1)
            remainder.removeFirst()
        }

        var parts = remainder.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1 {
            remainder = parts.removeLast().trimmingCharacters(in: .whitespaces)
            for part in parts {
                switch part.trimmingCharacters(in: .whitespaces).lowercased() {
                case "command", "cmd": modifiers.insert(.command)
                case "shift": modifiers.insert(.shift)
                case "option", "alt": modifiers.insert(.option)
                case "control", "ctrl": modifiers.insert(.control)
                default: return nil
                }
            }
        }

        let key: String
        if remainder.count >= 2, remainder.first?.lowercased() == "f",
           let number = Int(remainder.dropFirst()), (1...20).contains(number) {
            key = functionKey(number).keyEquivalent
        } else if remainder.lowercased() == "space" {
            key = " "
        } else if remainder.count == 1 {
            key = Self.canonicalKeyEquivalent(for: remainder.lowercased())
        } else {
            return nil
        }
        return .init(keyEquivalent: key, modifiers: modifiers)
    }

    var displayString: String {
        displayString(using: Self.localizedKeyEquivalent(for: keyEquivalent))
    }

    /// The layout-independent form used in the sidecar configuration.
    ///
    /// `displayString` is intentionally user-facing and can contain the
    /// current keyboard layout's replacement for an otherwise unreachable
    /// key. Persistence must continue to use AppKit's canonical equivalent.
    var serializedString: String {
        displayString(using: keyEquivalent)
    }

    private func displayString(using displayedKey: String) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        guard let scalar = displayedKey.unicodeScalars.first else { return result }
        if (0xF704...0xF717).contains(scalar.value) {
            return result + "F\(scalar.value - 0xF704 + 1)"
        }
        return result + displayedKey.uppercased()
    }

    private static func canonicalKeyEquivalent(for key: String) -> String {
        guard key.count == 1 else { return key }
        for canonical in ["[", "]"] {
            if localizedKeyEquivalent(for: canonical) == key {
                return canonical
            }
        }
        return key
    }

    private static func localizedKeyEquivalent(for key: String) -> String {
        guard key == "[" || key == "]", !canTypeWithoutOption(key) else {
            return key
        }

        // AppKit localizes the bracket pair to the adjacent letter keys on
        // layouts such as German QWERTZ: [ -> ö and ] -> ä. Those keys are
        // the US semicolon and quote positions, respectively.
        let keyCode: UInt16 = key == "[" ? 41 : 39
        guard let event = NSEvent.keyEvent(
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
        ), let localized = event.characters(byApplyingModifiers: []) else {
            return key
        }
        return localized.isEmpty ? key : localized
    }

    private static func canTypeWithoutOption(_ key: String) -> Bool {
        for keyCode in UInt16(0)...UInt16(127) {
            guard let event = NSEvent.keyEvent(
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
            ), let characters = event.characters(byApplyingModifiers: []) else {
                continue
            }
            if characters.caseInsensitiveCompare(key) == .orderedSame {
                return true
            }
        }
        return false
    }
}

enum KeyboardShortcutStore {
    static func load(from values: [String: String] = [:]) -> [ShortcutAction: KeyboardShortcut] {
        var result = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        for (identifier, value) in values {
            guard let action = ShortcutAction(rawValue: identifier) else { continue }
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[action] = .unbound
            } else if let shortcut = KeyboardShortcut.parse(value) {
                result[action] = shortcut
            }
        }
        return result
    }

    static func serialized(_ shortcuts: [ShortcutAction: KeyboardShortcut]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value.serializedString) })
    }
}
