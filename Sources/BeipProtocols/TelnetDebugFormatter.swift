import Foundation

/// Stateful formatter used by the network debugger. Its token names, spacing,
/// HTML escaping, and chunk-boundary behavior match `TelnetDebugger` in the
/// Windows client.
public struct TelnetDebugFormatter: Sendable {
    private enum State: Sendable { case normal, iac, negotiate, subStart, subData, subIAC }
    private enum Color: String, Sendable {
        case magenta = "#ff00ff"
        case lightBlue = "#8080ff"
        case green = "#008000"
        case red = "#ff0000"
        case white = "#ffffff"
    }

    private var state: State = .normal

    public init() {}

    public mutating func reset() { state = .normal }

    public mutating func format(_ data: Data) -> String {
        var output = ""
        var color: Color?

        func setColor(_ newColor: Color, pad: Bool = true) {
            guard color != newColor else { return }
            if pad, !output.isEmpty, output.last != "\n", output.last != " " { output.append(" ") }
            color = newColor
            output += "<font color='\(newColor.rawValue)'>"
        }

        func appendCharacter(_ byte: UInt8) {
            switch byte {
            case 8: setColor(.red); output += "BS "
            case 9: setColor(.red); output += "TAB "
            case 10: setColor(.red); output += "LF "
            case 13: setColor(.red); output += "CR "
            case 27: setColor(.red); output += "ESC "
            case 32..<127:
                setColor(.white)
                if byte == 60 { output += "&lt;" }
                else if byte == 38 { output += "&amp;" }
                else { output.append(Character(UnicodeScalar(byte))) }
            default:
                setColor(.green)
                output += "\(byte) "
            }
        }

        func appendIAC(_ byte: UInt8) {
            setColor(.magenta)
            if let label = Self.commandNames[byte] {
                output += "\(label) "
            } else {
                output += "(unk)"
                setColor(.green, pad: false)
                output += "(\(byte))"
            }
        }

        func appendOption(_ byte: UInt8) {
            setColor(.lightBlue)
            output += Self.optionNames[byte] ?? "(unk)"
            setColor(.green, pad: false)
            output += "(\(byte)) "
        }

        for byte in data {
            switch state {
            case .normal:
                if byte == 255 {
                    setColor(.magenta)
                    output += "IAC "
                    state = .iac
                } else {
                    appendCharacter(byte)
                }
            case .iac:
                appendIAC(byte)
                switch byte {
                case 251...254: state = .negotiate
                case 250: state = .subStart
                default: state = .normal
                }
            case .negotiate:
                appendOption(byte)
                state = .normal
            case .subStart:
                appendOption(byte)
                state = .subData
            case .subData:
                if byte == 255 {
                    appendIAC(byte)
                    state = .subIAC
                } else {
                    appendCharacter(byte)
                }
            case .subIAC:
                if byte == 240 { appendIAC(byte) }
                else { output += "(SB_IAC did not see a TELNET_SE) " }
                state = .normal
            }
        }
        return output
    }

    private static let commandNames: [UInt8: String] = [
        0: "BINARY", 236: "EOF", 237: "SUSP", 238: "ABORT", 239: "EOR", 240: "SE",
        241: "NOP", 242: "DM", 243: "BREAK", 244: "IP", 245: "AO", 246: "AYT",
        247: "EC", 248: "EL", 249: "GA", 250: "SB", 251: "WILL", 252: "WONT",
        253: "DO", 254: "DONT", 255: "IAC",
    ]

    private static let optionNames: [UInt8: String] = [
        0: "BINARY", 1: "ECHO", 2: "RCP", 3: "SGA", 4: "NAMS", 5: "STATUS", 6: "TM",
        7: "RCTE", 8: "NAOL", 9: "NAOP", 10: "NAOCRD", 11: "NAOHTS", 12: "NAOHTD",
        13: "NAOFFD", 14: "NAOVTS", 15: "NAOVTD", 16: "NAOLFD", 17: "XASCII",
        18: "LOGOUT", 19: "BM", 20: "DET", 21: "SUPDUP", 22: "SUPDUPOUTPUT", 23: "SNDLOC",
        24: "TTYPE", 25: "EOR", 26: "TUID", 27: "OUTMRK", 28: "TTYLOC", 29: "3270REGIME",
        30: "X3PAD", 31: "NAWS", 32: "TSPEED", 33: "LFLOW", 34: "LINEMODE",
        35: "XDISPLOC", 36: "OLD_ENVIRON", 37: "AUTHENTICATION", 38: "ENCRYPT",
        39: "NEW_ENVIRON", 42: "CHARSET", 45: "SLE", 69: "MSDP", 70: "MSSP",
        85: "MCCP1", 86: "MCCP2", 87: "MCCP3", 90: "MSP", 91: "MXP", 93: "ZMP",
        139: "SSPI_LOGON", 201: "GMCP", 255: "EXOPL",
    ]
}

public struct NetworkDebugFormatter: Sendable {
    public var showHex: Bool
    public var showTelnet: Bool
    private var received = TelnetDebugFormatter()
    private var sent = TelnetDebugFormatter()

    public init(showHex: Bool = false, showTelnet: Bool = true) {
        self.showHex = showHex
        self.showTelnet = showTelnet
    }

    public mutating func format(_ data: Data, received isReceived: Bool) -> String {
        var output = showHex ? data.map { String(format: "%02X ", $0) }.joined() + "\r\n" : ""
        if showTelnet {
            output += isReceived ? received.format(data) : sent.format(data)
        }
        return output
    }
}
