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
        case .convertReturns: .functionKey(1)
        case .convertTabs: .functionKey(1, modifiers: [.shift])
        case .convertSpaces: .functionKey(2, modifiers: [.shift])
        }
    }
}

struct KeyboardShortcut: Codable, Equatable {
    var keyEquivalent: String
    var modifierRawValue: UInt

    var modifiers: NSEvent.ModifierFlags { .init(rawValue: modifierRawValue) }

    init(keyEquivalent: String, modifiers: NSEvent.ModifierFlags = []) {
        self.keyEquivalent = keyEquivalent
        modifierRawValue = modifiers.rawValue
    }

    static func functionKey(_ number: Int, modifiers: NSEvent.ModifierFlags = []) -> KeyboardShortcut {
        let scalar = UnicodeScalar(0xF704 + max(1, min(20, number)) - 1)!
        return .init(keyEquivalent: String(Character(scalar)), modifiers: modifiers)
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
            key = remainder.lowercased()
        } else {
            return nil
        }
        return .init(keyEquivalent: key, modifiers: modifiers)
    }

    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        guard let scalar = keyEquivalent.unicodeScalars.first else { return result }
        if (0xF704...0xF717).contains(scalar.value) {
            return result + "F\(scalar.value - 0xF704 + 1)"
        }
        return result + keyEquivalent.uppercased()
    }
}

enum KeyboardShortcutStore {
    static func load(from values: [String: String] = [:]) -> [ShortcutAction: KeyboardShortcut] {
        var result = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        for (identifier, value) in values {
            if let action = ShortcutAction(rawValue: identifier), let shortcut = KeyboardShortcut.parse(value) {
                result[action] = shortcut
            }
        }
        return result
    }

    static func serialized(_ shortcuts: [ShortcutAction: KeyboardShortcut]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value.displayString) })
    }
}
