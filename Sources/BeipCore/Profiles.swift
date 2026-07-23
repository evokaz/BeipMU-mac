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
    public var gmcpWebViewPolicy: ServerWebViewPolicy?
    public var sendNAWSOnResize: Bool
    public var limitTelnetCharset: Bool
    /// Optional HTTP endpoint used by the native `/ai` window.  It is kept
    /// profile-local so prompts never leak across worlds.
    public var aiEndpoint: URL?
    public var aiModel: String

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
        gmcpWebViewPolicy: ServerWebViewPolicy = .ask,
        sendNAWSOnResize: Bool = false,
        limitTelnetCharset: Bool = false,
        aiEndpoint: URL? = nil,
        aiModel: String = ""
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
        self.gmcpWebViewPolicy = gmcpWebViewPolicy
        self.sendNAWSOnResize = sendNAWSOnResize
        self.limitTelnetCharset = limitTelnetCharset
        self.aiEndpoint = aiEndpoint
        self.aiModel = aiModel
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
    public var puppets: [PuppetProfile]

    public init(
        id: UUID = UUID(),
        name: String,
        connectText: String = "",
        password: String = "",
        autoConnect: Bool = false,
        idleTimeout: TimeInterval? = nil,
        idleText: String = "",
        variables: [String: String] = [:],
        puppets: [PuppetProfile] = []
    ) {
        self.id = id
        self.name = name
        self.connectText = connectText
        self.password = password
        self.autoConnect = autoConnect
        self.idleTimeout = idleTimeout
        self.idleText = idleText
        self.variables = variables
        self.puppets = puppets
    }
}

public struct PuppetProfile: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var receivePrefix: String
    public var sendPrefix: String
    public var receivePrefixIsRegex: Bool
    public var hideReceivePrefix: Bool
    public var autoConnect: Bool
    public var connectWithPlayer: Bool
    public var removeAccidentalPrefix: Bool
    public var logFilename: String
    public var logAppendsDate: Bool
    public var characterLog: Bool
    public var characterLogPrefix: String

    public init(
        id: UUID = UUID(),
        name: String,
        receivePrefix: String = "",
        sendPrefix: String = "",
        receivePrefixIsRegex: Bool = false,
        hideReceivePrefix: Bool = true,
        autoConnect: Bool = true,
        connectWithPlayer: Bool = false,
        removeAccidentalPrefix: Bool = false,
        logFilename: String = "",
        logAppendsDate: Bool = false,
        characterLog: Bool = false,
        characterLogPrefix: String = ""
    ) {
        self.id = id
        self.name = name
        self.receivePrefix = receivePrefix
        self.sendPrefix = sendPrefix
        self.receivePrefixIsRegex = receivePrefixIsRegex
        self.hideReceivePrefix = hideReceivePrefix
        self.autoConnect = autoConnect
        self.connectWithPlayer = connectWithPlayer
        self.removeAccidentalPrefix = removeAccidentalPrefix
        self.logFilename = logFilename
        self.logAppendsDate = logAppendsDate
        self.characterLog = characterLog
        self.characterLogPrefix = characterLogPrefix
    }
}

public enum PuppetRouter {
    public struct RoutedLine: Sendable, Equatable {
        public var puppetID: UUID
        public var text: String
        public var removedRange: Range<Int>?
    }

    public static func route(_ text: String, through puppets: [PuppetProfile]) -> RoutedLine? {
        for puppet in puppets where !puppet.receivePrefix.isEmpty {
            let range: Range<String.Index>?
            if puppet.receivePrefixIsRegex {
                guard let expression = try? NSRegularExpression(pattern: puppet.receivePrefix) else { continue }
                let sourceRange = NSRange(text.startIndex..., in: text)
                guard let match = expression.firstMatch(in: text, options: [.anchored], range: sourceRange) else {
                    continue
                }
                let selected = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound
                    ? match.range(at: 1)
                    : match.range
                range = Range(selected, in: text)
            } else {
                range = text.range(of: puppet.receivePrefix, options: [.caseInsensitive, .anchored])
            }
            guard let range else { continue }
            let routed = puppet.hideReceivePrefix
                ? String(text[..<range.lowerBound] + text[range.upperBound...])
                : text
            let nsRange = NSRange(range, in: text)
            return .init(
                puppetID: puppet.id,
                text: routed,
                removedRange: puppet.hideReceivePrefix ? nsRange.location..<nsRange.upperBound : nil
            )
        }
        return nil
    }

    public static func outgoing(_ text: String, for puppet: PuppetProfile) -> String {
        let value: String
        if puppet.removeAccidentalPrefix, !puppet.sendPrefix.isEmpty, text.hasPrefix(puppet.sendPrefix) {
            value = String(text.dropFirst(puppet.sendPrefix.count))
        } else {
            value = text
        }
        return puppet.sendPrefix + value
    }
}

public struct ConnectionRequest: Sendable, Hashable {
    public var server: ServerProfile
    public var character: CharacterProfile?
    public var puppet: PuppetProfile?
    public var policy: ConnectionPolicy

    public init(
        server: ServerProfile,
        character: CharacterProfile? = nil,
        puppet: PuppetProfile? = nil,
        policy: ConnectionPolicy = .init()
    ) {
        self.server = server
        self.character = character
        self.puppet = puppet
        self.policy = policy
    }
}

public struct ConnectionPolicy: Sendable, Hashable, Codable {
    public var connectTimeoutMilliseconds: Int
    public var retryCount: Int
    public var retryForever: Bool
    public var keepAlive: Bool
    public var noDelay: Bool

    public init(
        connectTimeoutMilliseconds: Int = 30_000,
        retryCount: Int = 5,
        retryForever: Bool = false,
        keepAlive: Bool = true,
        noDelay: Bool = true
    ) {
        self.connectTimeoutMilliseconds = max(1_000, connectTimeoutMilliseconds)
        self.retryCount = max(1, retryCount)
        self.retryForever = retryForever
        self.keepAlive = keepAlive
        self.noDelay = noDelay
    }
}

public struct ConnectionStatistics: Sendable, Hashable, Codable {
    public var bytesSent: UInt64 = 0
    public var bytesReceived: UInt64 = 0
    public var secondsConnected: TimeInterval = 0
    public var connectionCount: UInt64 = 0

    public init() {}
}
