import BeipCore
import BeipProtocols
import Foundation
import XCTest

final class TextDecoderTests: XCTestCase {
    func testCP1252AllBytesRoundTrip() throws {
        let bytes = Data((UInt8.min...UInt8.max))
        let decoded = BeipTextDecoder.decode(bytes, encoding: .cp1252)

        XCTAssertEqual(try BeipTextDecoder.encode(decoded, encoding: .cp1252), bytes)
        XCTAssertEqual(decoded.unicodeScalars.dropFirst(0x80).first?.value, 0x20AC)
        XCTAssertEqual(Array(decoded.unicodeScalars)[0x81].value, 0x0081)
        XCTAssertEqual(Array(decoded.unicodeScalars)[0x9D].value, 0x009D)
    }

    func testCP437AllBytesRoundTrip() throws {
        let bytes = Data((UInt8.min...UInt8.max))
        let decoded = BeipTextDecoder.decode(bytes, encoding: .cp437)

        XCTAssertEqual(try BeipTextDecoder.encode(decoded, encoding: .cp437), bytes)
        XCTAssertEqual(Array(decoded.unicodeScalars)[0x80].value, 0x00C7)
        XCTAssertEqual(Array(decoded.unicodeScalars)[0xDB].value, 0x2588)
    }

    func testUTF8RoundTrip() throws {
        let text = "BeipMU — Καλημέρα 🐾"
        XCTAssertEqual(
            BeipTextDecoder.decode(try BeipTextDecoder.encode(text, encoding: .utf8), encoding: .utf8),
            text
        )
    }

    func testLegacyEncodingsRejectUnrepresentableText() {
        XCTAssertThrowsError(try BeipTextDecoder.encode("🐾", encoding: .cp1252))
        XCTAssertThrowsError(try BeipTextDecoder.encode("€", encoding: .cp437))
    }
}
