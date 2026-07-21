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

    func testCoreOptionNegotiationMatchesWindowsClient() {
        var parser = TelnetParser()
        let events = parser.consume(Data([
            255, 251, 0,   // WILL BINARY -> DO BINARY
            255, 251, 25,  // WILL EOR -> DO EOR
            255, 251, 3,   // WILL SGA -> DONT SGA
            255, 253, 0,   // DO BINARY -> WILL BINARY
            255, 253, 24,  // DO TTYPE -> WILL TTYPE
            255, 253, 99,  // unsupported DO -> WONT
        ]))
        let sends = events.compactMap { event -> Data? in
            guard case let .send(data) = event else { return nil }
            return data
        }
        XCTAssertEqual(sends, [
            Data([255, 253, 0]),
            Data([255, 253, 25]),
            Data([255, 254, 3]),
            Data([255, 251, 0]),
            Data([255, 251, 24]),
            Data([255, 252, 99]),
        ])
    }

    func testTerminalTypeMTTSSequenceAndReset() {
        var parser = TelnetParser()
        parser.terminalType = "BeipMU Mac"
        let request = Data([255, 250, 24, 1, 255, 240])

        XCTAssertEqual(sentPayloads(parser.consume(request)), [Data([255, 250, 24, 0]) + Data("BeipMU Mac".utf8) + Data([255, 240])])
        XCTAssertEqual(sentPayloads(parser.consume(request)), [Data([255, 250, 24, 0]) + Data("ANSI".utf8) + Data([255, 240])])
        XCTAssertEqual(sentPayloads(parser.consume(request)), [Data([255, 250, 24, 0]) + Data("MTTS 269".utf8) + Data([255, 240])])
        XCTAssertEqual(sentPayloads(parser.consume(request)), [Data([255, 250, 24, 0]) + Data("MTTS 269".utf8) + Data([255, 240])])

        _ = parser.consume(Data([255, 254, 24]))
        XCTAssertEqual(sentPayloads(parser.consume(request)), [Data([255, 250, 24, 0]) + Data("BeipMU Mac".utf8) + Data([255, 240])])
    }

    func testCharsetRequestIsInvariantAcrossChunkBoundaries() {
        let request = Data([255, 250, 42, 1]) + Data(";US-ASCII;utf-8;ISO-8859-1".utf8) + Data([255, 240])
        let expectedReply = Data([255, 250, 42, 2]) + Data("UTF-8".utf8) + Data([255, 240])

        for split in 0...request.count {
            var parser = TelnetParser()
            let events = parser.consume(Data(request.prefix(split))) + parser.consume(Data(request.dropFirst(split)))
            XCTAssertEqual(sentPayloads(events), [expectedReply], "split \(split)")
            XCTAssertTrue(events.contains(.encoding(.utf8)), "split \(split)")
        }
    }

    func testFragmentedGMCPDoesNotPolluteLineBuffer() {
        var parser = TelnetParser()
        let bytes = Data("before".utf8)
            + Data([255, 250, 201])
            + Data("Char.Vitals {\"hp\":7}".utf8)
            + Data([255, 240])
            + Data("after\n".utf8)
        var events: [TelnetParser.Event] = []
        for byte in bytes { events += parser.consume(Data([byte])) }

        XCTAssertTrue(events.contains(.gmcp(.init(package: "Char.Vitals", payload: "{\"hp\":7}"))))
        XCTAssertTrue(events.contains(.line(Data("beforeafter".utf8))))
    }

    private func sentPayloads(_ events: [TelnetParser.Event]) -> [Data] {
        events.compactMap { event in
            guard case let .send(data) = event else { return nil }
            return data
        }
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

    func testStylesBackgroundAnd256Color() {
        var parser = ANSIParser()
        let line = parser.parse(
            "\u{1b}[1;3;4;9;48;5;22;38;5;196mstyled\u{1b}[22;23;24;29;49mplain"
        )

        XCTAssertEqual(line.text, "styledplain")
        XCTAssertEqual(line.runs.count, 2)
        XCTAssertEqual(line.runs[0].style.foreground, RGBColor(red: 255, green: 0, blue: 0))
        XCTAssertEqual(line.runs[0].style.background, RGBColor(red: 0, green: 95, blue: 0))
        XCTAssertFalse(line.runs[0].style.bold)
        XCTAssertTrue(line.runs[0].style.italic)
        XCTAssertTrue(line.runs[0].style.underline)
        XCTAssertTrue(line.runs[0].style.strikeout)
        XCTAssertEqual(line.runs[1].style.foreground, RGBColor(red: 255, green: 0, blue: 0))
        XCTAssertNil(line.runs[1].style.background)
        XCTAssertFalse(line.runs[1].style.bold)
        XCTAssertFalse(line.runs[1].style.italic)
        XCTAssertFalse(line.runs[1].style.underline)
        XCTAssertFalse(line.runs[1].style.strikeout)
    }

    func testInverseIsIdempotentAndTracksColorsSetWhileActive() {
        var parser = ANSIParser()
        let line = parser.parse("\u{1b}[31;44;7;7mfirst\u{1b}[32msecond\u{1b}[27;27mthird")

        XCTAssertEqual(line.text, "firstsecondthird")
        XCTAssertEqual(line.runs.count, 3)
        XCTAssertEqual(line.runs[0].style.foreground, RGBColor(red: 0, green: 0, blue: 238))
        XCTAssertEqual(line.runs[0].style.background, RGBColor(red: 205, green: 0, blue: 0))
        XCTAssertEqual(line.runs[1].style.foreground, RGBColor(red: 0, green: 0, blue: 238))
        XCTAssertEqual(line.runs[1].style.background, RGBColor(red: 0, green: 205, blue: 0))
        XCTAssertEqual(line.runs[2].style.foreground, RGBColor(red: 0, green: 205, blue: 0))
        XCTAssertEqual(line.runs[2].style.background, RGBColor(red: 0, green: 0, blue: 238))
    }

    func testConcealDoesNotAccidentallyInvertColors() {
        var parser = ANSIParser()
        let line = parser.parse("\u{1b}[31;44;8mvisible\u{1b}[28mstill visible")

        XCTAssertEqual(line.runs.count, 1)
        XCTAssertEqual(line.runs[0].style.foreground, RGBColor(red: 205, green: 0, blue: 0))
        XCTAssertEqual(line.runs[0].style.background, RGBColor(red: 0, green: 0, blue: 238))
    }

    func testBoldUsesBrightPaletteUnlessFontBoldIsEnabled() {
        var colorParser = ANSIParser()
        let colorBold = colorParser.parse("\u{1b}[31;1mbright")
        XCTAssertEqual(colorBold.runs[0].style.foreground, RGBColor(red: 255, green: 0, blue: 0))
        XCTAssertFalse(colorBold.runs[0].style.bold)

        var fontParser = ANSIParser(options: .init(useFontBold: true))
        let fontBold = fontParser.parse("\u{1b}[31;1mheavy")
        XCTAssertEqual(fontBold.runs[0].style.foreground, RGBColor(red: 205, green: 0, blue: 0))
        XCTAssertTrue(fontBold.runs[0].style.bold)
    }

    func testFaintDarkensLogicalForegroundWhileInverseIsActive() {
        var parser = ANSIParser()
        let line = parser.parse("\u{1b}[31;44;7;2mfaint")

        XCTAssertEqual(line.runs[0].style.foreground, RGBColor(red: 0, green: 0, blue: 238))
        XCTAssertEqual(line.runs[0].style.background, RGBColor(red: 102, green: 0, blue: 0))
    }

    func testPreventInvisibleContrastsEqualExplicitColors() {
        var protectedParser = ANSIParser()
        let protected = protectedParser.parse("\u{1b}[31;41mreadable")
        XCTAssertEqual(protected.runs[0].style.foreground, RGBColor(red: 50, green: 255, blue: 255))
        XCTAssertEqual(protected.runs[0].style.background, RGBColor(red: 205, green: 0, blue: 0))

        var literalParser = ANSIParser(options: .init(preventInvisible: false))
        let literal = literalParser.parse("\u{1b}[31;41mhidden")
        XCTAssertEqual(literal.runs[0].style.foreground, literal.runs[0].style.background)
    }
}

final class MUDProtocolPipelineTests: XCTestCase {
    func testFormattingResetDoesNotResetTelnetNegotiation() {
        var pipeline = MUDProtocolPipeline()
        _ = pipeline.consume(Data([255, 253, 31]))
        _ = pipeline.consume(Data("\u{1b}[31mred\n".utf8))

        pipeline.resetFormatting()

        let outputs = pipeline.consume(Data("plain\n".utf8))
        guard case let .line(line) = outputs.first else { return XCTFail("missing line") }
        XCTAssertNil(line.runs.first?.style.foreground)
        XCTAssertEqual(pipeline.windowSizeChanged(columns: 80, rows: 24), Data([255, 250, 31, 0, 80, 0, 24, 255, 240]))
    }

    func testManualWindowSizeDoesNotRequireNegotiation() {
        var pipeline = MUDProtocolPipeline()
        XCTAssertNil(pipeline.windowSizeChanged(columns: 100, rows: 40))
        XCTAssertEqual(
            pipeline.manualWindowSize(columns: 100, rows: 40),
            Data([255, 250, 31, 0, 100, 0, 40, 255, 240])
        )
    }

    func testTerminalTypeCanBeChangedThroughPipeline() {
        var pipeline = MUDProtocolPipeline()
        pipeline.setTerminalType("Beip Mac")
        let outputs = pipeline.consume(Data([255, 250, 24, 1, 255, 240]))
        XCTAssertEqual(
            outputs,
            [.transmit(Data([255, 250, 24, 0]) + Data("Beip Mac".utf8) + Data([255, 240]))]
        )
    }
}
