import Foundation

/// A parsed Mud Client Protocol message. MCP package names and parameter names
/// are case-insensitive on the wire; their original spelling is retained here.
public struct MCPMessage: Sendable, Hashable, Codable {
    public var package: String
    public var message: String
    public var parameters: [String: String]
    public var multiline: [String: [String]]

    public init(
        package: String,
        message: String = "",
        parameters: [String: String] = [:],
        multiline: [String: [String]] = [:]
    ) {
        self.package = package
        self.message = message
        self.parameters = parameters
        self.multiline = multiline
    }

    public var fullName: String {
        message.isEmpty ? package : "\(package)-\(message)"
    }

    public subscript(parameter name: String) -> String? {
        parameters.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func values(for name: String) -> [String]? {
        multiline.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct ClientMediaItem: Sendable, Hashable, Codable {
    public var name: String
    public var source: URL
    public var volume: Double
    public var loops: Int
    public var continues: Bool

    public init(name: String, source: URL, volume: Double = 0.5, loops: Int = 1, continues: Bool = true) {
        self.name = name
        self.source = source
        self.volume = min(1, max(0, volume))
        self.loops = loops
        self.continues = continues
    }
}

public enum ClientMediaEvent: Sendable, Hashable {
    case load(ClientMediaItem)
    case play(ClientMediaItem)
    case stop(name: String?)
}

public struct ClientMediaState: Sendable {
    public private(set) var isActive = false
    public private(set) var defaultURL = ""
    public private(set) var items: [String: ClientMediaItem] = [:]

    public init() {}

    public mutating func reset() {
        isActive = false
        defaultURL = ""
        items.removeAll()
    }

    public mutating func flush() -> [ClientMediaEvent] {
        reset()
        return [.stop(name: nil)]
    }

    public mutating func consume(_ message: GMCPMessage) throws -> [ClientMediaEvent] {
        let components = message.package.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0].caseInsensitiveCompare("Client") == .orderedSame,
              components[1].caseInsensitiveCompare("Media") == .orderedSame else { return [] }
        isActive = true
        let command = components[2].lowercased()
        let object = try Self.object(from: message.payload)

        switch command {
        case "default":
            defaultURL = Self.string("url", in: object) ?? ""
            return []
        case "load":
            let name = try Self.requiredString("name", in: object)
            guard items[name] == nil else { return [] }
            let item = try makeItem(name: name, object: object)
            items[name] = item
            return [.load(item)]
        case "play":
            let name = try Self.requiredString("name", in: object)
            var item: ClientMediaItem
            if let existing = items[name] { item = existing }
            else { item = try makeItem(name: name, object: object) }
            item.volume = min(1, max(0, (Self.number("volume", in: object) ?? 50) / 100))
            item.loops = Int(Self.number("loops", in: object) ?? 1)
            item.continues = Self.bool("continue", in: object) ?? true
            items[name] = item
            return [.play(item)]
        case "stop":
            let name = Self.string("name", in: object).flatMap { $0.isEmpty ? nil : $0 }
            return [.stop(name: name)]
        default:
            throw ClientMediaError.unsupportedCommand(command)
        }
    }

    public var information: String {
        var lines = ["GMCP Sound status", "Default URL: \(defaultURL.isEmpty ? "(none)" : defaultURL)"]
        lines += items.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.map {
            "Name: \($0.name)  URL: \($0.source.absoluteString)  Volume: \(Int(($0.volume * 100).rounded()))  Loop Count: \($0.loops)"
        }
        lines.append("GMCP Sound status end")
        return lines.joined(separator: "\n")
    }

    private func makeItem(name: String, object: [String: Any]) throws -> ClientMediaItem {
        let base = Self.string("url", in: object).flatMap { $0.isEmpty ? nil : $0 } ?? defaultURL
        guard !base.isEmpty else { throw ClientMediaError.missingURL(name) }
        return ClientMediaItem(
            name: name,
            source: try Self.resolve(base: base, name: name),
            volume: (Self.number("volume", in: object) ?? 50) / 100,
            loops: Int(Self.number("loops", in: object) ?? 1),
            continues: Self.bool("continue", in: object) ?? true
        )
    }

    private static func resolve(base: String, name: String) throws -> URL {
        guard let url = URL(string: base + name), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw ClientMediaError.invalidURL(base + name)
        }
        return url
    }

    private static func object(from payload: String) throws -> [String: Any] {
        let value = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [:] }
        guard let data = value.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientMediaError.expectedObject
        }
        return object
    }

    private static func value(_ name: String, in object: [String: Any]) -> Any? {
        object.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func string(_ name: String, in object: [String: Any]) -> String? {
        value(name, in: object) as? String
    }

    private static func number(_ name: String, in object: [String: Any]) -> Double? {
        (value(name, in: object) as? NSNumber)?.doubleValue
    }

    private static func bool(_ name: String, in object: [String: Any]) -> Bool? {
        if let value = value(name, in: object) as? Bool { return value }
        if let value = string(name, in: object) { return value.caseInsensitiveCompare("true") == .orderedSame }
        return nil
    }

    private static func requiredString(_ name: String, in object: [String: Any]) throws -> String {
        guard let value = string(name, in: object), !value.isEmpty else { throw ClientMediaError.missingParameter(name) }
        return value
    }
}

public enum ClientMediaError: LocalizedError, Equatable {
    case expectedObject
    case missingParameter(String)
    case missingURL(String)
    case invalidURL(String)
    case unsupportedCommand(String)

    public var errorDescription: String? {
        switch self {
        case .expectedObject: "Client.Media expected a JSON object"
        case let .missingParameter(name): "Client.Media is missing parameter '\(name)'"
        case let .missingURL(name): "Client.Media has no URL for '\(name)'"
        case let .invalidURL(value): "Client.Media URL is invalid: \(value)"
        case let .unsupportedCommand(command): "Unsupported Client.Media command: \(command)"
        }
    }
}
