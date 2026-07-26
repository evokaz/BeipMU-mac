import BeipAutomation
import BeipCore
import Foundation

/// Editable, lossless workspace for the portable profile portion of Config.txt.
/// The projection supplies native models while `document` retains every
/// comment, ordering choice, and platform-specific field for writeback.
public struct LegacyConfigurationWorkspace: Sendable {
    public enum AutomationScope: Sendable, Equatable {
        case global
        case server(UUID)
        case character(server: UUID, character: UUID)
        case puppet(server: UUID, character: UUID, puppet: UUID)

        public var displayName: String {
            switch self {
            case .global: "Global"
            case .server: "World"
            case .character: "Character"
            case .puppet: "Puppet"
            }
        }
    }

    public enum WorkspaceError: LocalizedError, Equatable {
        case serverNotFound
        case characterNotFound
        case puppetNotFound
        case automationEntryNotFound
        case emptyName
        case duplicateName(String)

        public var errorDescription: String? {
            switch self {
            case .serverNotFound: "The selected world no longer exists."
            case .characterNotFound: "The selected character no longer exists."
            case .puppetNotFound: "The selected puppet no longer exists."
            case .automationEntryNotFound: "The selected automation entry no longer exists."
            case .emptyName: "Names cannot be empty."
            case let .duplicateName(name): "“\(name)” is already in use at this level."
            }
        }
    }

    public private(set) var document: LegacyConfigurationDocument
    public private(set) var projection: LegacyConfigurationProjection
    public private(set) var sourceURL: URL?
    public private(set) var recoveredFrom: URL?
    public private(set) var isDirty: Bool

    public init(
        document: LegacyConfigurationDocument,
        sourceURL: URL? = nil,
        recoveredFrom: URL? = nil,
        isDirty: Bool = false
    ) throws {
        self.document = document
        self.projection = try LegacyConfigurationProjection(document: document)
        self.sourceURL = sourceURL
        self.recoveredFrom = recoveredFrom
        self.isDirty = isDirty
    }

    public static func empty(isDirty: Bool = true) throws -> Self {
        try .init(
            document: LegacyConfigurationDocument(source: """
            Version=331
            Connections
            {
              Shortcuts
              {
              }
            }
            """),
            isDirty: isDirty
        )
    }

    public var servers: [LegacyConfigurationProjection.Server] { projection.servers }
    public var settings: LegacyConfigurationProjection.ConnectionSettings { projection.settings }

    /// The intentionally small action surface exposed by the first native
    /// automation editor. Existing advanced action blocks remain untouched.
    public enum EditableTriggerAction: Sendable, Equatable {
        case gag(display: Bool, log: Bool)
        case send(String)
    }

    public var globalAliases: [Alias] { projection.automation.aliases.aliases }
    public var globalTriggers: [Trigger] { projection.automation.triggers.triggers }
    public var globalMacros: [KeyboardMacro] { projection.automation.macros.macros }

    public func aliases(in scope: AutomationScope) -> [Alias] {
        switch scope {
        case .global: projection.automation.aliases.aliases
        case let .server(id): server(id)?.automation.aliases.aliases ?? []
        case let .character(serverID, characterID): character(serverID: serverID, characterID: characterID)?.aliases.aliases ?? []
        case let .puppet(serverID, characterID, puppetID): puppet(serverID: serverID, characterID: characterID, puppetID: puppetID)?.aliases.aliases ?? []
        }
    }

    public func triggers(in scope: AutomationScope) -> [Trigger] {
        switch scope {
        case .global: projection.automation.triggers.triggers
        case let .server(id): server(id)?.automation.triggers.triggers ?? []
        case let .character(serverID, characterID): character(serverID: serverID, characterID: characterID)?.triggers.triggers ?? []
        case let .puppet(serverID, characterID, puppetID): puppet(serverID: serverID, characterID: characterID, puppetID: puppetID)?.triggers.triggers ?? []
        }
    }

    public func macros(in scope: AutomationScope) -> [KeyboardMacro] {
        switch scope {
        case .global: projection.automation.macros.macros
        case let .server(id): server(id)?.automation.macros.macros ?? []
        case let .character(serverID, characterID): character(serverID: serverID, characterID: characterID)?.macros.macros ?? []
        case let .puppet(serverID, characterID, puppetID): puppet(serverID: serverID, characterID: characterID, puppetID: puppetID)?.macros.macros ?? []
        }
    }

    public func variables(in scope: AutomationScope) throws -> [String: String] {
        let entries = document.unnamedBlockValues(at: try variableCollectionPath(scope))
        return Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            guard let name = entry.firstValue(caseInsensitiveKey: "Name"),
                  let value = entry.firstValue(caseInsensitiveKey: "Value") else { return nil }
            return (name, value)
        })
    }

    /// Adds or updates a v331 variable entry without rewriting neighbouring
    /// fields. An update therefore remains deterministic when an older host
    /// discarded the original entry before handoff.
    public mutating func setVariable(
        named name: String,
        value: String,
        in scope: AutomationScope
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.emptyName }
        let path = try variableCollectionPath(scope)
        let entries = document.unnamedBlockValues(at: path)
        let index: Int
        if let existing = entries.firstIndex(where: {
            $0.firstValue(caseInsensitiveKey: "Name")?.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            index = existing
        } else {
            index = try document.appendUnnamedBlock(at: path)
            try document.upsertValue(trimmed, inUnnamedBlockAt: index, collectionPath: path, relativePath: ["Name"])
        }
        try document.upsertValue(value, inUnnamedBlockAt: index, collectionPath: path, relativePath: ["Value"])
        try reloadProjectionAfterAutomationEdit()
    }

    @discardableResult
    public mutating func removeVariable(named name: String, in scope: AutomationScope) throws -> Bool {
        let path = try variableCollectionPath(scope)
        guard let index = document.unnamedBlockValues(at: path).firstIndex(where: {
            $0.firstValue(caseInsensitiveKey: "Name")?.caseInsensitiveCompare(name) == .orderedSame
        }) else { return false }
        let removed = try document.removeUnnamedBlock(at: index, collectionPath: path)
        try reloadProjectionAfterAutomationEdit()
        return removed
    }

    @discardableResult
    public mutating func addAlias(in scope: AutomationScope, description: String = "New Alias", match: MatchDefinition = .init(text: ""), replacement: String = "") throws -> Int {
        try addAutomationEntry(in: scope, kind: .aliases, description: description, match: match, replacement: replacement)
    }

    @discardableResult
    public mutating func addTrigger(in scope: AutomationScope, description: String = "New Trigger", match: MatchDefinition = .init(text: ""), action: EditableTriggerAction = .gag(display: true, log: false)) throws -> Int {
        try addAutomationEntry(in: scope, kind: .triggers, description: description, match: match, action: action)
    }

    @discardableResult
    public mutating func addTrigger(in scope: AutomationScope, trigger: Trigger) throws -> Int {
        let index = try addTrigger(in: scope, description: trigger.description, match: trigger.match)
        try updateTrigger(at: index, in: scope, trigger: trigger)
        return index
    }

    @discardableResult
    public mutating func addMacro(in scope: AutomationScope, description: String = "New Macro", key: String = "Control+Alt+M", macro: String = "", typeIntoInput: Bool = false) throws -> Int {
        try addAutomationEntry(in: scope, kind: .macros, description: description, key: key, macro: macro, typeIntoInput: typeIntoInput)
    }

    public mutating func updateAlias(at index: Int, in scope: AutomationScope, description: String, match: MatchDefinition, replacement: String) throws {
        try updateAutomationEntry(at: index, in: scope, kind: .aliases, description: description, match: match, replacement: replacement)
    }

    public mutating func updateTrigger(at index: Int, in scope: AutomationScope, description: String, match: MatchDefinition, action: EditableTriggerAction) throws {
        try updateAutomationEntry(at: index, in: scope, kind: .triggers, description: description, match: match, action: action)
    }

    public mutating func updateTrigger(at index: Int, in scope: AutomationScope, trigger: Trigger) throws {
        guard triggers(in: scope).indices.contains(index) else { throw WorkspaceError.automationEntryNotFound }
        let path = try automationCollectionPath(scope, kind: .triggers)
        try writeTrigger(trigger, at: index, collectionPath: path)
    }

    public mutating func updateMacro(at index: Int, in scope: AutomationScope, description: String, key: String, macro: String, typeIntoInput: Bool) throws {
        try updateAutomationEntry(at: index, in: scope, kind: .macros, description: description, key: key, macro: macro, typeIntoInput: typeIntoInput)
    }

    public mutating func removeAutomationEntry(at index: Int, in scope: AutomationScope, kind: AutomationKind) throws {
        let path = try automationCollectionPath(scope, kind: kind)
        let count = switch kind {
        case .aliases: aliases(in: scope).count
        case .triggers: triggers(in: scope).count
        case .macros: macros(in: scope).count
        }
        guard (0..<count).contains(index) else { throw WorkspaceError.automationEntryNotFound }
        _ = try document.removeUnnamedBlock(at: index, collectionPath: path)
        try reloadProjectionAfterAutomationEdit()
    }

    public enum AutomationKind: Sendable, Equatable { case aliases, triggers, macros }

    private func server(_ id: UUID) -> LegacyConfigurationProjection.Server? {
        projection.servers.first { $0.profile.id == id }
    }

    private func character(serverID: UUID, characterID: UUID) -> LegacyConfigurationProjection.Automation.Scope? {
        guard let server = server(serverID), let character = server.characters.first(where: { $0.id == characterID }) else { return nil }
        return server.automation.scope(for: character)
    }

    private func puppet(serverID: UUID, characterID: UUID, puppetID: UUID) -> LegacyConfigurationProjection.Automation.Scope? {
        guard let server = server(serverID), let character = server.characters.first(where: { $0.id == characterID }),
              let puppet = character.puppets.first(where: { $0.id == puppetID }) else { return nil }
        return server.automation.puppetScope(for: character, puppet: puppet)
    }

    private func automationCollectionPath(_ scope: AutomationScope, kind: AutomationKind) throws -> [String] {
        let collection: String = switch kind {
        case .aliases: "Aliases"
        case .triggers: "Triggers"
        case .macros: "KeyboardMacros2"
        }
        switch scope {
        case .global: return ["Connections", collection]
        case let .server(serverID):
            guard let server = server(serverID) else { throw WorkspaceError.serverNotFound }
            return ["Connections", "Shortcuts", server.profile.name, collection]
        case let .character(serverID, characterID):
            guard let server = server(serverID), let character = server.characters.first(where: { $0.id == characterID }) else {
                throw WorkspaceError.characterNotFound
            }
            return ["Connections", "Shortcuts", server.profile.name, "Characters", character.name, collection]
        case let .puppet(serverID, characterID, puppetID):
            guard let server = server(serverID), let character = server.characters.first(where: { $0.id == characterID }),
                  let puppet = character.puppets.first(where: { $0.id == puppetID }) else { throw WorkspaceError.puppetNotFound }
            return ["Connections", "Shortcuts", server.profile.name, "Characters", character.name, "Puppets", puppet.name, collection]
        }
    }

    private func variableCollectionPath(_ scope: AutomationScope) throws -> [String] {
        switch scope {
        case .global:
            return ["Connections", "Variables"]
        case let .server(serverID):
            guard let server = server(serverID) else { throw WorkspaceError.serverNotFound }
            // v331 has no Server.Variables property. Live variables belong to
            // Character and /set persists them there, so the compatible
            // representation of a world-scoped edit is the world's primary
            // character Variables collection.
            guard let character = server.characters.first else { throw WorkspaceError.characterNotFound }
            return [
                "Connections", "Shortcuts", server.profile.name,
                "Characters", character.name, "Variables",
            ]
        case let .character(serverID, characterID):
            guard let server = server(serverID),
                  let character = server.characters.first(where: { $0.id == characterID }) else {
                throw WorkspaceError.characterNotFound
            }
            return ["Connections", "Shortcuts", server.profile.name, "Characters", character.name, "Variables"]
        case let .puppet(serverID, characterID, puppetID):
            guard let server = server(serverID),
                  let character = server.characters.first(where: { $0.id == characterID }),
                  let puppet = character.puppets.first(where: { $0.id == puppetID }) else {
                throw WorkspaceError.puppetNotFound
            }
            return [
                "Connections", "Shortcuts", server.profile.name, "Characters", character.name,
                "Puppets", puppet.name, "Variables",
            ]
        }
    }

    private mutating func addAutomationEntry(
        in scope: AutomationScope,
        kind: AutomationKind,
        description: String,
        match: MatchDefinition,
        replacement: String
    ) throws -> Int {
        let path = try automationCollectionPath(scope, kind: kind)
        let index = aliases(in: scope).count
        if kind == .aliases {
            try document.upsertValue("true", at: path + ["Active"], quoted: false)
        }
        _ = try document.appendUnnamedBlock(at: path)
        try writeAlias(at: index, collectionPath: path, description: description, match: match, replacement: replacement)
        return index
    }

    private mutating func addAutomationEntry(
        in scope: AutomationScope,
        kind: AutomationKind,
        description: String,
        match: MatchDefinition,
        action: EditableTriggerAction
    ) throws -> Int {
        let path = try automationCollectionPath(scope, kind: kind)
        let index = triggers(in: scope).count
        if kind == .aliases {
            try document.upsertValue("true", at: path + ["Active"], quoted: false)
        }
        _ = try document.appendUnnamedBlock(at: path)
        try writeTrigger(at: index, collectionPath: path, description: description, match: match, action: action)
        return index
    }

    private mutating func addAutomationEntry(
        in scope: AutomationScope,
        kind: AutomationKind,
        description: String,
        key: String,
        macro: String,
        typeIntoInput: Bool
    ) throws -> Int {
        let path = try automationCollectionPath(scope, kind: kind)
        let index = macros(in: scope).count
        if kind == .aliases {
            try document.upsertValue("true", at: path + ["Active"], quoted: false)
        }
        _ = try document.appendUnnamedBlock(at: path)
        try writeMacro(at: index, collectionPath: path, description: description, key: key, macro: macro, typeIntoInput: typeIntoInput)
        return index
    }

    private mutating func updateAutomationEntry(
        at index: Int,
        in scope: AutomationScope,
        kind: AutomationKind,
        description: String,
        match: MatchDefinition,
        replacement: String
    ) throws {
        guard aliases(in: scope).indices.contains(index) else { throw WorkspaceError.automationEntryNotFound }
        let path = try automationCollectionPath(scope, kind: kind)
        try writeAlias(at: index, collectionPath: path, description: description, match: match, replacement: replacement)
    }

    private mutating func updateAutomationEntry(
        at index: Int,
        in scope: AutomationScope,
        kind: AutomationKind,
        description: String,
        match: MatchDefinition,
        action: EditableTriggerAction
    ) throws {
        guard triggers(in: scope).indices.contains(index) else { throw WorkspaceError.automationEntryNotFound }
        let path = try automationCollectionPath(scope, kind: kind)
        try writeTrigger(at: index, collectionPath: path, description: description, match: match, action: action)
    }

    private mutating func updateAutomationEntry(
        at index: Int,
        in scope: AutomationScope,
        kind: AutomationKind,
        description: String,
        key: String,
        macro: String,
        typeIntoInput: Bool
    ) throws {
        guard macros(in: scope).indices.contains(index) else { throw WorkspaceError.automationEntryNotFound }
        let path = try automationCollectionPath(scope, kind: kind)
        try writeMacro(at: index, collectionPath: path, description: description, key: key, macro: macro, typeIntoInput: typeIntoInput)
    }

    private mutating func writeAlias(at index: Int, collectionPath: [String], description: String, match: MatchDefinition, replacement: String) throws {
        try document.upsertValue(description, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Description"])
        try writeMatch(match, at: index, collectionPath: collectionPath)
        try document.upsertValue(replacement, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Replace"])
        try reloadProjectionAfterAutomationEdit()
    }

    private mutating func writeTrigger(at index: Int, collectionPath: [String], description: String, match: MatchDefinition, action: EditableTriggerAction) throws {
        try document.upsertValue(description, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Description"])
        try writeMatch(match, at: index, collectionPath: collectionPath)
        switch action {
        case let .gag(display, log):
            try document.upsertValue(Self.flag(display), inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Gag", "Active"], quoted: false)
            try document.upsertValue(Self.flag(log), inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Gag", "Log"], quoted: false)
            if document.value(
                inUnnamedBlockAt: index,
                collectionPath: collectionPath,
                relativePath: ["Send", "Active"]
            ) != nil {
                try document.upsertValue(
                    "false", inUnnamedBlockAt: index,
                    collectionPath: collectionPath,
                    relativePath: ["Send", "Active"], quoted: false
                )
            }
        case let .send(text):
            if document.value(
                inUnnamedBlockAt: index,
                collectionPath: collectionPath,
                relativePath: ["Gag", "Active"]
            ) != nil {
                try document.upsertValue(
                    "false", inUnnamedBlockAt: index,
                    collectionPath: collectionPath,
                    relativePath: ["Gag", "Active"], quoted: false
                )
            }
            try document.upsertValue("true", inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Send", "Active"], quoted: false)
            try document.upsertValue(text, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Send", "Send"])
        }
        try reloadProjectionAfterAutomationEdit()
    }

    private mutating func writeMacro(at index: Int, collectionPath: [String], description: String, key: String, macro: String, typeIntoInput: Bool) throws {
        try document.upsertValue(description, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Description"])
        try document.upsertValue(
            key, inUnnamedBlockAt: index, collectionPath: collectionPath,
            relativePath: ["key"], quoted: false
        )
        try document.upsertValue(macro, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Macro"])
        try document.upsertValue(Self.flag(typeIntoInput), inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Type"], quoted: false)
        try reloadProjectionAfterAutomationEdit()
    }

    /// Implements `/gag` as the same persisted global trigger used by the
    /// native trigger editor. Existing matches are re-enabled in place so a
    /// repeated command never creates duplicate gags.
    @discardableResult
    public mutating func addOrActivateGlobalGag(_ text: String) throws -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.emptyName }
        if let index = globalTriggers.firstIndex(where: {
            !$0.match.isRegularExpression && $0.match.text == trimmed
        }) {
            try document.upsertValue("true", inUnnamedBlockAt: index, collectionPath: ["Connections", "Triggers"], relativePath: ["Gag", "Active"], quoted: false)
            try reloadProjectionAfterAutomationEdit()
            return false
        }
        _ = try addGlobalTrigger(description: "Gag: \(trimmed)", match: .init(text: trimmed), action: .gag(display: true, log: false))
        return true
    }

    @discardableResult
    public mutating func addGlobalMacro(
        description: String = "",
        key: String = "Control+Alt+M",
        macro: String = "",
        typeIntoInput: Bool = false
    ) throws -> Int {
        let index = globalMacros.count
        try document.upsertValue("true", at: ["Connections", "KeyboardMacros2", "Active"], quoted: false)
        _ = try document.appendUnnamedBlock(at: ["Connections", "KeyboardMacros2"])
        try writeGlobalMacro(at: index, description: description, key: key, macro: macro, typeIntoInput: typeIntoInput)
        return index
    }

    public mutating func updateGlobalMacro(
        at index: Int,
        description: String,
        key: String,
        macro: String,
        typeIntoInput: Bool
    ) throws {
        guard globalMacros.indices.contains(index) else { throw WorkspaceError.automationEntryNotFound }
        try writeGlobalMacro(at: index, description: description, key: key, macro: macro, typeIntoInput: typeIntoInput)
    }

    public mutating func removeGlobalMacro(at index: Int) throws {
        guard globalMacros.indices.contains(index) else { throw WorkspaceError.automationEntryNotFound }
        _ = try document.removeUnnamedBlock(at: index, collectionPath: ["Connections", "KeyboardMacros2"])
        try reloadProjectionAfterAutomationEdit()
    }

    @discardableResult
    public mutating func addGlobalAlias(
        description: String = "",
        match: MatchDefinition = .init(text: ""),
        replacement: String = ""
    ) throws -> Int {
        let index = globalAliases.count
        try document.upsertValue("true", at: ["Connections", "Aliases", "Active"], quoted: false)
        _ = try document.appendUnnamedBlock(at: ["Connections", "Aliases"])
        try writeGlobalAlias(at: index, description: description, match: match, replacement: replacement)
        return index
    }

    public mutating func updateGlobalAlias(
        at index: Int,
        description: String,
        match: MatchDefinition,
        replacement: String
    ) throws {
        guard globalAliases.indices.contains(index) else { throw WorkspaceError.automationEntryNotFound }
        try writeGlobalAlias(at: index, description: description, match: match, replacement: replacement)
    }

    public mutating func removeGlobalAlias(at index: Int) throws {
        guard globalAliases.indices.contains(index) else { throw WorkspaceError.automationEntryNotFound }
        _ = try document.removeUnnamedBlock(at: index, collectionPath: ["Connections", "Aliases"])
        try reloadProjectionAfterAutomationEdit()
    }

    @discardableResult
    public mutating func addGlobalTrigger(
        description: String = "",
        match: MatchDefinition = .init(text: ""),
        action: EditableTriggerAction = .gag(display: true, log: false)
    ) throws -> Int {
        let index = globalTriggers.count
        try document.upsertValue("true", at: ["Connections", "Triggers", "Active"], quoted: false)
        _ = try document.appendUnnamedBlock(at: ["Connections", "Triggers"])
        try writeGlobalTrigger(at: index, description: description, match: match, action: action)
        return index
    }

    @discardableResult
    public mutating func addGlobalTrigger(_ trigger: Trigger) throws -> Int {
        let index = try addGlobalTrigger(description: trigger.description, match: trigger.match)
        try updateGlobalTrigger(at: index, trigger: trigger)
        return index
    }

    public mutating func updateGlobalTrigger(
        at index: Int,
        description: String,
        match: MatchDefinition,
        action: EditableTriggerAction
    ) throws {
        guard globalTriggers.indices.contains(index) else { throw WorkspaceError.automationEntryNotFound }
        try writeGlobalTrigger(at: index, description: description, match: match, action: action)
    }

    public mutating func updateGlobalTrigger(at index: Int, trigger: Trigger) throws {
        guard globalTriggers.indices.contains(index) else { throw WorkspaceError.automationEntryNotFound }
        try writeTrigger(trigger, at: index, collectionPath: ["Connections", "Triggers"])
    }

    public mutating func removeGlobalTrigger(at index: Int) throws {
        guard globalTriggers.indices.contains(index) else { throw WorkspaceError.automationEntryNotFound }
        _ = try document.removeUnnamedBlock(at: index, collectionPath: ["Connections", "Triggers"])
        try reloadProjectionAfterAutomationEdit()
    }

    @discardableResult
    public mutating func addServer(named requestedName: String = "New World") -> UUID {
        let name = Self.uniqueName(requestedName, among: projection.servers.map(\.profile.name))
        let profile = ServerProfile(name: name, host: "example.com", port: 8888)
        projection.servers.append(.init(profile: profile, characters: []))
        isDirty = true
        return profile.id
    }

    public mutating func updateServer(
        id: UUID,
        _ update: (inout LegacyConfigurationProjection.Server) -> Void
    ) throws {
        guard let index = projection.servers.firstIndex(where: { $0.profile.id == id }) else {
            throw WorkspaceError.serverNotFound
        }
        var candidate = projection.servers[index]
        update(&candidate)
        try Self.validate(
            candidate.profile.name,
            against: projection.servers.enumerated().filter { $0.offset != index }.map(\.element.profile.name)
        )
        candidate.profile.name = candidate.profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        projection.servers[index] = candidate
        isDirty = true
    }

    public mutating func removeServer(id: UUID) throws {
        guard let index = projection.servers.firstIndex(where: { $0.profile.id == id }) else {
            throw WorkspaceError.serverNotFound
        }
        projection.servers.remove(at: index)
        isDirty = true
    }

    @discardableResult
    public mutating func addCharacter(toServerID serverID: UUID, named requestedName: String = "New Character") throws -> UUID {
        guard let serverIndex = projection.servers.firstIndex(where: { $0.profile.id == serverID }) else {
            throw WorkspaceError.serverNotFound
        }
        let name = Self.uniqueName(requestedName, among: projection.servers[serverIndex].characters.map(\.name))
        let character = CharacterProfile(name: name)
        projection.servers[serverIndex].characters.append(character)
        isDirty = true
        return character.id
    }

    public mutating func updateCharacter(
        id: UUID,
        inServerID serverID: UUID,
        _ update: (inout CharacterProfile) -> Void
    ) throws {
        guard let serverIndex = projection.servers.firstIndex(where: { $0.profile.id == serverID }) else {
            throw WorkspaceError.serverNotFound
        }
        guard let characterIndex = projection.servers[serverIndex].characters.firstIndex(where: { $0.id == id }) else {
            throw WorkspaceError.characterNotFound
        }
        var candidate = projection.servers[serverIndex].characters[characterIndex]
        update(&candidate)
        try Self.validate(
            candidate.name,
            against: projection.servers[serverIndex].characters.enumerated()
                .filter { $0.offset != characterIndex }.map(\.element.name)
        )
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        projection.servers[serverIndex].characters[characterIndex] = candidate
        isDirty = true
    }

    public mutating func removeCharacter(id: UUID, fromServerID serverID: UUID) throws {
        guard let serverIndex = projection.servers.firstIndex(where: { $0.profile.id == serverID }) else {
            throw WorkspaceError.serverNotFound
        }
        guard let index = projection.servers[serverIndex].characters.firstIndex(where: { $0.id == id }) else {
            throw WorkspaceError.characterNotFound
        }
        projection.servers[serverIndex].characters.remove(at: index)
        isDirty = true
    }

    @discardableResult
    public mutating func addPuppet(
        toCharacterID characterID: UUID,
        inServerID serverID: UUID,
        named requestedName: String = "New Puppet"
    ) throws -> UUID {
        let location = try characterLocation(id: characterID, serverID: serverID)
        let names = projection.servers[location.server].characters[location.character].puppets.map(\.name)
        let name = Self.uniqueName(requestedName, among: names)
        let puppet = PuppetProfile(name: name)
        projection.servers[location.server].characters[location.character].puppets.append(puppet)
        isDirty = true
        return puppet.id
    }

    public mutating func updatePuppet(
        id: UUID,
        inCharacterID characterID: UUID,
        serverID: UUID,
        _ update: (inout PuppetProfile) -> Void
    ) throws {
        let location = try characterLocation(id: characterID, serverID: serverID)
        let puppets = projection.servers[location.server].characters[location.character].puppets
        guard let puppetIndex = puppets.firstIndex(where: { $0.id == id }) else {
            throw WorkspaceError.puppetNotFound
        }
        var candidate = puppets[puppetIndex]
        update(&candidate)
        try Self.validate(
            candidate.name,
            against: puppets.enumerated().filter { $0.offset != puppetIndex }.map(\.element.name)
        )
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        projection.servers[location.server].characters[location.character].puppets[puppetIndex] = candidate
        isDirty = true
    }

    public mutating func removePuppet(id: UUID, fromCharacterID characterID: UUID, serverID: UUID) throws {
        let location = try characterLocation(id: characterID, serverID: serverID)
        guard let index = projection.servers[location.server].characters[location.character].puppets
            .firstIndex(where: { $0.id == id }) else {
            throw WorkspaceError.puppetNotFound
        }
        projection.servers[location.server].characters[location.character].puppets.remove(at: index)
        isDirty = true
    }

    public mutating func updateSettings(
        _ update: (inout LegacyConfigurationProjection.ConnectionSettings) -> Void
    ) {
        update(&projection.settings)
        isDirty = true
    }

    public mutating func updateScripting(
        _ update: (inout LegacyConfigurationProjection.Scripting) -> Void
    ) {
        update(&projection.scripting)
        isDirty = true
    }

    public func renderedDocument() throws -> LegacyConfigurationDocument {
        try projection.applying(to: document)
    }

    public mutating func acceptSavedDocument(_ savedDocument: LegacyConfigurationDocument, at url: URL) {
        document = savedDocument
        sourceURL = url
        recoveredFrom = nil
        isDirty = false
    }

    private func characterLocation(id: UUID, serverID: UUID) throws -> (server: Int, character: Int) {
        guard let server = projection.servers.firstIndex(where: { $0.profile.id == serverID }) else {
            throw WorkspaceError.serverNotFound
        }
        guard let character = projection.servers[server].characters.firstIndex(where: { $0.id == id }) else {
            throw WorkspaceError.characterNotFound
        }
        return (server, character)
    }

    private mutating func writeGlobalAlias(
        at index: Int,
        description: String,
        match: MatchDefinition,
        replacement: String
    ) throws {
        let collection = ["Connections", "Aliases"]
        try document.upsertValue(description, inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Description"])
        try writeMatch(match, at: index, collectionPath: collection)
        try document.upsertValue(replacement, inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Replace"])
        try reloadProjectionAfterAutomationEdit()
    }

    private mutating func writeGlobalMacro(
        at index: Int,
        description: String,
        key: String,
        macro: String,
        typeIntoInput: Bool
    ) throws {
        let collection = ["Connections", "KeyboardMacros2"]
        try document.upsertValue(description, inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Description"])
        try document.upsertValue(
            key, inUnnamedBlockAt: index, collectionPath: collection,
            relativePath: ["key"], quoted: false
        )
        try document.upsertValue(macro, inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Macro"])
        try document.upsertValue(Self.flag(typeIntoInput), inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Type"], quoted: false)
        try reloadProjectionAfterAutomationEdit()
    }

    private mutating func writeGlobalTrigger(
        at index: Int,
        description: String,
        match: MatchDefinition,
        action: EditableTriggerAction
    ) throws {
        let collection = ["Connections", "Triggers"]
        try document.upsertValue(description, inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Description"])
        try writeMatch(match, at: index, collectionPath: collection)
        switch action {
        case let .gag(display, log):
            try document.upsertValue(Self.flag(display), inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Gag", "Active"], quoted: false)
            try document.upsertValue(Self.flag(log), inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Gag", "Log"], quoted: false)
            if document.value(
                inUnnamedBlockAt: index,
                collectionPath: collection,
                relativePath: ["Send", "Active"]
            ) != nil {
                try document.upsertValue(
                    "false", inUnnamedBlockAt: index,
                    collectionPath: collection,
                    relativePath: ["Send", "Active"], quoted: false
                )
            }
        case let .send(text):
            if document.value(
                inUnnamedBlockAt: index,
                collectionPath: collection,
                relativePath: ["Gag", "Active"]
            ) != nil {
                try document.upsertValue(
                    "false", inUnnamedBlockAt: index,
                    collectionPath: collection,
                    relativePath: ["Gag", "Active"], quoted: false
                )
            }
            try document.upsertValue("true", inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Send", "Active"], quoted: false)
            try document.upsertValue(text, inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Send", "Send"])
        }
        try reloadProjectionAfterAutomationEdit()
    }

    private mutating func writeTrigger(_ trigger: Trigger, at index: Int, collectionPath: [String]) throws {
        try document.upsertValue(trigger.description, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Description"])
        try writeMatch(trigger.match, at: index, collectionPath: collectionPath)
        try writeFlag(trigger.disabled, at: index, collectionPath: collectionPath, path: ["Disabled"])
        try writeFlag(trigger.stopProcessing, at: index, collectionPath: collectionPath, path: ["StopProcessing"])
        try writeFlag(trigger.oncePerLine, at: index, collectionPath: collectionPath, path: ["OncePerLine"])
        try writeFlag(trigger.awayPresent, at: index, collectionPath: collectionPath, path: ["AwayPresent"])
        try writeFlag(trigger.awayPresentOnce, at: index, collectionPath: collectionPath, path: ["AwayPresentOnce"])
        try writeFlag(trigger.away, at: index, collectionPath: collectionPath, path: ["Away"])
        try writeFlag(trigger.cooldown != nil, at: index, collectionPath: collectionPath, path: ["Cooldown"])
        try writeValueIfNeeded(Self.time(trigger.cooldown ?? 0), at: index, collectionPath: collectionPath, path: ["CooldownTime"], when: trigger.cooldown != nil)
        try writeFlag(trigger.multiline?.isEnabled == true, at: index, collectionPath: collectionPath, path: ["Multiline"])
        try writeValueIfNeeded(String(trigger.multiline?.lineLimit ?? 0), at: index, collectionPath: collectionPath, path: ["Multiline_Limit"], quoted: false, when: trigger.multiline?.isEnabled == true)
        try writeValueIfNeeded(Self.time(trigger.multiline?.timeLimit ?? 0), at: index, collectionPath: collectionPath, path: ["Multiline_Time"], when: trigger.multiline?.isEnabled == true)
        try writeFlag(trigger.childrenActive, at: index, collectionPath: collectionPath, path: ["Triggers", "Active"])

        let color = trigger.actions.firstColor
        let colorDefault = trigger.actions.firstColorDefault
        let colorHash = trigger.actions.firstColorHash
        let font = trigger.actions.firstFont
        let colorWholeLine = color?.wholeLine ?? colorDefault?.wholeLine ?? colorHash?.wholeLine ?? font?.wholeLine ?? false
        try writeFlag(color?.foreground != nil, at: index, collectionPath: collectionPath, path: ["Color", "UseForeColor"])
        try writeValueIfNeeded(color?.foreground.map(Self.colorString) ?? "#FFFFFF", at: index, collectionPath: collectionPath, path: ["Color", "Fore"], when: color?.foreground != nil)
        try writeFlag(color?.background != nil, at: index, collectionPath: collectionPath, path: ["Color", "UseBackColor"])
        try writeValueIfNeeded(color?.background.map(Self.colorString) ?? "#000000", at: index, collectionPath: collectionPath, path: ["Color", "Back"], when: color?.background != nil)
        try writeFlag(colorDefault?.foreground == true, at: index, collectionPath: collectionPath, path: ["Color", "ForeDefault"])
        try writeFlag(colorDefault?.background == true, at: index, collectionPath: collectionPath, path: ["Color", "BackDefault"])
        try writeFlag(colorHash?.foreground == true, at: index, collectionPath: collectionPath, path: ["Color", "ForeHash"])
        try writeFlag(colorHash?.background == true, at: index, collectionPath: collectionPath, path: ["Color", "BackHash"])
        try writeFlag(font != nil, at: index, collectionPath: collectionPath, path: ["Color", "UseFont"])
        try writeFlag(font?.useDefault == true, at: index, collectionPath: collectionPath, path: ["Color", "FontDefault"])
        try writeValueIfNeeded(font?.face ?? "", at: index, collectionPath: collectionPath, path: ["Color", "FontFace"], when: font != nil)
        try writeValueIfNeeded(Self.time(font?.size ?? 0), at: index, collectionPath: collectionPath, path: ["Color", "FontSize"], when: font != nil)
        try writeFlag(colorWholeLine, at: index, collectionPath: collectionPath, path: ["Color", "WholeLine"])

        let appearance = trigger.actions.firstAppearance
        let patch = appearance?.patch ?? TextStylePatch()
        try writeOptionalStyle(patch.bold, setPath: ["Style", "SetBold"], valuePath: ["Style", "Bold"], at: index, collectionPath: collectionPath)
        try writeOptionalStyle(patch.italic, setPath: ["Style", "SetItalic"], valuePath: ["Style", "Italic"], at: index, collectionPath: collectionPath)
        try writeOptionalStyle(patch.underline, setPath: ["Style", "SetUnderline"], valuePath: ["Style", "Underline"], at: index, collectionPath: collectionPath)
        try writeOptionalStyle(patch.strikeout, setPath: ["Style", "SetStrikeout"], valuePath: ["Style", "Strikeout"], at: index, collectionPath: collectionPath)
        try writeFlag(patch.blink != nil, at: index, collectionPath: collectionPath, path: ["Style", "Flash"])
        try writeFlag(patch.blink == .fast, at: index, collectionPath: collectionPath, path: ["Style", "FlashFast"])
        try writeFlag(appearance?.wholeLine == true, at: index, collectionPath: collectionPath, path: ["Style", "WholeLine"])

        let paragraph = trigger.actions.firstParagraph
        try writeParagraph(paragraph, at: index, collectionPath: collectionPath)

        let gag = trigger.actions.firstGag
        try writeFlag(gag?.display == true, at: index, collectionPath: collectionPath, path: ["Gag", "Active"])
        try writeFlag(gag?.log == true, at: index, collectionPath: collectionPath, path: ["Gag", "Log"])

        let activate = trigger.actions.contains(.activateWindow)
        let important = trigger.actions.contains(.activity(important: true))
        let activity = trigger.actions.contains(.activity(important: false))
        let suppressActivity = trigger.actions.contains(.suppressActivity)
        try writeFlag(activate || important || activity || suppressActivity, at: index, collectionPath: collectionPath, path: ["Activate", "Active"])
        try writeFlag(important, at: index, collectionPath: collectionPath, path: ["Activate", "ImportantActivity"])
        try writeFlag(activity, at: index, collectionPath: collectionPath, path: ["Activate", "Activity"])
        try writeFlag(suppressActivity, at: index, collectionPath: collectionPath, path: ["Activate", "NoActivity"])

        let spawn = trigger.actions.firstSpawn
        try writeFlag(spawn != nil, at: index, collectionPath: collectionPath, path: ["Spawn", "Active"])
        try writeValueIfNeeded(spawn?.title ?? "", at: index, collectionPath: collectionPath, path: ["Spawn", "Title"], when: spawn != nil)
        try writeValueIfNeeded(spawn?.tabGroup ?? "", at: index, collectionPath: collectionPath, path: ["Spawn", "TabGroup"], when: spawn != nil)
        try writeValueIfNeeded(spawn?.captureUntil ?? "", at: index, collectionPath: collectionPath, path: ["Spawn", "CaptureUntil"], when: spawn != nil)
        try writeFlag(spawn?.onlyChildrenDuringCapture == true, at: index, collectionPath: collectionPath, path: ["Spawn", "OnlyChildrenDuringCapture"])
        try writeFlag(spawn?.clear == true, at: index, collectionPath: collectionPath, path: ["Spawn", "Clear"])
        try writeFlag(spawn?.showTab == true, at: index, collectionPath: collectionPath, path: ["Spawn", "ShowTab"])
        try writeFlag(spawn?.gagLog == true, at: index, collectionPath: collectionPath, path: ["Spawn", "GagLog"])
        try writeFlag(spawn?.copy == true, at: index, collectionPath: collectionPath, path: ["Spawn", "Copy"])

        let stat = trigger.actions.firstStat
        try writeValueIfNeeded(stat?.prefix ?? "", at: index, collectionPath: collectionPath, path: ["Stat", "Prefix"], when: stat != nil)
        try writeValueIfNeeded(stat?.title ?? "", at: index, collectionPath: collectionPath, path: ["Stat", "Title"], when: stat != nil)
        try writeValueIfNeeded(stat?.name ?? "", at: index, collectionPath: collectionPath, path: ["Stat", "Name"], when: stat != nil || triggerValueExists(at: index, collectionPath: collectionPath, path: ["Stat", "Name"]))
        try writeValueIfNeeded(stat?.value ?? "", at: index, collectionPath: collectionPath, path: ["Stat", "Value"], when: stat != nil)
        try writeValueIfNeeded(Self.statType(stat?.kind ?? .integer), at: index, collectionPath: collectionPath, path: ["Stat", "Type"], quoted: false, when: stat != nil)
        try writeValueIfNeeded(Self.alignmentValue(stat?.nameAlignment ?? .center), at: index, collectionPath: collectionPath, path: ["Stat", "NameAlignment"], quoted: false, when: stat != nil)
        try writeFlag(stat?.color != nil, at: index, collectionPath: collectionPath, path: ["Stat", "UseColor"])
        try writeValueIfNeeded(stat?.color.map(Self.colorString) ?? "#FFFFFF", at: index, collectionPath: collectionPath, path: ["Stat", "Color"], when: stat?.color != nil)
        try writeFlag(stat?.addsToExistingInteger == true, at: index, collectionPath: collectionPath, path: ["Stat", "Int", "Add"])
        try writeValueIfNeeded(stat?.lower ?? "", at: index, collectionPath: collectionPath, path: ["Stat", "Range", "Lower"], when: stat != nil)
        try writeValueIfNeeded(stat?.upper ?? "", at: index, collectionPath: collectionPath, path: ["Stat", "Range", "Upper"], when: stat != nil)
        try writeValueIfNeeded(stat?.rangeColor.map(Self.colorString) ?? "#FFFFFF", at: index, collectionPath: collectionPath, path: ["Stat", "Range", "Color"], when: stat?.rangeColor != nil)
        try writeFlag(stat?.font != nil, at: index, collectionPath: collectionPath, path: ["Stat", "UseFont"])
        try writeValueIfNeeded(stat?.font?.name ?? "Courier New", at: index, collectionPath: collectionPath, path: ["Stat", "Font", "Name"], when: stat?.font != nil)
        try writeValueIfNeeded(Self.time(stat?.font?.size ?? 13), at: index, collectionPath: collectionPath, path: ["Stat", "Font", "Size"], when: stat?.font != nil)
        try writeFlag(stat?.font?.bold == true, at: index, collectionPath: collectionPath, path: ["Stat", "Font", "Bold"])
        try writeFlag(stat?.font?.italic == true, at: index, collectionPath: collectionPath, path: ["Stat", "Font", "Italic"])
        try writeFlag(stat?.font?.underline == true, at: index, collectionPath: collectionPath, path: ["Stat", "Font", "Underline"])
        try writeFlag(stat?.font?.strikeout == true, at: index, collectionPath: collectionPath, path: ["Stat", "Font", "Strikeout"])

        let sound = trigger.actions.firstSound
        try writeFlag(sound != nil, at: index, collectionPath: collectionPath, path: ["Sound", "Active"])
        try writeValueIfNeeded(sound ?? "", at: index, collectionPath: collectionPath, path: ["Sound", "Sound"], when: sound != nil)

        let speech = trigger.actions.firstSpeech
        try writeFlag(speech != nil, at: index, collectionPath: collectionPath, path: ["Speech", "Active"])
        try writeValueIfNeeded(speech?.text ?? "", at: index, collectionPath: collectionPath, path: ["Speech", "Say"], when: speech != nil)
        try writeFlag(speech?.wholeLine == true, at: index, collectionPath: collectionPath, path: ["Speech", "WholeLine"])

        let send = trigger.actions.firstSend
        try writeFlag(send != nil, at: index, collectionPath: collectionPath, path: ["Send", "Active"])
        try writeValueIfNeeded(send?.text ?? "", at: index, collectionPath: collectionPath, path: ["Send", "Send"], when: send != nil)
        try writeValueIfNeeded(String(send?.captureIndex ?? 1), at: index, collectionPath: collectionPath, path: ["Send", "CaptureIndex"], quoted: false, when: send != nil)
        try writeFlag(send?.expandVariables == true, at: index, collectionPath: collectionPath, path: ["Send", "ExpandVariables"])
        try writeFlag(send?.sendOnClick == true, at: index, collectionPath: collectionPath, path: ["Send", "SendOnClick"])

        try writeFlag(trigger.actions.contains(.notification), at: index, collectionPath: collectionPath, path: ["Toast", "Active"])

        let filter = trigger.actions.firstFilter
        try writeFlag(filter != nil, at: index, collectionPath: collectionPath, path: ["Filter", "Active"])
        try writeFlag(filter?.html == true, at: index, collectionPath: collectionPath, path: ["Filter", "HTML"])
        try writeFlag(filter?.expandVariables == true, at: index, collectionPath: collectionPath, path: ["Filter", "ExpandVariables"])
        try writeValueIfNeeded(filter?.text ?? "", at: index, collectionPath: collectionPath, path: ["Filter", "Replace"], when: filter != nil)

        let avatar = trigger.actions.firstAvatar
        try writeValueIfNeeded(avatar ?? "", at: index, collectionPath: collectionPath, path: ["Avatar", "URL"], when: avatar != nil || triggerValueExists(at: index, collectionPath: collectionPath, path: ["Avatar", "URL"]))

        let script = trigger.actions.firstScript
        try writeFlag(script != nil, at: index, collectionPath: collectionPath, path: ["Script", "Active"])
        try writeValueIfNeeded(script ?? "", at: index, collectionPath: collectionPath, path: ["Script", "Function"], when: script != nil)
        try reloadProjectionAfterAutomationEdit()
    }

    private mutating func writeMatch(
        _ match: MatchDefinition,
        at index: Int,
        collectionPath: [String]
    ) throws {
        let options: [(String, Bool)] = [
            ("RegularExpression", match.isRegularExpression),
            ("MatchCase", match.matchCase),
            ("StartsWith", match.startsWith),
            ("EndsWith", match.endsWith),
            ("WholeWord", match.wholeWord),
        ]
        try document.upsertValue(match.text, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["FindString", "MatchText"])
        for (name, value) in options
            where value || document.value(
                inUnnamedBlockAt: index,
                collectionPath: collectionPath,
                relativePath: ["FindString", name]
            ) != nil {
            try document.upsertValue(
                Self.flag(value), inUnnamedBlockAt: index,
                collectionPath: collectionPath,
                relativePath: ["FindString", name], quoted: false
            )
        }
    }

    private mutating func reloadProjectionAfterAutomationEdit() throws {
        projection = try LegacyConfigurationProjection(document: document)
        isDirty = true
    }

    private static func flag(_ value: Bool) -> String { value ? "true" : "false" }

    private mutating func writeFlag(
        _ value: Bool,
        at index: Int,
        collectionPath: [String],
        path: [String]
    ) throws {
        guard value || triggerValueExists(at: index, collectionPath: collectionPath, path: path) else { return }
        try document.upsertValue(Self.flag(value), inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: path, quoted: false)
    }

    private mutating func writeValueIfNeeded(
        _ value: String,
        at index: Int,
        collectionPath: [String],
        path: [String],
        quoted: Bool = true,
        when shouldWrite: Bool
    ) throws {
        guard shouldWrite || triggerValueExists(at: index, collectionPath: collectionPath, path: path) else { return }
        try document.upsertValue(value, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: path, quoted: quoted)
    }

    private mutating func writeOptionalStyle(
        _ value: Bool?,
        setPath: [String],
        valuePath: [String],
        at index: Int,
        collectionPath: [String]
    ) throws {
        try writeFlag(value != nil, at: index, collectionPath: collectionPath, path: setPath)
        try writeFlag(value == true, at: index, collectionPath: collectionPath, path: valuePath)
    }

    private mutating func writeParagraph(
        _ paragraph: ParagraphPatch?,
        at index: Int,
        collectionPath: [String]
    ) throws {
        try writeFlag(paragraph?.alignment != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseAlignment"])
        try writeValueIfNeeded(Self.alignmentValue(paragraph?.alignment ?? .left), at: index, collectionPath: collectionPath, path: ["Paragraph", "Alignment"], quoted: false, when: paragraph?.alignment != nil)
        try writeFlag(paragraph?.leftIndent != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseIndent_Left"])
        try writeValueIfNeeded(Self.time(paragraph?.leftIndent ?? 0), at: index, collectionPath: collectionPath, path: ["Paragraph", "Indent_Left"], when: paragraph?.leftIndent != nil)
        try writeFlag(paragraph?.rightIndent != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseIndent_Right"])
        try writeValueIfNeeded(Self.time(paragraph?.rightIndent ?? 0), at: index, collectionPath: collectionPath, path: ["Paragraph", "Indent_Right"], when: paragraph?.rightIndent != nil)
        try writeFlag(paragraph?.topPadding != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UsePadding_Top"])
        try writeValueIfNeeded(Self.time(paragraph?.topPadding ?? 0), at: index, collectionPath: collectionPath, path: ["Paragraph", "Padding_Top"], when: paragraph?.topPadding != nil)
        try writeFlag(paragraph?.bottomPadding != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UsePadding_Bottom"])
        try writeValueIfNeeded(Self.time(paragraph?.bottomPadding ?? 0), at: index, collectionPath: collectionPath, path: ["Paragraph", "Padding_Bottom"], when: paragraph?.bottomPadding != nil)
        try writeFlag(paragraph?.background != nil || paragraph?.backgroundHash == true, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseBackgroundColor"])
        try writeValueIfNeeded(paragraph?.background.map(Self.colorString) ?? "#000000", at: index, collectionPath: collectionPath, path: ["Paragraph", "Background"], when: paragraph?.background != nil)
        try writeFlag(paragraph?.backgroundHash == true, at: index, collectionPath: collectionPath, path: ["Paragraph", "BackgroundHash"])
        try writeFlag(paragraph?.borderWidth != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseBorder"])
        try writeValueIfNeeded(Self.time(paragraph?.borderWidth ?? 0), at: index, collectionPath: collectionPath, path: ["Paragraph", "Border"], when: paragraph?.borderWidth != nil)
        try writeFlag(paragraph?.borderStyle != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseBorderStyle"])
        try writeValueIfNeeded(paragraph?.borderStyle == .round ? "1" : "0", at: index, collectionPath: collectionPath, path: ["Paragraph", "BorderStyle"], quoted: false, when: paragraph?.borderStyle != nil)
        try writeFlag(paragraph?.strokeWidth != nil || paragraph?.strokeColor != nil || paragraph?.strokeHash == true || paragraph?.strokeStyle != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseStroke"])
        try writeValueIfNeeded(Self.time(paragraph?.strokeWidth ?? 0), at: index, collectionPath: collectionPath, path: ["Paragraph", "StrokeWidth"], when: paragraph?.strokeWidth != nil)
        try writeValueIfNeeded(paragraph?.strokeColor.map(Self.colorString) ?? "#FFFFFF", at: index, collectionPath: collectionPath, path: ["Paragraph", "Stroke"], when: paragraph?.strokeColor != nil)
        try writeFlag(paragraph?.strokeHash == true, at: index, collectionPath: collectionPath, path: ["Paragraph", "StrokeHash"])
        try writeValueIfNeeded(Self.strokeStyleValue(paragraph?.strokeStyle ?? .outline), at: index, collectionPath: collectionPath, path: ["Paragraph", "StrokeStyle"], quoted: false, when: paragraph?.strokeStyle != nil)
        try writeFlag(paragraph?.horizontalRule == true, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseHorizontalRule"])
    }

    private func triggerValueExists(at index: Int, collectionPath: [String], path: [String]) -> Bool {
        document.value(inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: path) != nil
    }

    private static func colorString(_ color: RGBColor) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }

    private static func time(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func statType(_ kind: TriggerStatKind) -> String {
        switch kind {
        case .integer: "0"
        case .string: "1"
        case .range: "2"
        }
    }

    private static func alignmentValue(_ alignment: ParagraphStyle.Alignment) -> String {
        switch alignment {
        case .left: "0"
        case .center: "1"
        case .right: "2"
        }
    }

    private static func strokeStyleValue(_ style: ParagraphStyle.StrokeStyle) -> String {
        switch style {
        case .outline: "0"
        case .top: "1"
        case .bottom: "2"
        }
    }

    private static func validate(_ name: String, against names: [String]) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.emptyName }
        guard !names.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            throw WorkspaceError.duplicateName(trimmed)
        }
    }

    private static func uniqueName(_ requestedName: String, among names: [String]) -> String {
        let base = requestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled"
            : requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = Set(names.map { $0.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }
}

private extension Dictionary where Key == String {
    func firstValue(caseInsensitiveKey key: String) -> Value? {
        first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

private extension Array where Element == TriggerAction {
    var firstColor: (foreground: RGBColor?, background: RGBColor?, wholeLine: Bool)? {
        for action in self {
            if case let .color(foreground, background, wholeLine) = action {
                return (foreground, background, wholeLine)
            }
        }
        return nil
    }

    var firstColorDefault: (foreground: Bool, background: Bool, wholeLine: Bool)? {
        for action in self {
            if case let .colorDefault(foreground, background, wholeLine) = action {
                return (foreground, background, wholeLine)
            }
        }
        return nil
    }

    var firstColorHash: (foreground: Bool, background: Bool, wholeLine: Bool)? {
        for action in self {
            if case let .colorHash(foreground, background, wholeLine) = action {
                return (foreground, background, wholeLine)
            }
        }
        return nil
    }

    var firstFont: (face: String, size: Double, useDefault: Bool, wholeLine: Bool)? {
        for action in self {
            if case let .font(face, size, useDefault, wholeLine) = action {
                return (face, size, useDefault, wholeLine)
            }
        }
        return nil
    }

    var firstAppearance: (patch: TextStylePatch, wholeLine: Bool)? {
        for action in self {
            if case let .appearance(patch, wholeLine) = action {
                return (patch, wholeLine)
            }
        }
        return nil
    }

    var firstParagraph: ParagraphPatch? {
        compactMap {
            if case let .paragraph(patch) = $0 { return patch }
            return nil
        }.first
    }

    var firstGag: (display: Bool, log: Bool)? {
        for action in self {
            if case let .gag(display, log) = action { return (display, log) }
        }
        return nil
    }

    var firstSpawn: TriggerSpawnAction? {
        compactMap {
            if case let .spawn(action) = $0 { return action }
            return nil
        }.first
    }

    var firstStat: TriggerStatAction? {
        compactMap {
            if case let .stat(action) = $0 { return action }
            return nil
        }.first
    }

    var firstSound: String? {
        compactMap {
            if case let .sound(path) = $0 { return path }
            return nil
        }.first
    }

    var firstSpeech: (text: String, wholeLine: Bool)? {
        for action in self {
            if case let .speech(text, wholeLine) = action { return (text, wholeLine) }
        }
        return nil
    }

    var firstSend: (text: String, captureIndex: Int, expandVariables: Bool, sendOnClick: Bool)? {
        for action in self {
            if case let .send(text, captureIndex, expandVariables, sendOnClick) = action {
                return (text, captureIndex, expandVariables, sendOnClick)
            }
        }
        return nil
    }

    var firstFilter: (text: String, html: Bool, expandVariables: Bool)? {
        for action in self {
            switch action {
            case let .replace(text, expandVariables):
                return (text, false, expandVariables)
            case let .replaceHTML(text, expandVariables):
                return (text, true, expandVariables)
            default:
                break
            }
        }
        return nil
    }

    var firstAvatar: String? {
        compactMap {
            if case let .avatar(url) = $0 { return url }
            return nil
        }.first
    }

    var firstScript: String? {
        compactMap {
            if case let .script(function) = $0 { return function }
            return nil
        }.first
    }
}
