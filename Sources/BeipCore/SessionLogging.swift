import Foundation

public enum SessionLogFormat: String, Sendable, Codable {
    case plainText, html

    public static func infer(from url: URL) -> SessionLogFormat {
        ["html", "htm"].contains(url.pathExtension.lowercased()) ? .html : .plainText
    }
}

public struct SessionLogOptions: Sendable, Codable, Equatable {
    public var logsSentText: Bool
    public var sentPrefix: String
    public var logsTypedText: Bool
    public var typedPrefix: String
    public var includesTime: Bool
    public var includesDate: Bool
    public var uses24HourTime: Bool
    public var wrapWidth: Int?
    public var hangingIndent: Int
    public var wrapsAtWords: Bool
    public var doubleSpaces: Bool

    public init(
        logsSentText: Bool = false,
        sentPrefix: String = "Sent>",
        logsTypedText: Bool = false,
        typedPrefix: String = "Typed>",
        includesTime: Bool = false,
        includesDate: Bool = false,
        uses24HourTime: Bool = false,
        wrapWidth: Int? = nil,
        hangingIndent: Int = 0,
        wrapsAtWords: Bool = true,
        doubleSpaces: Bool = false
    ) {
        self.logsSentText = logsSentText
        self.sentPrefix = sentPrefix
        self.logsTypedText = logsTypedText
        self.typedPrefix = typedPrefix
        self.includesTime = includesTime
        self.includesDate = includesDate
        self.uses24HourTime = uses24HourTime
        self.wrapWidth = wrapWidth.map { max(2, $0) }
        self.hangingIndent = max(0, hangingIndent)
        self.wrapsAtWords = wrapsAtWords
        self.doubleSpaces = doubleSpaces
    }
}

public struct SessionLogRenderer: Sendable {
    public var format: SessionLogFormat
    public var options: SessionLogOptions
    public var title: String
    public var foregroundHex: String
    public var backgroundHex: String

    public init(
        format: SessionLogFormat,
        options: SessionLogOptions = .init(),
        title: String,
        foregroundHex: String = "#E6E6E6",
        backgroundHex: String = "#0D0D0D"
    ) {
        self.format = format
        self.options = options
        self.title = title
        self.foregroundHex = foregroundHex
        self.backgroundHex = backgroundHex
    }

    public func documentHeader() -> String {
        guard format == .html else { return "" }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(Self.escapeHTML(title))</title>
        <style>body{background:\(backgroundHex);color:\(foregroundHex);font:13px ui-monospace,monospace}.log-event{border-block:1px dotted currentColor;padding:.5em}.line{white-space:pre-wrap;margin:0}.timestamp{opacity:.65;margin-right:1em}</style></head><body>

        """
    }

    public func startMarker(at date: Date = Date()) -> String {
        marker("Logging started", at: date, starts: true)
    }

    public func stopMarker(at date: Date = Date()) -> String {
        marker("Logging stopped", at: date, starts: false)
    }

    public func line(_ line: RenderedLine) -> String {
        switch format {
        case .plainText:
            return plainLine(line.text, date: line.timestamp)
        case .html:
            let timestamp = timestampHTML(line.timestamp)
            let alignment = line.paragraph.alignment.rawValue
            let background = line.paragraph.background.map { "background:\(Self.hex($0));" } ?? ""
            return "<p class=\"line\" style=\"text-align:\(alignment);\(background)\">\(timestamp)\(styledHTML(line))</p>\n"
        }
    }

    public func typed(_ text: String, at date: Date = Date()) -> String {
        guard options.logsTypedText else { return "" }
        return input(options.typedPrefix + text, date: date)
    }

    public func sent(_ text: String, at date: Date = Date()) -> String {
        guard options.logsSentText else { return "" }
        return input(options.sentPrefix + text, date: date)
    }

    private func input(_ text: String, date: Date) -> String {
        switch format {
        case .plainText: plainLine(text, date: date)
        case .html: "<p class=\"line\">\(timestampHTML(date))\(Self.escapeHTML(text))</p>\n"
        }
    }

    private func plainLine(_ text: String, date: Date) -> String {
        let prefix = timestamp(date)
        let logicalLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let rendered = logicalLines.flatMap { wrap($0, firstPrefixWidth: prefix.count) }
        let result = rendered.enumerated().map { index, value in
            (index == 0 ? prefix : "") + value
        }.joined(separator: "\n") + "\n"
        return options.doubleSpaces ? result + "\n" : result
    }

    private func wrap(_ text: String, firstPrefixWidth: Int) -> [String] {
        guard let configuredWidth = options.wrapWidth else { return [text] }
        let minimumWidth = 20
        var remaining = text
        var result: [String] = []
        var first = true
        while true {
            let prefixWidth = first ? firstPrefixWidth : options.hangingIndent
            let available = max(minimumWidth, configuredWidth - prefixWidth)
            guard remaining.count > available else {
                result.append((first ? "" : String(repeating: " ", count: options.hangingIndent)) + remaining)
                break
            }
            let splitIndex: String.Index
            let hard = remaining.index(remaining.startIndex, offsetBy: available)
            if options.wrapsAtWords,
               let space = remaining[..<hard].lastIndex(of: " "), space > remaining.startIndex {
                splitIndex = space
            } else {
                splitIndex = hard
            }
            result.append(
                (first ? "" : String(repeating: " ", count: options.hangingIndent))
                    + String(remaining[..<splitIndex])
            )
            remaining = String(remaining[splitIndex...]).trimmingCharacters(in: .whitespaces)
            first = false
        }
        return result
    }

    private func timestamp(_ date: Date) -> String {
        guard options.includesDate || options.includesTime else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let datePart = options.includesDate ? "yyyy-MM-dd" : ""
        let timePart = options.includesTime ? (options.uses24HourTime ? "HH:mm:ss" : "h:mm:ss a") : ""
        formatter.dateFormat = [datePart, timePart].filter { !$0.isEmpty }.joined(separator: " ")
        return formatter.string(from: date) + "  "
    }

    private func timestampHTML(_ date: Date) -> String {
        let value = timestamp(date).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? "" : "<span class=\"timestamp\">\(Self.escapeHTML(value))</span>"
    }

    private func marker(_ label: String, at date: Date, starts: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let value = "\(label): \(formatter.string(from: date))"
        if format == .html {
            return "<h2 class=\"log-event\">\(Self.escapeHTML(value))</h2>\n"
        }
        let border = starts ? "************************************************************" : "------------------------------------------------------------"
        let other = starts ? "------------------------------------------------------------" : "************************************************************"
        return "\(border)\n\(value)\n\(other)\n"
    }

    private func styledHTML(_ line: RenderedLine) -> String {
        let source = line.text as NSString
        let runs = line.runs.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var result = ""
        var cursor = 0
        for run in runs {
            let lower = max(cursor, min(source.length, run.range.lowerBound))
            let upper = max(lower, min(source.length, run.range.upperBound))
            if lower > cursor {
                result += Self.escapeHTML(source.substring(with: NSRange(location: cursor, length: lower - cursor)))
            }
            guard upper > lower else { continue }
            let text = Self.escapeHTML(source.substring(with: NSRange(location: lower, length: upper - lower)))
            var css: [String] = []
            if let color = run.style.foreground { css.append("color:\(Self.hex(color))") }
            if let color = run.style.background { css.append("background:\(Self.hex(color))") }
            if run.style.bold { css.append("font-weight:bold") }
            if run.style.italic { css.append("font-style:italic") }
            var decoration: [String] = []
            if run.style.underline { decoration.append("underline") }
            if run.style.strikeout { decoration.append("line-through") }
            if !decoration.isEmpty { css.append("text-decoration:\(decoration.joined(separator: " "))") }
            let styled = css.isEmpty ? text : "<span style=\"\(css.joined(separator: ";"))\">\(text)</span>"
            if case let .url(url)? = run.style.link {
                result += "<a href=\"\(Self.escapeHTML(url))\">\(styled)</a>"
            } else {
                result += styled
            }
            cursor = upper
        }
        if cursor < source.length {
            result += Self.escapeHTML(source.substring(from: cursor))
        }
        return result
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func hex(_ color: RGBColor) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }
}
