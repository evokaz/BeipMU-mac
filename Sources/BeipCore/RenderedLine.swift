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
        link: LinkAction? = nil
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
    public var alignment: Alignment
    public var leftIndent: Double
    public var rightIndent: Double
    public var topPadding: Double
    public var bottomPadding: Double
    public var background: RGBColor?

    public init(
        alignment: Alignment = .left,
        leftIndent: Double = 0,
        rightIndent: Double = 0,
        topPadding: Double = 0,
        bottomPadding: Double = 0,
        background: RGBColor? = nil
    ) {
        self.alignment = alignment
        self.leftIndent = leftIndent
        self.rightIndent = rightIndent
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.background = background
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

