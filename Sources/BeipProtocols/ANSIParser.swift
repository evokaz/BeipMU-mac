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
    private let options: Options

    public init(options: Options = .init()) {
        self.options = options
    }

    public mutating func reset() { style = TextStyle() }

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
                append(String(scalar), style: style, result: &result, runs: &runs)
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
            case 0: style = TextStyle()
            case 1: style.bold = true
            case 2: style.faint = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 5: style.blink = .slow
            case 6: style.blink = .fast
            case 7, 8: swap(&style.foreground, &style.background)
            case 9: style.strikeout = true
            case 22: style.bold = false; style.faint = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 25: style.blink = .none
            case 27, 28: swap(&style.foreground, &style.background)
            case 29: style.strikeout = false
            case 30...37: style.foreground = Self.palette[value - 30]
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
            case 39: style.foreground = nil
            case 40...47: style.background = Self.palette[value - 40]
            case 49: style.background = nil
            case 90...97: style.foreground = Self.palette[value - 90 + 8]
            case 100...107: style.background = Self.palette[value - 100 + 8]
            default: break
            }
            index += 1
        }
        values.removeAll(keepingCapacity: false)
    }

    private mutating func setColor(_ color: RGBColor, foreground: Bool) {
        if foreground { style.foreground = color } else { style.background = color }
    }

    public func translate256(_ value: Int) -> RGBColor {
        if (0..<16).contains(value) { return Self.palette[value] }
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
}

