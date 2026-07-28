import Foundation

public struct MatchDefinition: Sendable, Hashable, Codable {
    public var text: String
    public var isRegularExpression: Bool
    public var matchCase: Bool
    public var startsWith: Bool
    public var endsWith: Bool
    public var wholeWord: Bool

    public init(
        text: String,
        isRegularExpression: Bool = false,
        matchCase: Bool = false,
        startsWith: Bool = false,
        endsWith: Bool = false,
        wholeWord: Bool = false
    ) {
        self.text = text
        self.isRegularExpression = isRegularExpression
        self.matchCase = matchCase
        self.startsWith = startsWith
        self.endsWith = endsWith
        self.wholeWord = wholeWord
    }

    public func matches(in value: String) throws -> [MatchCapture] {
        if !isRegularExpression && text.isEmpty {
            return [.init(values: [""], range: NSRange(location: 0, length: 0))]
        }
        if !isRegularExpression {
            return literalMatches(in: value)
        }
        let pattern: String
        if isRegularExpression {
            pattern = text
        } else {
            var escaped = NSRegularExpression.escapedPattern(for: text)
            if wholeWord { escaped = "\\b(?:\(escaped))\\b" }
            if startsWith { escaped = "^(?:\(escaped))" }
            if endsWith { escaped = "(?:\(escaped))$" }
            pattern = escaped
        }
        let options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
        let expression = try NSRegularExpression(pattern: pattern, options: options)
        let full = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = expression.matches(in: value, range: full)
        let compatibleMatches: [NSTextCheckingResult]
        if let first = matches.first, first.range.length == 0 {
            compatibleMatches = [first]
        } else {
            compatibleMatches = matches
        }
        return compatibleMatches.map { result in
            let ranges = (0..<result.numberOfRanges).map { result.range(at: $0) }
            let values = (0..<result.numberOfRanges).map { index -> String? in
                let range = ranges[index]
                guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return nil }
                return String(value[swiftRange])
            }
            return MatchCapture(values: values, ranges: ranges)
        }
    }

    private func literalMatches(in value: String) -> [MatchCapture] {
        let fullRange = value.startIndex..<value.endIndex
        var options: String.CompareOptions = []
        if !matchCase { options.insert(.caseInsensitive) }

        if startsWith {
            guard let range = value.range(of: text, options: options.union(.anchored), range: fullRange),
                  (!endsWith || range.lowerBound == value.startIndex && range.upperBound == value.endIndex),
                  isWholeWord(range, in: value) else {
                return []
            }
            return [capture(for: range, in: value)]
        }

        if endsWith {
            guard let range = value.range(of: text, options: options.union([.anchored, .backwards]), range: fullRange),
                  range.upperBound == value.endIndex,
                  isWholeWord(range, in: value) else {
                return []
            }
            return [capture(for: range, in: value)]
        }

        var results: [MatchCapture] = []
        var start = value.startIndex
        while start <= value.endIndex,
              let range = value.range(of: text, options: options, range: start..<value.endIndex) {
            if isWholeWord(range, in: value) {
                results.append(capture(for: range, in: value))
            }
            start = range.upperBound
            if start == range.lowerBound { break }
        }
        return results
    }

    private func capture(for range: Range<String.Index>, in value: String) -> MatchCapture {
        .init(values: [String(value[range])], range: NSRange(range, in: value))
    }

    private func isWholeWord(_ range: Range<String.Index>, in value: String) -> Bool {
        guard wholeWord else { return true }
        let beforeIsLetter: Bool
        if range.lowerBound == value.startIndex {
            beforeIsLetter = false
        } else {
            beforeIsLetter = value[value.index(before: range.lowerBound)].isLetter
        }
        let afterIsLetter = range.upperBound == value.endIndex ? false : value[range.upperBound].isLetter
        return !beforeIsLetter && !afterIsLetter
    }
}

public struct MatchCapture: Sendable, Hashable {
    public var values: [String?]
    /// UTF-16 ranges for the complete match followed by every regular-expression
    /// capture. Unmatched optional captures retain `NSNotFound` so their indices
    /// continue to agree with replacement variables through `$99`.
    public var ranges: [NSRange]

    public var range: NSRange {
        ranges.first ?? NSRange(location: NSNotFound, length: 0)
    }

    public init(values: [String?], ranges: [NSRange]) {
        self.values = values
        self.ranges = ranges
    }

    public init(values: [String?], range: NSRange) {
        self.init(values: values, ranges: [range])
    }

    public subscript(_ index: Int) -> String? {
        values.indices.contains(index) ? values[index] : nil
    }
}

public enum Expansion {
    public static func apply(
        _ template: String,
        capture: MatchCapture?,
        variables: [String: String],
        escapeHTML: Bool = false
    ) -> String {
        var result = expandBackslashCaptures(template, capture: capture, escapeHTML: escapeHTML)
        if let capture {
            for index in stride(from: min(99, capture.values.count - 1), through: 0, by: -1) {
                let value = escaped(capture[index] ?? "", forHTML: escapeHTML)
                result = result.replacingOccurrences(of: "$\(index)", with: value)
            }
        }
        for (name, value) in variables {
            result = result.replacingOccurrences(of: "%\(name)%", with: value, options: .caseInsensitive)
        }
        return result
    }

    private static func expandBackslashCaptures(
        _ template: String,
        capture: MatchCapture?,
        escapeHTML: Bool
    ) -> String {
        guard let capture, template.contains("\\") else { return template }
        let characters = Array(template)
        var result = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "\\" else {
                result.append(characters[index])
                index += 1
                continue
            }
            guard index + 1 < characters.count else {
                result.append("\\")
                index += 1
                continue
            }

            let next = characters[index + 1]
            if next == "\\" {
                result.append("\\")
                index += 2
                continue
            }
            if next == "a" {
                guard index + 3 < characters.count,
                      let tens = characters[index + 2].wholeNumberValue,
                      let ones = characters[index + 3].wholeNumberValue else {
                    result.append("\\")
                    result.append(next)
                    index += 2
                    continue
                }
                let captureIndex = tens * 10 + ones
                if capture.values.indices.contains(captureIndex) {
                    result.append(escaped(capture[captureIndex] ?? "", forHTML: escapeHTML))
                } else {
                    result.append(String(characters[index...index + 3]))
                }
                index += 4
                continue
            }
            if let captureIndex = next.wholeNumberValue {
                if capture.values.indices.contains(captureIndex) {
                    result.append(escaped(capture[captureIndex] ?? "", forHTML: escapeHTML))
                } else {
                    result.append("\\")
                    result.append(next)
                }
                index += 2
                continue
            }

            result.append("\\")
            result.append(next)
            index += 2
        }
        return result
    }

    private static func escaped(_ value: String, forHTML escapeHTML: Bool) -> String {
        guard escapeHTML else { return value }
        return value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}
