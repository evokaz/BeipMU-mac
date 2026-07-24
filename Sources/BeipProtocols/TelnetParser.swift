import BeipCore
import Foundation

public struct TelnetParser: Sendable {
    public static let maximumLineBytes = 4 * 1_024 * 1_024
    public static let maximumSubnegotiationBytes = 2 * 1_024 * 1_024 + 64 * 1_024

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
        static let endOfRecord: UInt8 = 25
        static let naws: UInt8 = 31
        static let charset: UInt8 = 42
        static let gmcp: UInt8 = 201
    }

    private var state: State = .normal
    private var buffer = Data()
    private var sideBuffer = Data()
    private var discardingOversizedLine = false
    private var terminalTypeSequence = 0
    public private(set) var negotiatedNAWS = false
    public var terminalType = "Beip"
    public var charsetLimit: TextEncoding?

    public init() {}

    public mutating func reset() {
        state = .normal
        buffer.removeAll(keepingCapacity: true)
        sideBuffer.removeAll(keepingCapacity: true)
        discardingOversizedLine = false
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
                case 10:
                    if !discardingOversizedLine { events.append(.line(buffer)) }
                    buffer.removeAll(keepingCapacity: true)
                    discardingOversizedLine = false
                default:
                    if discardingOversizedLine {
                        continue
                    } else if buffer.count < Self.maximumLineBytes {
                        buffer.append(byte)
                    } else {
                        buffer.removeAll(keepingCapacity: true)
                        discardingOversizedLine = true
                        events.append(.diagnostic(
                            "Telnet line exceeded \(Self.maximumLineBytes) bytes and was discarded"
                        ))
                    }
                }
            case .iac:
                switch byte {
                case Code.ga, Code.eor:
                    if !buffer.isEmpty, !discardingOversizedLine {
                        events.append(.prompt(buffer))
                    }
                    if discardingOversizedLine {
                        buffer.removeAll(keepingCapacity: true)
                        discardingOversizedLine = false
                    }
                    state = .normal
                case Code.dont: state = .dont
                case Code.do: state = .do
                case Code.wont: state = .wont
                case Code.will: state = .will
                case Code.nop, Code.se: state = .normal
                case Code.iac:
                    if !discardingOversizedLine, buffer.count < Self.maximumLineBytes {
                        buffer.append(byte)
                    } else if !discardingOversizedLine {
                        buffer.removeAll(keepingCapacity: true)
                        discardingOversizedLine = true
                        events.append(.diagnostic(
                            "Telnet line exceeded \(Self.maximumLineBytes) bytes and was discarded"
                        ))
                    }
                    state = .normal
                case Code.sb: state = .subnegotiation
                default: state = .normal
                }
            case .will:
                switch byte {
                case Code.binary, Code.charset, Code.endOfRecord:
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
                if byte == Code.iac {
                    state = .gmcpIAC
                } else if sideBuffer.count < Self.maximumSubnegotiationBytes {
                    sideBuffer.append(byte)
                } else {
                    sideBuffer.removeAll(keepingCapacity: true)
                    state = .waitForIAC
                    events.append(.diagnostic(
                        "Telnet subnegotiation exceeded \(Self.maximumSubnegotiationBytes) bytes and was discarded"
                    ))
                }
            case .gmcpIAC:
                if byte == Code.se {
                    let value = String(decoding: sideBuffer, as: UTF8.self)
                    let pieces = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                    let package = pieces.first.map(String.init) ?? ""
                    let payload = pieces.count > 1 ? String(pieces[1]) : ""
                    events.append(.gmcp(.init(package: package, payload: payload)))
                    state = .normal
                } else if byte == Code.iac {
                    if sideBuffer.count < Self.maximumSubnegotiationBytes {
                        sideBuffer.append(Code.iac)
                        state = .gmcp
                    } else {
                        sideBuffer.removeAll(keepingCapacity: true)
                        state = .waitForIAC
                        events.append(.diagnostic(
                            "Telnet subnegotiation exceeded \(Self.maximumSubnegotiationBytes) bytes and was discarded"
                        ))
                    }
                } else {
                    events.append(.diagnostic("Invalid IAC command in GMCP subnegotiation: \(byte)"))
                    state = .gmcp
                }
            case .charset:
                if byte == 1 { sideBuffer.removeAll(keepingCapacity: true); state = .charsetList }
                else { state = .waitForIAC }
            case .charsetList:
                if byte == Code.iac {
                    state = .charsetIAC
                } else if sideBuffer.count < Self.maximumSubnegotiationBytes {
                    sideBuffer.append(byte)
                } else {
                    sideBuffer.removeAll(keepingCapacity: true)
                    state = .waitForIAC
                    events.append(.diagnostic(
                        "Telnet subnegotiation exceeded \(Self.maximumSubnegotiationBytes) bytes and was discarded"
                    ))
                }
            case .charsetIAC:
                if byte == Code.se, let separator = sideBuffer.first {
                    let offered = sideBuffer.dropFirst().split(separator: separator).map {
                        String(decoding: $0, as: UTF8.self).uppercased()
                    }
                    if offered.contains("UTF-8"), charsetLimit == nil || charsetLimit == .utf8 {
                        events.append(.send(subnegotiation(Code.charset, Data([2]) + Data("UTF-8".utf8))))
                        events.append(.encoding(.utf8))
                    }
                    state = .normal
                } else if byte == Code.iac {
                    if sideBuffer.count < Self.maximumSubnegotiationBytes {
                        sideBuffer.append(Code.iac)
                        state = .charsetList
                    } else {
                        sideBuffer.removeAll(keepingCapacity: true)
                        state = .waitForIAC
                        events.append(.diagnostic(
                            "Telnet subnegotiation exceeded \(Self.maximumSubnegotiationBytes) bytes and was discarded"
                        ))
                    }
                } else {
                    events.append(.diagnostic("Invalid IAC command in CHARSET subnegotiation: \(byte)"))
                    state = .charsetList
                }
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
        let dimensions = Data([
            UInt8(columns >> 8), UInt8(columns & 0xff),
            UInt8(rows >> 8), UInt8(rows & 0xff),
        ])
        return subnegotiation(Code.naws, escapingIAC(in: dimensions))
    }

    private func command(_ command: UInt8, _ option: UInt8) -> Data {
        Data([Code.iac, command, option])
    }

    private func subnegotiation(_ option: UInt8, _ payload: Data) -> Data {
        Data([Code.iac, Code.sb, option]) + payload + Data([Code.iac, Code.se])
    }

    private func escapingIAC(in data: Data) -> Data {
        data.reduce(into: Data()) { escaped, byte in
            escaped.append(byte)
            if byte == Code.iac { escaped.append(byte) }
        }
    }

    private func gmcpHello() -> Data {
        subnegotiation(Code.gmcp, Data("Core.Hello {\"client\":\"Beip\", \"version\":\"331\"}".utf8))
        + subnegotiation(Code.gmcp, Data("Core.Supports.Set [ \"WebView 1\", \"Beip.Stats 1\", \"Beip.Tilemap 1\", \"Beip.Id 1\", \"Client.Media 1\" ]".utf8))
    }
}
