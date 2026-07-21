import Foundation

public struct Alias: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var description: String
    public var match: MatchDefinition
    public var replacement: String
    public var stopProcessing: Bool
    public var expandVariables: Bool
    public var children: [Alias]

    public init(
        id: UUID = UUID(),
        description: String = "",
        match: MatchDefinition,
        replacement: String,
        stopProcessing: Bool = false,
        expandVariables: Bool = false,
        children: [Alias] = []
    ) {
        self.id = id
        self.description = description
        self.match = match
        self.replacement = replacement
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
}

public struct AliasResult: Sendable, Equatable {
    public var text: String
    public var matchedAliases: [UUID]
    public var stopped: Bool
}

public enum AliasEngine {
    public static func process(_ input: String, groups: [AliasGroup], variables: [String: String]) throws -> AliasResult {
        var result = AliasResult(text: input, matchedAliases: [], stopped: false)
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
            guard let capture = try alias.match.matches(in: result.text).first else { continue }
            result.text = Expansion.apply(alias.replacement, capture: capture, variables: alias.expandVariables ? variables : [:])
            result.matchedAliases.append(alias.id)
            if !alias.children.isEmpty { try process(alias.children, variables: variables, result: &result) }
            if alias.stopProcessing { result.stopped = true }
        }
    }
}

