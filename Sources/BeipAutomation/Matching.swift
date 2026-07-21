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
        return expression.matches(in: value, range: full).map { result in
            let values = (0..<result.numberOfRanges).map { index -> String? in
                let range = result.range(at: index)
                guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return nil }
                return String(value[swiftRange])
            }
            return MatchCapture(values: values, range: result.range)
        }
    }
}

public struct MatchCapture: Sendable, Hashable {
    public var values: [String?]
    public var range: NSRange

    public subscript(_ index: Int) -> String? {
        values.indices.contains(index) ? values[index] : nil
    }
}

public enum Expansion {
    public static func apply(_ template: String, capture: MatchCapture?, variables: [String: String]) -> String {
        var result = template
        if let capture {
            for index in stride(from: min(99, capture.values.count - 1), through: 0, by: -1) {
                let value = capture[index] ?? ""
                result = result.replacingOccurrences(of: "$\(index)", with: value)
                result = result.replacingOccurrences(of: "\\\(index)", with: value)
                result = result.replacingOccurrences(of: "\\a\(String(format: "%02d", index))", with: value)
            }
        }
        for (name, value) in variables {
            result = result.replacingOccurrences(of: "%\(name)%", with: value, options: .caseInsensitive)
        }
        return result
    }
}

