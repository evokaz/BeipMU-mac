import Foundation

public struct RGBColor: Sendable, Hashable, Codable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = RGBColor(red: 0, green: 0, blue: 0)
    public static let white = RGBColor(red: 255, green: 255, blue: 255)
    public static let transparent = RGBColor(red: 0, green: 0, blue: 0, alpha: 0)
}

public struct TextStyle: Sendable, Hashable, Codable {
    public var foreground: RGBColor?
    public var background: RGBColor?
    public var bold: Bool
    public var faint: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikeout: Bool
    public var blink: Blink
    public var link: LinkAction?
    public var fontFace: String?
    public var fontSize: Double?

    public enum Blink: String, Sendable, Hashable, Codable {
        case none, slow, fast
    }

    public init(
        foreground: RGBColor? = nil,
        background: RGBColor? = nil,
        bold: Bool = false,
        faint: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikeout: Bool = false,
        blink: Blink = .none,
        link: LinkAction? = nil,
        fontFace: String? = nil,
        fontSize: Double? = nil
    ) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.faint = faint
        self.italic = italic
        self.underline = underline
        self.strikeout = strikeout
        self.blink = blink
        self.link = link
        self.fontFace = fontFace
        self.fontSize = fontSize
    }

    /// Retains the pre-Milestone-4 initializer ABI for clients compiled
    /// against the original style model.
    public init(
        foreground: RGBColor?, background: RGBColor?, bold: Bool, faint: Bool,
        italic: Bool, underline: Bool, strikeout: Bool, blink: Blink, link: LinkAction?
    ) {
        self.init(
            foreground: foreground, background: background, bold: bold, faint: faint,
            italic: italic, underline: underline, strikeout: strikeout, blink: blink,
            link: link, fontFace: nil, fontSize: nil
        )
    }
}

public enum LinkAction: Sendable, Hashable, Codable {
    case url(String)
    case send(String, hints: [String])
    case command(String)
}

public struct StyleRun: Sendable, Hashable, Codable {
    /// UTF-16 offsets, matching AppKit and JavaScript string indexing.
    public var range: Range<Int>
    public var style: TextStyle

    public init(range: Range<Int>, style: TextStyle) {
        self.range = range
        self.style = style
    }
}

public struct ParagraphStyle: Sendable, Hashable, Codable {
    public enum Alignment: String, Sendable, Hashable, Codable { case left, center, right }
    public enum BorderStyle: String, Sendable, Hashable, Codable { case square, round }
    public enum StrokeStyle: String, Sendable, Hashable, Codable { case outline, top, bottom }
    public var alignment: Alignment
    public var leftIndent: Double
    /// Additional indentation applied to wrapped continuation lines.
    public var wrappedIndent: Double
    public var rightIndent: Double
    public var topPadding: Double
    public var bottomPadding: Double
    public var background: RGBColor?
    public var borderWidth: Double
    public var borderStyle: BorderStyle
    public var strokeWidth: Double
    public var strokeColor: RGBColor?
    public var strokeStyle: StrokeStyle
    public var horizontalRule: Bool

    public init(
        alignment: Alignment = .left,
        leftIndent: Double = 0,
        wrappedIndent: Double = 0,
        rightIndent: Double = 0,
        topPadding: Double = 0,
        bottomPadding: Double = 0,
        background: RGBColor? = nil,
        borderWidth: Double = 0,
        borderStyle: BorderStyle = .square,
        strokeWidth: Double = 0,
        strokeColor: RGBColor? = nil,
        strokeStyle: StrokeStyle = .outline,
        horizontalRule: Bool = false
    ) {
        self.alignment = alignment
        self.leftIndent = leftIndent
        self.wrappedIndent = wrappedIndent
        self.rightIndent = rightIndent
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.background = background
        self.borderWidth = borderWidth
        self.borderStyle = borderStyle
        self.strokeWidth = strokeWidth
        self.strokeColor = strokeColor
        self.strokeStyle = strokeStyle
        self.horizontalRule = horizontalRule
    }

    /// Retains the pre-Milestone-4 initializer ABI for persisted/test clients.
    public init(
        alignment: Alignment, leftIndent: Double, wrappedIndent: Double,
        rightIndent: Double, topPadding: Double, bottomPadding: Double,
        background: RGBColor?
    ) {
        self.init(
            alignment: alignment, leftIndent: leftIndent, wrappedIndent: wrappedIndent,
            rightIndent: rightIndent, topPadding: topPadding, bottomPadding: bottomPadding,
            background: background, borderWidth: 0, borderStyle: .square,
            strokeWidth: 0, strokeColor: nil, strokeStyle: .outline, horizontalRule: false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case alignment, leftIndent, wrappedIndent, rightIndent, topPadding, bottomPadding, background
        case borderWidth, borderStyle, strokeWidth, strokeColor, strokeStyle, horizontalRule
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        alignment = try values.decodeIfPresent(Alignment.self, forKey: .alignment) ?? .left
        leftIndent = try values.decodeIfPresent(Double.self, forKey: .leftIndent) ?? 0
        wrappedIndent = try values.decodeIfPresent(Double.self, forKey: .wrappedIndent) ?? 0
        rightIndent = try values.decodeIfPresent(Double.self, forKey: .rightIndent) ?? 0
        topPadding = try values.decodeIfPresent(Double.self, forKey: .topPadding) ?? 0
        bottomPadding = try values.decodeIfPresent(Double.self, forKey: .bottomPadding) ?? 0
        background = try values.decodeIfPresent(RGBColor.self, forKey: .background)
        borderWidth = try values.decodeIfPresent(Double.self, forKey: .borderWidth) ?? 0
        borderStyle = try values.decodeIfPresent(BorderStyle.self, forKey: .borderStyle) ?? .square
        strokeWidth = try values.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 0
        strokeColor = try values.decodeIfPresent(RGBColor.self, forKey: .strokeColor)
        strokeStyle = try values.decodeIfPresent(StrokeStyle.self, forKey: .strokeStyle) ?? .outline
        horizontalRule = try values.decodeIfPresent(Bool.self, forKey: .horizontalRule) ?? false
    }
}

public struct InlineAsset: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable { case image, avatar, icon }
    public var kind: Kind
    public var source: URL
    public var altText: String
    public var characterOffset: Int

    public init(kind: Kind, source: URL, altText: String, characterOffset: Int) {
        self.kind = kind
        self.source = source
        self.altText = altText
        self.characterOffset = characterOffset
    }
}

public struct RenderedLine: Identifiable, Sendable, Hashable, Codable {
    public enum Source: String, Sendable, Hashable, Codable {
        case server, prompt, localEcho, client, script, replay
    }

    public let id: UUID
    public var text: String
    public var runs: [StyleRun]
    public var paragraph: ParagraphStyle
    public var assets: [InlineAsset]
    public var timestamp: Date
    public var source: Source

    public init(
        id: UUID = UUID(),
        text: String,
        runs: [StyleRun] = [],
        paragraph: ParagraphStyle = .init(),
        assets: [InlineAsset] = [],
        timestamp: Date = Date(),
        source: Source = .server
    ) {
        self.id = id
        self.text = text
        self.runs = runs
        self.paragraph = paragraph
        self.assets = assets
        self.timestamp = timestamp
        self.source = source
    }
}
