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

    public struct Server: Sendable, Equatable {
        public var profile: ServerProfile
        public var characters: [CharacterProfile]
    }

    public var sourceVersion: Int
    public var settings: ConnectionSettings
    public var servers: [Server]

    public init(document: LegacyConfigurationDocument) throws {
        let version = document.rootValue("Version").flatMap(Int.init) ?? 0
        guard version <= Self.currentWindowsVersion else {
            throw ProjectionError.newerConfiguration(found: version, supported: Self.currentWindowsVersion)
        }
        sourceVersion = version
        let connections = document.firstBlock(named: "Connections")?.children ?? []
        settings = .init(
            connectTimeoutMilliseconds: connections.value("ConnectTimeout").flatMap(Int.init) ?? 30_000,
            connectRetryCount: connections.value("ConnectRetry").flatMap(Int.init) ?? 5,
            retryForever: connections.bool("RetryForever") ?? false,
            tcpKeepAlive: document.rootBool("TCP_KeepAlive") ?? true,
            tcpNoDelay: document.rootBool("TCP_NoDelay") ?? true
        )

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
                port: endpoint.port,
                encoding: encoding,
                usesTLS: usesTLS,
                verifiesCertificate: children.bool("VerifyCertificate") ?? false,
                forceIPv4: children.bool("IPV4") ?? false,
                pueblo: children.bool("Pueblo") ?? false,
                prompts: children.bool("Prompts") ?? false,
                mcp: children.bool("MCP") ?? false,
                mcmp: children.bool("MCMP") ?? false,
                sendNAWSOnResize: children.bool("NAWSOnResize") ?? false,
                limitTelnetCharset: children.bool("LimitTelnetCharset") ?? false
            )
            let characterNodes = children.firstBlock(named: "Characters")?.children ?? []
            let characters = characterNodes.namedBlocks().map { characterName, properties in
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
                        removeAccidentalPrefix: puppetProperties.bool("RemoveAccidentalPrefix") ?? false
                    )
                }
                return CharacterProfile(
                    name: characterName,
                    connectText: properties.value("Connect") ?? "",
                    password: properties.value("Password") ?? "",
                    autoConnect: properties.bool("ConnectAtStartup") ?? false,
                    idleTimeout: Self.idleTimeout(properties),
                    idleText: properties.value("IdleString") ?? "",
                    variables: Self.variables(properties),
                    puppets: puppets
                )
            }
            return Server(profile: profile, characters: characters)
        }
    }

    public var connectionPolicy: ConnectionPolicy {
        .init(
            connectTimeoutMilliseconds: settings.connectTimeoutMilliseconds,
            retryCount: settings.connectRetryCount,
            retryForever: settings.retryForever,
            keepAlive: settings.tcpKeepAlive,
            noDelay: settings.tcpNoDelay
        )
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
        try result.upsertValue(String(targetVersion), at: ["Version"], quoted: false)
        try result.upsertValue(String(settings.connectTimeoutMilliseconds), at: ["Connections", "ConnectTimeout"], quoted: false)
        try result.upsertValue(String(settings.connectRetryCount), at: ["Connections", "ConnectRetry"], quoted: false)
        try result.upsertValue(Self.flag(settings.retryForever), at: ["Connections", "RetryForever"], quoted: false)
        try result.upsertValue(Self.flag(settings.tcpKeepAlive), at: ["TCP_KeepAlive"], quoted: false)
        try result.upsertValue(Self.flag(settings.tcpNoDelay), at: ["TCP_NoDelay"], quoted: false)

        for server in servers {
            let base = ["Connections", "Shortcuts", server.profile.name]
            let host = server.profile.host.contains(":") ? "[\(server.profile.host)]:\(server.profile.port)" : "\(server.profile.host):\(server.profile.port)"
            try result.upsertValue(host, at: base + ["Host"])
            try result.upsertValue(server.profile.encoding.rawValue, at: base + ["Encoding"], quoted: false)
            for (name, enabled) in [
                ("TLS", server.profile.usesTLS), ("VerifyCertificate", server.profile.verifiesCertificate),
                ("IPV4", server.profile.forceIPv4), ("Pueblo", server.profile.pueblo),
                ("Prompts", server.profile.prompts), ("MCP", server.profile.mcp),
                ("MCMP", server.profile.mcmp), ("NAWSOnResize", server.profile.sendNAWSOnResize),
                ("LimitTelnetCharset", server.profile.limitTelnetCharset),
            ] {
                try result.upsertValue(Self.flag(enabled), at: base + [name], quoted: false)
            }
            for character in server.characters {
                let characterBase = base + ["Characters", character.name]
                try result.upsertValue(character.connectText, at: characterBase + ["Connect"])
                try result.upsertValue(character.password, at: characterBase + ["Password"])
                try result.upsertValue(Self.flag(character.autoConnect), at: characterBase + ["ConnectAtStartup"], quoted: false)
                let idleEnabled = character.idleTimeout != nil && !character.idleText.isEmpty
                try result.upsertValue(Self.flag(idleEnabled), at: characterBase + ["IdleEnabled"], quoted: false)
                if let timeout = character.idleTimeout {
                    try result.upsertValue(String(Int(timeout / 60)), at: characterBase + ["IdleTimeout"], quoted: false)
                    try result.upsertValue(character.idleText, at: characterBase + ["IdleString"])
                }
                for puppet in character.puppets {
                    let puppetBase = characterBase + ["Puppets", puppet.name]
                    try result.upsertValue(puppet.receivePrefix, at: puppetBase + ["ReceivePrefix"])
                    try result.upsertValue(puppet.sendPrefix, at: puppetBase + ["SendPrefix"])
                    for (name, enabled) in [
                        ("RegularExpression", puppet.receivePrefixIsRegex),
                        ("HideReceivePrefix", puppet.hideReceivePrefix),
                        ("AutoConnect", puppet.autoConnect),
                        ("ConnectWithPlayer", puppet.connectWithPlayer),
                        ("RemoveAccidentalPrefix", puppet.removeAccidentalPrefix),
                    ] {
                        try result.upsertValue(Self.flag(enabled), at: puppetBase + [name], quoted: false)
                    }
                }
            }
        }
        return result
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

    private static func migrateDeprecatedName(
        in document: inout LegacyConfigurationDocument,
        nodes: [LegacyConfigurationDocument.Node],
        base: [String],
        shortcut: String
    ) throws {
        guard let oldName = nodes.value("Name"), !oldName.isEmpty,
              oldName.caseInsensitiveCompare(shortcut) != .orderedSame else { return }
        var info = nodes.value("Info") ?? ""
        if !info.isEmpty, !info.hasSuffix("\n") { info += "\r\n" }
        info += "Name:\(oldName)"
        try document.upsertValue(info, at: base + ["Info"])
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
            guard case let .assignment(name, value, _) = node else { return nil }
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
            if case let .assignment(candidate, value, _) = node,
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
            if case let .block(candidate?, children, _) = node,
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
            case let .block(name?, children, _):
                let key = name.lowercased()
                if groups[key] == nil { order.append(key); canonicalNames[key] = name }
                groups[key, default: []].append(contentsOf: children)
            case let .assignment(name, value, range):
                guard let dot = name.firstIndex(of: ".") else { continue }
                let owner = String(name[..<dot])
                let field = String(name[name.index(after: dot)...])
                let key = owner.lowercased()
                if groups[key] == nil { order.append(key); canonicalNames[key] = owner }
                groups[key, default: []].append(.assignment(name: field, value: value, valueRange: range))
            default: break
            }
        }
        return order.compactMap { key in
            guard let name = canonicalNames[key], let children = groups[key] else { return nil }
            return (name, children)
        }
    }
}
