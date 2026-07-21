import BeipCore
import Foundation

public struct TelnetParser: Sendable {
    public enum Event: Sendable, Hashable {
        case line(Data)
        case prompt(Data)
        case send(Data)
        case gmcp(GMCPMessage)
        case encoding(TextEncoding)
        case requestNAWS
        case diagnostic(String)
    }

    private enum State: Sendable {
        case normal, iac, dont, `do`, wont, will, subnegotiation
        case gmcp, gmcpIAC, charset, charsetList, charsetIAC
        case terminalType, waitForIAC, subIAC
    }

    private enum Code {
        static let iac: UInt8 = 255
        static let dont: UInt8 = 254
        static let `do`: UInt8 = 253
        static let wont: UInt8 = 252
        static let will: UInt8 = 251
        static let sb: UInt8 = 250
        static let ga: UInt8 = 249
        static let nop: UInt8 = 241
        static let se: UInt8 = 240
        static let eor: UInt8 = 239
        static let binary: UInt8 = 0
        static let sga: UInt8 = 3
        static let terminalType: UInt8 = 24
        static let naws: UInt8 = 31
        static let charset: UInt8 = 42
        static let gmcp: UInt8 = 201
    }

    private var state: State = .normal
    private var buffer = Data()
    private var sideBuffer = Data()
    private var terminalTypeSequence = 0
    public private(set) var negotiatedNAWS = false
    public var terminalType = "Beip"

    public init() {}

    public mutating func reset() {
        state = .normal
        buffer.removeAll(keepingCapacity: true)
        sideBuffer.removeAll(keepingCapacity: true)
        terminalTypeSequence = 0
        negotiatedNAWS = false
    }

    public mutating func consume(_ data: Data) -> [Event] {
        var events: [Event] = []
        for byte in data {
            switch state {
            case .normal:
                switch byte {
                case 0: continue
                case Code.iac: state = .iac
                case 13: continue
                case 10: events.append(.line(buffer)); buffer.removeAll(keepingCapacity: true)
                default: buffer.append(byte)
                }
            case .iac:
                switch byte {
                case Code.ga, Code.eor:
                    if !buffer.isEmpty { events.append(.prompt(buffer)) }
                    state = .normal
                case Code.dont: state = .dont
                case Code.do: state = .do
                case Code.wont: state = .wont
                case Code.will: state = .will
                case Code.nop, Code.se: state = .normal
                case Code.iac: buffer.append(byte); state = .normal
                case Code.sb: state = .subnegotiation
                default: state = .normal
                }
            case .will:
                switch byte {
                case Code.binary, Code.charset, Code.eor:
                    events.append(.send(command(Code.do, byte)))
                case Code.sga:
                    events.append(.send(command(Code.dont, byte)))
                case Code.gmcp:
                    events.append(.send(command(Code.do, byte)))
                    events.append(.send(gmcpHello()))
                default:
                    events.append(.send(command(Code.dont, byte)))
                }
                state = .normal
            case .do:
                switch byte {
                case Code.binary, Code.charset, Code.terminalType:
                    events.append(.send(command(Code.will, byte)))
                case Code.naws:
                    if !negotiatedNAWS {
                        negotiatedNAWS = true
                        events.append(.send(command(Code.will, byte)))
                        events.append(.requestNAWS)
                    }
                default:
                    events.append(.send(command(Code.wont, byte)))
                }
                state = .normal
            case .dont:
                if byte == Code.terminalType { terminalTypeSequence = 0 }
                state = .normal
            case .wont:
                state = .normal
            case .subnegotiation:
                sideBuffer.removeAll(keepingCapacity: true)
                switch byte {
                case Code.charset: state = .charset
                case Code.terminalType: state = .terminalType
                case Code.gmcp: state = .gmcp
                case Code.iac: state = .subIAC
                default: state = .waitForIAC
                }
            case .gmcp:
                if byte == Code.iac { state = .gmcpIAC } else { sideBuffer.append(byte) }
            case .gmcpIAC:
                if byte == Code.se {
                    let value = String(decoding: sideBuffer, as: UTF8.self)
                    let pieces = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                    let package = pieces.first.map(String.init) ?? ""
                    let payload = pieces.count > 1 ? String(pieces[1]) : ""
                    events.append(.gmcp(.init(package: package, payload: payload)))
                }
                state = .normal
            case .charset:
                if byte == 1 { sideBuffer.removeAll(keepingCapacity: true); state = .charsetList }
                else { state = .waitForIAC }
            case .charsetList:
                if byte == Code.iac { state = .charsetIAC } else { sideBuffer.append(byte) }
            case .charsetIAC:
                if byte == Code.se, let separator = sideBuffer.first {
                    let offered = sideBuffer.dropFirst().split(separator: separator).map {
                        String(decoding: $0, as: UTF8.self).uppercased()
                    }
                    if offered.contains("UTF-8") {
                        events.append(.send(subnegotiation(Code.charset, Data([2]) + Data("UTF-8".utf8))))
                        events.append(.encoding(.utf8))
                    }
                }
                state = .normal
            case .terminalType:
                if byte == 1 {
                    let response: String
                    switch terminalTypeSequence {
                    case 0: response = terminalType
                    case 1: response = "ANSI"
                    default: response = "MTTS 269"
                    }
                    terminalTypeSequence = (terminalTypeSequence + 1) % 4
                    events.append(.send(subnegotiation(Code.terminalType, Data([0]) + Data(response.utf8))))
                    state = .waitForIAC
                }
            case .waitForIAC:
                if byte == Code.iac { state = .subIAC }
            case .subIAC:
                state = byte == Code.se ? .normal : .waitForIAC
            }
        }
        return events
    }

    public func naws(columns: UInt16, rows: UInt16) -> Data {
        subnegotiation(Code.naws, Data([
            UInt8(columns >> 8), UInt8(columns & 0xff),
            UInt8(rows >> 8), UInt8(rows & 0xff),
        ]))
    }

    private func command(_ command: UInt8, _ option: UInt8) -> Data {
        Data([Code.iac, command, option])
    }

    private func subnegotiation(_ option: UInt8, _ payload: Data) -> Data {
        Data([Code.iac, Code.sb, option]) + payload + Data([Code.iac, Code.se])
    }

    private func gmcpHello() -> Data {
        subnegotiation(Code.gmcp, Data("Core.Hello {\"client\":\"Beip\",\"version\":\"331\"}".utf8))
        + subnegotiation(Code.gmcp, Data("Core.Supports.Set [ \"WebView 1\", \"Beip.Stats 1\", \"Beip.Tilemap 1\", \"Beip.Id 1\", \"Client.Media 1\" ]".utf8))
    }
}

