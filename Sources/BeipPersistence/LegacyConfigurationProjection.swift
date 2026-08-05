import BeipAutomation
import BeipCore
import Foundation

/// Portable, typed view of the connection-related portion of Config.txt.
/// The syntax tree remains the source of truth so projecting it never drops
/// unknown or Windows-only properties.
public struct LegacyConfigurationProjection: Sendable, Equatable {
    public static let currentWindowsVersion = 331

    public enum ProjectionError: LocalizedError, Equatable {
        case newerConfiguration(found: Int, supported: Int)

        public var errorDescription: String? {
            switch self {
            case let .newerConfiguration(found, supported):
                "Config.txt is from version \(found), newer than supported Windows version \(supported); refusing a writable projection."
            }
        }
    }

    public struct ConnectionSettings: Sendable, Equatable {
        public var connectTimeoutMilliseconds: Int
        public var connectRetryCount: Int
        public var retryForever: Bool
        public var tcpKeepAlive: Bool
        public var tcpNoDelay: Bool

        public init(
            connectTimeoutMilliseconds: Int = 30_000,
            connectRetryCount: Int = 5,
            retryForever: Bool = false,
            tcpKeepAlive: Bool = true,
            tcpNoDelay: Bool = true
        ) {
            self.connectTimeoutMilliseconds = connectTimeoutMilliseconds
            self.connectRetryCount = connectRetryCount
            self.retryForever = retryForever
            self.tcpKeepAlive = tcpKeepAlive
            self.tcpNoDelay = tcpNoDelay
        }
    }

    /// Global scripting settings that are portable to the JavaScriptCore/XPC
    /// runtime. The source document remains lossless for all other OM fields.
    public struct Scripting: Sendable, Equatable {
        public var startupPath: String
        public var debugEnabled: Bool

        public init(startupPath: String = "", debugEnabled: Bool = false) {
            self.startupPath = startupPath
            self.debugEnabled = debugEnabled
        }
    }

    public struct Server: Sendable, Equatable {
        public var profile: ServerProfile
        public var characters: [CharacterProfile]
        public var automation: Automation
        public var restoreLogAssignments: [Int: String]

        public init(
            profile: ServerProfile,
            characters: [CharacterProfile],
            automation: Automation = .init(),
            restoreLogAssignments: [Int: String] = [:]
        ) {
            self.profile = profile
            self.characters = characters
            self.automation = automation
            self.restoreLogAssignments = restoreLogAssignments
        }
    }

    /// Read-only typed automation projection. Config.txt stays the source of
    /// truth, including unsupported trigger properties and unknown extensions.
    /// This supplies the portable alias/trigger subset to a live session.
    public struct Automation: Sendable, Equatable {
        public var aliases: AliasGroup
        public var triggers: TriggerGroup
        public var macros: KeyboardMacroGroup
        public var characters: [String: Scope]
        public var puppets: [String: Scope]

        public init(
            aliases: AliasGroup = .init(),
            triggers: TriggerGroup = .init(),
            macros: KeyboardMacroGroup = .init(),
            characters: [String: Scope] = [:],
            puppets: [String: Scope] = [:]
        ) {
            self.aliases = aliases
            self.triggers = triggers
            self.macros = macros
            self.characters = characters
            self.puppets = puppets
        }

        public struct Scope: Sendable, Equatable {
            public var aliases: AliasGroup
            public var triggers: TriggerGroup
            public var macros: KeyboardMacroGroup
            public var automaticLogFilename: String
            public var automaticLogAppendsDate: Bool
            public var variables: [String: String]

            public init(
                aliases: AliasGroup = .init(),
                triggers: TriggerGroup = .init(),
                macros: KeyboardMacroGroup = .init(),
                automaticLogFilename: String = "",
                automaticLogAppendsDate: Bool = false,
                variables: [String: String] = [:]
            ) {
                self.aliases = aliases
                self.triggers = triggers
                self.macros = macros
                self.automaticLogFilename = automaticLogFilename
                self.automaticLogAppendsDate = automaticLogAppendsDate
                self.variables = variables
            }
        }

        public func scope(for character: CharacterProfile?) -> Scope {
            guard let character else { return .init() }
            return characters[character.name.folding(options: [.caseInsensitive], locale: .current)] ?? .init()
        }

        public func puppetScope(for character: CharacterProfile?, puppet: PuppetProfile?) -> Scope {
            guard let character, let puppet else { return .init() }
            return puppets[Self.puppetKey(character.name, puppet.name)] ?? .init()
        }

        fileprivate static func puppetKey(_ character: String, _ puppet: String) -> String {
            "\(character.folding(options: [.caseInsensitive], locale: .current))/\(puppet.folding(options: [.caseInsensitive], locale: .current))"
        }
    }

    public var automation: Automation

    public var sourceVersion: Int
    public var settings: ConnectionSettings
    public var scripting: Scripting
    public var logging: SessionLogOptions
    public var loggingPath: String
    public var servers: [Server]

    public init(document: LegacyConfigurationDocument) throws {
        let version = document.rootValue("Version").flatMap(Int.init) ?? 0
        guard version <= Self.currentWindowsVersion else {
            throw ProjectionError.newerConfiguration(found: version, supported: Self.currentWindowsVersion)
        }
        sourceVersion = version
        let connections = document.firstBlock(named: "Connections")?.children ?? []
        let globalAutomation = Self.automation(from: connections)
        automation = globalAutomation
        settings = .init(
            connectTimeoutMilliseconds: connections.value("ConnectTimeout").flatMap(Int.init) ?? 30_000,
            connectRetryCount: connections.value("ConnectRetry").flatMap(Int.init) ?? 5,
            retryForever: connections.bool("RetryForever") ?? false,
            tcpKeepAlive: document.rootBool("TCP_KeepAlive") ?? true,
            tcpNoDelay: document.rootBool("TCP_NoDelay") ?? true
        )
        scripting = .init(
            startupPath: document.rootValue("ScriptStartup") ?? "",
            debugEnabled: document.rootBool("ScriptDebug") ?? false
        )
        let loggingNodes = connections.properties(named: "Logging")
        logging = Self.loggingOptions(from: loggingNodes)
        loggingPath = loggingNodes?.value("Path") ?? ""

        let shortcutNodes = connections.firstBlock(named: "Shortcuts")?.children ?? []
        servers = shortcutNodes.namedBlocks().map { name, children in
            var hostValue = children.value("Host") ?? "example.com:8889"
            if version < 215, !Self.hasPort(hostValue), let oldPort = children.value("Port") {
                hostValue += ":\(oldPort)"
            }
            let endpoint = Self.endpoint(hostValue)
            let encoding = TextEncoding(rawValue: children.value("Encoding")?.uppercased() ?? "CP1252") ?? .cp1252
            // Before build 261 the non-default Client GUID selected the TLS
            // transport. The serializer omitted the standard-client default,
            // so a persisted Client value is the legacy TLS selection.
            let usesTLS = version < 261
                ? children.value("Client") != nil
                : children.bool("TLS") ?? false
            let profile = ServerProfile(
                name: name,
                host: endpoint.host,
                info: version < 258
                    ? Self.legacyMigratedInfo(
                        children.value("Info") ?? "",
                        oldName: children.value("Name"),
                        shortcut: name
                    )
                    : children.value("Info") ?? "",
                port: endpoint.port,
                characterExpirationTime: children.value("CharacterExpirationTime").flatMap(Int.init) ?? 0,
                encoding: encoding,
                usesTLS: usesTLS,
                verifiesCertificate: children.bool("VerifyCertificate") ?? false,
                forceIPv4: children.bool("IPV4") ?? false,
                pueblo: children.bool("Pueblo") ?? false,
                prompts: children.bool("Prompts") ?? false,
                mcp: children.bool("MCP") ?? false,
                mcmp: children.bool("MCMP") ?? false,
                gmcpWebViewPolicy: children.value("GMCP_WebView").flatMap(Int.init).flatMap(ServerWebViewPolicy.init(rawValue:)) ?? .ask,
                sendNAWSOnResize: children.bool("NAWSOnResize") ?? false,
                limitTelnetCharset: children.bool("LimitTelnetCharset") ?? false,
                aiEndpoint: (children.value("AIEndpoint") ?? children.value("AI")).flatMap(URL.init(string:)),
                aiModel: children.value("AIModel") ?? ""
            )
            let characterNodes = children.firstBlock(named: "Characters")?.children ?? []
            let namedCharacters = characterNodes.namedBlocks()
            let characters = namedCharacters.map { characterName, properties in
                let puppetNodes = properties.firstBlock(named: "Puppets")?.children ?? []
                let puppets = puppetNodes.namedBlocks().map { puppetName, puppetProperties in
                    PuppetProfile(
                        name: puppetName,
                        receivePrefix: puppetProperties.value("ReceivePrefix") ?? "",
                        sendPrefix: puppetProperties.value("SendPrefix") ?? "",
                        receivePrefixIsRegex: puppetProperties.bool("RegularExpression") ?? false,
                        hideReceivePrefix: puppetProperties.bool("HideReceivePrefix") ?? true,
                        autoConnect: puppetProperties.bool("AutoConnect") ?? true,
                        connectWithPlayer: puppetProperties.bool("ConnectWithPlayer") ?? false,
                        removeAccidentalPrefix: puppetProperties.bool("RemoveAccidentalPrefix") ?? false,
                        logFilename: puppetProperties.value("LogFileName") ?? "",
                        logAppendsDate: (puppetProperties.value("LogFileNameTimeFormat").flatMap(Int.init) ?? 0) & 0b110 != 0,
                        characterLog: puppetProperties.bool("CharacterLog") ?? false,
                        characterLogPrefix: puppetProperties.value("CharacterLogPrefix") ?? ""
                    )
                }
                return CharacterProfile(
                    name: characterName,
                    connectText: properties.value("Connect") ?? "",
                    password: properties.value("Password") ?? "",
                    info: version < 258
                        ? Self.legacyMigratedInfo(
                            properties.value("Info") ?? "",
                            oldName: properties.value("Name"),
                            shortcut: characterName
                        )
                        : properties.value("Info") ?? "",
                    autoConnect: properties.bool("ConnectAtStartup") ?? false,
                    idleTimeout: Self.idleTimeout(properties),
                    idleText: properties.value("IdleString") ?? "",
                    logFilename: properties.value("LogFileName") ?? "",
                    logAppendsDate: (properties.value("LogFileNameTimeFormat").flatMap(Int.init) ?? 0) & 0b110 != 0,
                    restoreLog: properties.bool("RestoreLog") ?? true,
                    restoreLogIndex: properties.value("RestoreLogIndex").flatMap(Int.init) ?? -1,
                    bytesSent: properties.value("BytesSent").flatMap(UInt64.init) ?? 0,
                    bytesReceived: properties.value("BytesReceived").flatMap(UInt64.init) ?? 0,
                    secondsConnected: properties.value("SecondsConnected").flatMap(UInt64.init) ?? 0,
                    connectionCount: properties.value("ConnectionCount").flatMap(UInt64.init) ?? 0,
                    lastUsed: properties.value("LastUsed") ?? "",
                    created: properties.value("Created") ?? "",
                    variables: Self.variables(properties),
                    puppets: puppets
                )
            }
            var serverAutomation = Self.automation(from: children)
            for (characterName, properties) in characterNodes.namedBlocks() {
                serverAutomation.characters[characterName.folding(options: [.caseInsensitive], locale: .current)] = Self.scope(from: properties)
                for (puppetName, puppetProperties) in properties.firstBlock(named: "Puppets")?.children.namedBlocks() ?? [] {
                    serverAutomation.puppets[Automation.puppetKey(characterName, puppetName)] = Self.scope(from: puppetProperties)
                }
            }
            let restoreLogAssignments: [Int: String] = Dictionary(uniqueKeysWithValues: namedCharacters.compactMap { characterName, properties in
                guard let index = properties.value("RestoreLogIndex").flatMap(Int.init), index >= 0 else { return nil }
                return (index, "\(name) - \(characterName)")
            })
            return Server(
                profile: profile,
                characters: characters,
                automation: serverAutomation,
                restoreLogAssignments: restoreLogAssignments
            )
        }
    }

    public var connectionPolicy: ConnectionPolicy {
        return .init(
            connectTimeoutMilliseconds: settings.connectTimeoutMilliseconds,
            retryCount: settings.connectRetryCount,
            retryForever: settings.retryForever,
            keepAlive: settings.tcpKeepAlive,
            noDelay: settings.tcpNoDelay
        )
    }

    /// Builds the exact global → server → character → server → global order
    /// used by Connection.cpp. Alias scope activation retains its legacy
    /// master-switch behavior; trigger scopes are always included and their
    /// AfterCount values only determine the ordered pre/post slices.
    public func automationGroups(
        for server: ServerProfile,
        character: CharacterProfile?
    ) -> (aliases: [AliasGroup], triggers: [TriggerGroup]) {
        automationGroups(for: server, character: character, puppet: nil)
    }

    public func automationGroups(
        for server: ServerProfile,
        character: CharacterProfile?,
        puppet: PuppetProfile?
    ) -> (aliases: [AliasGroup], triggers: [TriggerGroup]) {
        guard let selected = servers.first(where: { $0.profile.id == server.id }) else {
            return ([], [])
        }
        let characterScope = selected.automation.scope(for: character)
        let puppetScope = selected.automation.puppetScope(for: character, puppet: puppet)
        let aliases = Self.aliasGroups(
            global: automation.aliases,
            server: selected.automation.aliases,
            character: characterScope.aliases,
            puppet: puppetScope.aliases
        )
        let triggers = Self.triggerGroups(
            global: automation.triggers,
            server: selected.automation.triggers,
            character: characterScope.triggers,
            puppet: puppetScope.triggers
        )
        return (aliases, triggers)
    }

    /// Keyboard macros resolve character before server before global, unlike
    /// aliases/triggers which use pre/post slices around every scope.
    public func macroGroups(for server: ServerProfile, character: CharacterProfile?) -> [KeyboardMacroGroup] {
        macroGroups(for: server, character: character, puppet: nil)
    }

    public func macroGroups(for server: ServerProfile, character: CharacterProfile?, puppet: PuppetProfile?) -> [KeyboardMacroGroup] {
        guard automation.macros.active,
              let selected = servers.first(where: { $0.profile.id == server.id }) else { return [] }
        let characterScope = selected.automation.scope(for: character)
        let puppetScope = selected.automation.puppetScope(for: character, puppet: puppet)
        var result = [characterScope.macros, selected.automation.macros, automation.macros]
        if puppet != nil { result.insert(puppetScope.macros, at: 0) }
        return result
    }

    public func variables(for server: ServerProfile, character: CharacterProfile?, puppet: PuppetProfile?) -> [String: String] {
        guard let selected = servers.first(where: { $0.profile.id == server.id }) else { return character?.variables ?? [:] }
        let characterScope = selected.automation.scope(for: character)
        let puppetScope = selected.automation.puppetScope(for: character, puppet: puppet)
        return (character?.variables ?? [:]).merging(characterScope.variables) { _, value in value }
            .merging(puppetScope.variables) { _, value in value }
    }

    public func automaticLog(for server: ServerProfile, character: CharacterProfile?) -> (filename: String, appendsDate: Bool)? {
        guard let character, !character.logFilename.isEmpty else { return nil }
        return (character.logFilename, character.logAppendsDate)
    }

    public func startupConnections() -> [ConnectionRequest] {
        servers.flatMap { server in
            server.characters.compactMap { character in
                guard character.autoConnect else { return nil }
                return ConnectionRequest(server: server.profile, character: character, policy: connectionPolicy)
            }
        }
    }

    /// Writes all portable connection fields into the existing legacy tree.
    /// Unknown fields, comments, ordering, and Windows-only values are retained.
    public func applying(
        to document: LegacyConfigurationDocument,
        targetVersion: Int = Self.currentWindowsVersion
    ) throws -> LegacyConfigurationDocument {
        guard targetVersion <= Self.currentWindowsVersion else {
            throw ProjectionError.newerConfiguration(found: targetVersion, supported: Self.currentWindowsVersion)
        }
        var result = document
        try migratePortableLegacyValues(in: &result)
        try removeStaleProfileEntries(from: &result)
        try result.upsertValue(String(targetVersion), at: ["Version"], quoted: false)
        try Self.upsert(
            String(settings.connectTimeoutMilliseconds), default: "30000",
            at: ["Connections", "ConnectTimeout"], quoted: false, in: &result
        )
        try Self.upsert(
            String(settings.connectRetryCount), default: "5",
            at: ["Connections", "ConnectRetry"], quoted: false, in: &result
        )
        try Self.upsert(
            Self.flag(settings.retryForever), default: "false",
            at: ["Connections", "RetryForever"], quoted: false, in: &result
        )
        try Self.upsert(
            Self.flag(settings.tcpKeepAlive), default: "true",
            at: ["TCP_KeepAlive"], quoted: false, in: &result
        )
        try Self.upsert(
            Self.flag(settings.tcpNoDelay), default: "true",
            at: ["TCP_NoDelay"], quoted: false, in: &result
        )
        try Self.upsert(scripting.startupPath, default: "", at: ["ScriptStartup"], in: &result)
        try Self.upsert(
            Self.flag(scripting.debugEnabled), default: "false",
            at: ["ScriptDebug"], quoted: false, in: &result
        )

        for server in servers {
            let base = ["Connections", "Shortcuts", server.profile.name]
            let host = server.profile.host.contains(":") ? "[\(server.profile.host)]:\(server.profile.port)" : "\(server.profile.host):\(server.profile.port)"
            try result.upsertValue(host, at: base + ["Host"])
            try Self.upsert(server.profile.info, default: "", at: base + ["Info"], in: &result)
            try Self.upsert(
                String(server.profile.characterExpirationTime), default: "0",
                at: base + ["CharacterExpirationTime"], quoted: false, in: &result
            )
            try Self.upsert(
                server.profile.encoding.rawValue, default: TextEncoding.cp1252.rawValue,
                at: base + ["Encoding"], quoted: false, in: &result
            )
            for (name, enabled, defaultValue) in [
                ("TLS", server.profile.usesTLS, false),
                ("VerifyCertificate", server.profile.verifiesCertificate, false),
                ("IPV4", server.profile.forceIPv4, false),
                ("Pueblo", server.profile.pueblo, false),
                ("Prompts", server.profile.prompts, false),
                ("MCP", server.profile.mcp, false),
                ("MCMP", server.profile.mcmp, false),
                ("NAWSOnResize", server.profile.sendNAWSOnResize, false),
                ("LimitTelnetCharset", server.profile.limitTelnetCharset, false),
            ] {
                try Self.upsert(
                    Self.flag(enabled), default: Self.flag(defaultValue),
                    at: base + [name], quoted: false, in: &result
                )
            }
            // AIEndpoint/AIModel are Mac projection extensions, not v331
            // properties. Update pre-existing syntax so existing Mac profiles
            // remain editable, but never introduce either field into a
            // Windows configuration.
            if result.value(at: base + ["AIEndpoint"]) != nil {
                try result.upsertValue(
                    server.profile.aiEndpoint?.absoluteString ?? "",
                    at: base + ["AIEndpoint"]
                )
            }
            if result.value(at: base + ["AIModel"]) != nil {
                try result.upsertValue(server.profile.aiModel, at: base + ["AIModel"])
            }
            try Self.upsert(
                String((server.profile.gmcpWebViewPolicy ?? .ask).rawValue), default: "2",
                at: base + ["GMCP_WebView"], quoted: false, in: &result
            )
            for character in server.characters {
                let characterBase = base + ["Characters", character.name]
                try Self.upsert(
                    character.connectText, default: "",
                    at: characterBase + ["Connect"], in: &result
                )
                try Self.upsert(
                    character.password, default: "",
                    at: characterBase + ["Password"], in: &result
                )
                if sourceVersion >= 261 || !character.info.isEmpty {
                    try Self.upsert(
                        character.info, default: "",
                        at: characterBase + ["Info"], in: &result
                    )
                }
                try Self.upsert(
                    Self.flag(character.autoConnect), default: "false",
                    at: characterBase + ["ConnectAtStartup"], quoted: false, in: &result
                )
                let idleEnabled = character.idleTimeout != nil && !character.idleText.isEmpty
                try Self.upsert(
                    Self.flag(idleEnabled), default: "false",
                    at: characterBase + ["IdleEnabled"], quoted: false, in: &result
                )
                if let timeout = character.idleTimeout {
                    try result.upsertValue(String(Int(timeout / 60)), at: characterBase + ["IdleTimeout"], quoted: false)
                    try result.upsertValue(character.idleText, at: characterBase + ["IdleString"])
                }
                try Self.upsert(
                    character.logFilename, default: "",
                    at: characterBase + ["LogFileName"], in: &result
                )
                try Self.upsert(
                    character.logAppendsDate ? "6" : "0", default: "0",
                    at: characterBase + ["LogFileNameTimeFormat"], quoted: false, in: &result
                )
                try Self.upsert(
                    Self.flag(character.restoreLog), default: "true",
                    at: characterBase + ["RestoreLog"], quoted: false, in: &result
                )
                try Self.upsert(
                    String(character.restoreLogIndex), default: "-1",
                    at: characterBase + ["RestoreLogIndex"], quoted: false, in: &result
                )
                try Self.upsert(
                    String(character.bytesSent), default: "0",
                    at: characterBase + ["BytesSent"], quoted: false, in: &result
                )
                try Self.upsert(
                    String(character.bytesReceived), default: "0",
                    at: characterBase + ["BytesReceived"], quoted: false, in: &result
                )
                try Self.upsert(
                    String(character.secondsConnected), default: "0",
                    at: characterBase + ["SecondsConnected"], quoted: false, in: &result
                )
                try Self.upsert(
                    String(character.connectionCount), default: "0",
                    at: characterBase + ["ConnectionCount"], quoted: false, in: &result
                )
                try Self.upsert(character.lastUsed, default: "", at: characterBase + ["LastUsed"], in: &result)
                try Self.upsert(character.created, default: "", at: characterBase + ["Created"], in: &result)
                for puppet in character.puppets {
                    let puppetBase = characterBase + ["Puppets", puppet.name]
                    try result.upsertValue(puppet.receivePrefix, at: puppetBase + ["ReceivePrefix"])
                    try result.upsertValue(puppet.sendPrefix, at: puppetBase + ["SendPrefix"])
                    try Self.upsert(
                        puppet.logFilename, default: "",
                        at: puppetBase + ["LogFileName"], in: &result
                    )
                    try Self.upsert(
                        puppet.logAppendsDate ? "6" : "0", default: "0",
                        at: puppetBase + ["LogFileNameTimeFormat"], quoted: false, in: &result
                    )
                    try Self.upsert(
                        puppet.characterLogPrefix, default: "",
                        at: puppetBase + ["CharacterLogPrefix"], in: &result
                    )
                    for (name, enabled, defaultValue) in [
                        ("RegularExpression", puppet.receivePrefixIsRegex, false),
                        ("HideReceivePrefix", puppet.hideReceivePrefix, true),
                        ("AutoConnect", puppet.autoConnect, true),
                        ("ConnectWithPlayer", puppet.connectWithPlayer, false),
                        ("RemoveAccidentalPrefix", puppet.removeAccidentalPrefix, false),
                        ("CharacterLog", puppet.characterLog, false),
                    ] {
                        try Self.upsert(
                            Self.flag(enabled), default: Self.flag(defaultValue),
                            at: puppetBase + [name], quoted: false, in: &result
                        )
                    }
                }
            }
        }
        return result
    }

    /// Mirrors v331's ShowDefaults=false serializer: an existing field is
    /// updated in place, while a missing field is introduced only when its
    /// value differs from the v331 default.
    private static func upsert(
        _ value: String,
        default defaultValue: String,
        at path: [String],
        quoted: Bool = true,
        in document: inout LegacyConfigurationDocument
    ) throws {
        guard document.value(at: path) != nil || value != defaultValue else { return }
        try document.upsertValue(value, at: path, quoted: quoted)
    }

    /// Reconciles deletions before portable fields are upserted. This is kept
    /// separate from projection so unknown properties on retained entries stay
    /// exactly where they were in the original syntax tree.
    private func removeStaleProfileEntries(from document: inout LegacyConfigurationDocument) throws {
        let connections = document.firstBlock(named: "Connections")?.children ?? []
        let shortcutNodes = connections.firstBlock(named: "Shortcuts")?.children ?? []
        var desiredServers: [String: Server] = [:]
        for server in servers { desiredServers[server.profile.name.lowercased()] = server }

        for (serverName, serverNodes) in shortcutNodes.namedBlocks() {
            guard let desiredServer = desiredServers[serverName.lowercased()] else {
                try document.removeCollectionEntry(
                    named: serverName,
                    at: ["Connections", "Shortcuts"]
                )
                continue
            }

            let characterNodes = serverNodes.firstBlock(named: "Characters")?.children ?? []
            var desiredCharacters: [String: CharacterProfile] = [:]
            for character in desiredServer.characters { desiredCharacters[character.name.lowercased()] = character }
            for (characterName, properties) in characterNodes.namedBlocks() {
                guard let desiredCharacter = desiredCharacters[characterName.lowercased()] else {
                    try document.removeCollectionEntry(
                        named: characterName,
                        at: ["Connections", "Shortcuts", serverName, "Characters"]
                    )
                    continue
                }

                let puppetNodes = properties.firstBlock(named: "Puppets")?.children ?? []
                let desiredPuppets = Set(desiredCharacter.puppets.map { $0.name.lowercased() })
                for (puppetName, _) in puppetNodes.namedBlocks()
                    where !desiredPuppets.contains(puppetName.lowercased()) {
                    try document.removeCollectionEntry(
                        named: puppetName,
                        at: [
                            "Connections", "Shortcuts", serverName,
                            "Characters", characterName, "Puppets",
                        ]
                    )
                }
            }
        }
    }

    /// Applies the connection-related version gates from Config.cpp before
    /// stamping a modern version. Windows-only UI nodes are deliberately left
    /// byte-for-byte intact, as required by the shared-core contract.
    private func migratePortableLegacyValues(in document: inout LegacyConfigurationDocument) throws {
        guard sourceVersion < 261 else { return }
        let connections = document.firstBlock(named: "Connections")?.children ?? []
        let shortcutNodes = connections.firstBlock(named: "Shortcuts")?.children ?? []
        for (serverName, serverNodes) in shortcutNodes.namedBlocks() {
            let serverBase = ["Connections", "Shortcuts", serverName]
            if sourceVersion < 258 {
                try Self.migrateDeprecatedName(in: &document, nodes: serverNodes, base: serverBase, shortcut: serverName)
                let characterNodes = serverNodes.firstBlock(named: "Characters")?.children ?? []
                for (characterName, properties) in characterNodes.namedBlocks() {
                    try Self.migrateDeprecatedName(
                        in: &document,
                        nodes: properties,
                        base: serverBase + ["Characters", characterName],
                        shortcut: characterName
                    )
                }
            }
            if sourceVersion < 261, serverNodes.value("TLS") == nil,
               serverNodes.value("Client") != nil {
                try document.upsertValue("true", at: serverBase + ["TLS"], quoted: false)
            }
        }
    }

    private static func automation(from nodes: [LegacyConfigurationDocument.Node]) -> Automation {
        .init(
            aliases: aliasGroup(from: nodes.firstBlock(named: "Aliases")?.children),
            triggers: triggerGroup(from: nodes.firstBlock(named: "Triggers")?.children),
            macros: macroGroup(from: nodes.firstBlock(named: "KeyboardMacros2")?.children)
        )
    }

    private static func scope(from nodes: [LegacyConfigurationDocument.Node]) -> Automation.Scope {
        let timeFormat = nodes.value("LogFileNameTimeFormat").flatMap(Int.init) ?? 0
        return .init(
            aliases: aliasGroup(from: nodes.firstBlock(named: "Aliases")?.children),
            triggers: triggerGroup(from: nodes.firstBlock(named: "Triggers")?.children),
            macros: macroGroup(from: nodes.firstBlock(named: "KeyboardMacros2")?.children),
            automaticLogFilename: nodes.value("LogFileName") ?? "",
            automaticLogAppendsDate: timeFormat & 0b110 != 0,
            variables: variables(nodes)
        )
    }

    private static func loggingOptions(from nodes: [LegacyConfigurationDocument.Node]?) -> SessionLogOptions {
        guard let nodes else { return .init() }
        let timeFormat = nodes.value("TimeFormat").flatMap(Int.init) ?? 0
        let wraps = nodes.bool("Wrap") ?? false
        let hanging = nodes.bool("HangingIndent") ?? false
        return .init(
            defaultLogFilename: nodes.value("DefaultLogFileName") ?? "",
            fileDateFormat: nodes.value("FileDateFormat") ?? "yyyy-MM-dd",
            logsSentText: nodes.bool("LogSent") ?? false,
            sentPrefix: nodes.value("SentPrefix") ?? "Sent>",
            logsTypedText: nodes.bool("LogTyped") ?? false,
            typedPrefix: nodes.value("TypedPrefix") ?? "Typed>",
            includesTime: timeFormat & 0b010 != 0,
            includesDate: timeFormat & 0b100 != 0,
            uses24HourTime: timeFormat & 0b1000 != 0,
            wrapWidth: wraps ? (nodes.value("WrapChars").flatMap(Int.init) ?? 80) : nil,
            hangingIndent: hanging ? (nodes.value("HangingIndentChars").flatMap(Int.init) ?? 2) : 0,
            wrapsAtWords: nodes.bool("WrapNearestWord") ?? true,
            doubleSpaces: nodes.bool("DoubleSpace") ?? false
        )
    }

    private static func macroGroup(from nodes: [LegacyConfigurationDocument.Node]?) -> KeyboardMacroGroup {
        guard let nodes else { return .init() }
        return .init(
            active: nodes.bool("Active") ?? true,
            macros: nodes.unnamedBlocks().map(macro)
        )
    }

    private static func macro(_ nodes: [LegacyConfigurationDocument.Node]) -> KeyboardMacro {
        let childGroup = nodes.firstBlock(named: "KeyboardMacros2")
        let description = nodes.value("Description") ?? ""
        let text = nodes.value("Macro") ?? ""
        let key = nodes.value("key") ?? ""
        let typeIntoInput = nodes.bool("Type") ?? false
        let folder = nodes.bool("Folder") ?? false
        let childrenActive = childGroup?.children.bool("Active") ?? true
        let children = macroGroup(from: childGroup?.children).macros
        return .init(
            description: description,
            macro: text,
            key: key,
            typeIntoInput: typeIntoInput,
            folder: folder,
            children: children,
            childrenActive: childrenActive
        )
    }

    private static func aliasGroup(from nodes: [LegacyConfigurationDocument.Node]?) -> AliasGroup {
        guard let nodes else { return .init() }
        let echo = nodes.bool("Echo") ?? true
        let processCommands = nodes.bool("ProcessCommands") ?? false
        return .init(
            active: nodes.bool("Active") ?? false,
            echo: echo,
            processCommands: processCommands,
            afterCount: nodes.value("AfterCount").flatMap(Int.init) ?? 0,
            aliases: nodes.unnamedBlocks().map {
                alias($0, inheritedEcho: echo, inheritedProcessCommands: processCommands)
            }
        )
    }

    private static func alias(
        _ nodes: [LegacyConfigurationDocument.Node],
        inheritedEcho: Bool = true,
        inheritedProcessCommands: Bool = false
    ) -> Alias {
        let childNodes = nodes.firstBlock(named: "Aliases")?.children
        let childGroup = aliasGroup(from: childNodes)
        return Alias(
            description: nodes.value("Description") ?? "",
            match: matchDefinition(from: nodes),
            example: nodes.value("Example") ?? "",
            replacement: nodes.value("Replace") ?? "",
            folder: nodes.bool("Folder") ?? false,
            active: nodes.bool("Active") ?? true,
            echo: nodes.bool("Echo") ?? inheritedEcho,
            processCommands: nodes.bool("ProcessCommands") ?? inheritedProcessCommands,
            stopProcessing: nodes.bool("StopProcessing") ?? false,
            expandVariables: nodes.bool("ExpandVariables") ?? false,
            children: childGroup.aliases,
            childrenActive: childGroup.active,
            childrenAfterCount: childGroup.afterCount
        )
    }

    private static func triggerGroup(from nodes: [LegacyConfigurationDocument.Node]?) -> TriggerGroup {
        guard let nodes else { return .init(active: false) }
        return .init(
            active: nodes.bool("Active") ?? true,
            afterCount: nodes.value("AfterCount").flatMap(Int.init) ?? 0,
            triggers: nodes.unnamedBlocks().map(trigger)
        )
    }

    private static func trigger(_ nodes: [LegacyConfigurationDocument.Node]) -> Trigger {
        let cooldown = nodes.bool("Cooldown") == true
            ? (nodes.value("CooldownTime").flatMap(TimeInterval.init) ?? 0)
            : nil
        let multiline: MultilineTriggerOptions? = nodes.bool("Multiline") == true
            ? .init(
                lineLimit: nodes.value("Multiline_Limit").flatMap(Int.init) ?? 0,
                timeLimit: nodes.value("Multiline_Time").flatMap(TimeInterval.init) ?? 0
            ) : nil
        let childGroup = triggerGroup(from: nodes.firstBlock(named: "Triggers")?.children)
        return Trigger(
            description: nodes.value("Description") ?? "",
            match: matchDefinition(from: nodes),
            folder: nodes.bool("Folder") ?? false,
            disabled: nodes.bool("Disabled") ?? false,
            stopProcessing: nodes.bool("StopProcessing") ?? false,
            oncePerLine: nodes.bool("OncePerLine") ?? false,
            awayPresent: nodes.bool("AwayPresent") ?? false,
            awayPresentOnce: nodes.bool("AwayPresentOnce") ?? false,
            away: nodes.bool("Away") ?? true,
            cooldown: cooldown,
            multiline: multiline,
            actions: triggerActions(from: nodes),
            children: childGroup.triggers,
            childrenActive: childGroup.active
        )
    }

    private static func matchDefinition(from nodes: [LegacyConfigurationDocument.Node]) -> MatchDefinition {
        // v331 canonicalizes edited match blocks to dotted assignments such as
        // `FindString.MatchText="WORLD:"`. Treat dotted and braced forms as
        // the same logical block so a Windows resave remains loadable on Mac.
        let find = nodes.namedBlocks().first {
            $0.0.caseInsensitiveCompare("FindString") == .orderedSame
        }?.1 ?? nodes
        return .init(
            text: find.value("MatchText") ?? "",
            isRegularExpression: find.bool("RegularExpression") ?? false,
            matchCase: find.bool("MatchCase") ?? false,
            startsWith: find.bool("StartsWith") ?? false,
            endsWith: find.bool("EndsWith") ?? false,
            wholeWord: find.bool("WholeWord") ?? false
        )
    }

    private static func triggerActions(from nodes: [LegacyConfigurationDocument.Node]) -> [TriggerAction] {
        var actions: [TriggerAction] = []
        if let color = nodes.firstBlock(named: "Color")?.children {
            let foreground = color.bool("UseForeColor") == true
                ? parseColor(color.value("Fore")) : nil
            let background = color.bool("UseBackColor") == true
                ? parseColor(color.value("Back")) : nil
            if foreground != nil || background != nil {
                actions.append(.color(
                    foreground: foreground,
                    background: background,
                    wholeLine: color.bool("WholeLine") ?? false
                ))
            }
            let wholeLine = color.bool("WholeLine") ?? false
            let defaultForeground = color.bool("ForeDefault") ?? false
            let defaultBackground = color.bool("BackDefault") ?? false
            if defaultForeground || defaultBackground {
                actions.append(.colorDefault(foreground: defaultForeground, background: defaultBackground, wholeLine: wholeLine))
            }
            let hashForeground = color.bool("ForeHash") ?? false
            let hashBackground = color.bool("BackHash") ?? false
            if hashForeground || hashBackground {
                actions.append(.colorHash(foreground: hashForeground, background: hashBackground, wholeLine: wholeLine))
            }
            let fontEnabled = color.bool("UseFont") ?? true
            let useDefaultFont = color.bool("FontDefault") ?? false
            let face = color.value("FontFace") ?? ""
            let size = color.value("FontSize").flatMap(Double.init) ?? 0
            if fontEnabled && (useDefaultFont || (!face.isEmpty && size > 0)) {
                actions.append(.font(face: face, size: size, useDefault: useDefaultFont, wholeLine: wholeLine))
            }
        }
        if let style = nodes.firstBlock(named: "Style")?.children {
            let patch = TextStylePatch(
                bold: style.bool("SetBold") == true ? (style.bool("Bold") ?? false) : nil,
                italic: style.bool("SetItalic") == true ? (style.bool("Italic") ?? false) : nil,
                underline: style.bool("SetUnderline") == true ? (style.bool("Underline") ?? false) : nil,
                strikeout: style.bool("SetStrikeout") == true ? (style.bool("Strikeout") ?? false) : nil,
                blink: style.bool("Flash") == true
                    ? (style.bool("FlashFast") == true ? .fast : .slow) : nil
            )
            if patch.bold != nil || patch.italic != nil || patch.underline != nil
                || patch.strikeout != nil || patch.blink != nil {
                actions.append(.appearance(patch, wholeLine: style.bool("WholeLine") ?? false))
            }
        }
        if let paragraph = nodes.firstBlock(named: "Paragraph")?.children {
            let alignment: ParagraphStyle.Alignment? = switch paragraph.value("Alignment").flatMap(Int.init) {
            case 1: .center
            case 2: .right
            case 0: .left
                default: nil
            }
            let strokeStyle: ParagraphStyle.StrokeStyle? = if paragraph.bool("UseStroke") == true {
                switch paragraph.value("StrokeStyle").flatMap(Int.init) {
                case 1: .top
                case 2: .bottom
                default: .outline
                }
            } else {
                nil
            }
            let patch = ParagraphPatch(
                alignment: paragraph.bool("UseAlignment") == true ? alignment : nil,
                leftIndent: paragraph.bool("UseIndent_Left") == true
                    ? paragraph.value("Indent_Left").flatMap(Double.init) : nil,
                rightIndent: paragraph.bool("UseIndent_Right") == true
                    ? paragraph.value("Indent_Right").flatMap(Double.init) : nil,
                topPadding: paragraph.bool("UsePadding_Top") == true
                    ? paragraph.value("Padding_Top").flatMap(Double.init) : nil,
                bottomPadding: paragraph.bool("UsePadding_Bottom") == true
                    ? paragraph.value("Padding_Bottom").flatMap(Double.init) : nil,
                background: paragraph.bool("UseBackgroundColor") == true
                    ? parseColor(paragraph.value("Background")) : nil,
                backgroundHash: paragraph.bool("UseBackgroundColor") == true
                    && paragraph.bool("BackgroundHash") == true,
                borderWidth: paragraph.bool("UseBorder") == true
                    ? paragraph.value("Border").flatMap(Double.init) : nil,
                borderStyle: paragraph.bool("UseBorderStyle") == true
                    ? (paragraph.value("BorderStyle") == "1" ? .round : .square) : nil,
                strokeWidth: paragraph.bool("UseStroke") == true
                    ? paragraph.value("StrokeWidth").flatMap(Double.init) : nil,
                strokeColor: paragraph.bool("UseStroke") == true
                    ? parseColor(paragraph.value("Stroke")) : nil,
                strokeHash: paragraph.bool("UseStroke") == true && paragraph.bool("StrokeHash") == true,
                strokeStyle: strokeStyle,
                horizontalRule: paragraph.bool("UseHorizontalRule") == true ? true : nil
            )
            if !patch.isEmpty { actions.append(.paragraph(patch)) }
        }
        if let gag = nodes.firstBlock(named: "Gag")?.children {
            let display = gag.bool("Active") ?? false
            let log = gag.bool("Log") ?? false
            if display || log { actions.append(.gag(display: display, log: log)) }
        }
        if let activate = nodes.firstBlock(named: "Activate")?.children,
           activate.bool("Active") == true {
            actions.append(.activateWindow)
            if activate.bool("ImportantActivity") == true {
                actions.append(.activity(important: true))
            } else if activate.bool("Activity") == true {
                actions.append(.activity(important: false))
            }
            if activate.bool("NoActivity") == true { actions.append(.suppressActivity) }
        }
        if let spawn = nodes.firstBlock(named: "Spawn")?.children,
           spawn.bool("Active") == true {
            actions.append(.spawn(.init(
                title: spawn.value("Title") ?? "",
                tabGroup: spawn.value("TabGroup") ?? "",
                captureUntil: spawn.value("CaptureUntil") ?? "",
                onlyChildrenDuringCapture: spawn.bool("OnlyChildrenDuringCapture") ?? false,
                clear: spawn.bool("Clear") ?? false,
                showTab: spawn.bool("ShowTab") ?? false,
                gagLog: spawn.bool("GagLog") ?? false,
                copy: spawn.bool("Copy") ?? false
            )))
        }
        if let stat = nodes.firstBlock(named: "Stat")?.children,
           let name = stat.value("Name"), !name.isEmpty {
            let kind: TriggerStatKind = switch stat.value("Type").flatMap(Int.init) {
            case 1: .string
            case 2: .range
            default: .integer
            }
            let integer = stat.firstBlock(named: "Int")?.children ?? []
            let range = stat.firstBlock(named: "Range")?.children ?? []
            let fontNodes = stat.firstBlock(named: "Font")?.children ?? []
            let font: TriggerFontStyle? = stat.bool("UseFont") == true ? .init(
                name: fontNodes.value("Name") ?? "Courier New",
                size: fontNodes.value("Size").flatMap(Double.init) ?? 13,
                bold: fontNodes.bool("Bold") ?? false,
                italic: fontNodes.bool("Italic") ?? false,
                underline: fontNodes.bool("Underline") ?? false,
                strikeout: fontNodes.bool("Strikeout") ?? false
            ) : nil
            let nameAlignment: ParagraphStyle.Alignment = switch stat.value("NameAlignment").flatMap(Int.init) {
            case 0: .left
            case 2: .right
            default: .center
            }
            actions.append(.stat(.init(
                title: stat.value("Title") ?? "",
                name: name,
                prefix: stat.value("Prefix") ?? "",
                value: stat.value("Value") ?? "",
                kind: kind,
                addsToExistingInteger: integer.bool("Add") ?? false,
                lower: range.value("Lower") ?? "",
                upper: range.value("Upper") ?? "",
                color: stat.bool("UseColor") == true ? parseColor(stat.value("Color")) : nil,
                rangeColor: parseColor(range.value("Color")),
                nameAlignment: nameAlignment,
                font: font
            )))
        }
        if let sound = nodes.firstBlock(named: "Sound")?.children,
           sound.bool("Active") == true, let path = sound.value("Sound"), !path.isEmpty {
            actions.append(.sound(path))
        }
        if let speech = nodes.firstBlock(named: "Speech")?.children,
           speech.bool("Active") == true {
            actions.append(.speech(
                speech.value("Say") ?? "",
                wholeLine: speech.bool("WholeLine") ?? false
            ))
        }
        if let send = nodes.firstBlock(named: "Send")?.children,
           send.bool("Active") == true, let text = send.value("Send"), !text.isEmpty {
            actions.append(.send(
                text,
                captureIndex: send.value("CaptureIndex").flatMap(Int.init) ?? 1,
                expandVariables: send.bool("ExpandVariables") ?? false,
                sendOnClick: send.bool("SendOnClick") ?? false
            ))
        }
        if let toast = nodes.firstBlock(named: "Toast")?.children, toast.bool("Active") == true {
            actions.append(.notification)
        }
        // Filter is intentionally late: replacing text invalidates match
        // offsets used by the visual, send-on-click, and notification actions.
        if let filter = nodes.firstBlock(named: "Filter")?.children,
           filter.bool("Active") == true {
            let replacement = filter.value("Replace") ?? ""
            let expand = filter.bool("ExpandVariables") ?? false
            actions.append(filter.bool("HTML") == true
                ? .replaceHTML(replacement, expandVariables: expand)
                : .replace(replacement, expandVariables: expand))
        }
        if let avatar = nodes.firstBlock(named: "Avatar")?.children,
           let url = avatar.value("URL"), !url.isEmpty {
            actions.append(.avatar(url))
        }
        if let script = nodes.firstBlock(named: "Script")?.children,
           script.bool("Active") == true, let function = script.value("Function"), !function.isEmpty {
            actions.append(.script(function))
        }
        return actions
    }

    private static func parseColor(_ source: String?) -> RGBColor? {
        guard let source else { return nil }
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        if hex.count == 6, let raw = UInt32(hex, radix: 16) {
            return .init(
                red: UInt8((raw >> 16) & 0xFF),
                green: UInt8((raw >> 8) & 0xFF),
                blue: UInt8(raw & 0xFF)
            )
        }
        if let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close {
            let components = value[value.index(after: open)..<close]
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if components.count >= 3, components.prefix(3).allSatisfy({ (0...255).contains($0) }) {
                return .init(red: UInt8(components[0]), green: UInt8(components[1]), blue: UInt8(components[2]))
            }
        }
        return switch value.lowercased() {
        case "white", "::colors::white": .white
        case "black", "::colors::black": .black
        case "transparent", "::colors::transparent": .transparent
        case "red", "::colors::red": .init(red: 255, green: 0, blue: 0)
        case "green", "::colors::green": .init(red: 0, green: 128, blue: 0)
        case "blue", "::colors::blue": .init(red: 0, green: 0, blue: 255)
        default: nil
        }
    }

    private static func aliasGroups(
        global: AliasGroup,
        server: AliasGroup,
        character: AliasGroup,
        puppet: AliasGroup
    ) -> [AliasGroup] {
        guard global.active else { return [] }
        return [
            aliasSlice(global.pre),
            aliasSlice(server.pre),
            aliasSlice(character.aliases),
            aliasSlice(puppet.aliases),
            aliasSlice(server.post),
            aliasSlice(global.post),
        ].filter { !$0.aliases.isEmpty }
    }

    private static func triggerGroups(
        global: TriggerGroup,
        server: TriggerGroup,
        character: TriggerGroup,
        puppet: TriggerGroup
    ) -> [TriggerGroup] {
        var result = [
            triggerSlice(global.pre),
            triggerSlice(server.pre),
            triggerSlice(character.triggers),
            triggerSlice(puppet.triggers),
            triggerSlice(server.post),
        ]
        result.append(triggerSlice(global.post))
        return result.filter { !$0.triggers.isEmpty }
    }

    private static func aliasSlice(_ aliases: [Alias]) -> AliasGroup {
        .init(active: true, aliases: aliases)
    }

    private static func triggerSlice(_ triggers: [Trigger]) -> TriggerGroup {
        .init(active: true, triggers: triggers)
    }

    private static func migrateDeprecatedName(
        in document: inout LegacyConfigurationDocument,
        nodes: [LegacyConfigurationDocument.Node],
        base: [String],
        shortcut: String
    ) throws {
        let info = legacyMigratedInfo(
            nodes.value("Info") ?? "",
            oldName: nodes.value("Name"),
            shortcut: shortcut
        )
        guard info != (nodes.value("Info") ?? "") else { return }
        try document.upsertValue(info, at: base + ["Info"])
    }

    private static func legacyMigratedInfo(_ info: String, oldName: String?, shortcut: String) -> String {
        guard let oldName, !oldName.isEmpty,
              oldName.caseInsensitiveCompare(shortcut) != .orderedSame else { return info }
        var info = info
        if !info.isEmpty, !info.hasSuffix("\n") { info += "\r\n" }
        info += "Name:\(oldName)"
        return info
    }

    private static func endpoint(_ value: String) -> (host: String, port: UInt16) {
        if value.hasPrefix("["), let closing = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<closing])
            let suffix = value[value.index(after: closing)...]
            let port = suffix.first == ":" ? UInt16(suffix.dropFirst()) : nil
            return (host, port ?? 8888)
        }
        guard let colon = value.lastIndex(of: ":"),
              let port = UInt16(value[value.index(after: colon)...]) else {
            return (value, 8888)
        }
        return (String(value[..<colon]), port)
    }

    private static func hasPort(_ value: String) -> Bool {
        if value.hasPrefix("[") { return value.contains("]:") }
        guard let colon = value.lastIndex(of: ":") else { return false }
        return UInt16(value[value.index(after: colon)...]) != nil
    }

    private static func flag(_ value: Bool) -> String { value ? "true" : "false" }

    private static func idleTimeout(_ nodes: [LegacyConfigurationDocument.Node]) -> TimeInterval? {
        guard nodes.bool("IdleEnabled") == true else { return nil }
        return nodes.value("IdleTimeout").flatMap(TimeInterval.init).map { $0 * 60 }
    }

    private static func variables(_ nodes: [LegacyConfigurationDocument.Node]) -> [String: String] {
        guard let variableNodes = nodes.firstBlock(named: "Variables")?.children else { return [:] }
        return Dictionary(uniqueKeysWithValues: variableNodes.compactMap { node in
            guard case let .assignment(name, value, _, _) = node else { return nil }
            return (name, LegacyConfigurationDocument.decoded(value))
        })
    }
}

private extension LegacyConfigurationDocument {
    func rootValue(_ name: String) -> String? { nodes.value(name) }
    func rootBool(_ name: String) -> Bool? { nodes.bool(name) }
    func firstBlock(named name: String) -> (name: String, children: [Node])? {
        nodes.firstBlock(named: name)
    }

    static func decoded(_ value: String) -> String {
        guard value.first == "\"", value.last == "\"", value.count >= 2 else { return value }
        var result = ""
        var escaped = false
        for character in value.dropFirst().dropLast() {
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
}

private extension Array where Element == LegacyConfigurationDocument.Node {
    func value(_ name: String) -> String? {
        for node in self {
            if case let .assignment(candidate, value, _, _) = node,
               candidate.caseInsensitiveCompare(name) == .orderedSame {
                return LegacyConfigurationDocument.decoded(value)
            }
        }
        return nil
    }

    func bool(_ name: String) -> Bool? {
        guard let value = value(name)?.lowercased() else { return nil }
        switch value {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    func firstBlock(named name: String) -> (name: String, children: [Element])? {
        for node in self {
            if case let .block(candidate?, children, _, _) = node,
               candidate.caseInsensitiveCompare(name) == .orderedSame {
                return (candidate, children)
            }
        }
        return nil
    }

    func namedBlocks() -> [(String, [Element])] {
        var order: [String] = []
        var canonicalNames: [String: String] = [:]
        var groups: [String: [Element]] = [:]
        for node in self {
            switch node {
            case let .block(name?, children, _, _):
                let key = name.lowercased()
                if groups[key] == nil { order.append(key); canonicalNames[key] = name }
                groups[key, default: []].append(contentsOf: children)
            case let .assignment(name, value, range, sourceRange):
                guard let dot = name.firstIndex(of: ".") else { continue }
                let owner = String(name[..<dot])
                let field = String(name[name.index(after: dot)...])
                let key = owner.lowercased()
                if groups[key] == nil { order.append(key); canonicalNames[key] = owner }
                groups[key, default: []].append(.assignment(
                    name: field,
                    value: value,
                    valueRange: range,
                    sourceRange: sourceRange
                ))
            default: break
            }
        }
        return order.compactMap { key in
            guard let name = canonicalNames[key], let children = groups[key] else { return nil }
            return (name, children)
        }
    }

    func properties(named name: String) -> [Element]? {
        namedBlocks().first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    func unnamedBlocks() -> [[Element]] {
        compactMap {
            guard case let .block(name: nil, children: children, insertionIndex: _, sourceRange: _) = $0 else {
                return nil
            }
            return children
        }
    }
}
