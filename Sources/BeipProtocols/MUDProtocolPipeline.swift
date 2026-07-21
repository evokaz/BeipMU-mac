import BeipCore
import Foundation

public struct MUDProtocolPipeline: ByteStreamProcessor {
    private var telnet = TelnetParser()
    private var ansi = ANSIParser()
    private var encoding: TextEncoding

    public init(encoding: TextEncoding = .cp1252) {
        self.encoding = encoding
    }

    public mutating func reset() {
        telnet.reset()
        ansi.reset()
    }

    public mutating func consume(_ data: Data) -> [ProtocolOutput] {
        telnet.consume(data).map { event in
            switch event {
            case let .line(bytes):
                return .line(ansi.parse(BeipTextDecoder.decode(bytes, encoding: encoding)))
            case let .prompt(bytes):
                return .prompt(ansi.parse(BeipTextDecoder.decode(bytes, encoding: encoding), source: .prompt))
            case let .send(bytes): return .transmit(bytes)
            case let .gmcp(message): return .gmcp(message)
            case let .encoding(newEncoding):
                encoding = newEncoding
                return .encoding(newEncoding)
            case .requestNAWS: return .requestNAWS
            case let .diagnostic(message): return .diagnostic(message)
            }
        }
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
}

