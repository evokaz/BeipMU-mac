import Foundation

public struct OutputSearchOptions: Sendable, Hashable {
    public var isRegularExpression: Bool
    public var isCaseSensitive: Bool
    public var wholeWord: Bool

    public init(
        isRegularExpression: Bool = false,
        isCaseSensitive: Bool = false,
        wholeWord: Bool = false
    ) {
        self.isRegularExpression = isRegularExpression
        self.isCaseSensitive = isCaseSensitive
        self.wholeWord = wholeWord
    }
}

public struct OutputSearchMatch: Sendable, Hashable {
    public var lineID: UUID
    /// UTF-16 offsets, matching `RenderedLine` style runs and AppKit ranges.
    public var range: Range<Int>

    public init(lineID: UUID, range: Range<Int>) {
        self.lineID = lineID
        self.range = range
    }
}

/// Bounded output history shared by the renderer, find panel, and recall commands.
/// Pausing retains incoming lines in a separate queue so the visible scroll position
/// is stable without dropping network output.
public struct OutputHistory: Sendable {
    private var storage: [RenderedLine] = []
    private var storageStart = 0
    public var lines: [RenderedLine] { Array(storage[storageStart...]) }
    public var count: Int { storage.count - storageStart }
    public private(set) var pendingLines: [RenderedLine] = []
    public private(set) var isPaused = false
    public var limit: Int {
        didSet {
            limit = max(1, limit)
            trimToLimit()
        }
    }

    public init(limit: Int = 10_000) {
        self.limit = max(1, limit)
    }

    /// Returns the number of old visible lines removed from the front.
    @discardableResult
    public mutating func append(_ line: RenderedLine) -> Int {
        if isPaused {
            pendingLines.append(line)
            if pendingLines.count > limit {
                pendingLines.removeFirst(pendingLines.count - limit)
            }
            return 0
        }
        storage.append(line)
        return trimToLimit()
    }

    @discardableResult
    public mutating func removeLast() -> RenderedLine? {
        if isPaused, !pendingLines.isEmpty { return pendingLines.removeLast() }
        guard storage.count > storageStart else { return nil }
        let result = storage.removeLast()
        compactStorageIfNeeded()
        return result
    }

    public mutating func clear() {
        storage.removeAll(keepingCapacity: true)
        storageStart = 0
        pendingLines.removeAll(keepingCapacity: true)
    }

    public func oldestLineIDs(_ requestedCount: Int) -> [UUID] {
        let amount = min(max(0, requestedCount), count)
        guard amount > 0 else { return [] }
        return storage[storageStart..<(storageStart + amount)].map(\.id)
    }

    public mutating func pause() { isPaused = true }

    /// Makes queued lines visible and returns the resulting complete bounded history.
    @discardableResult
    public mutating func resume() -> [RenderedLine] {
        guard isPaused else { return lines }
        isPaused = false
        storage.append(contentsOf: pendingLines)
        pendingLines.removeAll(keepingCapacity: true)
        trimToLimit()
        return lines
    }

    public func search(_ query: String, options: OutputSearchOptions = .init()) throws -> [OutputSearchMatch] {
        guard !query.isEmpty else { return [] }
        let pattern: String
        if options.isRegularExpression {
            pattern = options.wholeWord ? "\\b(?:\(query))\\b" : query
        } else {
            let escaped = NSRegularExpression.escapedPattern(for: query)
            pattern = options.wholeWord ? "\\b\(escaped)\\b" : escaped
        }
        let expression = try NSRegularExpression(
            pattern: pattern,
            options: options.isCaseSensitive ? [] : [.caseInsensitive]
        )
        return storage[storageStart...].flatMap { line in
            let fullRange = NSRange(location: 0, length: line.text.utf16.count)
            return expression.matches(in: line.text, range: fullRange).map { match in
                OutputSearchMatch(
                    lineID: line.id,
                    range: match.range.location..<(match.range.location + match.range.length)
                )
            }
        }
    }

    @discardableResult
    private mutating func trimToLimit() -> Int {
        let count = max(0, storage.count - storageStart - limit)
        storageStart += count
        compactStorageIfNeeded()
        return count
    }

    private mutating func compactStorageIfNeeded() {
        guard storageStart > 1_024, storageStart * 2 >= storage.count else { return }
        storage.removeFirst(storageStart)
        storageStart = 0
    }
}

/// Command history with shell-style draft restoration at the newest position.
public struct InputHistory: Sendable, Hashable {
    public private(set) var entries: [String] = []
    public var limit: Int {
        didSet {
            limit = max(1, limit)
            trimToLimit()
        }
    }
    private var cursor: Int?
    private var draft = ""

    public init(limit: Int = 500) {
        self.limit = max(1, limit)
    }

    public mutating func record(_ text: String) {
        guard !text.isEmpty else { return }
        if entries.last != text { entries.append(text) }
        trimToLimit()
        resetNavigation()
    }

    public mutating func previous(currentText: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if cursor == nil {
            draft = currentText
            cursor = entries.count - 1
        } else if let cursor, cursor > 0 {
            self.cursor = cursor - 1
        }
        return cursor.map { entries[$0] }
    }

    public mutating func next() -> String? {
        guard let cursor else { return nil }
        if cursor + 1 < entries.count {
            self.cursor = cursor + 1
            return entries[cursor + 1]
        }
        self.cursor = nil
        let restoredDraft = draft
        draft = ""
        return restoredDraft
    }

    public mutating func resetNavigation() {
        cursor = nil
        draft = ""
    }

    private mutating func trimToLimit() {
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        resetNavigation()
    }
}

public struct InputBehavior: Sendable, Hashable {
    public var prefix: String
    public var isSticky: Bool

    public init(prefix: String = "", isSticky: Bool = false) {
        self.prefix = prefix
        self.isSticky = isSticky
    }

    public func submission(for text: String) -> (outbound: String, replacement: String) {
        (prefix + text, isSticky ? text : "")
    }
}

public enum InputConversion: String, Sendable, CaseIterable {
    case returns
    case tabs
    case spaces

    public func apply(to text: String) -> String {
        switch self {
        case .returns:
            return text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\n", with: "%R")
        case .tabs:
            return text.replacingOccurrences(of: "\t", with: "%T")
        case .spaces:
            return text.replacingOccurrences(of: " ", with: "%B")
        }
    }
}
