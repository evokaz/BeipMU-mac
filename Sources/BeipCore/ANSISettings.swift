import Foundation

/// The sixteen logical ANSI colours, in the order used by BeipMU's settings
/// dialog and Config.txt projection.
public enum ANSIColorName: String, CaseIterable, Codable, Sendable, Hashable {
    case black = "Black"
    case red = "Red"
    case green = "Green"
    case yellow = "Yellow"
    case blue = "Blue"
    case magenta = "Magenta"
    case cyan = "Cyan"
    case white = "White"
    case boldBlack = "BoldBlack"
    case boldRed = "BoldRed"
    case boldGreen = "BoldGreen"
    case boldYellow = "BoldYellow"
    case boldBlue = "BoldBlue"
    case boldMagenta = "BoldMagenta"
    case boldCyan = "BoldCyan"
    case boldWhite = "BoldWhite"

    public var displayName: String {
        switch self {
        case .black: "Black"
        case .red: "Red"
        case .green: "Green"
        case .yellow: "Yellow"
        case .blue: "Blue"
        case .magenta: "Magenta"
        case .cyan: "Cyan"
        case .white: "White"
        case .boldBlack: "Bold Black"
        case .boldRed: "Bold Red"
        case .boldGreen: "Bold Green"
        case .boldYellow: "Bold Yellow"
        case .boldBlue: "Bold Blue"
        case .boldMagenta: "Bold Magenta"
        case .boldCyan: "Bold Cyan"
        case .boldWhite: "Bold White"
        }
    }

    public var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// The exact palette presets shipped by the original BeipMU client.
public enum ANSIPalettePreset: String, CaseIterable, Codable, Sendable, Hashable {
    case xTerm = "XTerm"
    case cmd = "CMD"
    case vga = "VGA"
    case old = "Old"
    case bright = "Bright"

    public static var xterm: Self { .xTerm }
    public static var `default`: Self { .xTerm }

    public var colors: [RGBColor] {
        switch self {
        case .xTerm:
            return Self.palette([
                (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
                (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
                (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
                (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
            ])
        case .cmd:
            return Self.palette([
                (0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0),
                (0, 0, 128), (128, 0, 128), (0, 128, 128), (192, 192, 192),
                (128, 128, 128), (255, 0, 0), (0, 255, 0), (255, 255, 0),
                (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
            ])
        case .vga:
            return Self.palette([
                (0, 0, 0), (170, 0, 0), (0, 170, 0), (170, 85, 0),
                (0, 0, 170), (170, 0, 170), (0, 170, 170), (170, 170, 170),
                (85, 85, 85), (255, 85, 85), (85, 255, 85), (255, 255, 85),
                (85, 85, 255), (255, 85, 255), (85, 255, 255), (255, 255, 255),
            ])
        case .old:
            return Self.palette([
                (0, 0, 0), (255, 0, 0), (0, 255, 0), (192, 192, 0),
                (0, 0, 255), (192, 0, 192), (0, 192, 192), (192, 192, 192),
                (128, 128, 128), (255, 128, 128), (128, 255, 128), (255, 255, 0),
                (128, 128, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
            ])
        case .bright:
            return Self.palette([
                (0, 0, 0), (255, 0, 0), (0, 255, 0), (255, 255, 0),
                (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
                (128, 128, 128), (255, 128, 128), (128, 255, 128), (255, 255, 128),
                (128, 128, 255), (255, 128, 255), (128, 255, 255), (255, 255, 255),
            ])
        }
    }

    private static func palette(_ values: [(Int, Int, Int)]) -> [RGBColor] {
        values.map { RGBColor(red: UInt8($0.0), green: UInt8($0.1), blue: UInt8($0.2)) }
    }
}

public typealias ANSIColor = ANSIColorName
public typealias ANSIPreset = ANSIPalettePreset

public extension Array where Element == RGBColor {
    subscript(_ name: ANSIColorName) -> RGBColor {
        get { self[name.index] }
        set { self[name.index] = newValue }
    }
}

/// Workspace-global ANSI appearance, palette, and beep settings.
public struct ANSISettings: Codable, Equatable, Hashable, Sendable {
    public var colors: [RGBColor] {
        didSet { colors = Self.normalized(colors) }
    }
    public var fontBold: Bool
    public var preventInvisible: Bool
    public var parse: Bool
    /// Legacy ANSI flash interval in milliseconds. A value of zero disables blinking.
    public var flashSpeed: Int
    public var parseBlinking: Bool {
        get { flashSpeed != 0 }
        set {
            // Preserve a legacy interval unless the UI's Boolean setting actually changes.
            guard newValue != parseBlinking else { return }
            flashSpeed = newValue ? 500 : 0
        }
    }
    public var beep: Bool
    public var beepSystem: Bool
    public var beepFileName: String
    public var resetOnNewLine: Bool

    private enum CodingKeys: String, CodingKey {
        case colors, fontBold, preventInvisible, parse, parseBlinking, flashSpeed
        case beep, beepSystem, beepFileName, resetOnNewLine
    }

    public init(
        colors: [RGBColor] = ANSIPalettePreset.xTerm.colors,
        fontBold: Bool = false,
        preventInvisible: Bool = true,
        parse: Bool = true,
        parseBlinking: Bool = true,
        flashSpeed: Int? = nil,
        beep: Bool = true,
        beepSystem: Bool = true,
        beepFileName: String = "",
        resetOnNewLine: Bool = false
    ) {
        self.colors = Self.normalized(colors)
        self.fontBold = fontBold
        self.preventInvisible = preventInvisible
        self.parse = parse
        self.flashSpeed = flashSpeed ?? (parseBlinking ? 500 : 0)
        self.beep = beep
        self.beepSystem = beepSystem
        self.beepFileName = beepFileName
        self.resetOnNewLine = resetOnNewLine
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let parseBlinking = try values.decodeIfPresent(Bool.self, forKey: .parseBlinking) ?? true
        self.init(
            colors: try values.decodeIfPresent([RGBColor].self, forKey: .colors) ?? ANSIPalettePreset.xTerm.colors,
            fontBold: try values.decodeIfPresent(Bool.self, forKey: .fontBold) ?? false,
            preventInvisible: try values.decodeIfPresent(Bool.self, forKey: .preventInvisible) ?? true,
            parse: try values.decodeIfPresent(Bool.self, forKey: .parse) ?? true,
            parseBlinking: parseBlinking,
            flashSpeed: try values.decodeIfPresent(Int.self, forKey: .flashSpeed),
            beep: try values.decodeIfPresent(Bool.self, forKey: .beep) ?? true,
            beepSystem: try values.decodeIfPresent(Bool.self, forKey: .beepSystem) ?? true,
            beepFileName: try values.decodeIfPresent(String.self, forKey: .beepFileName) ?? "",
            resetOnNewLine: try values.decodeIfPresent(Bool.self, forKey: .resetOnNewLine) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(colors, forKey: .colors)
        try values.encode(fontBold, forKey: .fontBold)
        try values.encode(preventInvisible, forKey: .preventInvisible)
        try values.encode(parse, forKey: .parse)
        try values.encode(parseBlinking, forKey: .parseBlinking)
        try values.encode(flashSpeed, forKey: .flashSpeed)
        try values.encode(beep, forKey: .beep)
        try values.encode(beepSystem, forKey: .beepSystem)
        try values.encode(beepFileName, forKey: .beepFileName)
        try values.encode(resetOnNewLine, forKey: .resetOnNewLine)
    }

    public static let `default` = ANSISettings()
    public static let xTerm = ANSISettings()
    public static let xterm = ANSISettings()

    public var palette: [RGBColor] {
        get { colors }
        set { colors = newValue }
    }

    public var namedColors: [ANSIColorName: RGBColor] {
        Dictionary(uniqueKeysWithValues: ANSIColorName.allCases.map { ($0, color(for: $0)) })
    }

    public var useFontBold: Bool {
        get { fontBold }
        set { fontBold = newValue }
    }

    public var blinking: Bool {
        get { parseBlinking }
        set { parseBlinking = newValue }
    }

    public var parseANSICodes: Bool {
        get { parse }
        set { parse = newValue }
    }

    public var parseANSI: Bool {
        get { parse }
        set { parse = newValue }
    }

    public var parseEnabled: Bool {
        get { parse }
        set { parse = newValue }
    }

    public var beepEnabled: Bool {
        get { beep }
        set { beep = newValue }
    }

    public var useSystemBeep: Bool {
        get { beepSystem }
        set { beepSystem = newValue }
    }

    public var systemBeep: Bool {
        get { beepSystem }
        set { beepSystem = newValue }
    }

    public var customBeep: Bool {
        get { !beepSystem }
        set { beepSystem = !newValue }
    }

    public var customBeepPath: String {
        get { beepFileName }
        set { beepFileName = newValue }
    }

    public var beepFile: String {
        get { beepFileName }
        set { beepFileName = newValue }
    }

    public func color(for name: ANSIColorName) -> RGBColor {
        colors[name.index]
    }

    public mutating func setColor(_ color: RGBColor, for name: ANSIColorName) {
        var color = color
        color.alpha = 255
        colors[name.index] = color
    }

    public func applying(_ preset: ANSIPalettePreset) -> ANSISettings {
        var copy = self
        copy.colors = preset.colors
        return copy
    }

    private static func normalized(_ colors: [RGBColor]) -> [RGBColor] {
        var normalized = Array(colors.prefix(ANSIColorName.allCases.count))
        let defaults = ANSIPalettePreset.xTerm.colors
        while normalized.count < ANSIColorName.allCases.count {
            normalized.append(defaults[normalized.count])
        }
        for index in normalized.indices { normalized[index].alpha = 255 }
        return normalized
    }
}
