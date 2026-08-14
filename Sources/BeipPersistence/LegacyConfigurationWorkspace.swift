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

    public enum ProfileEntrySelection: Sendable, Equatable {
        case world(UUID)
        case character(world: UUID, character: UUID)
        case puppet(world: UUID, character: UUID, puppet: UUID)
    }

    public struct AutomationItemPath: Sendable, Equatable {
        public var scope: AutomationScope
        public var path: [Int]

        public init(scope: AutomationScope, path: [Int]) {
            self.scope = scope
            self.path = path
        }
    }

    public enum AutomationEntrySelection: Sendable, Equatable {
        case scope(AutomationScope)
        case item(AutomationItemPath)
    }

    public enum AutomationImportDestination: Sendable, Equatable {
        case scope(AutomationScope)
        case folder(AutomationItemPath)
        case afterItem(AutomationItemPath)
    }

    public struct AutomationImportResult: Sendable, Equatable {
        public var scope: AutomationScope
        public var paths: [[Int]]

        public init(scope: AutomationScope, paths: [[Int]]) {
            self.scope = scope
            self.paths = paths
        }
    }

    public struct ProfileMergeResult: Sendable, Equatable {
        public var worldID: UUID
        public var characterIDs: [UUID]
        public var puppetIDs: [UUID]

        public init(worldID: UUID, characterIDs: [UUID], puppetIDs: [UUID]) {
            self.worldID = worldID
            self.characterIDs = characterIDs
            self.puppetIDs = puppetIDs
        }
    }

    public enum WorkspaceError: LocalizedError, Equatable {
        case serverNotFound
        case characterNotFound
        case puppetNotFound
        case automationEntryNotFound
        case emptyName
        case duplicateName(String)
        case macroTextTooLong
        case wrongAutomationCategory(expected: AutomationKind)
        case multipleContextualScopes
        case multipleWorlds
        case noProfilesFound

        public var errorDescription: String? {
            switch self {
            case .serverNotFound: "The selected world no longer exists."
            case .characterNotFound: "The selected character no longer exists."
            case .puppetNotFound: "The selected puppet no longer exists."
            case .automationEntryNotFound: "The selected automation entry no longer exists."
            case .emptyName: "Names cannot be empty."
            case let .duplicateName(name): "“\(name)” is already in use at this level."
            case .macroTextTooLong: "Macro Text cannot exceed 65,536 characters."
            case let .wrongAutomationCategory(expected):
                "The selected file does not contain \(expected.displayName.lowercased())."
            case .multipleContextualScopes:
                "The selected file contains automation from more than one world, character, or puppet scope."
            case .multipleWorlds:
                "Profile imports must contain exactly one world."
            case .noProfilesFound:
                "The selected file does not contain a world profile."
            }
        }
    }

    public private(set) var document: LegacyConfigurationDocument
    public private(set) var projection: LegacyConfigurationProjection
    public private(set) var sourceURL: URL?
    public private(set) var recoveredFrom: URL?
    public private(set) var isDirty: Bool

    // Config.txt has no persisted UUID for scopes. Keep the projection's
    // generated identities stable while lossless edits reparse the document;
    // editor selections and AutomationScope values can therefore survive an
    // alias/trigger write.
    private var stableServerIDs: [String: UUID]
    private var stableCharacterIDs: [String: UUID]
    private var stablePuppetIDs: [String: UUID]

    public init(
        document: LegacyConfigurationDocument,
        sourceURL: URL? = nil,
        recoveredFrom: URL? = nil,
        isDirty: Bool = false
    ) throws {
        let projected = try LegacyConfigurationProjection(document: document)
        self.document = document
        self.projection = projected
        self.sourceURL = sourceURL
        self.recoveredFrom = recoveredFrom
        self.isDirty = isDirty
        self.stableServerIDs = Self.serverIDs(in: projected)
        self.stableCharacterIDs = Self.characterIDs(in: projected)
        self.stablePuppetIDs = Self.puppetIDs(in: projected)
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
    public var taskbarOnTop: Bool { projection.taskbarOnTop }

    /// Distinguishes an absent root assignment from an invalid one. This is
    /// needed only by the one-time Mac preference migration; projection
    /// consumers should use `taskbarOnTop`, whose invalid/missing default is
    /// the portable top placement.
    public var hasRootTaskbarOnTopAssignment: Bool {
        document.assignmentValues(at: []).contains {
            $0.name.caseInsensitiveCompare("TaskbarOnTop") == .orderedSame
        }
    }

    /// Updates the portable menu strip placement. The syntax tree is rendered
    /// from the projection on save, so this keeps the edit lossless and marks
    /// the workspace dirty just like the other projection-backed settings.
    public mutating func setTaskbarOnTop(_ value: Bool) {
        projection.taskbarOnTop = value
        isDirty = true
    }

    /// Updates the lossless Config.txt projection for the global Restore Logs
    /// controls. The size is normalized here as well as in the UI so callers
    /// outside Settings cannot persist an invalid capacity.
    public mutating func setRestoreLogSettings(enabled: Bool, perCharacterBytes: Int) {
        projection.logging.restoreLogs = enabled
        projection.logging.restoreBufferSize = SessionLogOptions.normalizedRestoreBufferSize(perCharacterBytes)
        isDirty = true
    }

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

    /// Returns the complete alias collection for a scope, including its
    /// Windows Active/Echo/ProcessCommands and pre/post ordering settings.
    public func aliasGroup(in scope: AutomationScope) -> AliasGroup {
        switch scope {
        case .global: projection.automation.aliases
        case let .server(id): server(id)?.automation.aliases ?? .init()
        case let .character(serverID, characterID): character(serverID: serverID, characterID: characterID)?.aliases ?? .init()
        case let .puppet(serverID, characterID, puppetID): puppet(serverID: serverID, characterID: characterID, puppetID: puppetID)?.aliases ?? .init()
        }
    }

    public func alias(at path: [Int], in scope: AutomationScope) -> Alias? {
        Self.alias(at: path, in: aliases(in: scope))
    }

    public func triggers(in scope: AutomationScope) -> [Trigger] {
        switch scope {
        case .global: projection.automation.triggers.triggers
        case let .server(id): server(id)?.automation.triggers.triggers ?? []
        case let .character(serverID, characterID): character(serverID: serverID, characterID: characterID)?.triggers.triggers ?? []
        case let .puppet(serverID, characterID, puppetID): puppet(serverID: serverID, characterID: characterID, puppetID: puppetID)?.triggers.triggers ?? []
        }
    }

    public func triggerGroup(in scope: AutomationScope) -> TriggerGroup {
        switch scope {
        case .global: projection.automation.triggers
        case let .server(id): server(id)?.automation.triggers ?? .init(active: false)
        case let .character(serverID, characterID): character(serverID: serverID, characterID: characterID)?.triggers ?? .init(active: false)
        case let .puppet(serverID, characterID, puppetID): puppet(serverID: serverID, characterID: characterID, puppetID: puppetID)?.triggers ?? .init(active: false)
        }
    }

    public func trigger(at path: [Int], in scope: AutomationScope) -> Trigger? {
        Self.trigger(at: path, in: triggers(in: scope))
    }

    public func macros(in scope: AutomationScope) -> [KeyboardMacro] {
        switch scope {
        case .global: projection.automation.macros.macros
        case let .server(id): server(id)?.automation.macros.macros ?? []
        case let .character(serverID, characterID): character(serverID: serverID, characterID: characterID)?.macros.macros ?? []
        case let .puppet(serverID, characterID, puppetID): puppet(serverID: serverID, characterID: characterID, puppetID: puppetID)?.macros.macros ?? []
        }
    }

    public func macroGroup(in scope: AutomationScope) -> KeyboardMacroGroup {
        switch scope {
        case .global: projection.automation.macros
        case let .server(id): server(id)?.automation.macros ?? .init()
        case let .character(serverID, characterID): character(serverID: serverID, characterID: characterID)?.macros ?? .init()
        case let .puppet(serverID, characterID, puppetID): puppet(serverID: serverID, characterID: characterID, puppetID: puppetID)?.macros ?? .init()
        }
    }

    public func macro(at path: [Int], in scope: AutomationScope) -> KeyboardMacro? {
        Self.macro(at: path, in: macros(in: scope))
    }

    public func variables(in scope: AutomationScope) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: document.assignmentValues(at: try variableCollectionPath(scope)))
    }

    /// Adds or updates a v331 variable assignment without rewriting
    /// neighbouring fields. Existing key casing is preserved.
    public mutating func setVariable(
        named name: String,
        value: String,
        in scope: AutomationScope
    ) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.emptyName }
        let path = try variableCollectionPath(scope)
        let storedName = document.assignmentValues(at: path).first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        })?.name ?? trimmed
        try document.upsertValue(value, at: path + [storedName])
        try reloadProjectionAfterAutomationEdit()
    }

    @discardableResult
    public mutating func removeVariable(named name: String, in scope: AutomationScope) throws -> Bool {
        let path = try variableCollectionPath(scope)
        guard let storedName = document.assignmentValues(at: path).first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        })?.name else { return false }
        let removed = try document.removeAssignment(named: storedName, at: path)
        try reloadProjectionAfterAutomationEdit()
        return removed
    }

    @discardableResult
    public mutating func addAlias(in scope: AutomationScope, description: String = "New Alias", match: MatchDefinition = .init(text: ""), replacement: String = "") throws -> Int {
        try addAutomationEntry(in: scope, kind: .aliases, description: description, match: match, replacement: replacement)
    }

    @discardableResult
    public mutating func addAlias(in scope: AutomationScope, alias: Alias) throws -> Int {
        let path = try addAlias(in: scope, parentPath: [], alias: alias)
        return path[0]
    }

    /// Adds a complete alias tree at any depth. The returned path is relative
    /// to the selected scope and remains useful after the projection reload.
    @discardableResult
    public mutating func addAlias(
        in scope: AutomationScope,
        parentPath: [Int],
        alias: Alias
    ) throws -> [Int] {
        guard parentPath.isEmpty || self.alias(at: parentPath, in: scope) != nil else {
            throw WorkspaceError.automationEntryNotFound
        }
        let collectionPath = try automationCollectionPath(scope, kind: .aliases)
        try document.upsertValue("true", at: collectionPath + ["Active"], quoted: false)
        let index: Int
        if parentPath.isEmpty {
            index = try document.appendUnnamedBlock(at: collectionPath)
        } else {
            index = try document.appendUnnamedBlock(
                at: collectionPath,
                nestedIn: parentPath,
                nestedCollectionPath: ["Aliases"]
            )
        }
        let path = parentPath + [index]
        try writeAlias(alias, at: path, collectionPath: collectionPath)
        return path
    }

    @discardableResult
    public mutating func addAlias(
        in scope: AutomationScope,
        parentPath: [Int],
        description: String = "New Alias",
        match: MatchDefinition = .init(text: ""),
        replacement: String = ""
    ) throws -> [Int] {
        try addAlias(
            in: scope,
            parentPath: parentPath,
            alias: Alias(description: description, match: match, replacement: replacement)
        )
    }

    @discardableResult
    public mutating func addTrigger(in scope: AutomationScope, description: String = "New Trigger", match: MatchDefinition = .init(text: ""), action: EditableTriggerAction = .gag(display: true, log: false)) throws -> Int {
        try addAutomationEntry(in: scope, kind: .triggers, description: description, match: match, action: action)
    }

    @discardableResult
    public mutating func addTrigger(in scope: AutomationScope, trigger: Trigger) throws -> Int {
        let path = try automationCollectionPath(scope, kind: .triggers)
        try document.upsertValue("true", at: path + ["Active"], quoted: false)
        let index = try document.appendUnnamedBlock(at: path)
        try writeTrigger(trigger, at: index, collectionPath: path)
        return index
    }

    @discardableResult
    public mutating func addTrigger(
        in scope: AutomationScope,
        parentPath: [Int],
        description: String = "New Trigger",
        match: MatchDefinition = .init(text: ""),
        action: EditableTriggerAction = .gag(display: true, log: false)
    ) throws -> [Int] {
        let trigger = Trigger(description: description, match: match, actions: Self.actions(for: action))
        return try addTrigger(in: scope, parentPath: parentPath, trigger: trigger)
    }

    @discardableResult
    public mutating func addTrigger(
        in scope: AutomationScope,
        parentPath: [Int],
        trigger: Trigger
    ) throws -> [Int] {
        guard parentPath.isEmpty || self.trigger(at: parentPath, in: scope) != nil else {
            throw WorkspaceError.automationEntryNotFound
        }
        let collectionPath = try automationCollectionPath(scope, kind: .triggers)
        try document.upsertValue("true", at: collectionPath + ["Active"], quoted: false)
        let index: Int
        if parentPath.isEmpty {
            index = try document.appendUnnamedBlock(at: collectionPath)
        } else {
            index = try document.appendUnnamedBlock(
                at: collectionPath,
                nestedIn: parentPath,
                nestedCollectionPath: ["Triggers"]
            )
        }
        let path = parentPath + [index]
        try writeTrigger(trigger, at: path, collectionPath: collectionPath)
        return path
    }

    @discardableResult
    public mutating func addMacro(in scope: AutomationScope, description: String = "New Macro", key: String = "Control+Alt+M", macro: String = "", typeIntoInput: Bool = false) throws -> Int {
        try addMacro(
            in: scope,
            parentPath: [],
            macro: .init(description: description, macro: macro, key: key, typeIntoInput: typeIntoInput)
        )[0]
    }

    /// Adds a complete macro subtree under a folder or at a scope root.
    @discardableResult
    public mutating func addMacro(
        in scope: AutomationScope,
        parentPath: [Int],
        macro: KeyboardMacro
    ) throws -> [Int] {
        guard parentPath.isEmpty || self.macro(at: parentPath, in: scope)?.folder == true else {
            throw WorkspaceError.automationEntryNotFound
        }
        let collectionPath = try automationCollectionPath(scope, kind: .macros)
        try document.upsertValue("true", at: collectionPath + ["Active"], quoted: false)
        let index: Int
        if parentPath.isEmpty {
            index = try document.appendUnnamedBlock(at: collectionPath)
        } else {
            index = try document.appendUnnamedBlock(
                at: collectionPath,
                nestedIn: parentPath,
                nestedCollectionPath: ["KeyboardMacros2"]
            )
        }
        try writeMacro(macro, at: parentPath + [index], collectionPath: collectionPath)
        return parentPath + [index]
    }

    @discardableResult
    public mutating func addMacro(
        in scope: AutomationScope,
        parentPath: [Int],
        description: String = "New Macro",
        key: String = "Control+Alt+M",
        macro: String = "",
        typeIntoInput: Bool = false,
        folder: Bool = false
    ) throws -> [Int] {
        try addMacro(
            in: scope,
            parentPath: parentPath,
            macro: .init(
                description: description,
                macro: macro,
                key: key,
                typeIntoInput: typeIntoInput,
                folder: folder
            )
        )
    }

    public mutating func updateMacro(
        at path: [Int],
        in scope: AutomationScope,
        macro: KeyboardMacro
    ) throws {
        guard !path.isEmpty, self.macro(at: path, in: scope) != nil else {
            throw WorkspaceError.automationEntryNotFound
        }
        try writeMacro(macro, at: path, collectionPath: try automationCollectionPath(scope, kind: .macros))
    }

    public mutating func updateMacro(
        at path: [Int],
        in scope: AutomationScope,
        description: String,
        key: String,
        macro: String,
        typeIntoInput: Bool
    ) throws {
        guard var updated = self.macro(at: path, in: scope) else {
            throw WorkspaceError.automationEntryNotFound
        }
        updated.description = description
        updated.key = key
        updated.macro = macro
        updated.typeIntoInput = typeIntoInput
        try updateMacro(at: path, in: scope, macro: updated)
    }

    @discardableResult
    public mutating func removeMacro(at path: [Int], in scope: AutomationScope) throws -> Bool {
        guard !path.isEmpty, self.macro(at: path, in: scope) != nil else {
            throw WorkspaceError.automationEntryNotFound
        }
        let removed = try document.removeUnnamedBlock(
            at: path,
            collectionPath: try automationCollectionPath(scope, kind: .macros),
            nestedCollectionPath: ["KeyboardMacros2"]
        )
        try reloadProjectionAfterAutomationEdit()
        return removed
    }

    @discardableResult
    public mutating func removeMacro(at index: Int, in scope: AutomationScope) throws -> Bool {
        try removeMacro(at: [index], in: scope)
    }

    @discardableResult
    public mutating func copyMacro(
        at sourcePath: [Int],
        in sourceScope: AutomationScope,
        to destinationScope: AutomationScope,
        parentPath destinationParentPath: [Int] = [],
        index destinationIndex: Int? = nil
    ) throws -> [Int] {
        guard !sourcePath.isEmpty, macro(at: sourcePath, in: sourceScope) != nil,
              destinationParentPath.isEmpty || macro(at: destinationParentPath, in: destinationScope)?.folder == true else {
            throw WorkspaceError.automationEntryNotFound
        }
        if sourceScope == destinationScope, Self.path(destinationParentPath, hasPrefix: sourcePath) {
            throw WorkspaceError.automationEntryNotFound
        }
        let sourceCollection = try automationCollectionPath(sourceScope, kind: .macros)
        let destinationCollection = try automationCollectionPath(destinationScope, kind: .macros)
        let destinationCount = destinationParentPath.isEmpty
            ? macros(in: destinationScope).count
            : macro(at: destinationParentPath, in: destinationScope)?.children.count ?? 0
        let index = destinationIndex ?? destinationCount
        let copied = try document.copyUnnamedBlock(
            at: sourcePath,
            collectionPath: sourceCollection,
            nestedCollectionPath: ["KeyboardMacros2"],
            to: index,
            nestedIn: destinationParentPath,
            destinationCollectionPath: destinationCollection,
            destinationNestedCollectionPath: ["KeyboardMacros2"]
        )
        try reloadProjectionAfterAutomationEdit()
        return copied
    }

    @discardableResult
    public mutating func copyMacro(
        at sourcePath: [Int],
        in scope: AutomationScope,
        toParentPath destinationParentPath: [Int] = [],
        index destinationIndex: Int? = nil
    ) throws -> [Int] {
        try copyMacro(
            at: sourcePath,
            in: scope,
            to: scope,
            parentPath: destinationParentPath,
            index: destinationIndex
        )
    }

    @discardableResult
    public mutating func moveMacro(
        at sourcePath: [Int],
        in sourceScope: AutomationScope,
        to destinationScope: AutomationScope,
        parentPath destinationParentPath: [Int] = [],
        index destinationIndex: Int
    ) throws -> [Int] {
        guard !sourcePath.isEmpty, macro(at: sourcePath, in: sourceScope) != nil,
              destinationParentPath.isEmpty || macro(at: destinationParentPath, in: destinationScope)?.folder == true else {
            throw WorkspaceError.automationEntryNotFound
        }
        if sourceScope == destinationScope, Self.path(destinationParentPath, hasPrefix: sourcePath) {
            throw WorkspaceError.automationEntryNotFound
        }
        let moved = try document.moveUnnamedBlock(
            at: sourcePath,
            collectionPath: try automationCollectionPath(sourceScope, kind: .macros),
            nestedCollectionPath: ["KeyboardMacros2"],
            to: destinationIndex,
            nestedIn: destinationParentPath,
            destinationCollectionPath: try automationCollectionPath(destinationScope, kind: .macros),
            destinationNestedCollectionPath: ["KeyboardMacros2"]
        )
        try reloadProjectionAfterAutomationEdit()
        return moved
    }

    @discardableResult
    public mutating func moveMacro(
        at sourcePath: [Int],
        in scope: AutomationScope,
        toParentPath destinationParentPath: [Int],
        index destinationIndex: Int
    ) throws -> [Int] {
        try moveMacro(
            at: sourcePath,
            in: scope,
            to: scope,
            parentPath: destinationParentPath,
            index: destinationIndex
        )
    }

    @discardableResult
    public mutating func indentMacro(at path: [Int], in scope: AutomationScope) throws -> [Int] {
        guard let index = path.last, index > 0 else { throw WorkspaceError.automationEntryNotFound }
        let parent = Array(path.dropLast()) + [index - 1]
        let count = macro(at: parent, in: scope)?.children.count ?? 0
        return try moveMacro(at: path, in: scope, to: scope, parentPath: parent, index: count)
    }

    @discardableResult
    public mutating func outdentMacro(at path: [Int], in scope: AutomationScope) throws -> [Int] {
        guard path.count > 1, let parentIndex = path.dropLast().last else {
            throw WorkspaceError.automationEntryNotFound
        }
        let parent = Array(path.dropLast())
        return try moveMacro(
            at: path,
            in: scope,
            to: scope,
            parentPath: Array(parent.dropLast()),
            index: parentIndex + 1
        )
    }

    public mutating func updateMacroGroupSettings(in scope: AutomationScope, active: Bool) throws {
        let path = try automationCollectionPath(scope, kind: .macros)
        try document.upsertValue(active ? "true" : "false", at: path + ["Active"], quoted: false)
        try reloadProjectionAfterAutomationEdit()
    }

    public mutating func setMacroMasterActive(_ active: Bool) throws {
        try updateMacroGroupSettings(in: .global, active: active)
    }

    /// Imports every macro subtree in a valid Config.txt into the selected
    /// scope/folder. Source slices are appended directly so unknown fields are
    /// not lost merely because the Mac editor does not expose them.
    @discardableResult
    public mutating func importMacros(
        from imported: LegacyConfigurationDocument,
        into scope: AutomationScope,
        parentPath: [Int] = []
    ) throws -> Int {
        let destination: AutomationImportDestination = parentPath.isEmpty
            ? .scope(scope)
            : .folder(.init(scope: scope, path: parentPath))
        return try importAutomation(
            from: imported,
            kind: .macros,
            destination: destination
        ).paths.count
    }

    @discardableResult
    public mutating func importMacros(
        from imported: LegacyConfigurationDocument,
        in scope: AutomationScope,
        parentPath: [Int] = []
    ) throws -> Int {
        try importMacros(from: imported, into: scope, parentPath: parentPath)
    }

    /// Exports one macro subtree or all macros below a selected scope/folder.
    public func exportMacros(in scope: AutomationScope, path: [Int]? = nil) throws -> LegacyConfigurationDocument {
        let selection: AutomationEntrySelection = path.map {
            .item(.init(scope: scope, path: $0))
        } ?? .scope(scope)
        return try exportAutomation(kind: .macros, selection: selection)
    }

    public mutating func updateAlias(at index: Int, in scope: AutomationScope, description: String, match: MatchDefinition, replacement: String) throws {
        try updateAutomationEntry(at: index, in: scope, kind: .aliases, description: description, match: match, replacement: replacement)
    }

    public mutating func updateAlias(at index: Int, in scope: AutomationScope, alias: Alias) throws {
        try updateAlias(at: [index], in: scope, alias: alias)
    }

    public mutating func updateAlias(at path: [Int], in scope: AutomationScope, alias: Alias) throws {
        guard !path.isEmpty, self.alias(at: path, in: scope) != nil else {
            throw WorkspaceError.automationEntryNotFound
        }
        try writeAlias(alias, at: path, collectionPath: try automationCollectionPath(scope, kind: .aliases))
    }

    @discardableResult
    public mutating func removeAlias(at path: [Int], in scope: AutomationScope) throws -> Bool {
        guard !path.isEmpty, self.alias(at: path, in: scope) != nil else {
            throw WorkspaceError.automationEntryNotFound
        }
        let removed = try document.removeUnnamedBlock(
            at: path,
            collectionPath: try automationCollectionPath(scope, kind: .aliases),
            nestedCollectionPath: ["Aliases"]
        )
        try reloadProjectionAfterAutomationEdit()
        return removed
    }

    @discardableResult
    public mutating func removeAlias(at index: Int, in scope: AutomationScope) throws -> Bool {
        try removeAlias(at: [index], in: scope)
    }

    /// Copies a complete alias subtree, retaining fields that are not modeled
    /// by the Mac projection.
    @discardableResult
    public mutating func copyAlias(
        at sourcePath: [Int],
        in scope: AutomationScope,
        toParentPath destinationParentPath: [Int]? = nil,
        index destinationIndex: Int? = nil
    ) throws -> [Int] {
        guard !sourcePath.isEmpty, self.alias(at: sourcePath, in: scope) != nil else {
            throw WorkspaceError.automationEntryNotFound
        }
        let parent = destinationParentPath ?? Array(sourcePath.dropLast())
        guard parent.isEmpty || self.alias(at: parent, in: scope) != nil else {
            throw WorkspaceError.automationEntryNotFound
        }
        let collectionPath = try automationCollectionPath(scope, kind: .aliases)
        let count = parent.isEmpty
            ? aliases(in: scope).count
            : self.alias(at: parent, in: scope)?.children.count ?? 0
        let index = destinationIndex ?? count
        let copied = try document.copyUnnamedBlock(
            at: sourcePath,
            collectionPath: collectionPath,
            nestedCollectionPath: ["Aliases"],
            to: index,
            nestedIn: parent,
            destinationCollectionPath: collectionPath,
            destinationNestedCollectionPath: ["Aliases"]
        )
        try reloadProjectionAfterAutomationEdit()
        return copied
    }

    @discardableResult
    public mutating func moveAlias(
        at sourcePath: [Int],
        in scope: AutomationScope,
        toParentPath destinationParentPath: [Int],
        index destinationIndex: Int
    ) throws -> [Int] {
        try moveAlias(
            at: sourcePath,
            in: scope,
            to: scope,
            toParentPath: destinationParentPath,
            index: destinationIndex
        )
    }

    /// Moves an alias across scopes or folders without flattening or
    /// reserializing its raw Config.txt subtree.
    @discardableResult
    public mutating func moveAlias(
        at sourcePath: [Int],
        in sourceScope: AutomationScope,
        to destinationScope: AutomationScope,
        toParentPath destinationParentPath: [Int],
        index destinationIndex: Int
    ) throws -> [Int] {
        guard !sourcePath.isEmpty, self.alias(at: sourcePath, in: sourceScope) != nil,
              destinationParentPath.isEmpty || self.alias(at: destinationParentPath, in: destinationScope) != nil,
              !(sourceScope == destinationScope && Self.path(destinationParentPath, hasPrefix: sourcePath)) else {
            throw WorkspaceError.automationEntryNotFound
        }
        let sourceCollection = try automationCollectionPath(sourceScope, kind: .aliases)
        let destinationCollection = try automationCollectionPath(destinationScope, kind: .aliases)
        let sourceParent = Array(sourcePath.dropLast())
        let sourceGroup = aliasGroup(at: sourceParent, in: sourceScope)
        let destinationGroup = aliasGroup(at: destinationParentPath, in: destinationScope)
        let sourceCount = sourceGroup.aliases.count
        let sourceWasPost = (sourcePath.last ?? 0) >= max(0, sourceCount - sourceGroup.afterCount)
        let sameGroup = sourceScope == destinationScope && sourceParent == destinationParentPath
        let sourceAfter = max(0, sourceGroup.afterCount - (sourceWasPost ? 1 : 0))
        let destinationCount = destinationGroup.aliases.count - (sameGroup ? 1 : 0)
        let destinationAfterBeforeInsert = sameGroup ? sourceAfter : destinationGroup.afterCount
        let clampedIndex = min(max(0, destinationIndex), max(0, destinationCount))
        let destinationIsPost = clampedIndex >= max(0, destinationCount - destinationAfterBeforeInsert)
        let destinationAfter = min(
            destinationCount + 1,
            destinationAfterBeforeInsert + (destinationIsPost ? 1 : 0)
        )

        let moved = try document.moveUnnamedBlock(
            at: sourcePath,
            collectionPath: sourceCollection,
            nestedCollectionPath: ["Aliases"],
            to: clampedIndex,
            nestedIn: destinationParentPath,
            destinationCollectionPath: destinationCollection,
            destinationNestedCollectionPath: ["Aliases"]
        )
        try setAliasAfterCount(sourceAfter, at: sourceParent, in: sourceScope, reload: false)
        if !sameGroup {
            try setAliasAfterCount(destinationAfter, at: destinationParentPath, in: destinationScope, reload: false)
        } else {
            try setAliasAfterCount(destinationAfter, at: destinationParentPath, in: destinationScope, reload: false)
        }
        try reloadProjectionAfterAutomationEdit()
        return moved
    }

    public mutating func updateAliasGroupSettings(
        in scope: AutomationScope,
        active: Bool,
        echo: Bool,
        processCommands: Bool,
        afterCount: Int
    ) throws {
        let path = try automationCollectionPath(scope, kind: .aliases)
        try document.upsertValue(Self.flag(active), at: path + ["Active"], quoted: false)
        try document.upsertValue(Self.flag(echo), at: path + ["Echo"], quoted: false)
        try document.upsertValue(Self.flag(processCommands), at: path + ["ProcessCommands"], quoted: false)
        try document.upsertValue(String(max(0, afterCount)), at: path + ["AfterCount"], quoted: false)
        try reloadProjectionAfterAutomationEdit()
    }

    public mutating func updateAliasGroupSettings(
        at parentPath: [Int],
        in scope: AutomationScope,
        active: Bool,
        afterCount: Int
    ) throws {
        guard parentPath.isEmpty || self.alias(at: parentPath, in: scope) != nil else {
            throw WorkspaceError.automationEntryNotFound
        }
        if parentPath.isEmpty {
            let group = aliasGroup(in: scope)
            try updateAliasGroupSettings(
                in: scope,
                active: active,
                echo: group.echo,
                processCommands: group.processCommands,
                afterCount: afterCount
            )
            return
        }
        let collectionPath = try automationCollectionPath(scope, kind: .aliases)
        try document.upsertValue(
            Self.flag(active),
            inUnnamedBlockAt: parentPath,
            collectionPath: collectionPath,
            relativePath: ["Aliases", "Active"],
            quoted: false
        )
        try document.upsertValue(
            String(max(0, afterCount)),
            inUnnamedBlockAt: parentPath,
            collectionPath: collectionPath,
            relativePath: ["Aliases", "AfterCount"],
            quoted: false
        )
        try reloadProjectionAfterAutomationEdit()
    }

    /// Imports every top-level alias tree in a Windows v331
    /// Connections.Aliases document into the selected destination.
    @discardableResult
    public mutating func importAliases(
        from source: LegacyConfigurationDocument,
        into scope: AutomationScope,
        parentPath: [Int] = []
    ) throws -> [[Int]] {
        let destination: AutomationImportDestination = parentPath.isEmpty
            ? .scope(scope)
            : .folder(.init(scope: scope, path: parentPath))
        return try importAutomation(from: source, kind: .aliases, destination: destination).paths
    }

    /// Exports either one alias subtree or every alias in a selected scope as
    /// a portable Windows v331 configuration.
    public func exportAliases(
        in scope: AutomationScope,
        path: [Int]? = nil
    ) throws -> LegacyConfigurationDocument {
        let selection: AutomationEntrySelection = path.map {
            .item(.init(scope: scope, path: $0))
        } ?? .scope(scope)
        return try exportAutomation(kind: .aliases, selection: selection)
    }

    @discardableResult
    public mutating func importTriggers(
        from source: LegacyConfigurationDocument,
        into scope: AutomationScope,
        parentPath: [Int] = []
    ) throws -> [[Int]] {
        let destination: AutomationImportDestination = parentPath.isEmpty
            ? .scope(scope)
            : .folder(.init(scope: scope, path: parentPath))
        return try importAutomation(from: source, kind: .triggers, destination: destination).paths
    }

    public func exportTriggers(
        in scope: AutomationScope,
        path: [Int]? = nil
    ) throws -> LegacyConfigurationDocument {
        let selection: AutomationEntrySelection = path.map {
            .item(.init(scope: scope, path: $0))
        } ?? .scope(scope)
        return try exportAutomation(kind: .triggers, selection: selection)
    }

    public mutating func updateTrigger(at index: Int, in scope: AutomationScope, description: String, match: MatchDefinition, action: EditableTriggerAction) throws {
        try updateAutomationEntry(at: index, in: scope, kind: .triggers, description: description, match: match, action: action)
    }

    public mutating func updateTrigger(at index: Int, in scope: AutomationScope, trigger: Trigger) throws {
        guard triggers(in: scope).indices.contains(index) else { throw WorkspaceError.automationEntryNotFound }
        let path = try automationCollectionPath(scope, kind: .triggers)
        try writeTrigger(trigger, at: index, collectionPath: path)
    }

    public mutating func updateTrigger(at path: [Int], in scope: AutomationScope, trigger: Trigger) throws {
        guard !path.isEmpty, self.trigger(at: path, in: scope) != nil else {
            throw WorkspaceError.automationEntryNotFound
        }
        try writeTrigger(trigger, at: path, collectionPath: try automationCollectionPath(scope, kind: .triggers))
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

    public mutating func removeTrigger(at path: [Int], in scope: AutomationScope) throws {
        guard !path.isEmpty, trigger(at: path, in: scope) != nil else {
            throw WorkspaceError.automationEntryNotFound
        }
        _ = try document.removeUnnamedBlock(
            at: path,
            collectionPath: try automationCollectionPath(scope, kind: .triggers)
        )
        try reloadProjectionAfterAutomationEdit()
    }

    @discardableResult
    public mutating func moveTrigger(
        at sourcePath: [Int],
        in scope: AutomationScope,
        toParentPath destinationParentPath: [Int],
        index destinationIndex: Int
    ) throws -> [Int] {
        guard !sourcePath.isEmpty,
              trigger(at: sourcePath, in: scope) != nil,
              destinationParentPath.isEmpty || trigger(at: destinationParentPath, in: scope) != nil,
              !Self.path(destinationParentPath, hasPrefix: sourcePath) else {
            throw WorkspaceError.automationEntryNotFound
        }
        let moved = try document.moveUnnamedBlock(
            at: sourcePath,
            collectionPath: try automationCollectionPath(scope, kind: .triggers),
            to: destinationIndex,
            nestedIn: destinationParentPath,
            nestedCollectionPath: ["Triggers"]
        )
        try reloadProjectionAfterAutomationEdit()
        return moved
    }

    public mutating func updateTriggerGroupSettings(
        in scope: AutomationScope,
        active: Bool,
        afterCount: Int
    ) throws {
        let path = try automationCollectionPath(scope, kind: .triggers)
        try document.upsertValue(active ? "true" : "false", at: path + ["Active"], quoted: false)
        try document.upsertValue(String(max(0, afterCount)), at: path + ["AfterCount"], quoted: false)
        try reloadProjectionAfterAutomationEdit()
    }

    public enum AutomationKind: Sendable, Equatable {
        case aliases, triggers, macros

        public var displayName: String {
            switch self {
            case .aliases: "Aliases"
            case .triggers: "Triggers"
            case .macros: "Keyboard macros"
            }
        }
    }

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

    private static func trigger(at path: [Int], in triggers: [Trigger]) -> Trigger? {
        guard let first = path.first, triggers.indices.contains(first) else { return nil }
        if path.count == 1 { return triggers[first] }
        return trigger(at: Array(path.dropFirst()), in: triggers[first].children)
    }

    private static func alias(at path: [Int], in aliases: [Alias]) -> Alias? {
        guard let first = path.first, aliases.indices.contains(first) else { return nil }
        if path.count == 1 { return aliases[first] }
        return alias(at: Array(path.dropFirst()), in: aliases[first].children)
    }

    private static func macro(at path: [Int], in macros: [KeyboardMacro]) -> KeyboardMacro? {
        guard let first = path.first, macros.indices.contains(first) else { return nil }
        if path.count == 1 { return macros[first] }
        return macro(at: Array(path.dropFirst()), in: macros[first].children)
    }

    private func aliasGroup(at parentPath: [Int], in scope: AutomationScope) -> AliasGroup {
        guard let parent = alias(at: parentPath, in: scope) else {
            return aliasGroup(in: scope)
        }
        return .init(
            active: parent.childrenActive,
            afterCount: parent.childrenAfterCount,
            aliases: parent.children
        )
    }

    private mutating func setAliasAfterCount(
        _ afterCount: Int,
        at parentPath: [Int],
        in scope: AutomationScope,
        reload: Bool
    ) throws {
        let clamped = max(0, afterCount)
        let collectionPath = try automationCollectionPath(scope, kind: .aliases)
        if parentPath.isEmpty {
            try document.upsertValue(String(clamped), at: collectionPath + ["AfterCount"], quoted: false)
        } else {
            try document.upsertValue(
                String(clamped),
                inUnnamedBlockAt: parentPath,
                collectionPath: collectionPath,
                relativePath: ["Aliases", "AfterCount"],
                quoted: false
            )
        }
        if reload { try reloadProjectionAfterAutomationEdit() }
    }

    private static func path(_ path: [Int], hasPrefix prefix: [Int]) -> Bool {
        prefix.count <= path.count && Array(path.prefix(prefix.count)) == prefix
    }

    private static func actions(for action: EditableTriggerAction) -> [TriggerAction] {
        switch action {
        case let .gag(display, log):
            return [.gag(display: display, log: log)]
        case let .send(text):
            return [.send(text, captureIndex: 1, expandVariables: false)]
        }
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
        try document.upsertValue("true", at: path + ["Active"], quoted: false)
        let index = try document.appendUnnamedBlock(at: path)
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
        try document.upsertValue("true", at: path + ["Active"], quoted: false)
        let index = try document.appendUnnamedBlock(at: path)
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
        try document.upsertValue("true", at: path + ["Active"], quoted: false)
        let index = try document.appendUnnamedBlock(at: path)
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

    private mutating func writeAlias(
        _ alias: Alias,
        at indexPath: [Int],
        collectionPath: [String]
    ) throws {
        try document.upsertValue(
            alias.description,
            inUnnamedBlockAt: indexPath,
            collectionPath: collectionPath,
            relativePath: ["Description"]
        )
        try writeMatch(alias.match, at: indexPath, collectionPath: collectionPath)
        try document.upsertValue(
            alias.replacement,
            inUnnamedBlockAt: indexPath,
            collectionPath: collectionPath,
            relativePath: ["Replace"]
        )
        try writeFlag(alias.folder, at: indexPath, collectionPath: collectionPath, path: ["Folder"])
        // These are alias-level settings. Persist false explicitly as well as
        // true so a selected alias can override the legacy group defaults.
        try writeFlagWhenActive(alias.active, at: indexPath, collectionPath: collectionPath, path: ["Active"], when: true)
        try writeFlagWhenActive(alias.echo, at: indexPath, collectionPath: collectionPath, path: ["Echo"], when: true)
        try writeFlagWhenActive(alias.processCommands, at: indexPath, collectionPath: collectionPath, path: ["ProcessCommands"], when: true)
        try writeFlag(alias.stopProcessing, at: indexPath, collectionPath: collectionPath, path: ["StopProcessing"])
        try writeFlag(alias.expandVariables, at: indexPath, collectionPath: collectionPath, path: ["ExpandVariables"])
        try writeValueIfNeeded(
            alias.example,
            at: indexPath,
            collectionPath: collectionPath,
            path: ["Example"],
            when: !alias.example.isEmpty
                || aliasValueExists(at: indexPath, collectionPath: collectionPath, path: ["Example"])
        )

        let existingChildCount = document.unnamedBlockCount(
            at: collectionPath,
            nestedIn: indexPath,
            nestedCollectionPath: ["Aliases"]
        )
        let hasChildGroup = !alias.children.isEmpty
            || existingChildCount > 0
            || !alias.childrenActive
            || alias.childrenAfterCount > 0
            || aliasValueExists(at: indexPath, collectionPath: collectionPath, path: ["Aliases", "Active"])
            || aliasValueExists(at: indexPath, collectionPath: collectionPath, path: ["Aliases", "AfterCount"])
        if hasChildGroup {
            try document.upsertValue(
                Self.flag(alias.childrenActive),
                inUnnamedBlockAt: indexPath,
                collectionPath: collectionPath,
                relativePath: ["Aliases", "Active"],
                quoted: false
            )
            try document.upsertValue(
                String(max(0, min(alias.childrenAfterCount, alias.children.count))),
                inUnnamedBlockAt: indexPath,
                collectionPath: collectionPath,
                relativePath: ["Aliases", "AfterCount"],
                quoted: false
            )
        }
        if alias.children.count < existingChildCount {
            for index in stride(from: existingChildCount - 1, through: alias.children.count, by: -1) {
                _ = try document.removeUnnamedBlock(
                    at: indexPath + [index],
                    collectionPath: collectionPath,
                    nestedCollectionPath: ["Aliases"]
                )
            }
        }
        for (childIndex, child) in alias.children.enumerated() {
            if childIndex >= existingChildCount {
                _ = try document.appendUnnamedBlock(
                    at: collectionPath,
                    nestedIn: indexPath,
                    nestedCollectionPath: ["Aliases"]
                )
            }
            try writeAlias(child, at: indexPath + [childIndex], collectionPath: collectionPath)
        }
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

    private mutating func writeMacro(
        _ macro: KeyboardMacro,
        at indexPath: [Int],
        collectionPath: [String]
    ) throws {
        try document.upsertValue(
            macro.description,
            inUnnamedBlockAt: indexPath,
            collectionPath: collectionPath,
            relativePath: ["Description"]
        )
        try document.upsertValue(
            KeyboardMacroKey.canonical(macro.key),
            inUnnamedBlockAt: indexPath,
            collectionPath: collectionPath,
            relativePath: ["key"],
            quoted: false
        )
        try document.upsertValue(
            macro.macro,
            inUnnamedBlockAt: indexPath,
            collectionPath: collectionPath,
            relativePath: ["Macro"]
        )
        try document.upsertValue(
            Self.flag(macro.typeIntoInput),
            inUnnamedBlockAt: indexPath,
            collectionPath: collectionPath,
            relativePath: ["Type"],
            quoted: false
        )
        try writeFlag(macro.folder, at: indexPath, collectionPath: collectionPath, path: ["Folder"])
        let existingChildCount = document.unnamedBlockCount(
            at: collectionPath,
            nestedIn: indexPath,
            nestedCollectionPath: ["KeyboardMacros2"]
        )
        let hasChildGroup = !macro.children.isEmpty
            || existingChildCount > 0
            || !macro.childrenActive
            || document.value(
                inUnnamedBlockAt: indexPath,
                collectionPath: collectionPath,
                relativePath: ["KeyboardMacros2", "Active"]
            ) != nil
        if hasChildGroup {
            try document.upsertValue(
                Self.flag(macro.childrenActive),
                inUnnamedBlockAt: indexPath,
                collectionPath: collectionPath,
                relativePath: ["KeyboardMacros2", "Active"],
                quoted: false
            )
        }
        if macro.children.count < existingChildCount {
            for childIndex in stride(from: existingChildCount - 1, through: macro.children.count, by: -1) {
                _ = try document.removeUnnamedBlock(
                    at: indexPath + [childIndex],
                    collectionPath: collectionPath,
                    nestedCollectionPath: ["KeyboardMacros2"]
                )
            }
        }
        for (childIndex, child) in macro.children.enumerated() {
            if childIndex >= existingChildCount {
                _ = try document.appendUnnamedBlock(
                    at: collectionPath,
                    nestedIn: indexPath,
                    nestedCollectionPath: ["KeyboardMacros2"]
                )
            }
            try writeMacro(child, at: indexPath + [childIndex], collectionPath: collectionPath)
        }
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
        try document.upsertValue("true", at: ["Connections", "Triggers", "Active"], quoted: false)
        let index = try document.appendUnnamedBlock(at: ["Connections", "Triggers"])
        try writeTrigger(trigger, at: index, collectionPath: ["Connections", "Triggers"])
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
        let character = CharacterProfile(name: name, created: CharacterProfile.timestamp())
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

    /// Exports only the selected world hierarchy in ordinary Windows v331
    /// syntax. The selected named profile blocks are copied from the syntax
    /// tree, so comments and fields unknown to the projection survive.
    public func exportProfileHierarchy(
        _ selection: ProfileEntrySelection
    ) throws -> LegacyConfigurationDocument {
        let names = try profileNames(for: selection)
        guard let rawWorld = document.rawNamedBlockSource(
            named: names.world,
            at: ["Connections", "Shortcuts"]
        ) else { throw WorkspaceError.serverNotFound }

        var result = try Self.profileWrapper()
        try result.appendRawNamedBlock(rawWorld, at: ["Connections", "Shortcuts"])
        let worldPath = ["Connections", "Shortcuts", names.world]

        switch selection {
        case .world:
            break
        case .character:
            try Self.removeAutomationCollections(at: worldPath, from: &result)
            for candidate in result.namedBlockNames(at: worldPath + ["Characters"])
                where candidate.caseInsensitiveCompare(names.character!) != .orderedSame {
                _ = try result.removeCollectionEntry(named: candidate, at: worldPath + ["Characters"])
            }
        case .puppet:
            try Self.removeAutomationCollections(at: worldPath, from: &result)
            for candidate in result.namedBlockNames(at: worldPath + ["Characters"])
                where candidate.caseInsensitiveCompare(names.character!) != .orderedSame {
                _ = try result.removeCollectionEntry(named: candidate, at: worldPath + ["Characters"])
            }
            let characterPath = worldPath + ["Characters", names.character!]
            try Self.removeAutomationCollections(at: characterPath, from: &result)
            for candidate in result.namedBlockNames(at: characterPath + ["Puppets"])
                where candidate.caseInsensitiveCompare(names.puppet!) != .orderedSame {
                _ = try result.removeCollectionEntry(named: candidate, at: characterPath + ["Puppets"])
            }
        }
        return result
    }

    /// Exports a complete selected automation scope, or one exact raw item.
    /// Single items are intentionally context-free and always live beneath
    /// the global collection, matching the Windows client's export shape.
    public func exportAutomation(
        kind: AutomationKind,
        selection: AutomationEntrySelection
    ) throws -> LegacyConfigurationDocument {
        switch selection {
        case let .item(item):
            let collectionPath = try automationCollectionPath(item.scope, kind: kind)
            guard !item.path.isEmpty,
                  let raw = document.rawUnnamedBlockSource(
                      at: item.path,
                      collectionPath: collectionPath,
                      nestedCollectionPath: [Self.collectionName(for: kind)]
                  ) else { throw WorkspaceError.automationEntryNotFound }
            var result = try Self.automationWrapper(kind: kind)
            _ = try result.appendRawUnnamedBlock(raw, at: ["Connections", Self.collectionName(for: kind)])
            return result

        case .scope(.global):
            var result = try Self.profileWrapper()
            let collection = Self.collectionName(for: kind)
            if let raw = document.rawNamedBlockSource(named: collection, at: ["Connections"]) {
                try result.appendRawNamedBlock(raw, at: ["Connections"])
            } else {
                result = try Self.automationWrapper(kind: kind)
            }
            return result

        case let .scope(scope):
            let profileSelection = try profileSelection(for: scope)
            var result = try exportProfileHierarchy(profileSelection)
            let selectedNames = try scopeNames(for: scope)
            let exported = try LegacyConfigurationWorkspace(document: result)
            for world in exported.servers {
                let worldPath = ["Connections", "Shortcuts", world.profile.name]
                try Self.pruneAutomation(
                    at: worldPath,
                    context: .init(world: world.profile.name, character: nil, puppet: nil),
                    selected: selectedNames,
                    kind: kind,
                    document: &result
                )
                for character in world.characters {
                    let characterPath = worldPath + ["Characters", character.name]
                    try Self.pruneAutomation(
                        at: characterPath,
                        context: .init(world: world.profile.name, character: character.name, puppet: nil),
                        selected: selectedNames,
                        kind: kind,
                        document: &result
                    )
                    for puppet in character.puppets {
                        try Self.pruneAutomation(
                            at: characterPath + ["Puppets", puppet.name],
                            context: .init(world: world.profile.name, character: character.name, puppet: puppet.name),
                            selected: selectedNames,
                            kind: kind,
                            document: &result
                        )
                    }
                }
            }
            return result
        }
    }

    /// Imports automation atomically into a selection-aware destination.
    /// Context-free files use the current destination; contextual files merge
    /// into the hierarchy encoded by the document.
    @discardableResult
    public mutating func importAutomation(
        from source: LegacyConfigurationDocument,
        kind: AutomationKind,
        destination: AutomationImportDestination
    ) throws -> AutomationImportResult {
        var candidate = self
        let result = try candidate.importAutomationImpl(
            from: source,
            kind: kind,
            destination: destination
        )
        self = candidate
        return result
    }

    private mutating func importAutomationImpl(
        from source: LegacyConfigurationDocument,
        kind: AutomationKind,
        destination: AutomationImportDestination
    ) throws -> AutomationImportResult {
        let imported = try LegacyConfigurationWorkspace(document: source)
        let contexts = try imported.sourceAutomationContexts(for: kind)
        guard !contexts.isEmpty else {
            throw WorkspaceError.wrongAutomationCategory(expected: kind)
        }
        let contextual = contexts.filter { $0.character != nil || $0.puppet != nil || $0.world != nil }
        guard contextual.count <= 1, !(contexts.contains(where: { $0.world == nil }) && !contextual.isEmpty) else {
            throw WorkspaceError.multipleContextualScopes
        }

        if let context = contextual.first {
            let before = try matchingScope(for: context).map { automationCount(in: $0, kind: kind) } ?? 0
            _ = try mergeProfileHierarchy(from: source)
            guard let scope = try matchingScope(for: context) else {
                throw WorkspaceError.automationEntryNotFound
            }
            let after = automationCount(in: scope, kind: kind)
            return .init(scope: scope, paths: (before..<after).map { [$0] })
        }

        let (scope, parentPath, index) = try importLocation(destination, kind: kind)
        let rawSources = source.rawUnnamedBlockSources(at: ["Connections", Self.collectionName(for: kind)])
        var paths: [[Int]] = []
        var insertion = index
        for raw in rawSources {
            let prepared = try uniquelyNamedRawAutomation(raw, kind: kind, scope: scope, parentPath: parentPath)
            let collectionPath = try automationCollectionPath(scope, kind: kind)
            let inserted = try document.appendRawUnnamedBlock(
                prepared,
                at: collectionPath,
                nestedIn: parentPath,
                nestedCollectionPath: [Self.collectionName(for: kind)],
                index: insertion
            )
            paths.append(parentPath + [inserted])
            if let currentInsertion = insertion { insertion = currentInsertion + 1 }
            try reloadProjectionAfterAutomationEdit()
        }
        return .init(scope: scope, paths: paths)
    }

    /// Merges one contextual world hierarchy without applying root settings.
    /// Existing case-insensitive parents keep their settings; missing profile
    /// blocks are copied raw and automation leaf conflicts are renamed.
    @discardableResult
    public mutating func mergeProfileHierarchy(
        from source: LegacyConfigurationDocument
    ) throws -> ProfileMergeResult {
        var candidate = self
        let result = try candidate.mergeProfileHierarchyImpl(from: source)
        self = candidate
        return result
    }

    private mutating func mergeProfileHierarchyImpl(
        from source: LegacyConfigurationDocument
    ) throws -> ProfileMergeResult {
        let imported = try LegacyConfigurationWorkspace(document: source)
        guard !imported.servers.isEmpty else { throw WorkspaceError.noProfilesFound }
        guard imported.servers.count == 1 else { throw WorkspaceError.multipleWorlds }
        let sourceWorld = imported.servers[0]
        let shortcuts = ["Connections", "Shortcuts"]

        if !projection.servers.contains(where: {
            $0.profile.name.caseInsensitiveCompare(sourceWorld.profile.name) == .orderedSame
        }) {
            guard let raw = source.rawNamedBlockSource(named: sourceWorld.profile.name, at: shortcuts) else {
                throw WorkspaceError.noProfilesFound
            }
            try document.appendRawNamedBlock(raw, at: shortcuts)
            try reloadProjectionAfterAutomationEdit()
        } else {
            let targetWorldName = projection.servers.first {
                $0.profile.name.caseInsensitiveCompare(sourceWorld.profile.name) == .orderedSame
            }!.profile.name
            let sourceWorldPath = shortcuts + [sourceWorld.profile.name]
            let targetWorldPath = shortcuts + [targetWorldName]
            try mergeAutomationCollections(from: source, sourcePath: sourceWorldPath, targetPath: targetWorldPath)

            let targetWorld = projection.servers.first {
                $0.profile.name.caseInsensitiveCompare(sourceWorld.profile.name) == .orderedSame
            }!
            for sourceCharacter in sourceWorld.characters {
                if let targetCharacter = targetWorld.characters.first(where: {
                    $0.name.caseInsensitiveCompare(sourceCharacter.name) == .orderedSame
                }) {
                    let sourceCharacterPath = sourceWorldPath + ["Characters", sourceCharacter.name]
                    let targetCharacterPath = targetWorldPath + ["Characters", targetCharacter.name]
                    try mergeAutomationCollections(from: source, sourcePath: sourceCharacterPath, targetPath: targetCharacterPath)
                    for sourcePuppet in sourceCharacter.puppets {
                        if let targetPuppet = targetCharacter.puppets.first(where: {
                            $0.name.caseInsensitiveCompare(sourcePuppet.name) == .orderedSame
                        }) {
                            try mergeAutomationCollections(
                                from: source,
                                sourcePath: sourceCharacterPath + ["Puppets", sourcePuppet.name],
                                targetPath: targetCharacterPath + ["Puppets", targetPuppet.name]
                            )
                        } else if let raw = source.rawNamedBlockSource(
                            named: sourcePuppet.name,
                            at: sourceCharacterPath + ["Puppets"]
                        ) {
                            try document.appendRawNamedBlock(raw, at: targetCharacterPath + ["Puppets"])
                        }
                    }
                } else if let raw = source.rawNamedBlockSource(
                    named: sourceCharacter.name,
                    at: sourceWorldPath + ["Characters"]
                ) {
                    try document.appendRawNamedBlock(raw, at: targetWorldPath + ["Characters"])
                }
            }
            try reloadProjectionAfterAutomationEdit()
        }

        guard let world = projection.servers.first(where: {
            $0.profile.name.caseInsensitiveCompare(sourceWorld.profile.name) == .orderedSame
        }) else { throw WorkspaceError.serverNotFound }
        let importedCharacterNames = Set(sourceWorld.characters.map { $0.name.lowercased() })
        let characters = world.characters.filter { importedCharacterNames.contains($0.name.lowercased()) }
        let importedPuppetNames = Set(sourceWorld.characters.flatMap(\.puppets).map { $0.name.lowercased() })
        return .init(
            worldID: world.profile.id,
            characterIDs: characters.map(\.id),
            puppetIDs: characters.flatMap(\.puppets).filter { importedPuppetNames.contains($0.name.lowercased()) }.map(\.id)
        )
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

    private struct ScopeNames: Equatable {
        var world: String?
        var character: String?
        var puppet: String?
    }

    private func profileNames(for selection: ProfileEntrySelection) throws -> (world: String, character: String?, puppet: String?) {
        switch selection {
        case let .world(worldID):
            guard let world = server(worldID) else { throw WorkspaceError.serverNotFound }
            return (world.profile.name, nil, nil)
        case let .character(worldID, characterID):
            guard let world = server(worldID),
                  let character = world.characters.first(where: { $0.id == characterID }) else {
                throw WorkspaceError.characterNotFound
            }
            return (world.profile.name, character.name, nil)
        case let .puppet(worldID, characterID, puppetID):
            guard let world = server(worldID),
                  let character = world.characters.first(where: { $0.id == characterID }),
                  let puppet = character.puppets.first(where: { $0.id == puppetID }) else {
                throw WorkspaceError.puppetNotFound
            }
            return (world.profile.name, character.name, puppet.name)
        }
    }

    private func profileSelection(for scope: AutomationScope) throws -> ProfileEntrySelection {
        switch scope {
        case .global:
            throw WorkspaceError.serverNotFound
        case let .server(world):
            return .world(world)
        case let .character(world, character):
            return .character(world: world, character: character)
        case let .puppet(world, character, puppet):
            return .puppet(world: world, character: character, puppet: puppet)
        }
    }

    private func scopeNames(for scope: AutomationScope) throws -> ScopeNames {
        switch scope {
        case .global:
            return .init(world: nil, character: nil, puppet: nil)
        case let .server(worldID):
            guard let world = server(worldID) else { throw WorkspaceError.serverNotFound }
            return .init(world: world.profile.name, character: nil, puppet: nil)
        case let .character(worldID, characterID):
            guard let world = server(worldID),
                  let character = world.characters.first(where: { $0.id == characterID }) else {
                throw WorkspaceError.characterNotFound
            }
            return .init(world: world.profile.name, character: character.name, puppet: nil)
        case let .puppet(worldID, characterID, puppetID):
            guard let world = server(worldID),
                  let character = world.characters.first(where: { $0.id == characterID }),
                  let puppet = character.puppets.first(where: { $0.id == puppetID }) else {
                throw WorkspaceError.puppetNotFound
            }
            return .init(world: world.profile.name, character: character.name, puppet: puppet.name)
        }
    }

    private static func profileWrapper() throws -> LegacyConfigurationDocument {
        try LegacyConfigurationDocument(source: """
        Version=331
        Connections
        {
          Shortcuts
          {
          }
        }
        """)
    }

    private static func automationWrapper(kind: AutomationKind) throws -> LegacyConfigurationDocument {
        let collection = collectionName(for: kind)
        return try LegacyConfigurationDocument(source: """
        Version=331
        Connections
        {
          \(collection)
          {
          }
        }
        """)
    }

    private static func collectionName(for kind: AutomationKind) -> String {
        switch kind {
        case .aliases: "Aliases"
        case .triggers: "Triggers"
        case .macros: "KeyboardMacros2"
        }
    }

    private static func removeAutomationCollections(
        at path: [String],
        from document: inout LegacyConfigurationDocument
    ) throws {
        for kind in [AutomationKind.aliases, .triggers, .macros] {
            _ = try document.removeCollectionEntry(named: collectionName(for: kind), at: path)
        }
    }

    private static func pruneAutomation(
        at path: [String],
        context: ScopeNames,
        selected: ScopeNames,
        kind: AutomationKind,
        document: inout LegacyConfigurationDocument
    ) throws {
        for candidate in [AutomationKind.aliases, .triggers, .macros]
            where context != selected || candidate != kind {
            _ = try document.removeCollectionEntry(named: collectionName(for: candidate), at: path)
        }
    }

    private func sourceAutomationContexts(for kind: AutomationKind) throws -> [ScopeNames] {
        let collection = Self.collectionName(for: kind)
        var contexts: [ScopeNames] = []
        if document.hasBlock(at: ["Connections", collection]) {
            contexts.append(.init(world: nil, character: nil, puppet: nil))
        }
        for world in servers {
            let worldPath = ["Connections", "Shortcuts", world.profile.name]
            if document.hasBlock(at: worldPath + [collection]) {
                contexts.append(.init(world: world.profile.name, character: nil, puppet: nil))
            }
            for character in world.characters {
                let characterPath = worldPath + ["Characters", character.name]
                if document.hasBlock(at: characterPath + [collection]) {
                    contexts.append(.init(world: world.profile.name, character: character.name, puppet: nil))
                }
                for puppet in character.puppets where document.hasBlock(
                    at: characterPath + ["Puppets", puppet.name, collection]
                ) {
                    contexts.append(.init(world: world.profile.name, character: character.name, puppet: puppet.name))
                }
            }
        }
        return contexts
    }

    private func matchingScope(for names: ScopeNames) throws -> AutomationScope? {
        guard let worldName = names.world else { return .global }
        guard let world = projection.servers.first(where: {
            $0.profile.name.caseInsensitiveCompare(worldName) == .orderedSame
        }) else { return nil }
        guard let characterName = names.character else { return .server(world.profile.id) }
        guard let character = world.characters.first(where: {
            $0.name.caseInsensitiveCompare(characterName) == .orderedSame
        }) else { return nil }
        guard let puppetName = names.puppet else {
            return .character(server: world.profile.id, character: character.id)
        }
        guard let puppet = character.puppets.first(where: {
            $0.name.caseInsensitiveCompare(puppetName) == .orderedSame
        }) else { return nil }
        return .puppet(server: world.profile.id, character: character.id, puppet: puppet.id)
    }

    private func automationCount(in scope: AutomationScope, kind: AutomationKind) -> Int {
        switch kind {
        case .aliases: aliases(in: scope).count
        case .triggers: triggers(in: scope).count
        case .macros: macros(in: scope).count
        }
    }

    private func importLocation(
        _ destination: AutomationImportDestination,
        kind: AutomationKind
    ) throws -> (scope: AutomationScope, parentPath: [Int], index: Int?) {
        switch destination {
        case let .scope(scope):
            _ = try automationCollectionPath(scope, kind: kind)
            return (scope, [], nil)
        case let .folder(item):
            guard isFolder(at: item.path, in: item.scope, kind: kind) else {
                throw WorkspaceError.automationEntryNotFound
            }
            return (item.scope, item.path, nil)
        case let .afterItem(item):
            guard item.path.last != nil, automationExists(at: item.path, in: item.scope, kind: kind) else {
                throw WorkspaceError.automationEntryNotFound
            }
            return (item.scope, Array(item.path.dropLast()), item.path.last! + 1)
        }
    }

    private func automationExists(at path: [Int], in scope: AutomationScope, kind: AutomationKind) -> Bool {
        switch kind {
        case .aliases: alias(at: path, in: scope) != nil
        case .triggers: trigger(at: path, in: scope) != nil
        case .macros: macro(at: path, in: scope) != nil
        }
    }

    private func isFolder(at path: [Int], in scope: AutomationScope, kind: AutomationKind) -> Bool {
        switch kind {
        case .aliases: alias(at: path, in: scope)?.folder == true
        case .triggers: trigger(at: path, in: scope)?.folder == true
        case .macros: macro(at: path, in: scope)?.folder == true
        }
    }

    private func uniquelyNamedRawAutomation(
        _ raw: String,
        kind: AutomationKind,
        scope: AutomationScope,
        parentPath: [Int]
    ) throws -> String {
        let names: [String] = switch kind {
        case .aliases:
            parentPath.isEmpty ? aliases(in: scope).map(\.description) : alias(at: parentPath, in: scope)?.children.map(\.description) ?? []
        case .triggers:
            parentPath.isEmpty ? triggers(in: scope).map(\.description) : trigger(at: parentPath, in: scope)?.children.map(\.description) ?? []
        case .macros:
            parentPath.isEmpty ? macros(in: scope).map(\.description) : macro(at: parentPath, in: scope)?.children.map(\.description) ?? []
        }
        return try Self.uniquelyNamedRawAutomation(raw, kind: kind, existingNames: names)
    }

    private static func uniquelyNamedRawAutomation(
        _ raw: String,
        kind: AutomationKind,
        existingNames: [String]
    ) throws -> String {
        var temporary = try automationWrapper(kind: kind)
        let path = ["Connections", collectionName(for: kind)]
        _ = try temporary.appendRawUnnamedBlock(raw, at: path)
        guard let description = temporary.value(
            inUnnamedBlockAt: 0,
            collectionPath: path,
            relativePath: ["Description"]
        ), !description.isEmpty else { return raw }
        let unique = uniqueName(description, among: existingNames)
        guard unique != description else { return raw }
        try temporary.upsertValue(
            unique,
            inUnnamedBlockAt: 0,
            collectionPath: path,
            relativePath: ["Description"]
        )
        return temporary.rawUnnamedBlockSource(
            at: [0],
            collectionPath: path,
            nestedCollectionPath: [collectionName(for: kind)]
        ) ?? raw
    }

    private mutating func mergeAutomationCollections(
        from source: LegacyConfigurationDocument,
        sourcePath: [String],
        targetPath: [String]
    ) throws {
        for kind in [AutomationKind.aliases, .triggers, .macros] {
            let collection = Self.collectionName(for: kind)
            let sourceCollection = sourcePath + [collection]
            guard source.hasBlock(at: sourceCollection) else { continue }
            let targetCollection = targetPath + [collection]
            var existingNames = document.unnamedBlockValues(at: targetCollection).compactMap { values in
                values.first(where: { $0.key.caseInsensitiveCompare("Description") == .orderedSame })?.value
            }
            for raw in source.rawUnnamedBlockSources(at: sourceCollection) {
                let prepared = try Self.uniquelyNamedRawAutomation(raw, kind: kind, existingNames: existingNames)
                _ = try document.appendRawUnnamedBlock(prepared, at: targetCollection)
                var temporary = try Self.automationWrapper(kind: kind)
                _ = try temporary.appendRawUnnamedBlock(prepared, at: ["Connections", collection])
                if let name = temporary.value(
                    inUnnamedBlockAt: 0,
                    collectionPath: ["Connections", collection],
                    relativePath: ["Description"]
                ) { existingNames.append(name) }
            }
        }
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
        try writeTrigger(trigger, at: [index], collectionPath: collectionPath)
    }

    private mutating func writeTrigger(_ trigger: Trigger, at indexPath: [Int], collectionPath: [String]) throws {
        try document.upsertValue(trigger.description, inUnnamedBlockAt: indexPath, collectionPath: collectionPath, relativePath: ["Description"])
        try writeMatch(trigger.match, at: indexPath, collectionPath: collectionPath)
        try writeFlag(trigger.folder, at: indexPath, collectionPath: collectionPath, path: ["Folder"])
        try writeFlag(trigger.disabled, at: indexPath, collectionPath: collectionPath, path: ["Disabled"])
        try writeFlag(trigger.stopProcessing, at: indexPath, collectionPath: collectionPath, path: ["StopProcessing"])
        try writeFlag(trigger.oncePerLine, at: indexPath, collectionPath: collectionPath, path: ["OncePerLine"])
        try writeFlag(trigger.awayPresent, at: indexPath, collectionPath: collectionPath, path: ["AwayPresent"])
        try writeFlag(trigger.awayPresentOnce, at: indexPath, collectionPath: collectionPath, path: ["AwayPresentOnce"])
        try writeFlag(trigger.away, at: indexPath, collectionPath: collectionPath, path: ["Away"])
        try writeFlag(trigger.cooldown != nil, at: indexPath, collectionPath: collectionPath, path: ["Cooldown"])
        try writeValueIfNeeded(Self.time(trigger.cooldown ?? 0), at: indexPath, collectionPath: collectionPath, path: ["CooldownTime"], when: trigger.cooldown != nil)
        try writeFlag(trigger.multiline?.isEnabled == true, at: indexPath, collectionPath: collectionPath, path: ["Multiline"])
        try writeValueIfNeeded(String(trigger.multiline?.lineLimit ?? 0), at: indexPath, collectionPath: collectionPath, path: ["Multiline_Limit"], quoted: false, when: trigger.multiline?.isEnabled == true)
        try writeValueIfNeeded(Self.time(trigger.multiline?.timeLimit ?? 0), at: indexPath, collectionPath: collectionPath, path: ["Multiline_Time"], when: trigger.multiline?.isEnabled == true)
        try writeFlag(trigger.childrenActive, at: indexPath, collectionPath: collectionPath, path: ["Triggers", "Active"])

        let index = indexPath
        let color = trigger.actions.firstColor
        let colorDefault = trigger.actions.firstColorDefault
        let colorHash = trigger.actions.firstColorHash
        let font = trigger.actions.firstFont
        let colorWholeLine = color?.wholeLine ?? colorDefault?.wholeLine ?? colorHash?.wholeLine ?? font?.wholeLine ?? false
        try writeFlag(color?.foreground != nil, at: index, collectionPath: collectionPath, path: ["Color", "UseForeColor"])
        try writeValueWhenActive(color?.foreground.map(Self.colorString) ?? "#FFFFFF", at: index, collectionPath: collectionPath, path: ["Color", "Fore"], when: color?.foreground != nil)
        try writeFlag(color?.background != nil, at: index, collectionPath: collectionPath, path: ["Color", "UseBackColor"])
        try writeValueWhenActive(color?.background.map(Self.colorString) ?? "#000000", at: index, collectionPath: collectionPath, path: ["Color", "Back"], when: color?.background != nil)
        try writeFlag(colorDefault?.foreground == true, at: index, collectionPath: collectionPath, path: ["Color", "ForeDefault"])
        try writeFlag(colorDefault?.background == true, at: index, collectionPath: collectionPath, path: ["Color", "BackDefault"])
        try writeFlag(colorHash?.foreground == true, at: index, collectionPath: collectionPath, path: ["Color", "ForeHash"])
        try writeFlag(colorHash?.background == true, at: index, collectionPath: collectionPath, path: ["Color", "BackHash"])
        try writeFlag(font != nil, at: index, collectionPath: collectionPath, path: ["Color", "UseFont"])
        try writeFlag(font?.useDefault == true, at: index, collectionPath: collectionPath, path: ["Color", "FontDefault"])
        try writeValueWhenActive(font?.face ?? "", at: index, collectionPath: collectionPath, path: ["Color", "FontFace"], when: font != nil)
        try writeValueWhenActive(Self.time(font?.size ?? 0), at: index, collectionPath: collectionPath, path: ["Color", "FontSize"], when: font != nil)
        try writeFlag(colorWholeLine, at: index, collectionPath: collectionPath, path: ["Color", "WholeLine"])

        let appearance = trigger.actions.firstAppearance
        let patch = appearance?.patch ?? TextStylePatch()
        try writeOptionalStyle(patch.bold, setPath: ["Style", "SetBold"], valuePath: ["Style", "Bold"], at: index, collectionPath: collectionPath)
        try writeOptionalStyle(patch.italic, setPath: ["Style", "SetItalic"], valuePath: ["Style", "Italic"], at: index, collectionPath: collectionPath)
        try writeOptionalStyle(patch.underline, setPath: ["Style", "SetUnderline"], valuePath: ["Style", "Underline"], at: index, collectionPath: collectionPath)
        try writeOptionalStyle(patch.strikeout, setPath: ["Style", "SetStrikeout"], valuePath: ["Style", "Strikeout"], at: index, collectionPath: collectionPath)
        try writeFlag(patch.blink != nil, at: index, collectionPath: collectionPath, path: ["Style", "Flash"])
        try writeFlagWhenActive(patch.blink == .fast, at: index, collectionPath: collectionPath, path: ["Style", "FlashFast"], when: patch.blink != nil)
        try writeFlagWhenActive(appearance?.wholeLine == true, at: index, collectionPath: collectionPath, path: ["Style", "WholeLine"], when: appearance != nil)

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
        try writeFlagWhenActive(important, at: index, collectionPath: collectionPath, path: ["Activate", "ImportantActivity"], when: activate || important || activity || suppressActivity)
        try writeFlagWhenActive(activity, at: index, collectionPath: collectionPath, path: ["Activate", "Activity"], when: activate || important || activity || suppressActivity)
        try writeFlagWhenActive(suppressActivity, at: index, collectionPath: collectionPath, path: ["Activate", "NoActivity"], when: activate || important || activity || suppressActivity)

        let spawn = trigger.actions.firstSpawn
        try writeFlag(spawn != nil, at: index, collectionPath: collectionPath, path: ["Spawn", "Active"])
        try writeValueWhenActive(spawn?.title ?? "", at: index, collectionPath: collectionPath, path: ["Spawn", "Title"], when: spawn != nil)
        try writeValueWhenActive(spawn?.tabGroup ?? "", at: index, collectionPath: collectionPath, path: ["Spawn", "TabGroup"], when: spawn != nil)
        try writeValueWhenActive(spawn?.captureUntil ?? "", at: index, collectionPath: collectionPath, path: ["Spawn", "CaptureUntil"], when: spawn != nil)
        try writeFlagWhenActive(spawn?.onlyChildrenDuringCapture == true, at: index, collectionPath: collectionPath, path: ["Spawn", "OnlyChildrenDuringCapture"], when: spawn != nil)
        try writeFlagWhenActive(spawn?.clear == true, at: index, collectionPath: collectionPath, path: ["Spawn", "Clear"], when: spawn != nil)
        try writeFlagWhenActive(spawn?.showTab == true, at: index, collectionPath: collectionPath, path: ["Spawn", "ShowTab"], when: spawn != nil)
        try writeFlagWhenActive(spawn?.gagLog == true, at: index, collectionPath: collectionPath, path: ["Spawn", "GagLog"], when: spawn != nil)
        try writeFlagWhenActive(spawn?.copy == true, at: index, collectionPath: collectionPath, path: ["Spawn", "Copy"], when: spawn != nil)

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
        try writeValueWhenActive(sound ?? "", at: index, collectionPath: collectionPath, path: ["Sound", "Sound"], when: sound != nil)

        let speech = trigger.actions.firstSpeech
        try writeFlag(speech != nil, at: index, collectionPath: collectionPath, path: ["Speech", "Active"])
        try writeValueWhenActive(speech?.text ?? "", at: index, collectionPath: collectionPath, path: ["Speech", "Say"], when: speech != nil)
        try writeFlagWhenActive(speech?.wholeLine == true, at: index, collectionPath: collectionPath, path: ["Speech", "WholeLine"], when: speech != nil)

        let send = trigger.actions.firstSend
        try writeFlag(send != nil, at: index, collectionPath: collectionPath, path: ["Send", "Active"])
        try writeValueWhenActive(send?.text ?? "", at: index, collectionPath: collectionPath, path: ["Send", "Send"], when: send != nil)
        try writeValueWhenActive(String(send?.captureIndex ?? 1), at: index, collectionPath: collectionPath, path: ["Send", "CaptureIndex"], quoted: false, when: send != nil)
        try writeFlagWhenActive(send?.expandVariables == true, at: index, collectionPath: collectionPath, path: ["Send", "ExpandVariables"], when: send != nil)
        try writeFlagWhenActive(send?.sendOnClick == true, at: index, collectionPath: collectionPath, path: ["Send", "SendOnClick"], when: send != nil)

        try writeFlag(trigger.actions.contains(.notification), at: index, collectionPath: collectionPath, path: ["Toast", "Active"])

        let filter = trigger.actions.firstFilter
        try writeFlag(filter != nil, at: index, collectionPath: collectionPath, path: ["Filter", "Active"])
        try writeFlagWhenActive(filter?.html == true, at: index, collectionPath: collectionPath, path: ["Filter", "HTML"], when: filter != nil)
        try writeFlagWhenActive(filter?.expandVariables == true, at: index, collectionPath: collectionPath, path: ["Filter", "ExpandVariables"], when: filter != nil)
        try writeValueWhenActive(filter?.text ?? "", at: index, collectionPath: collectionPath, path: ["Filter", "Replace"], when: filter != nil)

        let avatar = trigger.actions.firstAvatar
        try writeValueIfNeeded(avatar ?? "", at: index, collectionPath: collectionPath, path: ["Avatar", "URL"], when: avatar != nil || triggerValueExists(at: index, collectionPath: collectionPath, path: ["Avatar", "URL"]))

        let script = trigger.actions.firstScript
        try writeFlag(script != nil, at: index, collectionPath: collectionPath, path: ["Script", "Active"])
        try writeValueWhenActive(script ?? "", at: index, collectionPath: collectionPath, path: ["Script", "Function"], when: script != nil)
        let existingChildCount = document.unnamedBlockCount(
            at: collectionPath,
            nestedIn: indexPath,
            nestedCollectionPath: ["Triggers"]
        )
        for (childIndex, child) in trigger.children.enumerated() {
            if childIndex >= existingChildCount {
                _ = try document.appendUnnamedBlock(
                    at: collectionPath,
                    nestedIn: indexPath,
                    nestedCollectionPath: ["Triggers"]
                )
            }
            try writeTrigger(child, at: indexPath + [childIndex], collectionPath: collectionPath)
        }
        try reloadProjectionAfterAutomationEdit()
    }

    private mutating func writeMatch(
        _ match: MatchDefinition,
        at index: Int,
        collectionPath: [String]
    ) throws {
        try writeMatch(match, at: [index], collectionPath: collectionPath)
    }

    private mutating func writeMatch(
        _ match: MatchDefinition,
        at index: [Int],
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
        var projected = try LegacyConfigurationProjection(document: document)
        Self.applyStableIDs(
            to: &projected,
            serverIDs: &stableServerIDs,
            characterIDs: &stableCharacterIDs,
            puppetIDs: &stablePuppetIDs
        )
        projection = projected
        isDirty = true
    }

    private static func identityKey(_ components: String...) -> String {
        components
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
            .joined(separator: "\u{1F}")
    }

    private static func serverIDs(in projection: LegacyConfigurationProjection) -> [String: UUID] {
        Dictionary(uniqueKeysWithValues: projection.servers.map { server in
            (identityKey(server.profile.name), server.profile.id)
        })
    }

    private static func characterIDs(in projection: LegacyConfigurationProjection) -> [String: UUID] {
        Dictionary(uniqueKeysWithValues: projection.servers.flatMap { server in
            server.characters.map { character in
                (identityKey(server.profile.name, character.name), character.id)
            }
        })
    }

    private static func puppetIDs(in projection: LegacyConfigurationProjection) -> [String: UUID] {
        Dictionary(uniqueKeysWithValues: projection.servers.flatMap { server in
            server.characters.flatMap { character in
                character.puppets.map { puppet in
                    (identityKey(server.profile.name, character.name, puppet.name), puppet.id)
                }
            }
        })
    }

    private static func applyStableIDs(
        to projection: inout LegacyConfigurationProjection,
        serverIDs: inout [String: UUID],
        characterIDs: inout [String: UUID],
        puppetIDs: inout [String: UUID]
    ) {
        for serverIndex in projection.servers.indices {
            let serverName = projection.servers[serverIndex].profile.name
            let serverKey = identityKey(serverName)
            let serverID = serverIDs[serverKey] ?? projection.servers[serverIndex].profile.id
            serverIDs[serverKey] = serverID
            projection.servers[serverIndex].profile.id = serverID

            for characterIndex in projection.servers[serverIndex].characters.indices {
                let characterName = projection.servers[serverIndex].characters[characterIndex].name
                let characterKey = identityKey(serverName, characterName)
                let characterID = characterIDs[characterKey] ?? projection.servers[serverIndex].characters[characterIndex].id
                characterIDs[characterKey] = characterID
                projection.servers[serverIndex].characters[characterIndex].id = characterID

                for puppetIndex in projection.servers[serverIndex].characters[characterIndex].puppets.indices {
                    let puppetName = projection.servers[serverIndex].characters[characterIndex].puppets[puppetIndex].name
                    let puppetKey = identityKey(serverName, characterName, puppetName)
                    let puppetID = puppetIDs[puppetKey] ?? projection.servers[serverIndex].characters[characterIndex].puppets[puppetIndex].id
                    puppetIDs[puppetKey] = puppetID
                    projection.servers[serverIndex].characters[characterIndex].puppets[puppetIndex].id = puppetID
                }
            }
        }
    }

    private static func flag(_ value: Bool) -> String { value ? "true" : "false" }

    private mutating func writeFlag(
        _ value: Bool,
        at index: [Int],
        collectionPath: [String],
        path: [String]
    ) throws {
        guard value || triggerValueExists(at: index, collectionPath: collectionPath, path: path) else { return }
        try document.upsertValue(Self.flag(value), inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: path, quoted: false)
    }

    private mutating func writeValueIfNeeded(
        _ value: String,
        at index: [Int],
        collectionPath: [String],
        path: [String],
        quoted: Bool = true,
        when shouldWrite: Bool
    ) throws {
        guard shouldWrite || triggerValueExists(at: index, collectionPath: collectionPath, path: path) else { return }
        try document.upsertValue(value, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: path, quoted: quoted)
    }

    private mutating func writeValueWhenActive(
        _ value: String,
        at index: [Int],
        collectionPath: [String],
        path: [String],
        quoted: Bool = true,
        when shouldWrite: Bool
    ) throws {
        guard shouldWrite else { return }
        try document.upsertValue(value, inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: path, quoted: quoted)
    }

    private mutating func writeFlagWhenActive(
        _ value: Bool,
        at index: [Int],
        collectionPath: [String],
        path: [String],
        when shouldWrite: Bool
    ) throws {
        guard shouldWrite else { return }
        try document.upsertValue(Self.flag(value), inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: path, quoted: false)
    }

    private mutating func writeOptionalStyle(
        _ value: Bool?,
        setPath: [String],
        valuePath: [String],
        at index: [Int],
        collectionPath: [String]
    ) throws {
        try writeFlag(value != nil, at: index, collectionPath: collectionPath, path: setPath)
        try writeFlagWhenActive(value == true, at: index, collectionPath: collectionPath, path: valuePath, when: value != nil)
    }

    private mutating func writeParagraph(
        _ paragraph: ParagraphPatch?,
        at index: [Int],
        collectionPath: [String]
    ) throws {
        try writeFlag(paragraph?.alignment != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseAlignment"])
        try writeValueWhenActive(Self.alignmentValue(paragraph?.alignment ?? .left), at: index, collectionPath: collectionPath, path: ["Paragraph", "Alignment"], quoted: false, when: paragraph?.alignment != nil)
        try writeFlag(paragraph?.leftIndent != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseIndent_Left"])
        try writeValueWhenActive(Self.time(paragraph?.leftIndent ?? 0), at: index, collectionPath: collectionPath, path: ["Paragraph", "Indent_Left"], when: paragraph?.leftIndent != nil)
        try writeFlag(paragraph?.rightIndent != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseIndent_Right"])
        try writeValueWhenActive(Self.time(paragraph?.rightIndent ?? 0), at: index, collectionPath: collectionPath, path: ["Paragraph", "Indent_Right"], when: paragraph?.rightIndent != nil)
        try writeFlag(paragraph?.topPadding != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UsePadding_Top"])
        try writeValueWhenActive(Self.time(paragraph?.topPadding ?? 0), at: index, collectionPath: collectionPath, path: ["Paragraph", "Padding_Top"], when: paragraph?.topPadding != nil)
        try writeFlag(paragraph?.bottomPadding != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UsePadding_Bottom"])
        try writeValueWhenActive(Self.time(paragraph?.bottomPadding ?? 0), at: index, collectionPath: collectionPath, path: ["Paragraph", "Padding_Bottom"], when: paragraph?.bottomPadding != nil)
        try writeFlag(paragraph?.background != nil || paragraph?.backgroundHash == true, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseBackgroundColor"])
        try writeValueWhenActive(paragraph?.background.map(Self.colorString) ?? "#000000", at: index, collectionPath: collectionPath, path: ["Paragraph", "Background"], when: paragraph?.background != nil)
        try writeFlag(paragraph?.backgroundHash == true, at: index, collectionPath: collectionPath, path: ["Paragraph", "BackgroundHash"])
        try writeFlag(paragraph?.borderWidth != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseBorder"])
        try writeValueWhenActive(Self.time(paragraph?.borderWidth ?? 0), at: index, collectionPath: collectionPath, path: ["Paragraph", "Border"], when: paragraph?.borderWidth != nil)
        try writeFlag(paragraph?.borderStyle != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseBorderStyle"])
        try writeValueWhenActive(paragraph?.borderStyle == .round ? "1" : "0", at: index, collectionPath: collectionPath, path: ["Paragraph", "BorderStyle"], quoted: false, when: paragraph?.borderStyle != nil)
        try writeFlag(paragraph?.strokeWidth != nil || paragraph?.strokeColor != nil || paragraph?.strokeHash == true || paragraph?.strokeStyle != nil, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseStroke"])
        try writeValueWhenActive(Self.time(paragraph?.strokeWidth ?? 0), at: index, collectionPath: collectionPath, path: ["Paragraph", "StrokeWidth"], when: paragraph?.strokeWidth != nil)
        try writeValueWhenActive(paragraph?.strokeColor.map(Self.colorString) ?? "#FFFFFF", at: index, collectionPath: collectionPath, path: ["Paragraph", "Stroke"], when: paragraph?.strokeColor != nil)
        try writeFlag(paragraph?.strokeHash == true, at: index, collectionPath: collectionPath, path: ["Paragraph", "StrokeHash"])
        try writeValueWhenActive(Self.strokeStyleValue(paragraph?.strokeStyle ?? .outline), at: index, collectionPath: collectionPath, path: ["Paragraph", "StrokeStyle"], quoted: false, when: paragraph?.strokeStyle != nil)
        try writeFlag(paragraph?.horizontalRule == true, at: index, collectionPath: collectionPath, path: ["Paragraph", "UseHorizontalRule"])
    }

    private func triggerValueExists(at index: [Int], collectionPath: [String], path: [String]) -> Bool {
        document.value(inUnnamedBlockAt: index, collectionPath: collectionPath, relativePath: path) != nil
    }

    private func aliasValueExists(at index: [Int], collectionPath: [String], path: [String]) -> Bool {
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
