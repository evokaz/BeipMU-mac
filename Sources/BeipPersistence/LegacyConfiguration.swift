import BeipCore
import CryptoKit
import Foundation

public struct LegacyConfigurationDocument: Sendable {
    public indirect enum Node: Sendable {
        case assignment(name: String, value: String, valueRange: Range<String.Index>)
        case block(name: String?, children: [Node])
        case bare(String)
    }

    public private(set) var source: String
    public private(set) var nodes: [Node]

    public init(source: String) throws {
        self.source = source
        var parser = LegacyParser(source: source)
        self.nodes = try parser.parse()
    }

    public func value(at path: [String]) -> String? {
        guard let final = path.last else { return nil }
        let parents = path.dropLast()
        guard let children = descend(Array(parents), nodes: nodes) else { return nil }
        for node in children {
            if case let .assignment(name, value, _) = node, name.caseInsensitiveCompare(final) == .orderedSame {
                return Self.unquote(value)
            }
        }
        return nil
    }

    public mutating func setValue(_ value: String, at path: [String], quoted: Bool = true) throws {
        guard let range = assignmentRange(at: path, nodes: nodes) else {
            throw LegacyConfigurationError.missingPath(path.joined(separator: "."))
        }
        let replacement = quoted ? Self.quote(value) : value
        source.replaceSubrange(range, with: replacement)
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
    }

    public func serialized() -> String { source }

    private func descend(_ path: [String], nodes: [Node]) -> [Node]? {
        guard let first = path.first else { return nodes }
        for node in nodes {
            if case let .block(name?, children) = node,
               name.caseInsensitiveCompare(first) == .orderedSame {
                return descend(Array(path.dropFirst()), nodes: children)
            }
        }
        return nil
    }

    private func assignmentRange(at path: [String], nodes: [Node]) -> Range<String.Index>? {
        guard let final = path.last,
              let children = descend(Array(path.dropLast()), nodes: nodes)
        else { return nil }
        for node in children {
            if case let .assignment(name, _, range) = node,
               name.caseInsensitiveCompare(final) == .orderedSame {
                return range
            }
        }
        return nil
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func unquote(_ value: String) -> String {
        guard value.first == "\"", value.last == "\"", value.count >= 2 else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

private struct LegacyParser {
    private struct Token {
        enum Kind { case atom(String), string(String), open, close, equal }
        var kind: Kind
        var range: Range<String.Index>
    }

    let source: String
    private var tokens: [Token]
    private var index = 0

    init(source: String) {
        self.source = source
        self.tokens = Self.lex(source)
    }

    mutating func parse() throws -> [LegacyConfigurationDocument.Node] {
        try parseNodes(expectClose: false)
    }

    private mutating func parseNodes(expectClose: Bool) throws -> [LegacyConfigurationDocument.Node] {
        var result: [LegacyConfigurationDocument.Node] = []
        while index < tokens.count {
            let token = tokens[index]
            switch token.kind {
            case .close:
                guard expectClose else { throw LegacyConfigurationError.unexpectedClosingBrace }
                index += 1
                return result
            case .open:
                index += 1
                result.append(.block(name: nil, children: try parseNodes(expectClose: true)))
            case let .atom(name), let .string(name):
                index += 1
                if consumeEqual() {
                    guard index < tokens.count else { throw LegacyConfigurationError.missingValue(name) }
                    let value = tokens[index]
                    switch value.kind {
                    case let .atom(raw), let .string(raw):
                        result.append(.assignment(name: name, value: raw, valueRange: value.range))
                        index += 1
                    default: throw LegacyConfigurationError.missingValue(name)
                    }
                } else if consumeOpen() {
                    result.append(.block(name: name, children: try parseNodes(expectClose: true)))
                } else {
                    result.append(.bare(name))
                }
            case .equal:
                throw LegacyConfigurationError.unexpectedEquals
            }
        }
        if expectClose { throw LegacyConfigurationError.missingClosingBrace }
        return result
    }

    private mutating func consumeEqual() -> Bool {
        guard index < tokens.count, case .equal = tokens[index].kind else { return false }
        index += 1
        return true
    }

    private mutating func consumeOpen() -> Bool {
        guard index < tokens.count, case .open = tokens[index].kind else { return false }
        index += 1
        return true
    }

    private static func lex(_ source: String) -> [Token] {
        var tokens: [Token] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            let character = source[cursor]
            if character.isWhitespace {
                cursor = source.index(after: cursor)
                continue
            }
            if character == "/", source.index(after: cursor) < source.endIndex,
               source[source.index(after: cursor)] == "/" {
                cursor = source[cursor...].firstIndex(of: "\n").map { source.index(after: $0) } ?? source.endIndex
                continue
            }
            let start = cursor
            switch character {
            case "{":
                cursor = source.index(after: cursor)
                tokens.append(Token(kind: .open, range: start..<cursor))
            case "}":
                cursor = source.index(after: cursor)
                tokens.append(Token(kind: .close, range: start..<cursor))
            case "=":
                cursor = source.index(after: cursor)
                tokens.append(Token(kind: .equal, range: start..<cursor))
            case "\"":
                cursor = source.index(after: cursor)
                var escaped = false
                while cursor < source.endIndex {
                    let current = source[cursor]
                    cursor = source.index(after: cursor)
                    if current == "\"", !escaped { break }
                    escaped = current == "\\" && !escaped
                    if current != "\\" { escaped = false }
                }
                tokens.append(Token(kind: .string(String(source[start..<cursor])), range: start..<cursor))
            default:
                while cursor < source.endIndex {
                    let current = source[cursor]
                    if current.isWhitespace || current == "{" || current == "}" || current == "=" { break }
                    cursor = source.index(after: cursor)
                }
                tokens.append(Token(kind: .atom(String(source[start..<cursor])), range: start..<cursor))
            }
        }
        return tokens
    }
}

public actor LegacyConfigurationStore {
    public let url: URL
    private var fingerprint: String?

    public init(url: URL) { self.url = url }

    public func load() throws -> LegacyConfigurationDocument {
        let data = try Data(contentsOf: url)
        guard let source = String(data: data, encoding: .utf8) else {
            throw LegacyConfigurationError.notUTF8
        }
        fingerprint = Self.fingerprint(data)
        return try LegacyConfigurationDocument(source: source)
    }

    public func save(_ document: LegacyConfigurationDocument) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let current = try Data(contentsOf: url)
            if let fingerprint, Self.fingerprint(current) != fingerprint {
                let conflict = url.deletingPathExtension().appendingPathExtension("conflict-\(Self.timestamp()).txt")
                try Data(document.serialized().utf8).write(to: conflict, options: .atomic)
                throw LegacyConfigurationError.externalChange(conflict)
            }
            let backup = url.deletingPathExtension().appendingPathExtension("backup-\(Self.timestamp()).txt")
            try current.write(to: backup, options: .atomic)
        }
        let data = Data(document.serialized().utf8)
        try data.write(to: url, options: .atomic)
        fingerprint = Self.fingerprint(data)
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}

public enum LegacyConfigurationError: LocalizedError {
    case notUTF8
    case missingPath(String)
    case missingValue(String)
    case missingClosingBrace
    case unexpectedClosingBrace
    case unexpectedEquals
    case externalChange(URL)

    public var errorDescription: String? {
        switch self {
        case .notUTF8: "Config.txt is not valid UTF-8."
        case let .missingPath(path): "Legacy configuration path does not exist: \(path)"
        case let .missingValue(name): "Missing value for legacy setting \(name)."
        case .missingClosingBrace: "Legacy configuration is missing a closing brace."
        case .unexpectedClosingBrace: "Legacy configuration has an unexpected closing brace."
        case .unexpectedEquals: "Legacy configuration has an unexpected equals sign."
        case let .externalChange(url): "Config.txt changed outside BeipMU. Changes were saved to \(url.path)."
        }
    }
}

