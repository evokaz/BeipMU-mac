import Foundation

public enum TextEncoding: String, Sendable, Codable, CaseIterable {
    case utf8 = "UTF8"
    case cp1252 = "CP1252"
    case cp437 = "CP437"
}

public struct ServerProfile: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var encoding: TextEncoding
    public var usesTLS: Bool
    public var verifiesCertificate: Bool
    public var forceIPv4: Bool
    public var pueblo: Bool
    public var prompts: Bool
    public var mcp: Bool
    public var mcmp: Bool
    public var sendNAWSOnResize: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16,
        encoding: TextEncoding = .cp1252,
        usesTLS: Bool = false,
        verifiesCertificate: Bool = false,
        forceIPv4: Bool = false,
        pueblo: Bool = false,
        prompts: Bool = false,
        mcp: Bool = false,
        mcmp: Bool = false,
        sendNAWSOnResize: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.encoding = encoding
        self.usesTLS = usesTLS
        self.verifiesCertificate = verifiesCertificate
        self.forceIPv4 = forceIPv4
        self.pueblo = pueblo
        self.prompts = prompts
        self.mcp = mcp
        self.mcmp = mcmp
        self.sendNAWSOnResize = sendNAWSOnResize
    }
}

public struct CharacterProfile: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var connectText: String
    public var password: String
    public var autoConnect: Bool
    public var idleTimeout: TimeInterval?
    public var idleText: String
    public var variables: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        connectText: String = "",
        password: String = "",
        autoConnect: Bool = false,
        idleTimeout: TimeInterval? = nil,
        idleText: String = "",
        variables: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.connectText = connectText
        self.password = password
        self.autoConnect = autoConnect
        self.idleTimeout = idleTimeout
        self.idleText = idleText
        self.variables = variables
    }
}

public struct PuppetProfile: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var receivePrefix: String
    public var sendPrefix: String
    public var receivePrefixIsRegex: Bool
    public var hideReceivePrefix: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        receivePrefix: String = "",
        sendPrefix: String = "",
        receivePrefixIsRegex: Bool = false,
        hideReceivePrefix: Bool = true
    ) {
        self.id = id
        self.name = name
        self.receivePrefix = receivePrefix
        self.sendPrefix = sendPrefix
        self.receivePrefixIsRegex = receivePrefixIsRegex
        self.hideReceivePrefix = hideReceivePrefix
    }
}

public struct ConnectionRequest: Sendable, Hashable {
    public var server: ServerProfile
    public var character: CharacterProfile?

    public init(server: ServerProfile, character: CharacterProfile? = nil) {
        self.server = server
        self.character = character
    }
}

