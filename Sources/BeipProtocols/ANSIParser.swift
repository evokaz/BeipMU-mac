import BeipCore
import Foundation

public struct ANSIParser: Sendable {
    public struct Options: Sendable {
        public var resetOnNewLine: Bool
        public var useFontBold: Bool
        public var preventInvisible: Bool

        public init(resetOnNewLine: Bool = false, useFontBold: Bool = false, preventInvisible: Bool = true) {
            self.resetOnNewLine = resetOnNewLine
            self.useFontBold = useFontBold
            self.preventInvisible = preventInvisible
        }
    }

    private var style = TextStyle()
    private var inverse = false
    private var foregroundPaletteIndex: Int?
    private let options: Options

    public init(options: Options = .init()) {
        self.options = options
    }

    public mutating func reset() {
        style = TextStyle()
        inverse = false
        foregroundPaletteIndex = nil
    }

    public mutating func parse(_ input: String, source: RenderedLine.Source = .server) -> RenderedLine {
        if options.resetOnNewLine { reset() }
        var result = ""
        var runs: [StyleRun] = []
        var scalarIndex = input.unicodeScalars.startIndex

        func append(_ text: String, style: TextStyle, result: inout String, runs: inout [StyleRun]) {
            guard !text.isEmpty else { return }
            let start = result.utf16.count
            result.append(text)
            let end = result.utf16.count
            if let last = runs.last, last.range.upperBound == start, last.style == style {
                runs[runs.count - 1].range = last.range.lowerBound..<end
            } else {
                runs.append(StyleRun(range: start..<end, style: style))
            }
        }

        while scalarIndex < input.unicodeScalars.endIndex {
            let scalar = input.unicodeScalars[scalarIndex]
            guard scalar.value == 0x1b else {
                append(String(scalar), style: renderedStyle(), result: &result, runs: &runs)
                scalarIndex = input.unicodeScalars.index(after: scalarIndex)
                continue
            }

            let afterEscape = input.unicodeScalars.index(after: scalarIndex)
            guard afterEscape < input.unicodeScalars.endIndex,
                  input.unicodeScalars[afterEscape] == "["
            else {
                scalarIndex = afterEscape
                continue
            }

            var end = input.unicodeScalars.index(after: afterEscape)
            while end < input.unicodeScalars.endIndex, input.unicodeScalars[end] != "m" {
                end = input.unicodeScalars.index(after: end)
            }
            guard end < input.unicodeScalars.endIndex else { break }
            let parameterStart = input.unicodeScalars.index(after: afterEscape)
            let parameters = String(input.unicodeScalars[parameterStart..<end])
            apply(parameters)
            scalarIndex = input.unicodeScalars.index(after: end)
        }

        return RenderedLine(text: result, runs: runs, source: source)
    }

    private mutating func apply(_ parameterString: String) {
        var values = parameterString.isEmpty
            ? [0]
            : parameterString.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var index = 0
        while index < values.count {
            let value = values[index]
            switch value {
            case 0: reset()
            case 1: style.bold = true
            case 2: style.faint = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 5: style.blink = .slow
            case 6: style.blink = .fast
            case 7, 8:
                if !inverse {
                    swap(&style.foreground, &style.background)
                    inverse = true
                }
            case 9: style.strikeout = true
            case 22: style.bold = false; style.faint = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 25: style.blink = .none
            case 27, 28:
                if inverse {
                    swap(&style.foreground, &style.background)
                    inverse = false
                }
            case 29: style.strikeout = false
            case 30...37: setColor(Self.palette[value - 30], foreground: true, paletteIndex: value - 30)
            case 38, 48:
                if index + 2 < values.count, values[index + 1] == 5 {
                    setColor(translate256(values[index + 2]), foreground: value == 38)
                    index += 2
                } else if index + 4 < values.count, values[index + 1] == 2 {
                    let color = RGBColor(
                        red: UInt8(clamping: values[index + 2]),
                        green: UInt8(clamping: values[index + 3]),
                        blue: UInt8(clamping: values[index + 4])
                    )
                    setColor(color, foreground: value == 38)
                    index += 4
                }
            case 39: clearColor(foreground: true)
            case 40...47: setColor(Self.palette[value - 40], foreground: false)
            case 49: clearColor(foreground: false)
            case 90...97: setColor(Self.palette[value - 90 + 8], foreground: true, paletteIndex: value - 90 + 8)
            case 100...107: setColor(Self.palette[value - 100 + 8], foreground: false)
            default: break
            }
            index += 1
        }
        values.removeAll(keepingCapacity: false)
    }

    private mutating func setColor(_ color: RGBColor, foreground: Bool, paletteIndex: Int? = nil) {
        if foreground { foregroundPaletteIndex = paletteIndex }
        if foreground != inverse { style.foreground = color } else { style.background = color }
    }

    private mutating func clearColor(foreground: Bool) {
        if foreground { foregroundPaletteIndex = nil }
        if foreground != inverse { style.foreground = nil } else { style.background = nil }
    }

    private func renderedStyle() -> TextStyle {
        var rendered = style
        let logicalForegroundIsBackground = inverse

        if rendered.bold, !options.useFontBold,
           let index = foregroundPaletteIndex, index < 8 {
            if logicalForegroundIsBackground {
                rendered.background = Self.palette[index + 8]
            } else {
                rendered.foreground = Self.palette[index + 8]
            }
        }

        if rendered.faint {
            if logicalForegroundIsBackground, let color = rendered.background {
                rendered.background = Self.darkened(color)
            } else if !logicalForegroundIsBackground, let color = rendered.foreground {
                rendered.foreground = Self.darkened(color)
            }
        }

        rendered.bold = options.useFontBold && rendered.bold
        if options.preventInvisible,
           let foreground = rendered.foreground,
           foreground == rendered.background {
            rendered.foreground = RGBColor(
                red: ~foreground.red,
                green: ~foreground.green,
                blue: ~foreground.blue,
                alpha: foreground.alpha
            )
        }
        return rendered
    }

    private static func darkened(_ color: RGBColor) -> RGBColor {
        RGBColor(
            red: color.red / 2,
            green: color.green / 2,
            blue: color.blue / 2,
            alpha: color.alpha
        )
    }

    public func translate256(_ value: Int) -> RGBColor {
        if (0..<16).contains(value) { return Self.extendedPalette[value] }
        if (16...231).contains(value) {
            let adjusted = value - 16
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            return RGBColor(
                red: levels[adjusted / 36],
                green: levels[(adjusted / 6) % 6],
                blue: levels[adjusted % 6]
            )
        }
        if (232...255).contains(value) {
            let level = UInt8(8 + (value - 232) * 10)
            return RGBColor(red: level, green: level, blue: level)
        }
        return RGBColor(red: 255, green: 0, blue: 0)
    }

    private static let palette: [RGBColor] = [
        .init(red: 0, green: 0, blue: 0), .init(red: 205, green: 0, blue: 0),
        .init(red: 0, green: 205, blue: 0), .init(red: 205, green: 205, blue: 0),
        .init(red: 0, green: 0, blue: 238), .init(red: 205, green: 0, blue: 205),
        .init(red: 0, green: 205, blue: 205), .init(red: 229, green: 229, blue: 229),
        .init(red: 127, green: 127, blue: 127), .init(red: 255, green: 0, blue: 0),
        .init(red: 0, green: 255, blue: 0), .init(red: 255, green: 255, blue: 0),
        .init(red: 92, green: 92, blue: 255), .init(red: 255, green: 0, blue: 255),
        .init(red: 0, green: 255, blue: 255), .init(red: 255, green: 255, blue: 255),
    ]

    // BeipMU's configurable ANSI palette is used for SGR 30...37/90...97,
    // while the first sixteen entries in the fixed 256-color table retain
    // the legacy Windows defaults from AnsiParser.cpp.
    private static let extendedPalette: [RGBColor] = [
        .init(red: 0, green: 0, blue: 0), .init(red: 128, green: 0, blue: 0),
        .init(red: 0, green: 128, blue: 0), .init(red: 128, green: 128, blue: 0),
        .init(red: 0, green: 0, blue: 128), .init(red: 128, green: 0, blue: 128),
        .init(red: 0, green: 128, blue: 128), .init(red: 192, green: 192, blue: 192),
        .init(red: 128, green: 128, blue: 128), .init(red: 255, green: 0, blue: 0),
        .init(red: 0, green: 255, blue: 0), .init(red: 255, green: 255, blue: 0),
        .init(red: 0, green: 0, blue: 255), .init(red: 255, green: 0, blue: 255),
        .init(red: 0, green: 255, blue: 255), .init(red: 255, green: 255, blue: 255),
    ]
}
