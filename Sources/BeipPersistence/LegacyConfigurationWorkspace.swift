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

    @discardableResult
    public mutating func addAlias(in scope: AutomationScope, description: String = "New Alias", match: MatchDefinition = .init(text: ""), replacement: String = "") throws -> Int {
        try addAutomationEntry(in: scope, kind: .aliases, description: description, match: match, replacement: replacement)
    }

    @discardableResult
    public mutating func addTrigger(in scope: AutomationScope, description: String = "New Trigger", match: MatchDefinition = .init(text: ""), action: EditableTriggerAction = .gag(display: true, log: false)) throws -> Int {
        try addAutomationEntry(in: scope, kind: .triggers, description: description, match: match, action: action)
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

    public enum AutomationKind: Sendable { case aliases, triggers, macros }

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

    private mutating func addAutomationEntry(
        in scope: AutomationScope,
        kind: AutomationKind,
        description: String,
        match: MatchDefinition,
        replacement: String
    ) throws -> Int {
        let path = try automationCollectionPath(scope, kind: kind)
        let index = aliases(in: scope).count
        try document.upsertValue("true", at: path + ["Active"], quoted: false)
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
        try document.upsertValue("true", at: path + ["Active"], quoted: false)
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
        try document.upsertValue("true", at: path + ["Active"], quoted: false)
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
            try document.upsertValue("false", inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Send", "Active"], quoted: false)
        case let .send(text):
            try document.upsertValue("false", inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Gag", "Active"], quoted: false)
            try document.upsertValue("true", inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Send", "Active"], quoted: false)
            try document.upsertValue(text, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Send", "Send"])
        }
        try reloadProjectionAfterAutomationEdit()
    }

    private mutating func writeMacro(at index: Int, collectionPath: [String], description: String, key: String, macro: String, typeIntoInput: Bool) throws {
        try document.upsertValue(description, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["Description"])
        try document.upsertValue(key, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["key"])
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

    public mutating func updateGlobalTrigger(
        at index: Int,
        description: String,
        match: MatchDefinition,
        action: EditableTriggerAction
    ) throws {
        guard globalTriggers.indices.contains(index) else { throw WorkspaceError.automationEntryNotFound }
        try writeGlobalTrigger(at: index, description: description, match: match, action: action)
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
        try document.upsertValue(key, inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["key"])
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
            try document.upsertValue("false", inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Send", "Active"], quoted: false)
        case let .send(text):
            try document.upsertValue("false", inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Gag", "Active"], quoted: false)
            try document.upsertValue("true", inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Send", "Active"], quoted: false)
            try document.upsertValue(text, inUnnamedBlockAt: index, collectionPath: collection, relativePath: ["Send", "Send"])
        }
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
        for (name, value) in options {
            try document.upsertValue(Self.flag(value), inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: ["FindString", name], quoted: false)
        }
    }

    private mutating func reloadProjectionAfterAutomationEdit() throws {
        projection = try LegacyConfigurationProjection(document: document)
        isDirty = true
    }

    private static func flag(_ value: Bool) -> String { value ? "true" : "false" }

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
