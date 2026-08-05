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
    /// Whether a folder's nested KeyboardMacros2 group participates in
    /// matching. Windows stores this as Active on the nested group.
    public var childrenActive: Bool
    public var children: [KeyboardMacro]

    public init(
        id: UUID = UUID(),
        description: String = "",
        macro: String,
        key: String,
        typeIntoInput: Bool = false,
        folder: Bool = false,
        children: [KeyboardMacro] = [],
        childrenActive: Bool = true
    ) {
        self.id = id
        self.description = description
        self.macro = macro
        self.key = key
        self.typeIntoInput = typeIntoInput
        self.folder = folder
        self.childrenActive = childrenActive
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id, description, macro, key, typeIntoInput, folder, childrenActive, children
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        macro = try values.decodeIfPresent(String.self, forKey: .macro) ?? ""
        key = try values.decodeIfPresent(String.self, forKey: .key) ?? ""
        typeIntoInput = try values.decodeIfPresent(Bool.self, forKey: .typeIntoInput) ?? false
        folder = try values.decodeIfPresent(Bool.self, forKey: .folder) ?? false
        childrenActive = try values.decodeIfPresent(Bool.self, forKey: .childrenActive) ?? true
        children = try values.decodeIfPresent([KeyboardMacro].self, forKey: .children) ?? []
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

/// The portable key vocabulary used by Windows Config.txt. A nil modifier in
/// `Components` means that the modifier is a wildcard (`?Control`, etc.).
public enum KeyboardMacroKey: Sendable {
    public struct Components: Sendable, Hashable, Equatable {
        public var key: String
        public var control: Bool?
        public var alt: Bool?
        public var shift: Bool?

        public init(
            key: String,
            control: Bool? = false,
            alt: Bool? = false,
            shift: Bool? = false
        ) {
            self.key = KeyboardMacroKey.canonicalKey(key)
            self.control = control
            self.alt = alt
            self.shift = shift
        }

        public var canonicalString: String {
            KeyboardMacroKey.canonicalFormat(
                key: key,
                control: control,
                alt: alt,
                shift: shift
            )
        }

        public var isConcrete: Bool { control != nil && alt != nil && shift != nil }
    }

    /// Parses a Config.txt key expression. Unknown key names are retained so
    /// a reader can display and round-trip legacy data that this Mac build
    /// does not capture.
    public static func parse(_ source: String) -> Components? {
        var values = source.split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let rawKey = values.popLast(), !rawKey.isEmpty else { return nil }

        var control: Bool? = false
        var alt: Bool? = false
        var shift: Bool? = false
        for value in values {
            let lower = value.lowercased()
            let wildcard = lower.hasPrefix("?")
            let rawName = wildcard ? String(lower.dropFirst()) : lower
            let name: String
            switch rawName {
            case "control", "ctrl": name = "control"
            case "alt", "option": name = "alt"
            case "shift": name = "shift"
            case "command", "cmd":
                // Command shortcuts are deliberately reserved by the Mac
                // runtime and are never valid macro bindings.
                return nil
            default:
                // Unknown modifier expressions are outside the Mac capture
                // vocabulary. Treat them as unsupported so an unrelated
                // detail edit can preserve the original Config.txt key.
                return nil
            }
            switch name {
            case "control": control = wildcard ? nil : true
            case "alt": alt = wildcard ? nil : true
            case "shift": shift = wildcard ? nil : true
            default: break
            }
        }
        return Components(
            key: String(rawKey),
            control: control,
            alt: alt,
            shift: shift
        )
    }

    /// Returns a canonical Config.txt spelling while leaving unsupported
    /// legacy key names intact. This is intentionally non-throwing because
    /// existing Config.txt data must remain editable and lossless.
    public static func canonical(_ source: String) -> String {
        parse(source)?.canonicalString ?? source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func canonicalFormat(
        key: String,
        control: Bool? = false,
        alt: Bool? = false,
        shift: Bool? = false
    ) -> String {
        var parts: [String] = []
        if let control { if control { parts.append("Control") } } else { parts.append("?Control") }
        if let alt { if alt { parts.append("Alt") } } else { parts.append("?Alt") }
        if let shift { if shift { parts.append("Shift") } } else { parts.append("?Shift") }
        let normalized = canonicalKey(key)
        return (parts + [normalized]).joined(separator: "+")
    }

    /// Formats a key for the macOS UI. The persisted Config.txt spelling is
    /// still `Alt`, but macOS users see the native `Option` name.
    public static func displayString(_ source: String) -> String {
        guard let components = parse(source) else { return source }
        var parts: [String] = []
        if let control = components.control { if control { parts.append("Control") } }
        else { parts.append("Control") }
        if let alt = components.alt { if alt { parts.append("Option") } }
        else { parts.append("Option") }
        if let shift = components.shift { if shift { parts.append("Shift") } }
        else { parts.append("Shift") }
        parts.append(displayKey(components.key))
        return parts.joined(separator: " + ")
    }

    public static func isSupportedKey(_ key: String) -> Bool {
        supportedKeys.contains { $0.caseInsensitiveCompare(canonicalKey(key)) == .orderedSame }
    }

    public static var supportedKeys: Set<String> {
        var values = Set(("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map(String.init)))
        values.formUnion((1...20).map { "F\($0)" })
        values.formUnion([
            "Comma", "Period", "Slash", "Backslash", "Semicolon", "Quote", "Grave",
            "Minus", "Equal", "LeftBracket", "RightBracket", "Plus",
            "NumPad0", "NumPad1", "NumPad2", "NumPad3", "NumPad4", "NumPad5",
            "NumPad6", "NumPad7", "NumPad8", "NumPad9", "NumPadDecimal",
            "NumPadDivide", "NumPadMultiply", "NumPadSubtract", "NumPadAdd", "NumPadEnter",
            "Left", "Right", "Up", "Down", "Home", "End", "PageUp", "PageDown",
            "Return", "Tab", "Escape", "Space", "Backspace", "Delete",
        ])
        return values
    }

    public static func matches(configured: String, pressed: String) -> Bool {
        guard let configured = parse(configured), let pressed = parse(pressed) else { return false }
        guard configured.key.caseInsensitiveCompare(pressed.key) == .orderedSame else { return false }
        for (configuredState, pressedState) in [
            (configured.control, pressed.control),
            (configured.alt, pressed.alt),
            (configured.shift, pressed.shift),
        ] {
            if let configuredState, configuredState != pressedState { return false }
        }
        return true
    }

    /// Converts a native Mac key code into the same key name used by capture
    /// and runtime matching. Keeping this map here prevents the editor and
    /// live input path from slowly acquiring different vocabularies.
    public static func keyName(forKeyCode keyCode: UInt16, characters: String? = nil) -> String? {
        let special: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
            80: "F19", 90: "F20", 82: "NumPad0", 83: "NumPad1", 84: "NumPad2",
            85: "NumPad3", 86: "NumPad4", 87: "NumPad5", 88: "NumPad6", 89: "NumPad7",
            91: "NumPad8", 92: "NumPad9", 65: "NumPadDecimal", 75: "NumPadDivide",
            67: "NumPadMultiply", 78: "NumPadSubtract", 69: "NumPadAdd", 76: "NumPadEnter",
            123: "Left", 124: "Right", 125: "Down", 126: "Up", 115: "Home", 119: "End",
            116: "PageUp", 121: "PageDown", 36: "Return", 48: "Tab", 53: "Escape",
            49: "Space", 51: "Backspace", 117: "Delete", 43: "Comma", 47: "Period",
            44: "Slash", 41: "Semicolon", 39: "Quote", 33: "LeftBracket", 30: "RightBracket",
            42: "Backslash", 27: "Minus", 24: "Equal", 50: "Grave",
        ]
        if let special = special[keyCode] { return special }
        guard let characters, characters.count == 1 else { return nil }
        let candidate = canonicalKey(characters)
        return isSupportedKey(candidate) ? candidate : nil
    }

    public static func pressedKey(
        key: String,
        control: Bool = false,
        alt: Bool = false,
        shift: Bool = false
    ) -> String {
        canonicalFormat(key: key, control: control, alt: alt, shift: shift)
    }

    private static func canonicalKey(_ key: String) -> String {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }
        let lower = value.lowercased()
        let aliases: [String: String] = [
            "numpad0": "NumPad0", "numpad1": "NumPad1", "numpad2": "NumPad2",
            "numpad3": "NumPad3", "numpad4": "NumPad4", "numpad5": "NumPad5",
            "numpad6": "NumPad6", "numpad7": "NumPad7", "numpad8": "NumPad8",
            "numpad9": "NumPad9", "keypad0": "NumPad0", "keypad1": "NumPad1",
            "keypad2": "NumPad2", "keypad3": "NumPad3", "keypad4": "NumPad4",
            "keypad5": "NumPad5", "keypad6": "NumPad6", "keypad7": "NumPad7",
            "keypad8": "NumPad8", "keypad9": "NumPad9", "esc": "Escape",
            "enter": "Return", "pgup": "PageUp", "pgdn": "PageDown",
            "leftarrow": "Left", "rightarrow": "Right", "uparrow": "Up", "downarrow": "Down",
        ]
        if let alias = aliases[lower] { return alias }
        if value.count == 1, value.unicodeScalars.allSatisfy({
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
        }) {
            return value.uppercased()
        }
        if value.count == 1, value.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }) {
            return value
        }
        if lower.hasPrefix("f"), let number = Int(lower.dropFirst()), (1...20).contains(number) {
            return "F\(number)"
        }
        return value
    }

    private static func displayKey(_ key: String) -> String {
        switch canonicalKey(key).lowercased() {
        case "left": return "Left Arrow"
        case "right": return "Right Arrow"
        case "up": return "Up Arrow"
        case "down": return "Down Arrow"
        case "pageup": return "Page Up"
        case "pagedown": return "Page Down"
        case "numpaddecimal": return "NumPad ."
        case "numpaddivide": return "NumPad /"
        case "numpadmultiply": return "NumPad *"
        case "numpadsubtract": return "NumPad -"
        case "numpadadd": return "NumPad +"
        case "numpadenter": return "NumPad Enter"
        default: return canonicalKey(key)
        }
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
            if macro.childrenActive, let child = find(pressedKey, in: macro.children) { return child }
        }
        return nil
    }
}
