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
        let newline = preferredLineEnding
        if parents.isEmpty {
            if source.last.map({ !Self.isLineBreak($0) }) == true { source.append(newline) }
            source.append("\(Self.identifier(name))=\(replacement)\(newline)")
        } else {
            if blockInsertionIndex(at: parents, nodes: nodes) == nil { try ensureBlocks(at: parents) }
            guard let insertion = blockInsertionIndex(at: parents, nodes: nodes) else {
                throw LegacyConfigurationError.missingPath(parents.joined(separator: "."))
            }
            let lineStart = lineStart(before: insertion)
            let closingIndent = source[lineStart..<insertion].prefix(while: { $0 == " " || $0 == "\t" })
            let childIndent = String(closingIndent) + "  "
            source.insert(contentsOf: "\(childIndent)\(Self.identifier(name))=\(replacement)\(newline)", at: insertion)
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
        let lineStart = lineStart(before: insertion)
        let closingIndent = source[lineStart..<insertion].prefix(while: { $0 == " " || $0 == "\t" })
        let childIndent = String(closingIndent) + "  "
        let newline = preferredLineEnding
        source.insert(contentsOf: "\(childIndent){\(newline)\(childIndent)}\(newline)", at: insertion)
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
        return (descend(path, nodes: nodes) ?? []).reduce(into: 0) { count, node in
            if case .block(name: nil, children: _, insertionIndex: _, sourceRange: _) = node { count += 1 }
        } - 1
    }

    @discardableResult
    public mutating func appendUnnamedBlock(
        at collectionPath: [String],
        nestedIn parentIndexPath: [Int],
        nestedCollectionPath: [String]
    ) throws -> Int {
        guard !parentIndexPath.isEmpty else {
            return try appendUnnamedBlock(at: collectionPath)
        }
        try ensureBlocks(
            at: nestedCollectionPath,
            inUnnamedBlockAt: parentIndexPath,
            collectionPath: collectionPath,
            nestedCollectionPath: nestedCollectionPath
        )
        guard let parent = unnamedBlock(at: parentIndexPath, collectionPath: collectionPath, nestedCollectionPath: nestedCollectionPath),
              let insertion = blockInsertionIndex(at: nestedCollectionPath, nodes: parent.children) else {
            throw LegacyConfigurationError.missingPath(nestedCollectionPath.joined(separator: "."))
        }
        let lineStart = lineStart(before: insertion)
        let closingIndent = source[lineStart..<insertion].prefix(while: { $0 == " " || $0 == "\t" })
        let childIndent = String(closingIndent) + "  "
        let newline = preferredLineEnding
        source.insert(contentsOf: "\(childIndent){\(newline)\(childIndent)}\(newline)", at: insertion)
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
        guard let refreshed = unnamedBlock(at: parentIndexPath, collectionPath: collectionPath, nestedCollectionPath: nestedCollectionPath),
              let children = descend(nestedCollectionPath, nodes: refreshed.children) else { return 0 }
        return Self.unnamedBlockCount(in: children) - 1
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
        let lineStart = lineStart(before: insertion)
        let closingIndent = source[lineStart..<insertion].prefix(while: { $0 == " " || $0 == "\t" })
        let childIndent = String(closingIndent) + "  "
        source.insert(
            contentsOf: "\(childIndent)\(Self.identifier(field))=\(quoted ? Self.quote(value) : value)\(preferredLineEnding)",
            at: insertion
        )
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
    }

    public mutating func upsertValue(
        _ value: String,
        inUnnamedBlockAt indexPath: [Int],
        collectionPath: [String],
        relativePath: [String],
        quoted: Bool = true
    ) throws {
        let nestedCollectionPath = Self.nestedCollectionPath(for: collectionPath)
        guard indexPath.count != 1 else {
            try upsertValue(value, inUnnamedBlockAt: indexPath[0], collectionPath: collectionPath, relativePath: relativePath, quoted: quoted)
            return
        }
        guard let field = relativePath.last else {
            throw LegacyConfigurationError.missingPath("")
        }
        guard let entry = unnamedBlock(
            at: indexPath,
            collectionPath: collectionPath,
            nestedCollectionPath: nestedCollectionPath
        ) else {
            throw LegacyConfigurationError.missingPath("\(collectionPath.joined(separator: "."))\(indexPath)")
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
            try ensureBlocks(
                at: parents,
                inUnnamedBlockAt: indexPath,
                collectionPath: collectionPath,
                nestedCollectionPath: nestedCollectionPath
            )
        }
        guard let refreshed = unnamedBlock(
            at: indexPath,
            collectionPath: collectionPath,
            nestedCollectionPath: nestedCollectionPath
        ) else {
            throw LegacyConfigurationError.missingPath("\(collectionPath.joined(separator: "."))\(indexPath)")
        }
        let insertion = parents.isEmpty
            ? refreshed.insertionIndex
            : blockInsertionIndex(at: parents, nodes: refreshed.children)
        guard let insertion else {
            throw LegacyConfigurationError.missingPath(relativePath.joined(separator: "."))
        }
        let lineStart = lineStart(before: insertion)
        let closingIndent = source[lineStart..<insertion].prefix(while: { $0 == " " || $0 == "\t" })
        let childIndent = String(closingIndent) + "  "
        source.insert(
            contentsOf: "\(childIndent)\(Self.identifier(field))=\(quoted ? Self.quote(value) : value)\(preferredLineEnding)",
            at: insertion
        )
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
    }

    public func value(
        inUnnamedBlockAt index: Int,
        collectionPath: [String],
        relativePath: [String]
    ) -> String? {
        guard let entry = unnamedBlock(at: index, collectionPath: collectionPath),
              let final = relativePath.last else { return nil }
        let parents = Array(relativePath.dropLast())
        for split in stride(from: parents.count, through: 0, by: -1) {
            guard let children = descend(Array(parents.prefix(split)), nodes: entry.children) else { continue }
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

    public func value(
        inUnnamedBlockAt indexPath: [Int],
        collectionPath: [String],
        relativePath: [String]
    ) -> String? {
        let nestedCollectionPath = Self.nestedCollectionPath(for: collectionPath)
        guard indexPath.count != 1 else {
            return value(inUnnamedBlockAt: indexPath[0], collectionPath: collectionPath, relativePath: relativePath)
        }
        guard let entry = unnamedBlock(
            at: indexPath,
            collectionPath: collectionPath,
            nestedCollectionPath: nestedCollectionPath
        ),
              let final = relativePath.last else { return nil }
        let parents = Array(relativePath.dropLast())
        for split in stride(from: parents.count, through: 0, by: -1) {
            guard let children = descend(Array(parents.prefix(split)), nodes: entry.children) else { continue }
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

    @discardableResult
    public mutating func removeUnnamedBlock(at indexPath: [Int], collectionPath: [String]) throws -> Bool {
        guard indexPath.count != 1 else {
            return try removeUnnamedBlock(at: indexPath[0], collectionPath: collectionPath)
        }
        guard let entry = unnamedBlock(at: indexPath, collectionPath: collectionPath) else { return false }
        source.removeSubrange(expandedRemovalRange(entry.sourceRange))
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
        return true
    }

    @discardableResult
    public mutating func removeUnnamedBlock(
        at indexPath: [Int],
        collectionPath: [String],
        nestedCollectionPath: [String]
    ) throws -> Bool {
        guard !indexPath.isEmpty,
              let entry = unnamedBlock(
                  at: indexPath,
                  collectionPath: collectionPath,
                  nestedCollectionPath: nestedCollectionPath
              ) else { return false }
        source.removeSubrange(expandedRemovalRange(entry.sourceRange))
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
        return true
    }

    @discardableResult
    public mutating func moveUnnamedBlock(
        at sourceIndexPath: [Int],
        collectionPath: [String],
        to destinationIndex: Int,
        nestedIn destinationParentIndexPath: [Int],
        nestedCollectionPath: [String]
    ) throws -> [Int] {
        guard !sourceIndexPath.isEmpty,
              let entry = unnamedBlock(at: sourceIndexPath, collectionPath: collectionPath) else {
            throw LegacyConfigurationError.missingPath("\(collectionPath.joined(separator: "."))\(sourceIndexPath)")
        }

        let removalRange = expandedRemovalRange(entry.sourceRange)
        let movingSource = String(source[removalRange])
        source.removeSubrange(removalRange)
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()

        let adjustedParent = Self.adjustedIndexPath(
            destinationParentIndexPath,
            afterRemoving: sourceIndexPath
        )
        if adjustedParent.isEmpty {
            if blockInsertionIndex(at: collectionPath, nodes: nodes) == nil {
                try ensureBlocks(at: collectionPath)
            }
        } else {
            try ensureBlocks(
                at: nestedCollectionPath,
                inUnnamedBlockAt: adjustedParent,
                collectionPath: collectionPath
            )
        }

        let count = unnamedBlockCount(
            at: collectionPath,
            nestedIn: adjustedParent,
            nestedCollectionPath: nestedCollectionPath
        )
        let clampedIndex = min(max(0, destinationIndex), count)
        guard let insertion = unnamedBlockInsertionIndex(
            at: clampedIndex,
            collectionPath: collectionPath,
            nestedIn: adjustedParent,
            nestedCollectionPath: nestedCollectionPath
        ) else {
            throw LegacyConfigurationError.missingPath("\(collectionPath.joined(separator: "."))\(adjustedParent)")
        }
        source.insert(contentsOf: movingSource, at: insertion)
        parser = LegacyParser(source: source)
        nodes = try parser.parse()
        return adjustedParent + [clampedIndex]
    }

    /// Moves an unnamed block between two collections while retaining its
    /// original source subtree verbatim. This is used by nested aliases, whose
    /// source and destination scopes may be different Config.txt paths.
    @discardableResult
    public mutating func moveUnnamedBlock(
        at sourceIndexPath: [Int],
        collectionPath: [String],
        nestedCollectionPath sourceNestedCollectionPath: [String],
        to destinationIndex: Int,
        nestedIn destinationParentIndexPath: [Int],
        destinationCollectionPath: [String],
        destinationNestedCollectionPath: [String]
    ) throws -> [Int] {
        guard !sourceIndexPath.isEmpty,
              let entry = unnamedBlock(
                  at: sourceIndexPath,
                  collectionPath: collectionPath,
                  nestedCollectionPath: sourceNestedCollectionPath
              ) else {
            throw LegacyConfigurationError.missingPath("\(collectionPath.joined(separator: "."))\(sourceIndexPath)")
        }

        let removalRange = expandedRemovalRange(entry.sourceRange)
        let movingSource = String(source[removalRange])
        source.removeSubrange(removalRange)
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()

        let sameDestination = collectionPath.map { $0.lowercased() } == destinationCollectionPath.map { $0.lowercased() }
        let adjustedParent = sameDestination
            ? Self.adjustedIndexPath(destinationParentIndexPath, afterRemoving: sourceIndexPath)
            : destinationParentIndexPath
        if adjustedParent.isEmpty {
            if blockInsertionIndex(at: destinationCollectionPath, nodes: nodes) == nil {
                try ensureBlocks(at: destinationCollectionPath)
            }
        } else {
            try ensureBlocks(
                at: destinationNestedCollectionPath,
                inUnnamedBlockAt: adjustedParent,
                collectionPath: destinationCollectionPath,
                nestedCollectionPath: destinationNestedCollectionPath
            )
        }

        let count = unnamedBlockCount(
            at: destinationCollectionPath,
            nestedIn: adjustedParent,
            nestedCollectionPath: destinationNestedCollectionPath
        )
        let clampedIndex = min(max(0, destinationIndex), count)
        guard let insertion = unnamedBlockInsertionIndex(
            at: clampedIndex,
            collectionPath: destinationCollectionPath,
            nestedIn: adjustedParent,
            nestedCollectionPath: destinationNestedCollectionPath
        ) else {
            throw LegacyConfigurationError.missingPath("\(destinationCollectionPath.joined(separator: "."))\(adjustedParent)")
        }
        source.insert(contentsOf: movingSource, at: insertion)
        parser = LegacyParser(source: source)
        nodes = try parser.parse()
        return adjustedParent + [clampedIndex]
    }

    /// Copies an unnamed block, including comments, unknown fields, and all
    /// nested payloads, into another collection.
    @discardableResult
    public mutating func copyUnnamedBlock(
        at sourceIndexPath: [Int],
        collectionPath: [String],
        nestedCollectionPath sourceNestedCollectionPath: [String],
        to destinationIndex: Int,
        nestedIn destinationParentIndexPath: [Int],
        destinationCollectionPath: [String],
        destinationNestedCollectionPath: [String]
    ) throws -> [Int] {
        guard !sourceIndexPath.isEmpty,
              let entry = unnamedBlock(
                  at: sourceIndexPath,
                  collectionPath: collectionPath,
                  nestedCollectionPath: sourceNestedCollectionPath
              ) else {
            throw LegacyConfigurationError.missingPath("\(collectionPath.joined(separator: "."))\(sourceIndexPath)")
        }
        let copiedSource = String(source[expandedRemovalRange(entry.sourceRange)])
        if destinationParentIndexPath.isEmpty {
            if blockInsertionIndex(at: destinationCollectionPath, nodes: nodes) == nil {
                try ensureBlocks(at: destinationCollectionPath)
            }
        } else {
            try ensureBlocks(
                at: destinationNestedCollectionPath,
                inUnnamedBlockAt: destinationParentIndexPath,
                collectionPath: destinationCollectionPath,
                nestedCollectionPath: destinationNestedCollectionPath
            )
        }
        let count = unnamedBlockCount(
            at: destinationCollectionPath,
            nestedIn: destinationParentIndexPath,
            nestedCollectionPath: destinationNestedCollectionPath
        )
        let clampedIndex = min(max(0, destinationIndex), count)
        guard let insertion = unnamedBlockInsertionIndex(
            at: clampedIndex,
            collectionPath: destinationCollectionPath,
            nestedIn: destinationParentIndexPath,
            nestedCollectionPath: destinationNestedCollectionPath
        ) else {
            throw LegacyConfigurationError.missingPath("\(destinationCollectionPath.joined(separator: "."))\(destinationParentIndexPath)")
        }
        source.insert(contentsOf: copiedSource, at: insertion)
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
        return destinationParentIndexPath + [clampedIndex]
    }

    public func unnamedBlockCount(
        at collectionPath: [String],
        nestedIn parentIndexPath: [Int] = [],
        nestedCollectionPath: [String] = []
    ) -> Int {
        if parentIndexPath.isEmpty {
            return Self.unnamedBlockCount(in: descend(collectionPath, nodes: nodes) ?? [])
        }
        guard let parent = unnamedBlock(at: parentIndexPath, collectionPath: collectionPath, nestedCollectionPath: nestedCollectionPath),
              let children = descend(nestedCollectionPath, nodes: parent.children) else { return 0 }
        return Self.unnamedBlockCount(in: children)
    }

    /// Returns scalar fields from every unnamed entry in a legacy collection.
    public func unnamedBlockValues(at collectionPath: [String]) -> [[String: String]] {
        guard let children = descend(collectionPath, nodes: nodes) else { return [] }
        return children.compactMap { node in
            guard case let .block(name: nil, entryChildren, _, _) = node else { return nil }
            return Dictionary(uniqueKeysWithValues: entryChildren.compactMap { child in
                guard case let .assignment(name, value, _, _) = child else { return nil }
                return (name, Self.unquote(value))
            })
        }
    }

    func assignmentValues(at path: [String]) -> [(name: String, value: String)] {
        guard let children = descend(path, nodes: nodes) else { return [] }
        return children.compactMap { node in
            guard case let .assignment(name, value, _, _) = node else { return nil }
            return (name, Self.unquote(value))
        }
    }

    @discardableResult
    mutating func removeAssignment(named name: String, at path: [String]) throws -> Bool {
        guard let children = descend(path, nodes: nodes) else { return false }
        let ranges = children.compactMap { node -> Range<String.Index>? in
            guard case let .assignment(candidate, _, _, range) = node,
                  candidate.caseInsensitiveCompare(name) == .orderedSame else { return nil }
            return range
        }
        guard !ranges.isEmpty else { return false }
        for range in ranges.map(expandedRemovalRange).sorted(by: { $0.lowerBound > $1.lowerBound }) {
            source.removeSubrange(range)
        }
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

    /// Returns complete source slices for unnamed entries, including comments
    /// attached to those entries. This is used for lossless macro import and
    /// export when the Mac projection does not know every Windows field.
    public func rawUnnamedBlockSources(at collectionPath: [String]) -> [String] {
        guard let children = descend(collectionPath, nodes: nodes) else { return [] }
        return children.compactMap { node in
            guard case let .block(name: nil, children: _, insertionIndex: _, sourceRange: range) = node else { return nil }
            return String(source[expandedRemovalRange(range)])
        }
    }

    public func rawUnnamedBlockSource(
        at indexPath: [Int],
        collectionPath: [String],
        nestedCollectionPath: [String] = []
    ) -> String? {
        guard let range = unnamedBlock(
            at: indexPath,
            collectionPath: collectionPath,
            nestedCollectionPath: nestedCollectionPath.isEmpty
                ? Self.nestedCollectionPath(for: collectionPath)
                : nestedCollectionPath
        )?.sourceRange else { return nil }
        return String(source[expandedRemovalRange(range)])
    }

    /// Finds all collections with the supplied name, regardless of scope.
    /// Config.txt uses the same KeyboardMacros2 block name globally and below
    /// worlds, characters, and folders.
    public func rawUnnamedBlockSources(named collectionName: String) -> [String] {
        func collect(_ nodes: [Node]) -> [String] {
            nodes.flatMap { node in
                switch node {
                    case let .block(name, children, _, _):
                    if name?.caseInsensitiveCompare(collectionName) == .orderedSame {
                        // Do not recurse into a matched collection: nested
                        // KeyboardMacros2 blocks are children of the macro
                        // subtree we are already copying.
                        let local: [String] = children.compactMap { child in
                            guard case let .block(name: nil, children: _, insertionIndex: _, sourceRange: range) = child else { return nil }
                            return String(source[expandedRemovalRange(range)])
                        }
                        return local
                    }
                    return collect(children)
                case .assignment, .bare:
                    return []
                }
            }
        }
        return collect(nodes)
    }

    /// Appends a serialized unnamed block without projecting or rewriting it.
    /// Unknown fields, comments, nested children, and source ordering inside
    /// the block are therefore preserved during cross-scope copies/imports.
    @discardableResult
    public mutating func appendRawUnnamedBlock(
        _ rawSource: String,
        at collectionPath: [String],
        nestedIn parentIndexPath: [Int] = [],
        nestedCollectionPath: [String] = [],
        index requestedIndex: Int? = nil
    ) throws -> Int {
        let childCollectionPath = nestedCollectionPath.isEmpty
            ? Self.nestedCollectionPath(for: collectionPath)
            : nestedCollectionPath
        if parentIndexPath.isEmpty {
            if blockInsertionIndex(at: collectionPath, nodes: nodes) == nil { try ensureBlocks(at: collectionPath) }
        } else {
            try ensureBlocks(
                at: childCollectionPath,
                inUnnamedBlockAt: parentIndexPath,
                collectionPath: collectionPath,
                nestedCollectionPath: childCollectionPath
            )
        }
        let count = unnamedBlockCount(
            at: collectionPath,
            nestedIn: parentIndexPath,
            nestedCollectionPath: childCollectionPath
        )
        let index = min(max(0, requestedIndex ?? count), count)
        guard let insertion = unnamedBlockInsertionIndex(
            at: index,
            collectionPath: collectionPath,
            nestedIn: parentIndexPath,
            nestedCollectionPath: childCollectionPath
        ) else {
            throw LegacyConfigurationError.missingPath(collectionPath.joined(separator: "."))
        }
        let prefix = source[..<insertion].last.map { $0.isNewline ? "" : preferredLineEnding } ?? ""
        let suffix = rawSource.last.map { $0.isNewline ? "" : preferredLineEnding } ?? preferredLineEnding
        source.insert(contentsOf: prefix + rawSource + suffix, at: insertion)
        var parser = LegacyParser(source: source)
        nodes = try parser.parse()
        return index
    }

    private var preferredLineEnding: String {
        source.contains("\r\n") ? "\r\n" : "\n"
    }

    private func lineStart(before index: String.Index) -> String.Index {
        source[..<index].lastIndex(where: Self.isLineBreak).map(source.index(after:)) ?? source.startIndex
    }

    private static func isLineBreak(_ character: Character) -> Bool {
        character.isNewline
    }

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

    private func unnamedBlock(
        at indexPath: [Int],
        collectionPath: [String],
        nestedCollectionPath: [String] = ["Triggers"]
    ) -> (children: [Node], insertionIndex: String.Index, sourceRange: Range<String.Index>)? {
        guard let first = indexPath.first,
              var entry = unnamedBlock(at: first, collectionPath: collectionPath) else { return nil }
        for index in indexPath.dropFirst() {
            guard let children = descend(nestedCollectionPath, nodes: entry.children) else { return nil }
            var offset = 0
            var next: (children: [Node], insertionIndex: String.Index, sourceRange: Range<String.Index>)?
            for node in children {
                guard case let .block(name: nil, children: entryChildren, insertionIndex: insertionIndex, sourceRange: sourceRange) = node else {
                    continue
                }
                if offset == index {
                    next = (entryChildren, insertionIndex, sourceRange)
                    break
                }
                offset += 1
            }
            guard let next else { return nil }
            entry = next
        }
        return entry
    }

    private func unnamedBlockInsertionIndex(
        at index: Int,
        collectionPath: [String],
        nestedIn parentIndexPath: [Int],
        nestedCollectionPath: [String]
    ) -> String.Index? {
        let children: [Node]?
        if parentIndexPath.isEmpty {
            children = descend(collectionPath, nodes: nodes)
        } else {
            guard let parent = unnamedBlock(at: parentIndexPath, collectionPath: collectionPath, nestedCollectionPath: nestedCollectionPath) else {
                return nil
            }
            children = descend(nestedCollectionPath, nodes: parent.children)
        }
        guard let children else { return nil }
        var offset = 0
        for node in children {
            guard case let .block(name: nil, children: _, insertionIndex: _, sourceRange: sourceRange) = node else {
                continue
            }
            if offset == index { return expandedRemovalRange(sourceRange).lowerBound }
            offset += 1
        }
        if parentIndexPath.isEmpty {
            return blockInsertionIndex(at: collectionPath, nodes: nodes)
        }
        guard let parent = unnamedBlock(at: parentIndexPath, collectionPath: collectionPath, nestedCollectionPath: nestedCollectionPath) else {
            return nil
        }
        return blockInsertionIndex(at: nestedCollectionPath, nodes: parent.children)
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
            let newline = preferredLineEnding
            if parentPath.isEmpty {
                if source.last.map({ !Self.isLineBreak($0) }) == true { source.append(newline) }
                source.append("\(serializedName)\(newline){\(newline)}\(newline)")
            } else {
                guard let insertion = blockInsertionIndex(at: parentPath, nodes: nodes) else {
                    throw LegacyConfigurationError.missingPath(parentPath.joined(separator: "."))
                }
                let lineStart = lineStart(before: insertion)
                let closingIndent = source[lineStart..<insertion].prefix(while: { $0 == " " || $0 == "\t" })
                let childIndent = String(closingIndent) + "  "
                source.insert(
                    contentsOf: "\(childIndent)\(serializedName)\(newline)\(childIndent){\(newline)\(childIndent)}\(newline)",
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
        collectionPath: [String],
        nestedCollectionPath: [String] = ["Triggers"]
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
            let lineStart = lineStart(before: insertion)
            let closingIndent = source[lineStart..<insertion].prefix(while: { $0 == " " || $0 == "\t" })
            let childIndent = String(closingIndent) + "  "
            let newline = preferredLineEnding
            source.insert(
                contentsOf: "\(childIndent)\(Self.identifier(path[depth - 1]))\(newline)\(childIndent){\(newline)\(childIndent)}\(newline)",
                at: insertion
            )
            var parser = LegacyParser(source: source)
            nodes = try parser.parse()
        }
    }

    private mutating func ensureBlocks(
        at path: [String],
        inUnnamedBlockAt indexPath: [Int],
        collectionPath: [String],
        nestedCollectionPath: [String] = ["Triggers"]
    ) throws {
        guard indexPath.count != 1 else {
            try ensureBlocks(at: path, inUnnamedBlockAt: indexPath[0], collectionPath: collectionPath, nestedCollectionPath: nestedCollectionPath)
            return
        }
        for depth in 1...path.count {
            guard let entry = unnamedBlock(at: indexPath, collectionPath: collectionPath, nestedCollectionPath: nestedCollectionPath) else {
                throw LegacyConfigurationError.missingPath("\(collectionPath.joined(separator: "."))\(indexPath)")
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
            let lineStart = lineStart(before: insertion)
            let closingIndent = source[lineStart..<insertion].prefix(while: { $0 == " " || $0 == "\t" })
            let childIndent = String(closingIndent) + "  "
            let newline = preferredLineEnding
            source.insert(
                contentsOf: "\(childIndent)\(Self.identifier(path[depth - 1]))\(newline)\(childIndent){\(newline)\(childIndent)}\(newline)",
                at: insertion
            )
            var parser = LegacyParser(source: source)
            nodes = try parser.parse()
        }
    }

    private func expandedRemovalRange(_ range: Range<String.Index>) -> Range<String.Index> {
        let lineStart = source[..<range.lowerBound].lastIndex(where: Self.isLineBreak).map(source.index(after:)) ?? source.startIndex
        let nextNewline = source[range.upperBound...].firstIndex(where: Self.isLineBreak)
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

    private static func unnamedBlockCount(in nodes: [Node]) -> Int {
        nodes.reduce(into: 0) { count, node in
            if case .block(name: nil, children: _, insertionIndex: _, sourceRange: _) = node { count += 1 }
        }
    }

    private static func nestedCollectionPath(for collectionPath: [String]) -> [String] {
        guard let name = collectionPath.last?.lowercased() else { return ["Triggers"] }
        switch name {
        case "aliases": return ["Aliases"]
        case "triggers": return ["Triggers"]
        case "keyboardmacros2", "keyboardmacros": return ["KeyboardMacros2"]
        default: return ["Triggers"]
        }
    }

    private static func adjustedIndexPath(_ path: [Int], afterRemoving removedPath: [Int]) -> [Int] {
        let parentPath = Array(removedPath.dropLast())
        guard path.count > parentPath.count,
              Array(path.prefix(parentPath.count)) == parentPath,
              let removedIndex = removedPath.last,
              path[parentPath.count] > removedIndex else {
            return path
        }
        var adjusted = path
        adjusted[parentPath.count] -= 1
        return adjusted
    }

    private static func identifier(_ value: String) -> String {
        // v331's ConfigImport::Parse_KeyString accepts letters only. Its own
        // serializer therefore quotes property/scope names containing digits,
        // underscores, punctuation, or whitespace (for example
        // "KeyboardMacros2", "GMCP_WebView", and "TCP_NoDelay").
        value.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        } ? value : quote(value)
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
                cursor = source[cursor...].firstIndex(where: \.isNewline)
                    .map { source.index(after: $0) } ?? source.endIndex
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
    private let engine: LegacyConfigurationPersistenceEngine

    public init(url: URL) {
        self.url = url
        engine = .init(url: url, backupStrategy: .timestamped)
    }

    init(
        url: URL,
        writer: AtomicFileWriter = .live,
        backupWriter: AtomicFileWriter = .live,
        conflictWriter: AtomicFileWriter = .live
    ) {
        self.url = url
        engine = .init(
            url: url,
            backupStrategy: .timestamped,
            writer: writer,
            backupWriter: backupWriter,
            conflictWriter: conflictWriter
        )
    }

    public func load() throws -> LegacyConfigurationDocument {
        let loaded = try engine.load()
        fingerprint = loaded.primaryFingerprint
        return loaded.document
    }

    /// Loads the primary configuration, falling back to the newest readable
    /// timestamped backup without modifying either file.
    public func loadRecoveringFromBackup() throws -> Recovery {
        let loaded = try engine.loadRecoveringFromBackup()
        fingerprint = loaded.primaryFingerprint
        return Recovery(document: loaded.document, recoveredFrom: loaded.recoveredFrom)
    }

    public func save(_ document: LegacyConfigurationDocument) throws {
        fingerprint = try engine.checkedSave(
            document,
            expectedPrimaryFingerprint: fingerprint
        )
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
