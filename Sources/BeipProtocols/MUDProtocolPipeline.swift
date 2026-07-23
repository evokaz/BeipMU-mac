import BeipCore
import Foundation

public struct MUDProtocolPipeline: ByteStreamProcessor {
    private var telnet = TelnetParser()
    private var ansi = ANSIParser()
    private var mcp: MCPParser
    private var encoding: TextEncoding
    private let mcpConfigured: Bool
    private let puebloConfigured: Bool
    private var puebloActive: Bool

    public init(
        encoding: TextEncoding = .cp1252,
        mcp: Bool = false,
        mcpAuthenticationKey: String? = nil,
        pueblo: Bool = false,
        puebloActive: Bool = false,
        limitTelnetCharset: Bool = false
    ) {
        self.encoding = encoding
        self.mcpConfigured = mcp
        self.mcp = MCPParser(authenticationKey: mcpAuthenticationKey)
        self.puebloConfigured = pueblo
        self.puebloActive = puebloActive
        telnet.charsetLimit = limitTelnetCharset ? encoding : nil
    }

    public mutating func reset() {
        telnet.reset()
        ansi.reset()
        mcp.reset()
        puebloActive = false
    }

    public mutating func resetFormatting() {
        ansi.reset()
    }

    public mutating func setTerminalType(_ value: String) {
        telnet.terminalType = value
    }

    public mutating func consume(_ data: Data) -> [ProtocolOutput] {
        telnet.consume(data).flatMap { event -> [ProtocolOutput] in
            switch event {
            case let .line(bytes):
                let text = BeipTextDecoder.decode(bytes, encoding: encoding)
                var outputs: [ProtocolOutput] = []
                if mcpConfigured {
                    let events = mcp.consume(text)
                    if events.count != 1 || events.first != .display(text) {
                        for event in events {
                            switch event {
                            case let .display(value): outputs.append(contentsOf: renderLine(value))
                            case let .transmit(data): outputs.append(.transmit(data))
                            case let .message(message): outputs.append(.mcp(message))
                            case let .diagnostic(message): outputs.append(.diagnostic(message))
                            }
                        }
                        return outputs
                    }
                }
                outputs.append(contentsOf: renderLine(text))
                return outputs
            case let .prompt(bytes):
                return [.prompt(ansi.parse(BeipTextDecoder.decode(bytes, encoding: encoding), source: .prompt))]
            case let .send(bytes): return [.transmit(bytes)]
            case let .gmcp(message): return [.gmcp(message)]
            case let .encoding(newEncoding):
                encoding = newEncoding
                return [.encoding(newEncoding)]
            case .requestNAWS: return [.requestNAWS]
            case let .diagnostic(message): return [.diagnostic(message)]
            }
        }
    }

    private mutating func renderLine(_ text: String) -> [ProtocolOutput] {
        var outputs: [ProtocolOutput] = []
                if puebloConfigured, !puebloActive {
                    if text.hasPrefix("This world is Pueblo ") {
                        outputs.append(.transmit(Data("PUEBLOCLIENT 2.01\r\n".utf8)))
                    }
                    if text.range(of: "</xch_mudtext>", options: .caseInsensitive) != nil {
                        puebloActive = true
                    }
                }
                if puebloActive {
                    let parser = PuebloParser()
                    let result = parser.parse(text)
                    outputs.append(.line(parser.apply(result, to: ansi.parse(result.text))))
                } else {
                    outputs.append(.line(ansi.parse(text)))
                }
        return outputs
    }

    public mutating func encode(_ text: String) throws -> Data {
        let encoded = try BeipTextDecoder.encode(text, encoding: encoding)
        var escaped = Data()
        escaped.reserveCapacity(encoded.count)
        for byte in encoded {
            escaped.append(byte)
            if byte == 255 { escaped.append(byte) }
        }
        return escaped
    }

    public mutating func encodeMCP(_ message: MCPMessage) -> [Data] {
        mcp.encode(message)
    }

    public mutating func windowSizeChanged(columns: UInt16, rows: UInt16) -> Data? {
        guard telnet.negotiatedNAWS else { return nil }
        return telnet.naws(columns: columns, rows: rows)
    }

    public mutating func manualWindowSize(columns: UInt16, rows: UInt16) -> Data? {
        telnet.naws(columns: columns, rows: rows)
    }
}
