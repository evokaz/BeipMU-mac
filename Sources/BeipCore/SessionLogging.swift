import Foundation

public enum SessionLogFormat: String, Sendable, Codable {
    case plainText, html

    public static func infer(from url: URL) -> SessionLogFormat {
        ["html", "htm"].contains(url.pathExtension.lowercased()) ? .html : .plainText
    }
}

public struct SessionLogOptions: Sendable, Codable, Equatable {
    /// Config.txt names retained as the Mac recovery configuration surface.
    public var restoreLogs: Bool
    public var restoreBufferSize: Int
    public var autoLogEnabled: Bool
    public var defaultLogFilename: String
    public var appendsDateToFilename: Bool
    public var fileDateFormat: String
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
        restoreLogs: Bool = true,
        restoreBufferSize: Int = 10 * 1_024 * 1_024,
        autoLogEnabled: Bool = false,
        defaultLogFilename: String = "",
        appendsDateToFilename: Bool = false,
        fileDateFormat: String = "yyyy-MM-dd",
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
        self.restoreLogs = restoreLogs
        self.restoreBufferSize = max(4 * 1_024, restoreBufferSize)
        self.autoLogEnabled = autoLogEnabled
        self.defaultLogFilename = defaultLogFilename
        self.appendsDateToFilename = appendsDateToFilename
        self.fileDateFormat = fileDateFormat.isEmpty ? "yyyy-MM-dd" : fileDateFormat
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

    private enum CodingKeys: String, CodingKey {
        case restoreLogs, restoreBufferSize
        case autoLogEnabled, defaultLogFilename, appendsDateToFilename, fileDateFormat
        case logsSentText, sentPrefix, logsTypedText, typedPrefix
        case includesTime, includesDate, uses24HourTime, wrapWidth, hangingIndent, wrapsAtWords, doubleSpaces
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            restoreLogs: try values.decodeIfPresent(Bool.self, forKey: .restoreLogs) ?? true,
            restoreBufferSize: try values.decodeIfPresent(Int.self, forKey: .restoreBufferSize) ?? 10 * 1_024 * 1_024,
            autoLogEnabled: try values.decodeIfPresent(Bool.self, forKey: .autoLogEnabled) ?? false,
            defaultLogFilename: try values.decodeIfPresent(String.self, forKey: .defaultLogFilename) ?? "",
            appendsDateToFilename: try values.decodeIfPresent(Bool.self, forKey: .appendsDateToFilename) ?? false,
            fileDateFormat: try values.decodeIfPresent(String.self, forKey: .fileDateFormat) ?? "yyyy-MM-dd",
            logsSentText: try values.decodeIfPresent(Bool.self, forKey: .logsSentText) ?? false,
            sentPrefix: try values.decodeIfPresent(String.self, forKey: .sentPrefix) ?? "Sent>",
            logsTypedText: try values.decodeIfPresent(Bool.self, forKey: .logsTypedText) ?? false,
            typedPrefix: try values.decodeIfPresent(String.self, forKey: .typedPrefix) ?? "Typed>",
            includesTime: try values.decodeIfPresent(Bool.self, forKey: .includesTime) ?? false,
            includesDate: try values.decodeIfPresent(Bool.self, forKey: .includesDate) ?? false,
            uses24HourTime: try values.decodeIfPresent(Bool.self, forKey: .uses24HourTime) ?? false,
            wrapWidth: try values.decodeIfPresent(Int.self, forKey: .wrapWidth),
            hangingIndent: try values.decodeIfPresent(Int.self, forKey: .hangingIndent) ?? 0,
            wrapsAtWords: try values.decodeIfPresent(Bool.self, forKey: .wrapsAtWords) ?? true,
            doubleSpaces: try values.decodeIfPresent(Bool.self, forKey: .doubleSpaces) ?? false
        )
    }
}

/// Expands the portable filename substitutions used by manual and automatic
/// logs. A date substitution makes the log a daily log, so callers can safely
/// reopen it when the local calendar day changes.
public enum SessionLogFilename {
    public struct Resolution: Sendable, Equatable {
        public var filename: String
        public var rollsOverDaily: Bool

        public init(filename: String, rollsOverDaily: Bool) {
            self.filename = filename
            self.rollsOverDaily = rollsOverDaily
        }
    }

    public static func resolve(
        _ template: String,
        date: Date = Date(),
        dateFormat: String = "yyyy-MM-dd",
        appendingDate: Bool = false,
        serverName: String? = nil,
        characterName: String? = nil,
        timeZone: TimeZone = .current
    ) -> Resolution {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat.isEmpty ? "yyyy-MM-dd" : dateFormat
        let dateText = formatter.string(from: date)
        var filename = template
        var rollsOverDaily = appendingDate
        if filename.range(of: "%date%", options: .caseInsensitive) != nil {
            filename = filename.replacingOccurrences(of: "%date%", with: dateText, options: .caseInsensitive)
            rollsOverDaily = true
        }
        if let serverName {
            filename = filename.replacingOccurrences(of: "%server%", with: serverName, options: .caseInsensitive)
        }
        if let characterName {
            filename = filename.replacingOccurrences(of: "%character%", with: characterName, options: .caseInsensitive)
        }
        if appendingDate {
            let path = filename as NSString
            let extensionValue = path.pathExtension
            let stem = extensionValue.isEmpty ? filename : path.deletingPathExtension
            filename = stem + " - " + dateText + (extensionValue.isEmpty ? "" : "." + extensionValue)
        }
        return .init(filename: filename, rollsOverDaily: rollsOverDaily)
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
        <style>
        body{background:\(backgroundHex);color:\(foregroundHex);font:13px ui-monospace,monospace}
        .log-event{border-block:1px dotted currentColor;padding:.5em;text-align:center}
        .log-control{position:absolute;top:2.25em;display:inline-flex;align-items:center;gap:.5em;cursor:pointer}
        .timestamps-control{left:.75em}
        .unformat-control{right:.75em}
        .log-control input{position:absolute;opacity:0;pointer-events:none}
        .switch{box-sizing:border-box;width:2.25em;height:1.25em;padding:2px;background:#c0c0c0;border-radius:1em}
        .switch::after{display:block;width:calc(1.25em - 4px);height:calc(1.25em - 4px);content:"";background:#fff;border-radius:50%;box-shadow:0 1px 3px #0008;transition:transform .2s}
        .log-control input:checked+.switch::after{transform:translateX(1em)}
        .log-control input:focus-visible+.switch{outline:2px solid currentColor;outline-offset:2px}
        .line{display:flex;white-space:pre-wrap;margin:0}
        .line-content{box-sizing:border-box;display:block;flex:1 1 auto;min-width:0;position:relative}
        .paragraph-stroke{box-sizing:border-box;position:absolute;inset:0;pointer-events:none}
        .horizontal-rule{position:absolute;left:0;right:0;top:50%;transform:translateY(-50%);pointer-events:none}
        .timestamp{display:none;flex:none;opacity:.65;margin-right:1em;white-space:nowrap}
        body.show-timestamps .timestamp{display:inline}
        body.unformatted .line{color:inherit!important;background:transparent!important;border:0!important;text-align:left!important;font:inherit!important}
        body.unformatted .line .line-content{color:inherit!important;background:transparent!important;border:0!important;border-radius:0!important;box-shadow:none!important;font:inherit!important;margin:0!important;outline:0!important;padding:0!important;text-indent:0!important}
        body.unformatted .line .line-content *{color:inherit!important;background:transparent!important;border:0!important;box-shadow:none!important;font:inherit!important;text-decoration:none!important}
        body.unformatted .line .line-content .paragraph-stroke,body.unformatted .line .line-content .horizontal-rule{display:none!important}
        @media(max-width:600px){.log-event:first-of-type{padding-top:2.5em}.log-control{top:1em}}
        </style>
        <script>
        document.addEventListener("DOMContentLoaded",function(){
          document.getElementById("timestamp-toggle").addEventListener("change",function(event){
            document.body.classList.toggle("show-timestamps",event.currentTarget.checked);
          });
          document.getElementById("unformat-toggle").addEventListener("change",function(event){
            document.body.classList.toggle("unformatted",event.currentTarget.checked);
          });
        });
        </script></head><body>
        <label class="log-control timestamps-control"><input id="timestamp-toggle" type="checkbox"><span class="switch" aria-hidden="true"></span><span>Timestamps</span></label>
        <label class="log-control unformat-control"><input id="unformat-toggle" type="checkbox"><span class="switch" aria-hidden="true"></span><span>Unformat</span></label>

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
            let paragraph = line.paragraph
            let style = paragraphHTMLStyle(paragraph)
            let stroke = paragraphStrokeHTML(paragraph)
            let horizontalRule = paragraph.horizontalRule
                ? "<span class=\"horizontal-rule\" style=\"height:\(Self.cssPixels(max(1, paragraph.strokeWidth)));background:\(paragraph.strokeColor.map(Self.hex) ?? "currentColor");\"></span>"
                : ""
            return "<p class=\"line\" style=\"text-align:\(paragraph.alignment.rawValue);\">\(timestamp)<span class=\"line-content\" style=\"\(style)\">\(styledHTML(line))\(stroke)\(horizontalRule)</span></p>\n"
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
        case .html: "<p class=\"line\">\(timestampHTML(date))<span class=\"line-content\">\(Self.escapeHTML(text))</span></p>\n"
        }
    }

    private func paragraphHTMLStyle(_ paragraph: ParagraphStyle) -> String {
        let leftIndent = max(0, paragraph.leftIndent)
        let rightIndent = max(0, paragraph.rightIndent)
        let wrappedIndent = max(0, paragraph.wrappedIndent)
        let borderWidth = max(0, paragraph.borderWidth)
        let topPadding = max(0, paragraph.topPadding)
        let bottomPadding = max(0, paragraph.bottomPadding)
        let background = paragraph.background.map { "background:\(Self.hex($0));" } ?? ""
        let radius = paragraph.borderStyle == .round ? "border-radius:8px;" : ""
        return "margin-left:\(leftIndent)%;margin-right:\(rightIndent)%;padding-left:\(Self.cssPixels(borderWidth + wrappedIndent));padding-right:\(Self.cssPixels(borderWidth));padding-top:\(Self.cssPixels(borderWidth + topPadding));padding-bottom:\(Self.cssPixels(borderWidth + bottomPadding));text-indent:-\(Self.cssPixels(wrappedIndent));\(background)\(radius)"
    }

    private func paragraphStrokeHTML(_ paragraph: ParagraphStyle) -> String {
        let width = max(0, paragraph.strokeWidth)
        guard width > 0 else { return "" }
        let color = paragraph.strokeColor.map(Self.hex) ?? "currentColor"
        let border = switch paragraph.strokeStyle {
        case .outline: "border:\(Self.cssPixels(width)) solid \(color);"
        case .top: "border-top:\(Self.cssPixels(width)) solid \(color);"
        case .bottom: "border-bottom:\(Self.cssPixels(width)) solid \(color);"
        }
        let radius = paragraph.borderStyle == .round ? "border-radius:8px;" : ""
        return "<span class=\"paragraph-stroke\" style=\"\(border)\(radius)\"></span>"
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
        var value = timestamp(date).trimmingCharacters(in: .whitespaces)
        if value.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "M/d/yyyy h:mm:ss a"
            value = formatter.string(from: date)
        }
        return "<span class=\"timestamp\">\(Self.escapeHTML(value))</span>"
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
        let boundaries = Set(
            [0, source.length]
                + line.runs.flatMap { run in
                    let lower = max(0, min(source.length, run.range.lowerBound))
                    let upper = max(lower, min(source.length, run.range.upperBound))
                    return [lower, upper]
                }
        ).sorted()
        var result = ""
        for (lower, upper) in zip(boundaries, boundaries.dropFirst()) where lower < upper {
            let text = Self.escapeHTML(source.substring(with: NSRange(location: lower, length: upper - lower)))
            // Trigger effects are appended after the protocol's original style
            // runs. Resolve overlaps from the end so HTML matches AppKit's
            // later-attributes-win behavior.
            guard let run = line.runs.last(where: {
                $0.range.lowerBound <= lower && $0.range.upperBound >= upper
            }) else {
                result += text
                continue
            }
            result += styledHTML(text, style: run.style)
        }
        return result
    }

    private func styledHTML(_ text: String, style: TextStyle) -> String {
        var css: [String] = []
        if let color = style.foreground { css.append("color:\(Self.hex(color))") }
        if let color = style.background { css.append("background:\(Self.hex(color))") }
        if style.bold { css.append("font-weight:bold") }
        if style.italic { css.append("font-style:italic") }
        var decoration: [String] = []
        if style.underline { decoration.append("underline") }
        if style.strikeout { decoration.append("line-through") }
        if !decoration.isEmpty { css.append("text-decoration:\(decoration.joined(separator: " "))") }
        let styled = css.isEmpty ? text : "<span style=\"\(css.joined(separator: ";"))\">\(text)</span>"
        if case let .url(url)? = style.link {
            return "<a href=\"\(Self.escapeHTML(url))\">\(styled)</a>"
        }
        return styled
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

    private static func cssPixels(_ value: Double) -> String {
        guard value.isFinite else { return "0px" }
        return "\(value)px"
    }
}
