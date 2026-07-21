import BeipCore
import Foundation

public struct EditWindowOptions: Sendable, Equatable {
    public var title: String
    public var captureLineCount: Int
    public var captureSkipCount: Int
    public var checksSpelling: Bool
    public var prepend: String
    public var append: String

    public init(
        title: String = "",
        captureLineCount: Int = 0,
        captureSkipCount: Int = 0,
        checksSpelling: Bool = true,
        prepend: String = "",
        append: String = ""
    ) {
        self.title = title
        self.captureLineCount = captureLineCount
        self.captureSkipCount = captureSkipCount
        self.checksSpelling = checksSpelling
        self.prepend = prepend
        self.append = append
    }
}

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
    case gmcpDump(Bool)
    case disconnect(all: Bool)
    case reconnect(all: Bool)
    case connect(address: String, character: String?)
    case repeatCommand(count: Int, command: String)
    case receive(String)
    case receiveGMCP(GMCPMessage)
    case ping(String)
    case setInput(String)
    case idle(minutes: UInt?, command: String?)
    case statistics
    case connectionInfo
    case close
    case exit
    case newWindow
    case newTab
    case newInput(prefix: String, unique: Bool)
    case newEdit(EditWindowOptions)
    case silence
    case removeLast
    case wall(String)
    case openDialog(String, parameter: String?)
    case listServers
    case listCharacters
    case listPuppets
    case connectPuppet(String)
    case stopLogs
    case startLog(filename: String, history: LogHistory)
    case delay(DelayAction)
    case script(String)
    case scriptHelp(String?)
    case openCommandHelp(String)
    case resetScript
    case invoke(name: String, arguments: [String], rawArguments: String)
    case unimplemented(String)
    case notACommand

    public enum LogHistory: Sendable, Equatable {
        case none, all, window
    }

    public enum DelayAction: Sendable, Equatable {
        case list
        case killAll
        case kill(String)
        case schedule(id: String?, repeating: Bool, seconds: Double, command: String)
    }
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
        guard !command.isEmpty else { return .display(Self.unrecognizedCommandMessage) }
        switch command {
        case "clear": return .clear
        case "disconnect":
            return .disconnect(all: arguments.first?.lowercased() == "all")
        case "reconnect":
            guard arguments.count <= 1 else { return .display("Usage: /reconnect [all]") }
            return .reconnect(all: arguments.first?.lowercased() == "all")
        case "connect", "world":
            guard (1...2).contains(arguments.count) else {
                return .display(arguments.isEmpty
                    ? "Missing Address"
                    : "Usage: connect <server name or IP address>:<port> (or <server name> <character>)")
            }
            return .connect(address: arguments[0], character: arguments.count == 2 ? arguments[1] : nil)
        case "repeat":
            guard arguments.count == 2, let count = Int(arguments[0]), count >= 0 else {
                return .display("Usage: '/repeat {count} {command}' (note that command should be in quotes if it's more than 1 word)")
            }
            return .repeatCommand(count: count, command: arguments[1])
        case "delay": return parseDelay(arguments)
        case "receive":
            guard !rawArguments.isEmpty else { return .display("Usage: /receive <text>") }
            return .receive(String(rawArguments))
        case "receivegmcp":
            guard let message = gmcpMessage(from: rawArguments) else {
                return .display("Usage: /receivegmcp <package> [json]")
            }
            return .receiveGMCP(message)
        case "ping": return .ping(String(rawArguments))
        case "setinput": return .setInput(String(rawArguments))
        case "idle":
            if arguments.isEmpty { return .idle(minutes: nil, command: nil) }
            guard arguments.count == 2, let minutes = UInt(arguments[0]) else {
                return .display("Usage:'/idle <time in minutes> <string:Command to enter>', no parameters turns it off")
            }
            return .idle(minutes: max(1, minutes), command: arguments[1])
        case "stats": return .statistics
        case "connectioninfo": return .connectionInfo
        case "close": return .close
        case "exit": return .exit
        case "new": return .newWindow
        case "newtab": return .newTab
        case "newinput":
            var unique = false
            for argument in arguments {
                if argument.hasPrefix("/") {
                    guard argument.caseInsensitiveCompare("/unique") == .orderedSame else {
                        return .display("Unknown option: \(argument)")
                    }
                    unique = true
                }
            }
            let prefix = arguments.last.flatMap { $0.hasPrefix("/") ? nil : $0 } ?? ""
            return .newInput(prefix: prefix, unique: unique)
        case "newedit":
            do { return .newEdit(try parseEditWindowOptions(String(rawArguments))) }
            catch { return .display("Command error: \(error.localizedDescription)") }
        case "silence": return .silence
        case "removelast": return .removeLast
        case "wall":
            guard !rawArguments.isEmpty else { return .display("Usage: /wall <text>") }
            return .wall(String(rawArguments))
        case "opendialog":
            guard let dialog = arguments.first else {
                return .display("Usage: '/opendialog (aliases/triggers/macros/worlds/about)'")
            }
            let allowed = ["aliases", "triggers", "macros", "worlds", "settings", "about"]
            guard allowed.contains(dialog.lowercased()) else { return .display("Unknown dialog") }
            return .openDialog(dialog.lowercased(), parameter: arguments.count > 1 ? arguments[1] : nil)
        case "slist": return .listServers
        case "chars": return .listCharacters
        case "puppets": return .listPuppets
        case "puppet":
            guard arguments.count == 1 else { return .display("Need a puppet name to connect a puppet") }
            return .connectPuppet(arguments[0])
        case "stoplogs": return .stopLogs
        case "log", "logall", "logtop":
            guard arguments.count == 1 else {
                switch command {
                case "logall": return .display("Usage: '/logall <filename>', '/log' stops the log")
                case "logtop": return .display("Usage: '/logtop <filename>', '/log' stops the log")
                default: return .display("Usage: '/log <filename>'")
                }
            }
            let history: CommandOutcome.LogHistory = command == "logall" ? .all : command == "logtop" ? .window : .none
            return .startLog(filename: arguments[0], history: history)
        case "echo":
            guard let value = arguments.first else { return .localEcho(true) }
            switch value.lowercased() {
            case "on": return .localEcho(true)
            case "off": return .localEcho(false)
            default: return .display("Usage: '/echo <ON/off>' Without on/off default is ON.")
            }
        case "ansireset": return .resetANSI
        case "naws":
            if arguments.count == 1, arguments[0].lowercased() == "auto" { return .nawsAuto }
            if arguments.count == 2,
               let columns = UInt16(arguments[0]), columns > 0,
               let rows = UInt16(arguments[1]), rows > 0 {
                return .naws(columns, rows)
            }
            return .display("Invalid usage, try '/help naws' to see help for this command")
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
            guard let name = arguments.first else { return .display("Error, missing variable name") }
            return .unsetVariable(name)
        case "printenv":
            if let name = arguments.first {
                return .display(variables[name] ?? "Variable not found: \(name)")
            }
            return .display(variables.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        case "gmcp":
            if arguments.count == 1, arguments[0].lowercased() == "dump_on" { return .gmcpDump(true) }
            if arguments.count == 1, arguments[0].lowercased() == "dump_off" { return .gmcpDump(false) }
            return .display("GMCP No parameter specified, available options are dump_on and dump_off")
        case "script", "@":
            guard !rawArguments.isEmpty else { return .display("Usage: /\(command) <JavaScript>") }
            return .script(String(rawArguments))
        case "shelp": return .scriptHelp(arguments.first)
        case "resetscript": return .resetScript
        case "roll": return roll(arguments.first)
        case "help", "?":
            if arguments.count == 1 { return .openCommandHelp(arguments[0]) }
            return .display(Self.commandHelp)
        case "makali":
            return .display("Even a man who is pure of heart,\nand says his prayers by night,\nmay become a wolf when the wolfsbane blooms,\nand the autumn moon is bright.")
        case "lizards":
            return .display("And now some messages from our Lizard supporters:\nCam-a-cam-mal, Pria-toi, Gan delah - Snowglass\nkweh - Thistle\n🦌 ☀️ ☀️ 🚙\n🦎 🦎")
        default:
            return Self.knownCommands.contains(command)
                ? .invoke(name: command, arguments: arguments, rawArguments: String(rawArguments))
                : .display(Self.unrecognizedCommandMessage)
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

    private func parseEditWindowOptions(_ source: String) throws -> EditWindowOptions {
        var options = EditWindowOptions()
        var index = source.startIndex

        func skipWhitespace() {
            while index < source.endIndex, source[index].isWhitespace {
                index = source.index(after: index)
            }
        }

        while true {
            skipWhitespace()
            guard index < source.endIndex else { return options }

            let nameStart = index
            while index < source.endIndex, !source[index].isWhitespace, source[index] != "=" {
                index = source.index(after: index)
            }
            let name = String(source[nameStart..<index]).lowercased()
            guard !name.isEmpty else { throw EditOptionError("Missing attribute name") }
            skipWhitespace()
            guard index < source.endIndex, source[index] == "=" else {
                throw EditOptionError("Missing '=' after attribute: \(name)")
            }
            index = source.index(after: index)
            skipWhitespace()
            guard index < source.endIndex else { throw EditOptionError("Missing value for attribute: \(name)") }

            let rawValue: String
            if source[index] == "\"" || source[index] == "'" {
                let quote = source[index]
                index = source.index(after: index)
                let valueStart = index
                while index < source.endIndex, source[index] != quote {
                    index = source.index(after: index)
                }
                guard index < source.endIndex else { throw EditOptionError("Unterminated quoted value for attribute: \(name)") }
                rawValue = String(source[valueStart..<index])
                index = source.index(after: index)
            } else {
                let valueStart = index
                while index < source.endIndex, !source[index].isWhitespace {
                    index = source.index(after: index)
                }
                rawValue = String(source[valueStart..<index])
            }
            let value = try decodeXMLEntities(rawValue)

            switch name {
            case "title": options.title = value
            case "capture":
                guard let count = Int(value), count >= 0 else { throw EditOptionError("Capture attribute is not a number") }
                options.captureLineCount = count
            case "capture_skip":
                guard let count = Int(value), count >= 0 else { throw EditOptionError("Capture_skip attribute is not a number") }
                options.captureSkipCount = count
            case "spellcheck": options.checksSpelling = try parseFlag(value)
            case "prepend": options.prepend = value
            case "append": options.append = value
            default: throw EditOptionError("Unknown attribute: \(name)")
            }
        }
    }

    private func parseFlag(_ value: String) throws -> Bool {
        switch value.lowercased() {
        case "t", "true", "1", "yes", "y", "on": return true
        case "f", "false", "0", "no", "n", "off": return false
        default: throw EditOptionError("Invalid flag: \(value)")
        }
    }

    private func decodeXMLEntities(_ source: String) throws -> String {
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            guard source[index] == "&" else {
                result.append(source[index])
                index = source.index(after: index)
                continue
            }
            guard let semicolon = source[index...].firstIndex(of: ";") else {
                throw EditOptionError("Unterminated XML entity")
            }
            let entity = String(source[source.index(after: index)..<semicolon])
            switch entity {
            case "amp": result.append("&")
            case "lt": result.append("<")
            case "gt": result.append(">")
            case "quot": result.append("\"")
            case "apos": result.append("'")
            default:
                let number: UInt32?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    number = UInt32(entity.dropFirst(2), radix: 16)
                } else if entity.hasPrefix("#") {
                    number = UInt32(entity.dropFirst())
                } else {
                    number = nil
                }
                guard let number, let scalar = UnicodeScalar(number) else {
                    throw EditOptionError("Unknown XML entity: &\(entity);")
                }
                result.unicodeScalars.append(scalar)
            }
            index = source.index(after: semicolon)
        }
        return result
    }

    private func gmcpMessage(from arguments: Substring) -> GMCPMessage? {
        let packageEnd = arguments.firstIndex(where: { $0.isWhitespace }) ?? arguments.endIndex
        let package = String(arguments[..<packageEnd])
        guard !package.isEmpty else { return nil }
        let payload = arguments[packageEnd...].drop(while: { $0.isWhitespace })
        return .init(package: package, payload: String(payload))
    }

    private func parseDelay(_ arguments: [String]) -> CommandOutcome {
        guard let first = arguments.first else { return .display("Invalid usage, try '/help delay' to see help for this command") }
        if first.caseInsensitiveCompare("list") == .orderedSame, arguments.count == 1 { return .delay(.list) }
        if first.caseInsensitiveCompare("killall") == .orderedSame, arguments.count == 1 { return .delay(.killAll) }
        if first.caseInsensitiveCompare("kill") == .orderedSame, arguments.count == 2 { return .delay(.kill(arguments[1])) }

        var index = 0
        var id: String?
        var repeating = false
        if arguments[index].caseInsensitiveCompare("id") == .orderedSame {
            guard arguments.indices.contains(index + 1) else { return .display("Missing ID after 'id' parameter") }
            id = arguments[index + 1]
            index += 2
        }
        guard arguments.indices.contains(index) else { return .display("Invalid usage, try '/help delay' to see help for this command") }
        if arguments[index].caseInsensitiveCompare("every") == .orderedSame {
            repeating = true
            index += 1
        }
        guard arguments.indices.contains(index + 1), arguments.count == index + 2,
              let seconds = parseTime(arguments[index]) else {
            return .display("Invalid usage, try '/help delay' to see help for this command")
        }
        return .delay(.schedule(id: id, repeating: repeating, seconds: seconds, command: arguments[index + 1]))
    }

    private func parseTime(_ value: String) -> Double? {
        guard !value.isEmpty else { return nil }
        let multiplier: Double
        let number: Substring
        switch value.last {
        case "s": multiplier = 1; number = value.dropLast()
        case "m": multiplier = 60; number = value.dropLast()
        case "h": multiplier = 3_600; number = value.dropLast()
        default: multiplier = 1; number = value[...]
        }
        let bounds = number.split(separator: "-", maxSplits: 1)
        guard let lower = bounds.first.flatMap({ Double($0) }), lower >= 0 else { return nil }
        if bounds.count == 1 { return lower * multiplier }
        guard let upper = Double(bounds[1]), upper >= lower else { return nil }
        return Double.random(in: lower...upper) * multiplier
    }

    private func roll(_ specification: String?) -> CommandOutcome {
        guard let specification else { return .display("🎲 Roll: Missing parameter") }
        let parts = specification.lowercased().split(separator: "d", maxSplits: 1)
        guard parts.count == 2, let count = Int(parts[0]), count > 0, count <= 1_000 else {
            return .display("🎲 Bad roll format, should be in the form of [count]d[sides](+bonus). The count must be <= 1000. For example, to roll a 6 sided die 10 times: /roll 10d6")
        }
        let sideParts = parts[1].split(separator: "+", maxSplits: 1)
        guard let sides = Int(sideParts[0]), sides > 0 else {
            return .display("🎲 Bad roll format, should be in the form of [count]d[sides](+bonus). The count must be <= 1000. For example, to roll a 6 sided die 10 times: /roll 10d6")
        }
        let bonus = sideParts.count == 2 ? Int(sideParts[1]) ?? 0 : 0
        let rolls = (0..<count).map { _ in Int.random(in: 1...sides) }
        return .display("🎲 Rolled \(rolls.map(String.init).joined(separator: " "))\n🎲 Roll Total: \(rolls.reduce(0, +) + bonus)")
    }

    /// Plain-text equivalent of the release-visible v331 help page. The UI
    /// adds styling, but keeping this content here makes headless output exact
    /// and testable.
    private static let commandHelp = """
    BeipMU - Command Line Help
    Scripting
    /@ $ - Run an immediate script, $ can span multiple lines of text
    /silent/(command) - Prefix for any command that will suppress informational messages from it

    /ansireset - Reset ansi state to default (useful if the server misbehaves and leaves a style set)
    /autolog - If one is setup and was stopped, this restarts the autolog
    /capturecancel - Cancel any spawn capture in the current window
    /chars - List characters for the current server
    /clear - Clears the Output window
    /close - Close the current tab
    /connect ($)/$ - Connect to a server
    /connectioninfo - Shows connection information (like socket security information)
    /debugaliases - Opens up an alias debug window
    /debugnetwork - Opens up a network debug window
    /debugtriggers - Opens up a trigger debug window
    /delay - Runs given commands after given given number of seconds
    /disconnect - Disconnect from the current server
    /echo <on/off> - Command Echo
    /exit - Closes all windows and exits the app (same as File->Exit)
    /gag $ - Gag incoming lines that contain a string
    /gmcp $ - Generic MUD Communcation Protocol
    /mcmp $ - Mud Client Media Protocol
    /grab $/$ - Use @pemit to grab a property for easy editing
    /help ($) - This help list, if a parameter given it opens the web help for that command
    /idle # $ - Idle Message, entered after a specified time of idling in minutes
    /log $ - Log incoming text into a file
    /logall $ - Same as log, but includes all previously received text
    /logtop $ - Same as log, but from the top of the current window
    /stoplogs - Stop all logs
    /map_addroom - Add a room to the map (see online help)
    /map_addexit - Add an exit to the map (see online help)
    /map_guesslocation - Try to figure out where the player is on the map based on recent scrollback
    /naws - Send telnet NAWS
    /new - Open a new window
    /newtab - Open a new tab in the current window
    /newedit - Open a new edit window (see help for parameters)
    /newinput (/unique) ($)- Open a new input window with an optional prefix
    /opendialog (aliases/triggers/macros/worlds/settings) (parameters...) - Open a built in dialog
    /ping $ - Sends the given text to the server and times how long before a response is received
    /printenv - Print environment variables
    /puppet $ - Open a new window and connect through the given puppet
    /puppets - Show puppets for the current character
    /repeat # $ - Repeats a command multiple times
    /recall # $ - Search output buffer for a string
    /receive $ - Acts like whatever text after "/receive " was received from the server (plus a cr-lf after)
    /reconnect $ - Reconnects if disconnected (with 'all' parameter it applies to every window)
    /resetscript - Reset the scripting engine (possibly switching languages)
    /roll [count]d[sides](+bonus) - Dice roll. Example /roll 10d6
    /script $ - Run single line script
    /shelp ($) - Scripting help
    /set $=$ - Set environment variable
    /setinput $ - Sets any text after the "/setinput " into the active input window
    /silence - Stop all playing sounds
    /slist - List all worlds
    /stats - List connection statistics
    /switchtab <tab group> <tab name> - Brings 'tab name' to top in the 'tab group' spawn window
    /tabcolor <color> - Sets the tab to the given HTML style color (#RRGGBB or a name)
    /ttype - Set Telnet Terminal Type (Default = "Beip")
    /unset $ - Delete an environment variable
    /wall $ - Send text to all connected windows

    Type '/help <command>' to open up the web help for a particular command
    """

    private static let unrecognizedCommandMessage = "Unrecognized Command, use // to send text directly to the mu*, /help for a list of commands, or set 'Send unrecognized commands' in settings/input window"
}

private struct EditOptionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
