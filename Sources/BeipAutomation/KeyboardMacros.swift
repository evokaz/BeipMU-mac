import Foundation

public struct KeyboardMacro: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var description: String
    public var macro: String
    /// Legacy Config.txt key expression, for example `Control+Alt+A`.
    public var key: String
    /// `Type=true` inserts the macro into the active input editor instead of
    /// submitting it to the connection.
    public var typeIntoInput: Bool
    public var folder: Bool
    public var children: [KeyboardMacro]

    public init(
        id: UUID = UUID(),
        description: String = "",
        macro: String,
        key: String,
        typeIntoInput: Bool = false,
        folder: Bool = false,
        children: [KeyboardMacro] = []
    ) {
        self.id = id
        self.description = description
        self.macro = macro
        self.key = key
        self.typeIntoInput = typeIntoInput
        self.folder = folder
        self.children = children
    }
}

public struct KeyboardMacroGroup: Sendable, Hashable, Codable {
    public var active: Bool
    public var macros: [KeyboardMacro]

    public init(active: Bool = true, macros: [KeyboardMacro] = []) {
        self.active = active
        self.macros = macros
    }
}

/// Parses and compares the portable Config.txt spelling used by Windows key
/// macros. `?Control`/`?Alt`/`?Shift` are wildcard modifiers.
public enum KeyboardMacroKey: Sendable {
    public static func matches(configured: String, pressed: String) -> Bool {
        let configured = configuredComponents(configured)
        let pressed = pressedComponents(pressed)
        guard configured.key.caseInsensitiveCompare(pressed.key) == .orderedSame else { return false }
        for modifier in ["control", "alt", "shift"] {
            guard !configured.wildcards.contains(modifier) else { continue }
            if configured.enabled.contains(modifier) != pressed.enabled.contains(modifier) { return false }
        }
        return true
    }

    private static func configuredComponents(_ source: String) -> (key: String, enabled: Set<String>, wildcards: Set<String>) {
        var values = source.split(separator: "+", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let key = values.popLast().map { String($0) } ?? ""
        var enabled: Set<String> = []
        var wildcards: Set<String> = []
        for value in values {
            let lower = value.lowercased()
            let optional = lower.hasPrefix("?")
            let name = optional ? String(lower.dropFirst()) : lower
            guard ["control", "ctrl", "alt", "option", "shift"].contains(name) else { continue }
            let canonical = name == "ctrl" ? "control" : name == "option" ? "alt" : name
            if optional { wildcards.insert(canonical) } else { enabled.insert(canonical) }
        }
        return (key, enabled, wildcards)
    }

    private static func pressedComponents(_ source: String) -> (key: String, enabled: Set<String>) {
        let parsed = configuredComponents(source)
        return (parsed.key, parsed.enabled)
    }
}

public enum KeyboardMacroEngine: Sendable {
    /// Groups must be supplied in precedence order (character, server,
    /// global), matching `Connection::MacroKey` in the Windows client.
    public static func macro(for pressedKey: String, groups: [KeyboardMacroGroup]) -> KeyboardMacro? {
        for group in groups where group.active {
            if let match = find(pressedKey, in: group.macros) { return match }
        }
        return nil
    }

    private static func find(_ pressedKey: String, in macros: [KeyboardMacro]) -> KeyboardMacro? {
        for macro in macros {
            if !macro.folder, KeyboardMacroKey.matches(configured: macro.key, pressed: pressedKey) { return macro }
            if let child = find(pressedKey, in: macro.children) { return child }
        }
        return nil
    }
}
