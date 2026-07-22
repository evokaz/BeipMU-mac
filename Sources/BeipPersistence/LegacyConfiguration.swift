import BeipCore
import CryptoKit
import Foundation

public struct LegacyConfigurationDocument: Sendable {
    public indirect enum Node: Sendable {
        case assignment(
            name: String,
            value: String,
            valueRange: Range<String.Index>,
            sourceRange: Range<String.Index>
        )
        case block(
            name: String?,
            children: [Node],
            insertionIndex: String.Index,
            sourceRange: Range<String.Index>
        )
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
        let parents = Array(path.dropLast())
        for split in stride(from: parents.count, through: 0, by: -1) {
            guard let children = descend(Array(parents.prefix(split)), nodes: nodes) else { continue }
            let candidate = (Array(parents.dropFirst(split)) + [final]).joined(separator: ".")
            for node in children {
                if case let .assignment(name, value, _, _) = node,
                   name.caseInsensitiveCompare(candidate) == .orderedSame {
                    return Self.unquote(value)
                }
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

    public mutating func upsertValue(_ value: String, at path: [String], quoted: Bool = true) throws {
        if assignmentRange(at: path, nodes: nodes) != nil {
            try setValue(value, at: path, quoted: quoted)
            return
        }
        guard let name = path.last else { throw LegacyConfigurationError.missingPath("") }
        let replacement = quoted ? Self.quote(value) : value
        let parents = Array(path.dropLast())
        if parents.isEmpty {
            if !source.isEmpty, source.last != "\n" { source.append("\n") }
            source.append("\(name)=\(replacement)\n")
        } else {
            if blockInsertionIndex(at: parents, nodes: nodes) == nil { try ensureBlocks(at: parents) }
            guard let insertion = blockInsertionIndex(at: parents, nodes: nodes) else {
                throw LegacyConfigurationError.missingPath(parents.joined(separator: "."))
            }
            let lineStart = source[..<insertion].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
            let closingIndent = source[lineStart..<insertion].prefix(while: { $0 == " " || $0 == "\t" })
            let childIndent = String(closingIndent) + "  "
            source.insert(contentsOf: "\(childIndent)\(name)=\(replacement)\n", at: insertion)
        }
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
    }

    /// Appends an unnamed block to a legacy collection such as `Aliases` or
    /// `Triggers`. The new block is intentionally empty so its supported
    /// fields can be added through `upsertValue(_:inUnnamedBlockAt:...)`
    /// without serializing or disturbing neighbouring entries.
    @discardableResult
    public mutating func appendUnnamedBlock(at path: [String]) throws -> Int {
        if blockInsertionIndex(at: path, nodes: nodes) == nil { try ensureBlocks(at: path) }
        guard let insertion = blockInsertionIndex(at: path, nodes: nodes) else {
            throw LegacyConfigurationError.missingPath(path.joined(separator: "."))
        }
        let lineStart = source[..<insertion].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        let closingIndent = source[lineStart..<insertion].prefix(while: { $0 == " " || $0 == "\t" })
        let childIndent = String(closingIndent) + "  "
        source.insert(contentsOf: "\(childIndent){\n\(childIndent)}\n", at: insertion)
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
        return (descend(path, nodes: nodes) ?? []).reduce(into: 0) { count, node in
            if case .block(name: nil, children: _, insertionIndex: _, sourceRange: _) = node { count += 1 }
        } - 1
    }

    /// Updates a value inside an unnamed collection entry. Named child blocks
    /// are created only when absent, and all other source text is retained.
    public mutating func upsertValue(
        _ value: String,
        inUnnamedBlockAt index: Int,
        collectionPath: [String],
        relativePath: [String],
        quoted: Bool = true
    ) throws {
        guard let field = relativePath.last else {
            throw LegacyConfigurationError.missingPath("")
        }
        guard let entry = unnamedBlock(at: index, collectionPath: collectionPath) else {
            throw LegacyConfigurationError.missingPath("\(collectionPath.joined(separator: "."))[\(index)]")
        }
        if let range = assignmentRange(at: relativePath, nodes: entry.children) {
            source.replaceSubrange(range, with: quoted ? Self.quote(value) : value)
            var parser = LegacyParser(source: source)
            nodes = try parser.parse()
            return
        }

        let parents = Array(relativePath.dropLast())
        if !parents.isEmpty,
           blockInsertionIndex(at: parents, nodes: entry.children) == nil {
            try ensureBlocks(at: parents, inUnnamedBlockAt: index, collectionPath: collectionPath)
        }
        guard let refreshed = unnamedBlock(at: index, collectionPath: collectionPath) else {
            throw LegacyConfigurationError.missingPath("\(collectionPath.joined(separator: "."))[\(index)]")
        }
        let insertion = parents.isEmpty
            ? refreshed.insertionIndex
            : blockInsertionIndex(at: parents, nodes: refreshed.children)
        guard let insertion else {
            throw LegacyConfigurationError.missingPath(relativePath.joined(separator: "."))
        }
        let lineStart = source[..<insertion].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        let closingIndent = source[lineStart..<insertion].prefix(while: { $0 == " " || $0 == "\t" })
        let childIndent = String(closingIndent) + "  "
        source.insert(contentsOf: "\(childIndent)\(field)=\(quoted ? Self.quote(value) : value)\n", at: insertion)
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
    }

    /// Removes one unnamed entry while leaving the rest of its collection
    /// byte-for-byte intact.
    @discardableResult
    public mutating func removeUnnamedBlock(at index: Int, collectionPath: [String]) throws -> Bool {
        guard let entry = unnamedBlock(at: index, collectionPath: collectionPath) else { return false }
        source.removeSubrange(expandedRemovalRange(entry.sourceRange))
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
        return true
    }

    /// Removes one named entry from a legacy collection. Both full block form
    /// (`World { ... }`) and dotted shorthand (`World.Host=...`) are handled.
    /// Text outside the matching entry remains byte-for-byte unchanged.
    @discardableResult
    public mutating func removeCollectionEntry(named name: String, at path: [String]) throws -> Bool {
        guard let children = descend(path, nodes: nodes) else { return false }
        var ranges: [Range<String.Index>] = []
        for node in children {
            switch node {
            case let .block(candidate?, _, _, range)
                where candidate.caseInsensitiveCompare(name) == .orderedSame:
                ranges.append(range)
            case let .assignment(candidate, _, _, range):
                guard let dot = candidate.firstIndex(of: ".") else { continue }
                let owner = String(candidate[..<dot])
                if owner.caseInsensitiveCompare(name) == .orderedSame { ranges.append(range) }
            default:
                break
            }
        }
        guard !ranges.isEmpty else { return false }
        for range in ranges.map(expandedRemovalRange).sorted(by: { $0.lowerBound > $1.lowerBound }) {
            source.removeSubrange(range)
        }
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
        return true
    }

    public func serialized() -> String { source }

    private func descend(_ path: [String], nodes: [Node]) -> [Node]? {
        guard let first = path.first else { return nodes }
        for node in nodes {
            if case let .block(name?, children, _, _) = node,
               name.caseInsensitiveCompare(first) == .orderedSame {
                return descend(Array(path.dropFirst()), nodes: children)
            }
        }
        return nil
    }

    private func blockInsertionIndex(at path: [String], nodes: [Node]) -> String.Index? {
        guard let first = path.first else { return nil }
        for node in nodes {
            if case let .block(name?, children, insertionIndex, _) = node,
               name.caseInsensitiveCompare(first) == .orderedSame {
                return path.count == 1
                    ? insertionIndex
                    : blockInsertionIndex(at: Array(path.dropFirst()), nodes: children)
            }
        }
        return nil
    }

    private func unnamedBlock(at index: Int, collectionPath: [String]) -> (children: [Node], insertionIndex: String.Index, sourceRange: Range<String.Index>)? {
        guard index >= 0, let children = descend(collectionPath, nodes: nodes) else { return nil }
        var offset = 0
        for node in children {
            guard case let .block(name: nil, children: entryChildren, insertionIndex: insertionIndex, sourceRange: sourceRange) = node else {
                continue
            }
            if offset == index { return (entryChildren, insertionIndex, sourceRange) }
            offset += 1
        }
        return nil
    }

    private func assignmentRange(at path: [String], nodes: [Node]) -> Range<String.Index>? {
        guard let final = path.last else { return nil }
        let parents = Array(path.dropLast())
        for split in stride(from: parents.count, through: 0, by: -1) {
            guard let children = descend(Array(parents.prefix(split)), nodes: nodes) else { continue }
            let candidate = (Array(parents.dropFirst(split)) + [final]).joined(separator: ".")
            for node in children {
                if case let .assignment(name, _, range, _) = node,
                   name.caseInsensitiveCompare(candidate) == .orderedSame {
                    return range
                }
            }
        }
        return nil
    }

    private mutating func ensureBlocks(at path: [String]) throws {
        for depth in 1...path.count where blockInsertionIndex(at: Array(path.prefix(depth)), nodes: nodes) == nil {
            let name = path[depth - 1]
            let serializedName = Self.identifier(name)
            let parentPath = Array(path.prefix(depth - 1))
            if parentPath.isEmpty {
                if !source.isEmpty, source.last != "\n" { source.append("\n") }
                source.append("\(serializedName)\n{\n}\n")
            } else {
                guard let insertion = blockInsertionIndex(at: parentPath, nodes: nodes) else {
                    throw LegacyConfigurationError.missingPath(parentPath.joined(separator: "."))
                }
                let lineStart = source[..<insertion].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
                let closingIndent = source[lineStart..<insertion].prefix(while: { $0 == " " || $0 == "\t" })
                let childIndent = String(closingIndent) + "  "
                source.insert(
                    contentsOf: "\(childIndent)\(serializedName)\n\(childIndent){\n\(childIndent)}\n",
                    at: insertion
                )
            }
            var parser = LegacyParser(source: source)
            nodes = try parser.parse()
        }
    }

    private mutating func ensureBlocks(
        at path: [String],
        inUnnamedBlockAt index: Int,
        collectionPath: [String]
    ) throws {
        for depth in 1...path.count {
            guard let entry = unnamedBlock(at: index, collectionPath: collectionPath) else {
                throw LegacyConfigurationError.missingPath("\(collectionPath.joined(separator: "."))[\(index)]")
            }
            let prefix = Array(path.prefix(depth))
            guard blockInsertionIndex(at: prefix, nodes: entry.children) == nil else { continue }
            let parentPath = Array(prefix.dropLast())
            let insertion = parentPath.isEmpty
                ? entry.insertionIndex
                : blockInsertionIndex(at: parentPath, nodes: entry.children)
            guard let insertion else {
                throw LegacyConfigurationError.missingPath(parentPath.joined(separator: "."))
            }
            let lineStart = source[..<insertion].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
            let closingIndent = source[lineStart..<insertion].prefix(while: { $0 == " " || $0 == "\t" })
            let childIndent = String(closingIndent) + "  "
            source.insert(
                contentsOf: "\(childIndent)\(Self.identifier(path[depth - 1]))\n\(childIndent){\n\(childIndent)}\n",
                at: insertion
            )
            var parser = LegacyParser(source: source)
            nodes = try parser.parse()
        }
    }

    private func expandedRemovalRange(_ range: Range<String.Index>) -> Range<String.Index> {
        let lineStart = source[..<range.lowerBound].lastIndex(of: "\n").map(source.index(after:)) ?? source.startIndex
        let nextNewline = source[range.upperBound...].firstIndex(of: "\n")
        let lineEnd = nextNewline ?? source.endIndex
        let prefix = source[lineStart..<range.lowerBound]
        let suffix = source[range.upperBound..<lineEnd]
        let onlyWhitespace = { (text: Substring) in text.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" } }
        guard onlyWhitespace(prefix), onlyWhitespace(suffix) else { return range }
        let upper = nextNewline.map(source.index(after:)) ?? lineEnd
        return lineStart..<upper
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func identifier(_ value: String) -> String {
        value.contains(where: { $0.isWhitespace || $0 == "{" || $0 == "}" || $0 == "=" })
            ? quote(value)
            : value
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
    private var lastClosingBraceStart: String.Index?
    private var lastClosingBraceEnd: String.Index?

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
                lastClosingBraceStart = token.range.lowerBound
                lastClosingBraceEnd = token.range.upperBound
                index += 1
                return result
            case .open:
                let start = token.range.lowerBound
                index += 1
                let children = try parseNodes(expectClose: true)
                result.append(.block(
                    name: nil,
                    children: children,
                    insertionIndex: lastClosingBraceStart!,
                    sourceRange: start..<lastClosingBraceEnd!
                ))
            case let .atom(rawName), let .string(rawName):
                let name = Self.identifier(from: token.kind, raw: rawName)
                let nodeStart = token.range.lowerBound
                index += 1
                if consumeEqual() {
                    guard index < tokens.count else { throw LegacyConfigurationError.missingValue(name) }
                    let value = tokens[index]
                    switch value.kind {
                    case let .atom(raw), let .string(raw):
                        result.append(.assignment(
                            name: name,
                            value: raw,
                            valueRange: value.range,
                            sourceRange: nodeStart..<value.range.upperBound
                        ))
                        index += 1
                    case .open:
                        // The legacy format uses braces both for blocks and for
                        // scalar tuple values (for example ClientSize={80,24}).
                        // After an equals sign a brace is always a value.
                        let start = value.range.lowerBound
                        var depth = 0
                        var end = value.range.upperBound
                        repeat {
                            guard index < tokens.count else {
                                throw LegacyConfigurationError.missingClosingBrace
                            }
                            let component = tokens[index]
                            switch component.kind {
                            case .open: depth += 1
                            case .close: depth -= 1
                            default: break
                            }
                            end = component.range.upperBound
                            index += 1
                        } while depth > 0
                        let range = start..<end
                        result.append(.assignment(
                            name: name,
                            value: String(source[range]),
                            valueRange: range,
                            sourceRange: nodeStart..<range.upperBound
                        ))
                    default: throw LegacyConfigurationError.missingValue(name)
                    }
                } else if consumeOpen() {
                    let children = try parseNodes(expectClose: true)
                    result.append(.block(
                        name: name,
                        children: children,
                        insertionIndex: lastClosingBraceStart!,
                        sourceRange: nodeStart..<lastClosingBraceEnd!
                    ))
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

    private static func identifier(from kind: Token.Kind, raw: String) -> String {
        guard case .string = kind, raw.count >= 2 else { return raw }
        var result = ""
        var escaped = false
        for character in raw.dropFirst().dropLast() {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
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
    public struct Recovery: Sendable {
        public var document: LegacyConfigurationDocument
        public var recoveredFrom: URL?
    }

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

    /// Loads the primary configuration, falling back to the newest readable
    /// timestamped backup without modifying either file.
    public func loadRecoveringFromBackup() throws -> Recovery {
        do { return Recovery(document: try load(), recoveredFrom: nil) }
        catch {
            let primaryData = try? Data(contentsOf: url)
            for backup in backupCandidates() {
                guard let data = try? Data(contentsOf: backup),
                      let source = String(data: data, encoding: .utf8),
                      let document = try? LegacyConfigurationDocument(source: source) else { continue }
                fingerprint = primaryData.map(Self.fingerprint)
                return Recovery(document: document, recoveredFrom: backup)
            }
            throw error
        }
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

    private func backupCandidates() -> [URL] {
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent + ".backup-"
        let values = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return values.filter {
            $0.lastPathComponent.hasPrefix(stem) && $0.pathExtension.lowercased() == "txt"
        }.sorted { lhs, rhs in
            let leftDate = try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let rightDate = try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if leftDate != rightDate { return (leftDate ?? .distantPast) > (rightDate ?? .distantPast) }
            return lhs.lastPathComponent > rhs.lastPathComponent
        }
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
