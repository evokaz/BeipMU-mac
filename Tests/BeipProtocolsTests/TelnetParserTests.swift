import BeipCore
import BeipProtocols
import Foundation
import XCTest

final class TelnetParserTests: XCTestCase {
    func testBELIsAnExplicitEventAndNeverEntersText() {
        var parser = TelnetParser()
        XCTAssertEqual(parser.consume(Data([7, 7])), [.beep, .beep])
        XCTAssertEqual(parser.consume(Data("before\u{07}after\n".utf8)), [.beep, .line(Data("beforeafter".utf8))])
    }

    func testWindowsCompatibleTelnetDebugFormattingAndChunkState() {
        var formatter = TelnetDebugFormatter()
        XCTAssertEqual(
            formatter.format(Data([255, 251])),
            "<font color='#ff00ff'>IAC WILL "
        )
        XCTAssertEqual(
            formatter.format(Data([201, 60, 38, 13, 10, 1])),
            "<font color='#8080ff'>GMCP<font color='#008000'>(201) <font color='#ffffff'>&lt;&amp; <font color='#ff0000'>CR LF <font color='#008000'>1 "
        )
    }

    func testWindowsCompatibleTelnetDebugSubnegotiationAndUnknownValues() {
        var formatter = TelnetDebugFormatter()
        XCTAssertEqual(
            formatter.format(Data([255, 250, 24, 1, 255, 240, 255, 253, 222])),
            "<font color='#ff00ff'>IAC SB <font color='#8080ff'>TTYPE<font color='#008000'>(24) 1 <font color='#ff00ff'>IAC SE IAC DO <font color='#8080ff'>(unk)<font color='#008000'>(222) "
        )
    }

    func testNetworkDebugFormatterKeepsIndependentSendAndReceiveState() {
        var formatter = NetworkDebugFormatter(showHex: true)
        XCTAssertTrue(formatter.format(Data([255, 251]), received: true).hasPrefix("FF FB \r\n"))
        XCTAssertTrue(formatter.format(Data([255, 253]), received: false).hasSuffix("IAC DO "))
        XCTAssertTrue(formatter.format(Data([201]), received: true).hasSuffix("GMCP<font color='#008000'>(201) "))
    }

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

    func testSeededTelnetPropertyMatrixIsInvariantAcrossRandomPartitions() {
        let bytes = Data([255, 251, 0])
            + Data("\u{1b}[31mred\u{1b}[0m\r\nPrompt> ".utf8)
            + Data([255, 249, 255, 250, 201])
            + Data("Char.Vitals {\"hp\":7}".utf8)
            + Data([255, 240])
            + Data("done\n".utf8)
        var whole = TelnetParser()
        let expected = whole.consume(bytes)

        for seed in 0..<128 {
            var random = SeededRandom(seed: UInt64(seed + 1))
            var parser = TelnetParser()
            var actual: [TelnetParser.Event] = []
            var offset = 0
            while offset < bytes.count {
                let width = min(bytes.count - offset, random.nextInt(upperBound: 9) + 1)
                actual += parser.consume(Data(bytes[offset..<(offset + width)]))
                offset += width
            }
            XCTAssertEqual(actual, expected, "seed \(seed)")
        }
    }

    func testGMCPNegotiationAndFrame() {
        var parser = TelnetParser()
        let reply = parser.consume(Data([255, 251, 201]))
        XCTAssertEqual(reply.count, 2)
        guard case let .send(negotiation) = reply[0] else { return XCTFail("missing negotiation") }
        XCTAssertEqual(negotiation, Data([255, 253, 201]))
        guard case let .send(hello) = reply[1] else { return XCTFail("missing hello") }
        XCTAssertTrue(hello.starts(with: Data([255, 250, 201]) + Data("Core.Hello {\"client\":\"Beip\", \"version\":\"331\"}".utf8)))

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

    func testCharsetLimitPreservesConfiguredLegacyEncoding() {
        let request = Data([255, 250, 42, 1]) + Data(";US-ASCII;UTF-8".utf8) + Data([255, 240])
        var limited = TelnetParser()
        limited.charsetLimit = .cp437
        XCTAssertTrue(sentPayloads(limited.consume(request)).isEmpty)

        limited.charsetLimit = .utf8
        let reply = sentPayloads(limited.consume(request))
        XCTAssertEqual(reply, [Data([255, 250, 42, 2]) + Data("UTF-8".utf8) + Data([255, 240])])
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

    func testPromptRemainsInFollowingLineAcrossEveryChunkBoundaryLikeWindows() {
        let bytes = Data("Name: ".utf8) + Data([255, 249]) + Data("Welcome\r\n".utf8)
        for split in 0...bytes.count {
            var parser = TelnetParser()
            let events = parser.consume(Data(bytes.prefix(split))) + parser.consume(Data(bytes.dropFirst(split)))
            XCTAssertTrue(events.contains(.prompt(Data("Name: ".utf8))), "split \(split)")
            XCTAssertTrue(events.contains(.line(Data("Name: Welcome".utf8))), "split \(split)")
        }
    }

    func testEscapedIACInsideGMCPRemainsInSubnegotiation() {
        var parser = TelnetParser()
        let input = Data([255, 250, 201]) + Data("Core.Test abc".utf8) + Data([255, 255])
            + Data("def".utf8) + Data([255, 240]) + Data("line\n".utf8)

        let events = parser.consume(input)
        XCTAssertTrue(events.contains(.gmcp(.init(package: "Core.Test", payload: "abc�def"))))
        XCTAssertTrue(events.contains(.line(Data("line".utf8))))
    }

    private func sentPayloads(_ events: [TelnetParser.Event]) -> [Data] {
        events.compactMap { event in
            guard case let .send(data) = event else { return nil }
            return data
        }
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }
}

final class ANSIParserTests: XCTestCase {
    func testConfigurablePaletteAndLiveReconfigurationPreserveState() {
        var settings = ANSISettings.default
        settings.colors[.red] = RGBColor(red: 1, green: 2, blue: 3)
        settings.colors[.boldRed] = RGBColor(red: 4, green: 5, blue: 6)
        var parser = ANSIParser(settings: settings)
        let first = parser.parse("\u{1b}[31mold")
        XCTAssertEqual(first.runs[0].style.foreground, RGBColor(red: 1, green: 2, blue: 3))

        settings.colors[.red] = RGBColor(red: 7, green: 8, blue: 9)
        parser.configureANSI(settings)
        let second = parser.parse("new")
        XCTAssertEqual(second.runs[0].style.foreground, RGBColor(red: 7, green: 8, blue: 9))
        XCTAssertEqual(first.runs[0].style.foreground, RGBColor(red: 1, green: 2, blue: 3))
    }

    func testParsingDisabledConsumesEscapeAndDisplaysTheRemainingSequence() {
        var settings = ANSISettings.default
        settings.parse = false
        var parser = ANSIParser(settings: settings)
        let line = parser.parse("a\u{1b}[31mb")
        XCTAssertEqual(line.text, "a[31mb")
        XCTAssertEqual(line.runs.count, 1)
    }

    func testDisablingParsingClearsPreviouslyActiveSGRState() {
        var parser = ANSIParser()
        let styled = parser.parse("\u{1b}[31;3;4mstyled")
        XCTAssertEqual(styled.runs[0].style.foreground, RGBColor(red: 205, green: 0, blue: 0))
        XCTAssertTrue(styled.runs[0].style.italic)
        XCTAssertTrue(styled.runs[0].style.underline)

        var settings = parser.ansiSettings
        settings.parse = false
        parser.configure(settings)

        let plain = parser.parse("plain")
        XCTAssertEqual(plain.runs.count, 1)
        XCTAssertEqual(plain.runs[0].style, TextStyle())
    }

    func testBlinkingCanBeSuppressedWithoutChangingText() {
        var settings = ANSISettings.default
        settings.parseBlinking = false
        var parser = ANSIParser(settings: settings)
        let line = parser.parse("\u{1b}[5mblink")
        XCTAssertEqual(line.text, "blink")
        XCTAssertEqual(line.runs[0].style.blink, .none)
    }

    func testSeededANSIPropertyMatrixPreservesUnicodeText() {
        let codes = [0, 1, 2, 3, 4, 5, 7, 8, 9, 22, 23, 24, 25, 27, 28, 29, 30, 37, 40, 47, 90, 97]
        let tokens = ["alpha", "βeta", "雪", "🙂", "<&>"]
        var random = SeededRandom(seed: 0xB31F_331)
        for iteration in 0..<256 {
            var source = ""
            var expected = ""
            for _ in 0..<(random.nextInt(upperBound: 12) + 1) {
                let token = tokens[random.nextInt(upperBound: tokens.count)]
                source += "\u{1b}[\(codes[random.nextInt(upperBound: codes.count)])m\(token)"
                expected += token
            }
            source += "\u{1b}[0m"
            var parser = ANSIParser()
            XCTAssertEqual(parser.parse(source).text, expected, "iteration \(iteration)")
        }
    }

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

    func testConcealUsesLegacyInverseBehaviorAnd28RestoresColors() {
        var parser = ANSIParser()
        let line = parser.parse("\u{1b}[31;44;8mvisible\u{1b}[28mstill visible")

        XCTAssertEqual(line.runs.count, 2)
        XCTAssertEqual(line.runs[0].style.foreground, RGBColor(red: 0, green: 0, blue: 238))
        XCTAssertEqual(line.runs[0].style.background, RGBColor(red: 205, green: 0, blue: 0))
        XCTAssertEqual(line.runs[1].style.foreground, RGBColor(red: 205, green: 0, blue: 0))
        XCTAssertEqual(line.runs[1].style.background, RGBColor(red: 0, green: 0, blue: 238))
    }

    func testIndexedBaseColorsUseLegacyFixedPalette() {
        var parser = ANSIParser()
        let line = parser.parse("\u{1b}[31mdirect\u{1b}[38;5;1mindexed")

        XCTAssertEqual(line.runs.count, 2)
        XCTAssertEqual(line.runs[0].style.foreground, RGBColor(red: 205, green: 0, blue: 0))
        XCTAssertEqual(line.runs[1].style.foreground, RGBColor(red: 128, green: 0, blue: 0))
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

private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func nextInt(upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state % UInt64(upperBound))
    }
}

final class MUDProtocolPipelineTests: XCTestCase {
    func testPuebloNegotiationEntitiesLinksSendTagsAndImages() {
        var pipeline = MUDProtocolPipeline(encoding: .utf8, pueblo: true)
        let handshake = pipeline.consume(Data("This world is Pueblo 2.50 Enhanced</xch_mudtext>\n".utf8))
        XCTAssertTrue(handshake.contains(.transmit(Data("PUEBLOCLIENT 2.01\r\n".utf8))))

        let input = "<PUEBLO><A XCH_CMD='look'>Room &amp; Hall</A> <send href='examine|touch' hint='Examine|Touch'>object</send> <IMG SRC='https://example.test/map.png' ALT='Map'>\n"
        let outputs = pipeline.consume(Data(input.utf8))
        guard case let .line(line) = outputs.last else { return XCTFail("missing Pueblo line") }
        XCTAssertEqual(line.text, "Room & Hall object 🖼️")
        XCTAssertEqual(line.assets.first?.source.absoluteString, "https://example.test/map.png")
        XCTAssertEqual(line.assets.first?.altText, "Map")
        XCTAssertTrue(line.runs.contains { $0.style.link == .send("look", hints: []) }, "\(line.runs)")
        XCTAssertTrue(line.runs.contains { $0.style.link == .send("examine", hints: ["Examine", "Touch"]) })
        XCTAssertTrue(line.runs.contains { $0.style.link == .url("https://example.test/map.png") })
    }

    func testPuebloNumericEntitiesAndMalformedMarkupRemainSafe() {
        var pipeline = MUDProtocolPipeline(encoding: .utf8, pueblo: true, puebloActive: true)
        let outputs = pipeline.consume(Data("&#65; &#x1F43E; &unknown; <send href='look'>open\n".utf8))
        guard case let .line(line) = outputs.first else { return XCTFail("missing line") }
        XCTAssertEqual(line.text, "A 🐾 &unknown; open")
        XCTAssertTrue(line.runs.contains { $0.style.link == .send("look", hints: []) }, "\(line.runs)")
    }

    func testPuebloStandardStyleTagsOverlayANSIAndBRMatchesWindowsLineFraming() {
        var pipeline = MUDProtocolPipeline(encoding: .utf8, pueblo: true, puebloActive: true)
        let outputs = pipeline.consume(Data("\u{1b}[44mplain <b>bold <font color='#123456'><i>both</i></font></b><br>end\n".utf8))
        guard case let .line(line) = outputs.first else { return XCTFail("missing line") }
        XCTAssertEqual(line.text, "plain bold bothend")
        let bothOffset = "plain bold ".utf16.count
        guard let bothRun = line.runs.first(where: { $0.range.contains(bothOffset) }) else {
            return XCTFail("missing nested style run")
        }
        XCTAssertEqual(bothRun.style.foreground, RGBColor(red: 0x12, green: 0x34, blue: 0x56))
        XCTAssertEqual(bothRun.style.background, RGBColor(red: 0, green: 0, blue: 238))
        XCTAssertTrue(bothRun.style.bold)
        XCTAssertTrue(bothRun.style.italic)
    }

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
