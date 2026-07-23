import BeipCore
import Foundation

public enum MCPParserEvent: Sendable, Hashable {
    case display(String)
    case transmit(Data)
    case message(MCPMessage)
    case diagnostic(String)
}

/// Stateful MCP 2.1 line parser and encoder.
public struct MCPParser: Sendable {
    private struct Package: Sendable {
        var name: String
        var minimum: String
        var maximum: String
    }

    private struct Pending: Sendable {
        var message: MCPMessage
        var tag: String
    }

    private static let packages = [
        Package(name: "mcp-negotiate", minimum: "1.0", maximum: "2.0"),
        Package(name: "dns-org-mud-moo-simpleedit", minimum: "1.0", maximum: "1.0"),
        Package(name: "dns-com-awns-status", minimum: "1.0", maximum: "1.0"),
        Package(name: "dns-com-vmoo-client", minimum: "1.0", maximum: "1.0"),
        Package(name: "dns-com-awns-ping", minimum: "1.0", maximum: "1.0"),
    ]

    public private(set) var isActive = false
    public private(set) var negotiatedPackages: Set<String> = []
    public private(set) var authenticationKey: String
    private let fixedAuthenticationKey: String?
    private var pending: [String: Pending] = [:]
    private var nextDataTag: UInt64 = 1

    public init(authenticationKey: String? = nil) {
        fixedAuthenticationKey = authenticationKey
        self.authenticationKey = authenticationKey ?? Self.randomAuthenticationKey()
    }

    public mutating func reset() {
        isActive = false
        negotiatedPackages.removeAll()
        pending.removeAll()
        nextDataTag = 1
        authenticationKey = fixedAuthenticationKey ?? Self.randomAuthenticationKey()
    }

    public mutating func consume(_ line: String) -> [MCPParserEvent] {
        if !isActive {
            guard line.hasPrefix("#$#mcp") else { return [.display(line)] }
            isActive = true
            negotiatedPackages.insert("mcp-negotiate")
            return activationFrames().map(MCPParserEvent.transmit)
        }

        if line.hasPrefix("#$\"") { return [.display(String(line.dropFirst(3)))] }
        guard line.hasPrefix("#$#") else { return [.display(line)] }
        let control = String(line.dropFirst(3))
        if control.hasPrefix("*") { return consumeContinuation(String(control.dropFirst())) }
        if control.hasPrefix(":") { return consumeEnd(String(control.dropFirst())) }

        do {
            guard let parsed = try parseMessage(control) else { return [] }
            if let tag = parsed[parameter: "_data-tag"], !parsed.multiline.isEmpty {
                pending[tag.lowercased()] = Pending(message: parsed, tag: tag)
                return []
            }
            return dispatch(parsed)
        } catch {
            return [.diagnostic("MCP protocol error: \(error.localizedDescription)")]
        }
    }

    public mutating func encode(_ message: MCPMessage) -> [Data] {
        guard isActive, Self.validIdentifier(message.package),
              message.message.isEmpty || Self.validIdentifier(message.message) else { return [] }
        let tag = message.multiline.isEmpty ? nil : String(format: "%016llx", nextDataTag)
        if tag != nil { nextDataTag &+= 1 }
        var first = "#$#\(message.fullName) \(authenticationKey)"
        for (key, value) in message.parameters.sorted(by: Self.parameterOrder) where Self.validIdentifier(key) {
            first += " \(key): \"\(Self.quoted(value))\""
        }
        for key in message.multiline.keys.sorted() where Self.validIdentifier(key) {
            first += " \(key)*: \"\""
        }
        if let tag { first += " _data-tag: \(tag)" }
        var frames = [Data((first + "\n").utf8)]
        if let tag {
            for key in message.multiline.keys.sorted() where Self.validIdentifier(key) {
                for value in message.multiline[key] ?? [] {
                    let safe = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                    frames.append(Data("#$#* \(tag) \(key): \(safe)\n".utf8))
                }
            }
            frames.append(Data("#$#: \(tag)\n".utf8))
        }
        return frames
    }

    private mutating func consumeContinuation(_ body: String) -> [MCPParserEvent] {
        let content = body.drop(while: { $0 == " " })
        guard let firstSpace = content.firstIndex(of: " ") else { return [.diagnostic("MCP protocol error: malformed multiline continuation")] }
        let tag = String(content[..<firstSpace])
        let rest = content[content.index(after: firstSpace)...]
        guard let colon = rest.firstIndex(of: ":"), colon < rest.endIndex else {
            return [.diagnostic("MCP protocol error: malformed multiline continuation")]
        }
        let key = String(rest[..<colon])
        var value = String(rest[rest.index(after: colon)...])
        if value.first == " " { value.removeFirst() }
        guard Self.validSimpleValue(tag), Self.validIdentifier(key), var item = pending[tag.lowercased()],
              let storedKey = item.message.multiline.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) else {
            return [.diagnostic("MCP protocol error: unknown multiline tag or key")]
        }
        item.message.multiline[storedKey, default: []].append(value)
        pending[tag.lowercased()] = item
        return []
    }

    private mutating func consumeEnd(_ body: String) -> [MCPParserEvent] {
        let tag = body.trimmingCharacters(in: .whitespaces)
        guard Self.validSimpleValue(tag), let item = pending.removeValue(forKey: tag.lowercased()) else {
            return [.diagnostic("MCP protocol error: unknown multiline end tag")]
        }
        return dispatch(item.message)
    }

    private mutating func dispatch(_ message: MCPMessage) -> [MCPParserEvent] {
        let package = message.package.lowercased()
        if package == "mcp-negotiate" { return negotiate(message) }
        guard negotiatedPackages.contains(package) else {
            return [.diagnostic("MCP protocol error: unsupported package message \(message.fullName)")]
        }
        if package == "dns-com-awns-ping" {
            guard let id = message[parameter: "id"] else {
                return [.diagnostic("MCP message was missing required parameter 'id'")]
            }
            return encode(.init(package: "dns-com-awns-ping", message: "reply", parameters: ["id": id])).map(MCPParserEvent.transmit)
        }
        return [.message(message)]
    }

    private mutating func negotiate(_ message: MCPMessage) -> [MCPParserEvent] {
        switch message.message.lowercased() {
        case "can":
            guard let name = message[parameter: "package"],
                  let minimum = message[parameter: "min-version"],
                  let maximum = message[parameter: "max-version"],
                  let local = Self.packages.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  Self.versionsIntersect(local.minimum, local.maximum, minimum, maximum) else { return [] }
            let key = local.name.lowercased()
            negotiatedPackages.insert(key)
            if key == "dns-com-vmoo-client" {
                let info = MCPMessage(
                    package: local.name,
                    message: "info",
                    parameters: ["name": "BeipMU", "text-version": "macOS", "internal-version": "macOS"]
                )
                return encode(info).map(MCPParserEvent.transmit)
            }
            return []
        case "end": return []
        default: return [.diagnostic("mcp-negotiate: unknown command \(message.message)")]
        }
    }

    private func activationFrames() -> [Data] {
        var values = [Data("#$#mcp authentication-key: \(authenticationKey) version: 2.1 to: 2.1\n".utf8)]
        for package in Self.packages {
            var copy = self
            values += copy.encode(.init(
                package: "mcp-negotiate",
                message: "can",
                parameters: ["package": package.name, "min-version": package.minimum, "max-version": package.maximum]
            ))
        }
        var copy = self
        values += copy.encode(.init(package: "mcp-negotiate", message: "end"))
        return values
    }

    private func parseMessage(_ body: String) throws -> MCPMessage? {
        var scanner = Scanner(body)
        guard let fullName = scanner.identifier(), scanner.spaces(), let auth = scanner.simpleValue(), auth == authenticationKey else {
            throw MCPParserError.malformedMessage
        }
        let split = Self.split(fullName: fullName)
        var parameters: [String: String] = [:]
        var multiline: [String: [String]] = [:]
        while scanner.spaces() {
            guard let key = scanner.identifier() else { throw MCPParserError.malformedParameter }
            let isMultiline = scanner.take("*")
            guard scanner.take(":"), scanner.spaces(), let value = scanner.value() else { throw MCPParserError.malformedParameter }
            if isMultiline { multiline[key] = [] } else { parameters[key] = value }
        }
        guard scanner.atEnd else { throw MCPParserError.malformedMessage }
        return MCPMessage(package: split.package, message: split.message, parameters: parameters, multiline: multiline)
    }

    private static func split(fullName: String) -> (package: String, message: String) {
        for package in packages.sorted(by: { $0.name.count > $1.name.count }) {
            if fullName.caseInsensitiveCompare(package.name) == .orderedSame { return (fullName, "") }
            let prefix = package.name + "-"
            if fullName.lowercased().hasPrefix(prefix.lowercased()) {
                return (String(fullName.prefix(package.name.count)), String(fullName.dropFirst(prefix.count)))
            }
        }
        guard let dash = fullName.lastIndex(of: "-") else { return (fullName, "") }
        return (String(fullName[..<dash]), String(fullName[fullName.index(after: dash)...]))
    }

    private static func versionsIntersect(_ localMin: String, _ localMax: String, _ remoteMin: String, _ remoteMax: String) -> Bool {
        guard let lmin = version(localMin), let lmax = version(localMax), let rmin = version(remoteMin), let rmax = version(remoteMax) else { return false }
        return max(lmin, rmin) <= min(lmax, rmax)
    }

    private static func version(_ value: String) -> Int? {
        let values = value.split(separator: ".", omittingEmptySubsequences: false)
        guard values.count == 2, let major = Int(values[0]), let minor = Int(values[1]), minor < 65_536 else { return nil }
        return major << 16 | minor
    }

    private static func parameterOrder(_ lhs: (key: String, value: String), _ rhs: (key: String, value: String)) -> Bool {
        lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
    }

    private static func randomAuthenticationKey() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }

    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func validIdentifier(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter || first == "_" else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    private static func validSimpleValue(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { Scanner.isSimple($0) }
    }
}

private struct Scanner {
    let characters: [Character]
    var index = 0

    init(_ value: String) { characters = Array(value) }
    var atEnd: Bool { index == characters.count }

    mutating func take(_ character: Character) -> Bool {
        guard index < characters.count, characters[index] == character else { return false }
        index += 1
        return true
    }

    mutating func spaces() -> Bool {
        guard take(" ") else { return false }
        while take(" ") {}
        return true
    }

    mutating func identifier() -> String? {
        guard index < characters.count, characters[index].isLetter || characters[index] == "_" else { return nil }
        let start = index
        while index < characters.count {
            let value = characters[index]
            guard value.isASCII && (value.isLetter || value.isNumber || value == "_" || value == "-") else { break }
            index += 1
        }
        return String(characters[start..<index])
    }

    mutating func simpleValue() -> String? {
        let start = index
        while index < characters.count, Self.isSimple(characters[index]) { index += 1 }
        return start == index ? nil : String(characters[start..<index])
    }

    mutating func value() -> String? {
        guard take("\"") else { return simpleValue() }
        var result = ""
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "\"" { return result }
            if character == "\\" {
                guard index < characters.count, characters[index] == "\"" || characters[index] == "\\" else { return nil }
                result.append(characters[index])
                index += 1
            } else if Self.isSimple(character) || character == " " || character == ":" || character == "*" {
                result.append(character)
            } else { return nil }
        }
        return nil
    }

    static func isSimple(_ character: Character) -> Bool {
        guard character.isASCII, let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return character.isLetter || character.isNumber || character == "_" || value == 33 ||
            (35...41).contains(value) || value == 43 || value == 44 || (45...47).contains(value) ||
            (59...64).contains(value) || value == 91 || value == 93 || value == 94 || value == 96 ||
            (123...126).contains(value)
    }
}

private enum MCPParserError: LocalizedError {
    case malformedMessage
    case malformedParameter

    var errorDescription: String? {
        switch self {
        case .malformedMessage: "malformed message or invalid authentication key"
        case .malformedParameter: "malformed parameter"
        }
    }
}
