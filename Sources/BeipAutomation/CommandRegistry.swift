import BeipCore
import Foundation

public enum CommandOutcome: Sendable, Equatable {
    case send(String)
    case display(String)
    case clear
    case localEcho(Bool)
    case resetANSI
    case nawsAuto
    case naws(UInt16, UInt16)
    case terminalType(String?)
    case setVariable(String, String)
    case unsetVariable(String)
    case gmcp(GMCPMessage)
    case script(String)
    case scriptHelp(String?)
    case resetScript
    case unimplemented(String)
    case notACommand
}

public struct CommandRegistry: Sendable {
    public static let knownCommands: Set<String> = [
        "@", "ai", "ansireset", "autolog", "capturecancel", "chars", "clear", "close",
        "connect", "connectioninfo", "debugaliases", "debugnetwork", "debugtimers", "debugtriggers",
        "delay", "disconnect", "echo", "exit", "gag", "gmcp", "grab", "help", "idle", "log",
        "lizards", "logall", "logtop", "makali", "map_addexit", "map_addroom", "map_guesslocation", "map_look",
        "mcmp", "naws", "new", "newedit", "newinput", "newtab", "opendialog", "ping", "printenv",
        "puppet", "puppets", "recall", "receive", "receivegmcp", "reconnect", "removelast", "repeat",
        "resetconfig", "resetscript", "restoreinfo", "roll", "rolltest", "script", "set", "setinput",
        "shelp", "silence", "slist", "stats", "stoplogs", "switchtab", "tabcolor", "test", "tilemap",
        "ttype", "unset", "wall", "webview", "world",
    ]

    public init() {}

    public func parse(_ input: String, variables: [String: String]) -> CommandOutcome {
        guard input.hasPrefix("/") else { return .notACommand }
        if input.hasPrefix("//") { return .send(String(input.dropFirst())) }
        var body = String(input.dropFirst())
        if body.lowercased().hasPrefix("silent/") {
            body = String(body.dropFirst("silent/".count))
        }
        let commandEnd = body.firstIndex(where: { $0.isWhitespace }) ?? body.endIndex
        let command = body[..<commandEnd].lowercased()
        let rawArguments = body[commandEnd...].drop(while: { $0.isWhitespace })
        let arguments = split(String(rawArguments))
        guard !command.isEmpty else { return .display("Use /help for a list of commands.") }
        switch command {
        case "clear": return .clear
        case "echo":
            guard let value = arguments.first else { return .localEcho(true) }
            switch value.lowercased() {
            case "on": return .localEcho(true)
            case "off": return .localEcho(false)
            default: return .display("Usage: /echo <on/off>")
            }
        case "ansireset": return .resetANSI
        case "naws":
            if arguments.count == 1, arguments[0].lowercased() == "auto" { return .nawsAuto }
            if arguments.count == 2,
               let columns = UInt16(arguments[0]), columns > 0,
               let rows = UInt16(arguments[1]), rows > 0 {
                return .naws(columns, rows)
            }
            return .display("Invalid usage, try /naws auto or /naws <width> <height>.")
        case "ttype": return .terminalType(arguments.first)
        case "set":
            guard let equals = rawArguments.firstIndex(of: "=") else {
                return .display("Syntax error, missing '='")
            }
            let name = rawArguments[..<equals].trimmingCharacters(in: .whitespaces)
            let value = rawArguments[rawArguments.index(after: equals)...]
            guard !name.isEmpty else { return .display("Syntax error, missing variable name") }
            return .setVariable(name, String(value))
        case "unset":
            guard let name = arguments.first else { return .display("Usage: /unset <name>") }
            return .unsetVariable(name)
        case "printenv":
            if let name = arguments.first {
                return .display(variables[name] ?? "Variable not found: \(name)")
            }
            return .display(variables.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        case "gmcp":
            let packageEnd = rawArguments.firstIndex(where: { $0.isWhitespace }) ?? rawArguments.endIndex
            let package = String(rawArguments[..<packageEnd])
            guard !package.isEmpty else { return .display("Usage: /gmcp <package> [json]") }
            let payload = rawArguments[packageEnd...].drop(while: { $0.isWhitespace })
            return .gmcp(.init(package: package, payload: String(payload)))
        case "script", "@":
            guard !rawArguments.isEmpty else { return .display("Usage: /\(command) <JavaScript>") }
            return .script(String(rawArguments))
        case "shelp": return .scriptHelp(arguments.first)
        case "resetscript": return .resetScript
        case "roll": return roll(arguments.first)
        case "help", "?": return .display("BeipMU commands: " + Self.knownCommands.sorted().map { "/" + $0 }.joined(separator: ", "))
        case "makali":
            return .display("Even a man who is pure of heart,\nand says his prayers by night,\nmay become a wolf when the wolfsbane blooms,\nand the autumn moon is bright.")
        case "lizards":
            return .display("And now some messages from our Lizard supporters:\nCam-a-cam-mal, Pria-toi, Gan delah - Snowglass\nkweh - Thistle\n🦌 ☀️ ☀️ 🚙\n🦎 🦎")
        default:
            return Self.knownCommands.contains(command) ? .unimplemented(command) : .display("Unrecognized command: /\(command)")
        }
    }

    private func split(_ value: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in value {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { words.append(current); current = "" }
            } else { current.append(character) }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private func roll(_ specification: String?) -> CommandOutcome {
        guard let specification else { return .display("🎲 Roll: Missing parameter") }
        let parts = specification.lowercased().split(separator: "d", maxSplits: 1)
        guard parts.count == 2, let count = Int(parts[0]), count > 0, count <= 1_000 else {
            return .display("🎲 Bad roll format, expected [count]d[sides](+bonus).")
        }
        let sideParts = parts[1].split(separator: "+", maxSplits: 1)
        guard let sides = Int(sideParts[0]), sides > 0 else {
            return .display("🎲 Bad roll format, expected [count]d[sides](+bonus).")
        }
        let bonus = sideParts.count == 2 ? Int(sideParts[1]) ?? 0 : 0
        let rolls = (0..<count).map { _ in Int.random(in: 1...sides) }
        return .display("🎲 Rolled \(rolls.map(String.init).joined(separator: " "))\n🎲 Roll Total: \(rolls.reduce(0, +) + bonus)")
    }
}
