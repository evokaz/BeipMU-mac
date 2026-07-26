import BeipCore
import XCTest

final class RenderedLineTests: XCTestCase {
    func testRenderedLineRoundTripsThroughJSON() throws {
        let line = RenderedLine(
            text: "Hello 🌍",
            runs: [.init(range: 0..<5, style: .init(foreground: .init(red: 1, green: 2, blue: 3), bold: true))],
            source: .server
        )
        let decoded = try JSONDecoder().decode(RenderedLine.self, from: JSONEncoder().encode(line))
        XCTAssertEqual(decoded, line)
    }

    func testOlderParagraphStyleDecodesWithZeroWrappedIndent() throws {
        let data = Data(#"{"alignment":"left","leftIndent":4,"rightIndent":2,"topPadding":0,"bottomPadding":0}"#.utf8)
        let style = try JSONDecoder().decode(ParagraphStyle.self, from: data)
        XCTAssertEqual(style.leftIndent, 4)
        XCTAssertEqual(style.wrappedIndent, 0)
        XCTAssertEqual(style.rightIndent, 2)
    }

    func testOutputHistoryExposesOldestIDsWithoutChangingStorage() {
        var history = OutputHistory(limit: 3)
        let lines = (0..<3).map { RenderedLine(text: String($0)) }
        lines.forEach { history.append($0) }
        XCTAssertEqual(history.oldestLineIDs(2), Array(lines.prefix(2)).map(\.id))
        XCTAssertEqual(history.lines, lines)
    }

    func testConnectPlaceholders() {
        let character = CharacterProfile(name: "Guest", connectText: "connect %NAME% %PASSWORD%", password: "secret")
        XCTAssertEqual(character.name, "Guest")
        XCTAssertEqual(character.connectText, "connect %NAME% %PASSWORD%")
    }

    func testPuppetRoutingSupportsLiteralRegexHiddenPrefixesAndOutgoingText() {
        let literal = PuppetProfile(
            name: "Bot", receivePrefix: "Bot> ", sendPrefix: "tell Bot ",
            removeAccidentalPrefix: true
        )
        let regex = PuppetProfile(
            name: "Numbered", receivePrefix: #"^P\d+(: )"#,
            receivePrefixIsRegex: true, hideReceivePrefix: true
        )

        XCTAssertEqual(PuppetRouter.route("Bot> hello", through: [literal])?.text, "hello")
        XCTAssertEqual(PuppetRouter.route("bOt> hello", through: [literal])?.text, "hello")
        XCTAssertEqual(PuppetRouter.route("P12: status", through: [regex])?.text, "P12status")
        XCTAssertNil(PuppetRouter.route("ordinary", through: [literal, regex]))
        XCTAssertEqual(PuppetRouter.outgoing("look", for: literal), "tell Bot look")
        XCTAssertEqual(PuppetRouter.outgoing("tell Bot look", for: literal), "tell Bot look")
    }

    func testOutputHistoryBoundsPausesResumesAndSearchesUTF16Ranges() throws {
        var history = OutputHistory(limit: 2)
        let first = RenderedLine(text: "discard me")
        let second = RenderedLine(text: "Hello world")
        let third = RenderedLine(text: "🌍 hello again")
        history.append(first)
        history.append(second)
        XCTAssertEqual(history.append(third), 1)
        XCTAssertEqual(history.lines.map(\.id), [second.id, third.id])

        history.pause()
        let pending = RenderedLine(text: "HELLO pending")
        history.append(pending)
        XCTAssertEqual(history.lines.map(\.id), [second.id, third.id])
        XCTAssertEqual(history.pendingLines.map(\.id), [pending.id])
        XCTAssertEqual(try history.search("hello").map(\.lineID), [second.id, third.id])

        history.resume()
        XCTAssertEqual(history.lines.map(\.id), [third.id, pending.id])
        let matches = try history.search("hello", options: .init(wholeWord: true))
        XCTAssertEqual(matches.map(\.lineID), [third.id, pending.id])
        XCTAssertEqual(matches.first?.range, 3..<8) // globe occupies two UTF-16 code units
    }

    func testOutputHistorySupportsRegularExpressionsAndRejectsInvalidOnes() throws {
        var history = OutputHistory()
        let line = RenderedLine(text: "HP: 123/456")
        history.append(line)
        let matches = try history.search(#"\d+"#, options: .init(isRegularExpression: true))
        XCTAssertEqual(matches.map(\.range), [4..<7, 8..<11])
        XCTAssertThrowsError(try history.search("[", options: .init(isRegularExpression: true)))
    }

    func testOutputHistoryRetainsNewestLinesAcrossStorageCompaction() {
        var history = OutputHistory(limit: 10)
        for index in 0..<3_000 { history.append(.init(text: String(index))) }
        XCTAssertEqual(history.count, 10)
        XCTAssertEqual(history.lines.map(\.text), (2_990..<3_000).map(String.init))
    }

    func testInputHistoryRestoresDraftDeduplicatesAndBoundsEntries() {
        var history = InputHistory(limit: 2)
        history.record("look")
        history.record("look")
        history.record("north")
        history.record("say hi")
        XCTAssertEqual(history.entries, ["north", "say hi"])
        XCTAssertEqual(history.previous(currentText: "unfinished"), "say hi")
        XCTAssertEqual(history.previous(currentText: "ignored"), "north")
        XCTAssertEqual(history.previous(currentText: "ignored"), "north")
        XCTAssertEqual(history.next(), "say hi")
        XCTAssertEqual(history.next(), "unfinished")
        XCTAssertNil(history.next())
    }

    func testInputBehaviorAppliesPrefixAndStickyReplacement() {
        XCTAssertEqual(InputBehavior(prefix: "say ").submission(for: "hello").outbound, "say hello")
        XCTAssertEqual(InputBehavior(isSticky: true).submission(for: "look").replacement, "look")
        XCTAssertEqual(InputBehavior().submission(for: "look").replacement, "")
    }

    func testInputConversionsMatchLegacyPercentTokens() {
        XCTAssertEqual(InputConversion.returns.apply(to: "one\r\ntwo\nthree\rfour"), "one%Rtwo%Rthree%Rfour")
        XCTAssertEqual(InputConversion.tabs.apply(to: "one\ttwo"), "one%Ttwo")
        XCTAssertEqual(InputConversion.spaces.apply(to: "one  two"), "one%B%Btwo")
    }

    func testPlainSessionLogRendersHistoryTypedSentWrappingAndSpacing() {
        let date = Date(timeIntervalSince1970: 0)
        let renderer = SessionLogRenderer(
            format: .plainText,
            options: .init(
                logsSentText: true,
                sentPrefix: "Sent>",
                logsTypedText: true,
                typedPrefix: "Typed>",
                includesTime: true,
                uses24HourTime: true,
                wrapWidth: 24,
                hangingIndent: 2,
                doubleSpaces: true
            ),
            title: "Test"
        )
        let line = renderer.line(.init(text: "a line long enough to wrap at a word", timestamp: date))
        XCTAssertTrue(line.contains("a line long enough"))
        XCTAssertTrue(line.contains("\n  to wrap at a word"))
        XCTAssertTrue(line.hasSuffix("\n\n"))
        XCTAssertTrue(renderer.typed("look", at: date).contains("Typed>look"))
        XCTAssertTrue(renderer.sent("north", at: date).contains("Sent>north"))
    }

    func testHTMLSessionLogEscapesTextAndPreservesStylesAndLinks() {
        let line = RenderedLine(
            text: "<open>",
            runs: [.init(
                range: 0..<6,
                style: .init(
                    foreground: .init(red: 255, green: 0, blue: 128),
                    bold: true,
                    link: .url("https://example.com/?a=1&b=2")
                )
            )]
        )
        let renderer = SessionLogRenderer(format: .html, title: "A & B")
        let header = renderer.documentHeader()
        XCTAssertTrue(header.contains("A &amp; B"))
        XCTAssertTrue(header.contains("timestamp-toggle"))
        XCTAssertTrue(header.contains("unformat-toggle"))
        XCTAssertTrue(header.contains("show-timestamps"))
        XCTAssertTrue(header.contains("body.unformatted"))
        let html = renderer.line(line)
        XCTAssertTrue(html.contains("class=\"timestamp\""))
        XCTAssertTrue(html.contains("class=\"line-content\""))
        XCTAssertTrue(html.contains("&lt;open&gt;"))
        XCTAssertTrue(html.contains("color:#FF0080"))
        XCTAssertTrue(html.contains("font-weight:bold"))
        XCTAssertTrue(html.contains("a=1&amp;b=2"))
    }

    func testLogFilenameExpandsTokensAndMarksDailyFilesForRollover() {
        let date = Date(timeIntervalSince1970: 86_400)
        let resolution = SessionLogFilename.resolve(
            "Logs/%server%-%character%-%date%.html",
            date: date,
            dateFormat: "yyyy-MM-dd",
            serverName: "Lambda",
            characterName: "Ada",
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(resolution.filename, "Logs/Lambda-Ada-1970-01-02.html")
        XCTAssertTrue(resolution.rollsOverDaily)

        let appended = SessionLogFilename.resolve(
            "Logs/session.txt",
            date: date,
            appendingDate: true,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(appended.filename, "Logs/session - 1970-01-02.txt")
        XCTAssertTrue(appended.rollsOverDaily)
    }

    func testSessionLogOptionsDecodesPreAutologPreferences() throws {
        let data = Data("{\"logsSentText\":true,\"sentPrefix\":\"Sent:\"}".utf8)
        let options = try JSONDecoder().decode(SessionLogOptions.self, from: data)
        XCTAssertTrue(options.logsSentText)
        XCTAssertEqual(options.sentPrefix, "Sent:")
        XCTAssertFalse(options.autoLogEnabled)
        XCTAssertEqual(options.defaultLogFilename, "")
        XCTAssertEqual(options.fileDateFormat, "yyyy-MM-dd")
    }
}
