import BeipCore
import BeipProtocols
import XCTest

final class TelnetParserTests: XCTestCase {
    func testLinesAreInvariantAcrossChunkBoundaries() {
        let bytes = Data("one\r\ntwo\n".utf8)
        for split in 0...bytes.count {
            var parser = TelnetParser()
            let first = parser.consume(Data(bytes.prefix(split)))
            let second = parser.consume(Data(bytes.dropFirst(split)))
            let lines = (first + second).compactMap { event -> String? in
                guard case let .line(data) = event else { return nil }
                return String(decoding: data, as: UTF8.self)
            }
            XCTAssertEqual(lines, ["one", "two"], "split \(split)")
        }
    }

    func testGMCPNegotiationAndFrame() {
        var parser = TelnetParser()
        let reply = parser.consume(Data([255, 251, 201]))
        XCTAssertEqual(reply.count, 2)
        guard case let .send(negotiation) = reply[0] else { return XCTFail("missing negotiation") }
        XCTAssertEqual(negotiation, Data([255, 253, 201]))
        guard case let .send(hello) = reply[1] else { return XCTFail("missing hello") }
        XCTAssertTrue(String(decoding: hello, as: UTF8.self).contains("Core.Hello"))

        let input = Data([255, 250, 201]) + Data("Core.Ping {\"x\":1}".utf8) + Data([255, 240])
        let events = parser.consume(input)
        guard case let .gmcp(message) = events.first else { return XCTFail("missing GMCP") }
        XCTAssertEqual(message.package, "Core.Ping")
        XCTAssertEqual(message.payload, "{\"x\":1}")
    }

    func testNAWSNegotiation() {
        var parser = TelnetParser()
        let events = parser.consume(Data([255, 253, 31]))
        XCTAssertTrue(events.contains(.requestNAWS))
        XCTAssertEqual(parser.naws(columns: 80, rows: 24), Data([255, 250, 31, 0, 80, 0, 24, 255, 240]))
        XCTAssertEqual(
            parser.naws(columns: 255, rows: 511),
            Data([255, 250, 31, 0, 255, 255, 1, 255, 255, 255, 240])
        )
    }
}

final class ANSIParserTests: XCTestCase {
    func testSixteenAndTrueColor() {
        var parser = ANSIParser()
        let line = parser.parse("normal \u{1b}[31mred\u{1b}[38;2;1;2;3mrgb\u{1b}[0m end")
        XCTAssertEqual(line.text, "normal redrgb end")
        XCTAssertEqual(line.runs[1].style.foreground, RGBColor(red: 205, green: 0, blue: 0))
        XCTAssertEqual(line.runs[2].style.foreground, RGBColor(red: 1, green: 2, blue: 3))
    }

    func testCodePage437() {
        XCTAssertEqual(BeipTextDecoder.decode(Data([0x80, 0xDB]), encoding: .cp437), "Ç█")
    }
}
