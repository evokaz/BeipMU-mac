import Foundation

public struct Alias: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var description: String
    public var match: MatchDefinition
    /// The Windows editor's persisted test/example string. An empty value
    /// means that the editor should use its generated example.
    public var example: String
    public var replacement: String
    public var folder: Bool
    /// Whether this alias is eligible to run. The containing alias group still
    /// acts as the master switch for the scope.
    public var active: Bool
    /// Per-alias output behavior. These values are materialized from the
    /// legacy group defaults when an older Config.txt is projected.
    public var echo: Bool
    public var processCommands: Bool
    public var stopProcessing: Bool
    public var expandVariables: Bool
    public var children: [Alias]
    /// The persisted settings of a folder's child `Aliases` collection.
    /// These are deliberately kept on the parent so nested ordering survives
    /// projection even though the public API exposes children as an array.
    public var childrenActive: Bool
    public var childrenAfterCount: Int

    public init(
        id: UUID = UUID(),
        description: String = "",
        match: MatchDefinition,
        example: String = "",
        replacement: String,
        folder: Bool = false,
        active: Bool = true,
        echo: Bool = true,
        processCommands: Bool = false,
        stopProcessing: Bool = false,
        expandVariables: Bool = false,
        children: [Alias] = [],
        childrenActive: Bool = true,
        childrenAfterCount: Int = 0
    ) {
        self.id = id
        self.description = description
        self.match = match
        self.example = example
        self.replacement = replacement
        self.folder = folder
        self.active = active
        self.echo = echo
        self.processCommands = processCommands
        self.stopProcessing = stopProcessing
        self.expandVariables = expandVariables
        self.children = children
        self.childrenActive = childrenActive
        self.childrenAfterCount = max(0, min(childrenAfterCount, children.count))
    }

    private enum CodingKeys: String, CodingKey {
        case id, description, match, example, replacement, folder,
             active, echo, processCommands, stopProcessing, expandVariables, children, childrenActive,
             childrenAfterCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        description = try values.decode(String.self, forKey: .description)
        match = try values.decode(MatchDefinition.self, forKey: .match)
        example = try values.decodeIfPresent(String.self, forKey: .example) ?? ""
        replacement = try values.decode(String.self, forKey: .replacement)
        folder = try values.decodeIfPresent(Bool.self, forKey: .folder) ?? false
        active = try values.decodeIfPresent(Bool.self, forKey: .active) ?? true
        echo = try values.decodeIfPresent(Bool.self, forKey: .echo) ?? true
        processCommands = try values.decodeIfPresent(Bool.self, forKey: .processCommands) ?? false
        stopProcessing = try values.decodeIfPresent(Bool.self, forKey: .stopProcessing) ?? false
        expandVariables = try values.decodeIfPresent(Bool.self, forKey: .expandVariables) ?? false
        children = try values.decodeIfPresent([Alias].self, forKey: .children) ?? []
        childrenActive = try values.decodeIfPresent(Bool.self, forKey: .childrenActive) ?? true
        childrenAfterCount = max(0, min(
            try values.decodeIfPresent(Int.self, forKey: .childrenAfterCount) ?? 0,
            children.count
        ))
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
    public var echo: Bool
    public var processCommands: Bool
    public var stopped: Bool
    public var trace: [AutomationTraceEvent]
    public var diagnostics: [AliasDiagnostic]

    public init(
        text: String,
        matchedAliases: [UUID] = [],
        echo: Bool = false,
        processCommands: Bool = false,
        stopped: Bool = false,
        trace: [AutomationTraceEvent] = [],
        diagnostics: [AliasDiagnostic] = []
    ) {
        self.text = text
        self.matchedAliases = matchedAliases
        self.echo = echo
        self.processCommands = processCommands
        self.stopped = stopped
        self.trace = trace
        self.diagnostics = diagnostics
    }
}

public struct AliasDiagnostic: Sendable, Equatable, Hashable {
    public var aliasID: UUID
    public var description: String
    public var message: String

    public init(aliasID: UUID, description: String, message: String) {
        self.aliasID = aliasID
        self.description = description
        self.message = message
    }
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
        var result = AliasResult(text: input)
        for group in groups where group.active && !result.stopped {
            let split = max(0, min(group.afterCount, group.aliases.count))
            let pre = group.aliases.dropLast(split)
            let post = group.aliases.suffix(split)
            try process(
                pre + post,
                groupEcho: group.echo,
                groupProcessCommands: group.processCommands,
                variables: variables,
                result: &result
            )
        }
        return result
    }

    private static func process<S: Sequence>(
        _ aliases: S,
        groupEcho: Bool = true,
        groupProcessCommands: Bool = false,
        variables: [String: String],
        result: inout AliasResult
    ) throws where S.Element == Alias {
        for alias in aliases where !result.stopped {
            guard alias.active else {
                result.trace.append(.init(
                    engine: .alias,
                    description: alias.description,
                    pattern: alias.folder ? "<folder>" : alias.match.text,
                    input: result.text,
                    matchCount: 0,
                    output: result.text,
                    reason: "Skipped: alias inactive"
                ))
                continue
            }
            var matched = false
            var matchCount = 0
            let input = result.text
            if !alias.folder {
                // An empty ordinary alias is a useful placeholder in the
                // editor, but Windows does not let it match every command.
                if !alias.match.text.isEmpty {
                    do {
                        var cursor = 0
                        var emptyMatchSeen = false
                        while let capture = try alias.match.firstMatch(in: result.text, startingAtUTF16: cursor) {
                            if capture.range.length == 0, emptyMatchSeen { break }
                            emptyMatchSeen = capture.range.length == 0
                            matchCount += 1
                            let replacement = Expansion.apply(
                                alias.replacement,
                                capture: capture,
                                variables: alias.expandVariables ? variables : [:]
                            )
                            guard let range = Range(capture.range, in: result.text) else { break }
                            result.text.replaceSubrange(range, with: replacement)
                            matched = true
                            // FindStringSearch resumes immediately after the
                            // replacement, so replacement text is not searched
                            // again and later ranges are based on the new result.
                            cursor = capture.range.location + replacement.utf16.count
                        }
                    } catch {
                        let message = "Invalid regular expression: \(error.localizedDescription)"
                        result.diagnostics.append(.init(
                            aliasID: alias.id,
                            description: alias.description,
                            message: message
                        ))
                        result.trace.append(.init(
                            engine: .alias,
                            description: alias.description,
                            pattern: alias.match.text,
                            input: input,
                            matchCount: 0,
                            output: result.text,
                            reason: message
                        ))
                        continue
                    }
                }
                if matched {
                    result.matchedAliases.append(alias.id)
                    result.echo = result.echo || (groupEcho && alias.echo)
                    result.processCommands = result.processCommands || groupProcessCommands || alias.processCommands
                }
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
                // Windows processes a folder's child collection directly;
                // its Active/AfterCount payload is retained for round-trip
                // compatibility but is not a second runtime phase.
                try process(
                    alias.children,
                    groupEcho: groupEcho,
                    groupProcessCommands: groupProcessCommands,
                    variables: variables,
                    result: &result
                )
            }
            if matched && alias.stopProcessing { result.stopped = true }
        }
    }
}
