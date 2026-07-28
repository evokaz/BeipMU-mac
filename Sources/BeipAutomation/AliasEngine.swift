import Foundation

public struct Alias: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var description: String
    public var match: MatchDefinition
    public var replacement: String
    public var folder: Bool
    public var stopProcessing: Bool
    public var expandVariables: Bool
    public var children: [Alias]

    public init(
        id: UUID = UUID(),
        description: String = "",
        match: MatchDefinition,
        replacement: String,
        folder: Bool = false,
        stopProcessing: Bool = false,
        expandVariables: Bool = false,
        children: [Alias] = []
    ) {
        self.id = id
        self.description = description
        self.match = match
        self.replacement = replacement
        self.folder = folder
        self.stopProcessing = stopProcessing
        self.expandVariables = expandVariables
        self.children = children
    }
}

public struct AliasGroup: Sendable, Hashable, Codable {
    public var active: Bool
    public var echo: Bool
    public var processCommands: Bool
    public var afterCount: Int
    public var aliases: [Alias]

    public init(active: Bool = true, echo: Bool = true, processCommands: Bool = false, afterCount: Int = 0, aliases: [Alias] = []) {
        self.active = active
        self.echo = echo
        self.processCommands = processCommands
        self.afterCount = afterCount
        self.aliases = aliases
    }

    public var pre: [Alias] {
        aliases.dropLast(max(0, min(afterCount, aliases.count))).map { $0 }
    }

    public var post: [Alias] {
        aliases.suffix(max(0, min(afterCount, aliases.count))).map { $0 }
    }
}

public struct AliasResult: Sendable, Equatable {
    public var text: String
    public var matchedAliases: [UUID]
    public var stopped: Bool
    public var trace: [AutomationTraceEvent]
}

public struct AutomationTraceEvent: Sendable, Equatable {
    public enum Engine: String, Sendable {
        case alias
        case trigger
    }

    public var engine: Engine
    public var description: String
    public var pattern: String
    public var input: String
    public var matchCount: Int
    public var output: String
    public var reason: String?

    public init(
        engine: Engine,
        description: String,
        pattern: String,
        input: String,
        matchCount: Int,
        output: String,
        reason: String? = nil
    ) {
        self.engine = engine
        self.description = description
        self.pattern = pattern
        self.input = input
        self.matchCount = matchCount
        self.output = output
        self.reason = reason
    }
}

public enum AliasEngine {
    public static func process(_ input: String, groups: [AliasGroup], variables: [String: String]) throws -> AliasResult {
        var result = AliasResult(text: input, matchedAliases: [], stopped: false, trace: [])
        for group in groups where group.active && !result.stopped {
            let split = max(0, min(group.afterCount, group.aliases.count))
            let pre = group.aliases.dropLast(split)
            let post = group.aliases.suffix(split)
            try process(pre + post, variables: variables, result: &result)
        }
        return result
    }

    private static func process<S: Sequence>(_ aliases: S, variables: [String: String], result: inout AliasResult) throws where S.Element == Alias {
        for alias in aliases where !result.stopped {
            let input = result.text
            var matched = false
            var matchCount = 0
            if !alias.folder {
                // Windows applies every match within the current input line and
                // continues after each replacement. Applying right-to-left
                // preserves the original UTF-16 match ranges while avoiding
                // replacement text being searched again.
                let captures = try alias.match.matches(in: result.text)
                matchCount = captures.count
                for capture in captures.reversed() {
                    let replacement = Expansion.apply(
                        alias.replacement,
                        capture: capture,
                        variables: alias.expandVariables ? variables : [:]
                    )
                    guard let range = Range(capture.range, in: result.text) else { continue }
                    result.text.replaceSubrange(range, with: replacement)
                    matched = true
                }
                if matched { result.matchedAliases.append(alias.id) }
            }
            result.trace.append(.init(
                engine: .alias,
                description: alias.description,
                pattern: alias.folder ? "<folder>" : alias.match.text,
                input: input,
                matchCount: matchCount,
                output: result.text
            ))
            // Folder children always run; ordinary alias children run only
            // when their parent matched, matching Connection::ProcessAlias.
            if !alias.children.isEmpty && (alias.folder || matched) {
                try process(alias.children, variables: variables, result: &result)
            }
            if matched && alias.stopProcessing { result.stopped = true }
        }
    }
}
