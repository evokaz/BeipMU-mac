import BeipCore
import Foundation

struct PuebloParser: Sendable {
    struct Result: Sendable {
        struct Link: Sendable {
            var range: Range<Int>
            var action: LinkAction
        }

        struct Span: Sendable {
            var range: Range<Int>
            var style: TextStyle
        }

        var text: String
        var links: [Link]
        var assets: [InlineAsset]
        var spans: [Span]
    }

    func parse(_ input: String) -> Result {
        var output = ""
        var links: [Result.Link] = []
        var assets: [InlineAsset] = []
        var spans: [Result.Span] = []
        var activeLink: (start: Int, action: LinkAction)?
        var style = TextStyle()
        var styleStart = 0
        var styleStack: [(name: String, previous: TextStyle)] = []
        var cursor = input.startIndex
        func visibleOffset() -> Int { Self.visibleUTF16Count(output) }

        func flushStyle() {
            let end = visibleOffset()
            if styleStart < end, style != TextStyle() {
                spans.append(.init(range: styleStart..<end, style: style))
            }
            styleStart = end
        }

        func beginStyle(_ name: String, update: (inout TextStyle) -> Void) {
            flushStyle()
            styleStack.append((name, style))
            update(&style)
        }

        func endStyle(_ name: String) {
            guard let index = styleStack.lastIndex(where: { $0.name == name }) else { return }
            flushStyle()
            style = styleStack[index].previous
            styleStack.removeSubrange(index...)
        }

        while cursor < input.endIndex {
            if input[cursor] == "<", let close = input[cursor...].firstIndex(of: ">") {
                let rawTag = String(input[input.index(after: cursor)..<close])
                let tag = Self.tag(rawTag)
                switch tag.name {
                case "b", "strong":
                    if tag.closing { endStyle(tag.name) } else { beginStyle(tag.name) { $0.bold = true } }
                case "i", "em":
                    if tag.closing { endStyle(tag.name) } else { beginStyle(tag.name) { $0.italic = true } }
                case "u":
                    if tag.closing { endStyle(tag.name) } else { beginStyle(tag.name) { $0.underline = true } }
                case "s", "strike":
                    if tag.closing { endStyle(tag.name) } else { beginStyle(tag.name) { $0.strikeout = true } }
                case "font":
                    if tag.closing {
                        endStyle(tag.name)
                    } else if let color = tag.attributes["color"].flatMap(Self.color) {
                        beginStyle(tag.name) { $0.foreground = color }
                    }
                case "a":
                    if tag.closing {
                        Self.finishLink(&activeLink, at: visibleOffset(), into: &links)
                    } else if let command = tag.attributes["xch_cmd"] {
                        Self.finishLink(&activeLink, at: visibleOffset(), into: &links)
                        activeLink = (visibleOffset(), .send(Self.primary(command), hints: []))
                    } else if let href = tag.attributes["href"] {
                        Self.finishLink(&activeLink, at: visibleOffset(), into: &links)
                        activeLink = (visibleOffset(), .url(href))
                    }
                case "send":
                    if tag.closing {
                        Self.finishLink(&activeLink, at: visibleOffset(), into: &links)
                    } else {
                        let sends = tag.attributes["href"] ?? tag.unkeyedValue ?? ""
                        let hints = tag.attributes["hint"].map {
                            $0.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                        } ?? []
                        Self.finishLink(&activeLink, at: visibleOffset(), into: &links)
                        activeLink = (visibleOffset(), .send(Self.primary(sends), hints: hints))
                    }
                case "img" where !tag.closing:
                    if let source = tag.attributes["src"], let url = URL(string: source) {
                        let offset = visibleOffset()
                        output.append("🖼️")
                        assets.append(.init(
                            kind: .image,
                            source: url,
                            altText: tag.attributes["alt"] ?? "Image",
                            characterOffset: offset
                        ))
                        links.append(.init(range: offset..<visibleOffset(), action: .url(source)))
                    }
                case "br" where !tag.closing:
                    // The Windows Pueblo handler consumes BR inside an already
                    // line-framed record; it does not add another newline.
                    break
                default:
                    break
                }
                cursor = input.index(after: close)
                continue
            }

            if input[cursor] == "&", let semicolon = input[cursor...].firstIndex(of: ";") {
                let entity = String(input[input.index(after: cursor)..<semicolon])
                if let decoded = Self.decodeEntity(entity) {
                    output.append(decoded)
                    cursor = input.index(after: semicolon)
                    continue
                }
            }

            output.append(input[cursor])
            cursor = input.index(after: cursor)
        }
        Self.finishLink(&activeLink, at: visibleOffset(), into: &links)
        flushStyle()
        return .init(text: output, links: links, assets: assets, spans: spans)
    }

    func apply(_ result: Result, to line: RenderedLine) -> RenderedLine {
        var line = line
        line.assets.append(contentsOf: result.assets)
        for span in result.spans where !span.range.isEmpty {
            line.runs = Self.overlay(line.runs, range: span.range) { style in
                var style = style
                if let foreground = span.style.foreground { style.foreground = foreground }
                if span.style.bold { style.bold = true }
                if span.style.italic { style.italic = true }
                if span.style.underline { style.underline = true }
                if span.style.strikeout { style.strikeout = true }
                return style
            }
        }
        for link in result.links where !link.range.isEmpty {
            line.runs = Self.overlay(line.runs, range: link.range) { style in
                var style = style
                style.link = link.action
                style.underline = true
                return style
            }
        }
        return line
    }

    private static func overlay(
        _ runs: [StyleRun],
        range: Range<Int>,
        transform: (TextStyle) -> TextStyle
    ) -> [StyleRun] {
        var next: [StyleRun] = []
        for run in runs {
            if run.range.upperBound <= range.lowerBound || run.range.lowerBound >= range.upperBound {
                next.append(run)
                continue
            }
            if run.range.lowerBound < range.lowerBound {
                next.append(.init(range: run.range.lowerBound..<range.lowerBound, style: run.style))
            }
            let overlap = max(run.range.lowerBound, range.lowerBound)..<min(run.range.upperBound, range.upperBound)
            next.append(.init(range: overlap, style: transform(run.style)))
            if run.range.upperBound > range.upperBound {
                next.append(.init(range: range.upperBound..<run.range.upperBound, style: run.style))
            }
        }
        return next
    }

    private static func finishLink(
        _ active: inout (start: Int, action: LinkAction)?,
        at end: Int,
        into links: inout [Result.Link]
    ) {
        if let active, active.start < end {
            links.append(.init(range: active.start..<end, action: active.action))
        }
        active = nil
    }

    private static func primary(_ value: String) -> String {
        value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
    }

    private static func decodeEntity(_ entity: String) -> String? {
        switch entity.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00a0}"
        default:
            let number: UInt32?
            if entity.lowercased().hasPrefix("#x") {
                number = UInt32(entity.dropFirst(2), radix: 16)
            } else if entity.hasPrefix("#") {
                number = UInt32(entity.dropFirst())
            } else {
                number = nil
            }
            return number.flatMap(UnicodeScalar.init).map(String.init)
        }
    }

    private static func visibleUTF16Count(_ value: String) -> Int {
        var count = 0
        var index = value.unicodeScalars.startIndex
        while index < value.unicodeScalars.endIndex {
            let scalar = value.unicodeScalars[index]
            if scalar.value == 0x1b {
                let next = value.unicodeScalars.index(after: index)
                if next < value.unicodeScalars.endIndex, value.unicodeScalars[next] == "[" {
                    index = value.unicodeScalars.index(after: next)
                    while index < value.unicodeScalars.endIndex {
                        let candidate = value.unicodeScalars[index]
                        index = value.unicodeScalars.index(after: index)
                        if candidate == "m" { break }
                    }
                    continue
                }
            }
            count += scalar.value > 0xffff ? 2 : 1
            index = value.unicodeScalars.index(after: index)
        }
        return count
    }

    private static func color(_ value: String) -> RGBColor? {
        let lower = value.lowercased()
        let named: [String: RGBColor] = [
            "black": .init(red: 0, green: 0, blue: 0), "red": .init(red: 255, green: 0, blue: 0),
            "green": .init(red: 0, green: 128, blue: 0), "lime": .init(red: 0, green: 255, blue: 0),
            "blue": .init(red: 0, green: 0, blue: 255), "aqua": .init(red: 0, green: 255, blue: 255),
            "cyan": .init(red: 0, green: 255, blue: 255), "magenta": .init(red: 255, green: 0, blue: 255),
            "yellow": .init(red: 255, green: 255, blue: 0), "white": .init(red: 255, green: 255, blue: 255),
            "silver": .init(red: 192, green: 192, blue: 192), "gray": .init(red: 128, green: 128, blue: 128),
            "grey": .init(red: 128, green: 128, blue: 128), "teal": .init(red: 0, green: 128, blue: 128),
            "maroon": .init(red: 128, green: 0, blue: 0), "purple": .init(red: 128, green: 0, blue: 128),
        ]
        if let named = named[lower] { return named }
        let hex = lower.hasPrefix("#") ? String(lower.dropFirst()) : lower
        guard hex.count == 6, let raw = UInt32(hex, radix: 16) else { return nil }
        return .init(red: UInt8(raw >> 16), green: UInt8((raw >> 8) & 0xff), blue: UInt8(raw & 0xff))
    }

    private struct Tag {
        var name: String
        var closing: Bool
        var attributes: [String: String]
        var unkeyedValue: String?
    }

    private static func tag(_ raw: String) -> Tag {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let closing = text.first == "/"
        if closing { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameEnd = text.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? text.endIndex
        let name = text[..<nameEnd].lowercased()
        var remainder = text[nameEnd...]
        var attributes: [String: String] = [:]
        var unkeyed: String?

        while !remainder.isEmpty {
            remainder = remainder.drop(while: { $0.isWhitespace || $0 == "/" })
            guard !remainder.isEmpty else { break }
            let keyEnd = remainder.firstIndex(where: { $0.isWhitespace || $0 == "=" }) ?? remainder.endIndex
            let key = String(remainder[..<keyEnd]).lowercased()
            remainder = remainder[keyEnd...].drop(while: { $0.isWhitespace })
            guard remainder.first == "=" else {
                if unkeyed == nil { unkeyed = key }
                continue
            }
            remainder = remainder.dropFirst().drop(while: { $0.isWhitespace })
            guard let first = remainder.first else { attributes[key] = ""; break }
            if first == "\"" || first == "'" {
                remainder = remainder.dropFirst()
                let end = remainder.firstIndex(of: first) ?? remainder.endIndex
                attributes[key] = String(remainder[..<end])
                remainder = end < remainder.endIndex ? remainder[remainder.index(after: end)...] : remainder[end...]
            } else {
                let end = remainder.firstIndex(where: { $0.isWhitespace }) ?? remainder.endIndex
                attributes[key] = String(remainder[..<end])
                remainder = remainder[end...]
            }
        }
        return .init(name: name, closing: closing, attributes: attributes, unkeyedValue: unkeyed)
    }
}
