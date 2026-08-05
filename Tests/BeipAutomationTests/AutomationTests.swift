import BeipAutomation
import BeipCore
import Foundation
import XCTest

final class AutomationTests: XCTestCase {
    func testAliasCaptureAndVariables() throws {
        let alias = Alias(
            match: .init(text: "^say (.+)$", isRegularExpression: true),
            replacement: "pose says $1 to %target%",
            expandVariables: true
        )
        let result = try AliasEngine.process("say hello", groups: [.init(aliases: [alias])], variables: ["target": "Sam"])
        XCTAssertEqual(result.text, "pose says hello to Sam")
        XCTAssertEqual(result.matchedAliases, [alias.id])
    }

    func testAliasReplacesEveryOccurrenceWithoutDiscardingUnmatchedText() throws {
        let alias = Alias(
            match: .init(text: "cat"),
            replacement: "dog"
        )
        let result = try AliasEngine.process(
            "cat and cat",
            groups: [.init(aliases: [alias])],
            variables: [:]
        )
        XCTAssertEqual(result.text, "dog and dog")
        XCTAssertEqual(result.matchedAliases, [alias.id])
        XCTAssertEqual(result.trace.map(\.matchCount), [2])
        XCTAssertEqual(result.trace.first?.output, "dog and dog")
    }

    func testAliasUsesWindowsReplacementCursorAndSkipsEmptyPlaceholders() throws {
        let expanding = Alias(match: .init(text: "a"), replacement: "aa")
        let empty = Alias(match: .init(text: ""), replacement: "unexpected")
        let result = try AliasEngine.process(
            "aaa",
            groups: [.init(aliases: [expanding, empty])],
            variables: [:]
        )
        XCTAssertEqual(result.text, "aaaaaa")
        XCTAssertEqual(result.matchedAliases, [expanding.id])
        XCTAssertEqual(result.trace.last?.matchCount, 0)
    }

    func testAliasInvalidRegexDoesNotPreventLaterAliases() throws {
        let invalid = Alias(description: "Bad", match: .init(text: "(", isRegularExpression: true), replacement: "bad")
        let valid = Alias(description: "Good", match: .init(text: "ok"), replacement: "done")
        let result = try AliasEngine.process("ok", groups: [.init(aliases: [invalid, valid])], variables: [:])
        XCTAssertEqual(result.text, "done")
        XCTAssertEqual(result.diagnostics.map(\.description), ["Bad"])
        XCTAssertTrue(result.trace.first?.reason?.contains("Invalid regular expression") == true)
    }

    func testAliasSpecificProcessingEchoAndCommandFlags() throws {
        let inactive = Alias(
            description: "Inactive",
            match: .init(text: "one"),
            replacement: "wrong",
            active: false
        )
        let command = Alias(
            description: "Command",
            match: .init(text: "two"),
            replacement: "/look",
            echo: false,
            processCommands: true
        )
        let result = try AliasEngine.process(
            "one two",
            groups: [.init(echo: true, processCommands: false, aliases: [inactive, command])],
            variables: [:]
        )

        XCTAssertEqual(result.text, "one /look")
        XCTAssertEqual(result.matchedAliases, [command.id])
        XCTAssertFalse(result.echo)
        XCTAssertTrue(result.processCommands)
        XCTAssertTrue(result.trace.contains { $0.reason == "Skipped: alias inactive" })
    }

    func testAliasUsesWindowsCaptureFormsAndFolderChildOrder() throws {
        let first = Alias(match: .init(text: "a"), replacement: "A")
        let post = Alias(match: .init(text: "A"), replacement: "B")
        let folder = Alias(
            match: .init(text: ""),
            replacement: "",
            folder: true,
            children: [first, post],
            childrenAfterCount: 1
        )
        let ordered = try AliasEngine.process("a", groups: [.init(aliases: [folder])], variables: [:])
        XCTAssertEqual(ordered.text, "B")

        let regex = Alias(
            match: .init(text: "(hp) (\\d+)", isRegularExpression: true),
            replacement: "\\0|\\1|\\a02|%who%",
            expandVariables: true
        )
        let result = try AliasEngine.process("hp 42", groups: [.init(aliases: [regex])], variables: ["who": "Ada"])
        XCTAssertEqual(result.text, "hp 42|hp|42|Ada")
    }

    func testAliasStopRunsAfterChildren() throws {
        let child = Alias(match: .init(text: "north"), replacement: "N")
        let parent = Alias(
            match: .init(text: "go"),
            replacement: "north",
            stopProcessing: true,
            children: [child]
        )
        let later = Alias(match: .init(text: "N"), replacement: "done")
        let stopped = try AliasEngine.process("go", groups: [.init(aliases: [parent, later])], variables: [:])
        XCTAssertEqual(stopped.text, "N")
        XCTAssertTrue(stopped.stopped)
    }

    func testKeyboardMacrosUseWindowsScopePrecedenceAndNestedFolders() {
        let global = KeyboardMacroGroup(macros: [
            .init(macro: "global", key: "Control+Alt+N"),
        ])
        let server = KeyboardMacroGroup(macros: [
            .init(macro: "server", key: "Control+Alt+N"),
        ])
        let character = KeyboardMacroGroup(macros: [
            .init(macro: "", key: "", folder: true, children: [
                .init(macro: "character", key: "Control+Alt+N", typeIntoInput: true),
            ]),
        ])

        let match = KeyboardMacroEngine.macro(for: "Control+Alt+N", groups: [character, server, global])
        XCTAssertEqual(match?.macro, "character")
        XCTAssertTrue(match?.typeIntoInput == true)
        XCTAssertNil(KeyboardMacroEngine.macro(for: "Control+N", groups: [character, server, global]))
    }

    func testAliasHierarchyRunsFoldersAlwaysAndChildrenOnlyAfterParentMatch() throws {
        let nested = Alias(match: .init(text: "north"), replacement: "N")
        let folder = Alias(
            match: .init(text: ""),
            replacement: "",
            folder: true,
            children: [nested]
        )
        let gated = Alias(
            match: .init(text: "go"),
            replacement: "north",
            children: [nested]
        )

        let folderResult = try AliasEngine.process(
            "north",
            groups: [.init(aliases: [folder])],
            variables: [:]
        )
        XCTAssertEqual(folderResult.text, "N")

        let noMatchResult = try AliasEngine.process(
            "north",
            groups: [.init(aliases: [gated])],
            variables: [:]
        )
        XCTAssertEqual(noMatchResult.text, "north")

        let matchResult = try AliasEngine.process(
            "go",
            groups: [.init(aliases: [gated])],
            variables: [:]
        )
        XCTAssertEqual(matchResult.text, "N")
    }

    func testTriggerCooldown() async throws {
        let trigger = Trigger(match: .init(text: "alert"), cooldown: 5, actions: [.activity(important: true)])
        let engine = TriggerEngine()
        let now = Date()
        let first = try await engine.process(.init(text: "alert"), triggers: [trigger], variables: [:], now: now)
        let second = try await engine.process(.init(text: "alert"), triggers: [trigger], variables: [:], now: now.addingTimeInterval(1))
        XCTAssertEqual(first, [.activity(important: true)])
        XCTAssertTrue(second.isEmpty)
    }

    func testTriggerTraceRecordsMatchDecisions() async throws {
        let miss = Trigger(description: "Miss", match: .init(text: "quiet"))
        let hit = Trigger(description: "Hit", match: .init(text: "alert"), actions: [.activity(important: true)])
        let engine = TriggerEngine()

        _ = try await engine.process(.init(text: "alert"), triggers: [miss, hit], variables: [:])
        let trace = await engine.lastTrace()

        XCTAssertEqual(trace.map(\.description), ["Miss", "Hit"])
        XCTAssertEqual(trace.map(\.matchCount), [0, 1])
    }

    func testInvalidImportedRegexIsSkippedWithTraceDiagnostic() async throws {
        let invalid = Trigger(
            description: "Imported Bad Regex",
            match: .init(text: "(", isRegularExpression: true),
            actions: [.send("bad", captureIndex: 1, expandVariables: false)]
        )
        let valid = Trigger(
            description: "Still Runs",
            match: .init(text: "alert"),
            actions: [.send("ok", captureIndex: 1, expandVariables: false)]
        )
        let engine = TriggerEngine()

        let effects = try await engine.process(.init(text: "alert"), triggers: [invalid, valid], variables: [:])
        let trace = await engine.lastTrace()

        XCTAssertEqual(effects, [.send("ok")])
        XCTAssertEqual(trace.map(\.description), ["Imported Bad Regex", "Still Runs"])
        XCTAssertEqual(trace.map(\.matchCount), [0, 1])
        XCTAssertTrue(trace.first?.output.contains("Invalid regular expression") == true)
    }

    func testTriggerTraceExposesPhase6SkipReasons() async throws {
        let cooldown = Trigger(
            description: "Cooldown",
            match: .init(text: "alert"),
            cooldown: 30,
            actions: [.activity(important: true)]
        )
        let away = Trigger(
            description: "Away Only",
            match: .init(text: "alert"),
            awayPresent: true,
            away: true,
            actions: [.activity(important: true)]
        )
        let stopper = Trigger(
            description: "Stopper",
            match: .init(text: "stop"),
            stopProcessing: true,
            actions: [.send("halt", captureIndex: 0, expandVariables: false)]
        )
        let afterStop = Trigger(
            description: "After Stop",
            match: .init(text: "stop"),
            actions: [.send("missed", captureIndex: 0, expandVariables: false)]
        )
        let engine = TriggerEngine()
        let now = Date()

        _ = try await engine.process(
            .init(text: "alert"),
            groups: [
                .init(active: false, triggers: [cooldown]),
                .init(triggers: [cooldown, away]),
            ],
            variables: [:],
            now: now,
            isAway: false
        )
        let disabledGroup = await engine.lastTrace()
        XCTAssertTrue(disabledGroup.contains { $0.reason == "Skipped: disabled group" })

        _ = try await engine.process(
            .init(text: "alert"),
            groups: [.init(triggers: [cooldown, away])],
            variables: [:],
            now: now.addingTimeInterval(1),
            isAway: false
        )
        let skipped = await engine.lastTrace()

        XCTAssertTrue(skipped.contains { $0.reason == "Skipped: cooldown active" })
        XCTAssertTrue(skipped.contains { $0.reason == "Skipped: Away condition not met" })

        _ = try await engine.process(
            .init(text: "stop"),
            triggers: [stopper, afterStop],
            variables: [:],
            now: now.addingTimeInterval(40)
        )
        let stopped = await engine.lastTrace()
        XCTAssertTrue(stopped.contains { $0.reason == "Stop Processing: remaining triggers skipped" })
    }

    func testAwayPresentTriggersFollowWindowActivityAndOncePerAwayState() async throws {
        let away = Trigger(
            match: .init(text: "alert"),
            awayPresent: true,
            awayPresentOnce: true,
            away: true,
            actions: [.activity(important: true)]
        )
        let present = Trigger(
            match: .init(text: "alert"),
            awayPresent: true,
            away: false,
            actions: [.send("present", captureIndex: 1, expandVariables: false)]
        )
        let engine = TriggerEngine()

        let firstAway = try await engine.process(.init(text: "alert"), triggers: [away, present], variables: [:], isAway: true)
        let secondAway = try await engine.process(.init(text: "alert"), triggers: [away, present], variables: [:], isAway: true)
        let active = try await engine.process(.init(text: "alert"), triggers: [away, present], variables: [:], isAway: false)
        let awayAgain = try await engine.process(.init(text: "alert"), triggers: [away, present], variables: [:], isAway: true)

        XCTAssertEqual(firstAway, [.activity(important: true)])
        XCTAssertTrue(secondAway.isEmpty)
        XCTAssertEqual(active, [.send("present")])
        XCTAssertEqual(awayAgain, [.activity(important: true)])
    }

    func testTriggerGroupsHonorActiveStateAndSendExpandsConfiguredTemplate() async throws {
        let skipped = Trigger(match: .init(text: "alert"), actions: [.send("skip", captureIndex: 1, expandVariables: false)])
        let active = Trigger(
            match: .init(text: "([A-Z]+)", isRegularExpression: true),
            actions: [.send("say $1 to %target%", captureIndex: 1, expandVariables: true)]
        )
        let engine = TriggerEngine()
        let effects = try await engine.process(
            .init(text: "HELLO"),
            groups: [
                .init(active: false, triggers: [skipped]),
                .init(active: true, triggers: [active]),
            ],
            variables: ["target": "Ada"]
        )
        XCTAssertEqual(effects, [.send("say HELLO to Ada")])
    }

    func testTriggerVisualActionsTargetRegexCaptureGroupsAndSendOnClickRange() async throws {
        let patch = TextStylePatch(bold: true)
        let trigger = Trigger(
            match: .init(text: "(HP): (\\d+)", isRegularExpression: true),
            actions: [
                .color(foreground: .white, background: nil, wholeLine: false),
                .appearance(patch, wholeLine: false),
                .send("score $2", captureIndex: 2, expandVariables: true, sendOnClick: true),
            ]
        )

        let effects = try await TriggerEngine().process(
            .init(text: "HP: 42"),
            triggers: [trigger],
            variables: [:]
        )

        XCTAssertEqual(effects, [
            .style(range: NSRange(location: 0, length: 2), foreground: .white, background: nil),
            .style(range: NSRange(location: 4, length: 2), foreground: .white, background: nil),
            .appearance(range: NSRange(location: 0, length: 2), patch: patch),
            .appearance(range: NSRange(location: 4, length: 2), patch: patch),
            .link(range: NSRange(location: 4, length: 2), send: "score 42"),
        ])
    }

    func testCaptureExpansionSupportsGroup99() throws {
        let pattern = String(repeating: "(a)", count: 99)
        let input = String(repeating: "a", count: 99)
        let capture = try XCTUnwrap(MatchDefinition(text: pattern, isRegularExpression: true).matches(in: input).first)

        XCTAssertEqual(capture.values.count, 100)
        XCTAssertEqual(Expansion.apply("$99", capture: capture, variables: [:]), "a")
    }

    func testCaptureExpansionSupportsWindowsBackslashFormsAndEscapedSlash() throws {
        let capture = try XCTUnwrap(MatchDefinition(text: "(hp) (<tag&>)", isRegularExpression: true).matches(in: "hp <tag&>").first)

        XCTAssertEqual(
            Expansion.apply("\\0|\\1|\\a02|\\\\|\\9", capture: capture, variables: [:]),
            "hp <tag&>|hp|<tag&>|\\|\\9"
        )
    }

    func testHTMLCaptureExpansionEscapesSubstitutions() throws {
        let capture = try XCTUnwrap(MatchDefinition(text: "(<tag&>)", isRegularExpression: true).matches(in: "<tag&>").first)

        XCTAssertEqual(
            Expansion.apply("<b>\\1</b>", capture: capture, variables: [:], escapeHTML: true),
            "<b>&lt;tag&amp;></b>"
        )
    }

    func testEmptyLiteralMatchProducesSingleStartCapture() throws {
        let captures = try MatchDefinition(text: "").matches(in: "abc")

        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.range, NSRange(location: 0, length: 0))
        XCTAssertEqual(captures.first?.values, [""])
    }

    func testLiteralWholeWordUsesWindowsLetterBoundaries() throws {
        let captures = try MatchDefinition(text: "cat", wholeWord: true).matches(in: "cat9 bobcat cat")

        XCTAssertEqual(captures.map(\.range), [
            NSRange(location: 0, length: 3),
            NSRange(location: 12, length: 3),
        ])
    }

    func testLiteralStartsWithAndEndsWithCombinationRequiresWholeLine() throws {
        let exact = MatchDefinition(text: "cat", startsWith: true, endsWith: true)
        let prefix = MatchDefinition(text: "cat", startsWith: true)
        let suffix = MatchDefinition(text: "cat", endsWith: true)

        XCTAssertEqual(try exact.matches(in: "cat").count, 1)
        XCTAssertEqual(try exact.matches(in: "cat nap").count, 0)
        XCTAssertEqual(try prefix.matches(in: "cat nap").first?.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(try suffix.matches(in: "bobcat").first?.range, NSRange(location: 3, length: 3))
    }

    func testZeroLengthRegexStopsAfterFirstEmptyCapture() throws {
        let captures = try MatchDefinition(text: "(?=a)", isRegularExpression: true).matches(in: "aaa")

        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.range, NSRange(location: 0, length: 0))
    }

    func testFilterHTMLCaptureExpansionEscapesCaptureSubstitutions() async throws {
        let trigger = Trigger(
            match: .init(text: "(<tag&>)", isRegularExpression: true),
            actions: [.replaceHTML("<b>\\1</b>", expandVariables: false)]
        )

        let effects = try await TriggerEngine().process(.init(text: "<tag&>"), triggers: [trigger], variables: [:])

        XCTAssertEqual(effects, [.replaceHTML(range: NSRange(location: 0, length: 6), with: "<b>&lt;tag&amp;></b>")])
    }

    func testTriggerHashDefaultFontAndParagraphOptionsProduceExecutableEffects() async throws {
        let paragraph = ParagraphPatch(
            backgroundHash: true,
            borderWidth: 3,
            borderStyle: .round,
            strokeWidth: 2,
            strokeHash: true,
            strokeStyle: .bottom,
            horizontalRule: true
        )
        let trigger = Trigger(
            match: .init(text: "(Hero)", isRegularExpression: true),
            actions: [
                .colorHash(foreground: true, background: true, wholeLine: false),
                .colorDefault(foreground: true, background: true, wholeLine: false),
                .font(face: "Menlo", size: 16, useDefault: false, wholeLine: false),
                .paragraph(paragraph),
            ]
        )

        let effects = try await TriggerEngine().process(.init(text: "Hero"), triggers: [trigger], variables: [:])

        guard case let .style(range, foreground, background) = effects[0] else { return XCTFail("missing hash colors") }
        XCTAssertEqual(range, NSRange(location: 0, length: 4))
        XCTAssertNotNil(foreground)
        XCTAssertNotNil(background)
        XCTAssertEqual(effects[1], .resetColors(range: range, foreground: true, background: true))
        XCTAssertEqual(effects[2], .font(range: range, face: "Menlo", size: 16))
        guard case let .paragraph(expanded) = effects[3] else { return XCTFail("missing paragraph") }
        XCTAssertNotNil(expanded.background)
        XCTAssertNotNil(expanded.strokeColor)
        XCTAssertEqual(expanded.borderStyle, .round)
        XCTAssertEqual(expanded.strokeStyle, .bottom)
        XCTAssertEqual(expanded.horizontalRule, true)
    }

    func testTriggerStopProcessingPreventsLaterGroups() async throws {
        let stop = Trigger(
            match: .init(text: "alert"),
            stopProcessing: true,
            actions: [.send("first", captureIndex: 1, expandVariables: false)]
        )
        let later = Trigger(
            match: .init(text: "alert"),
            actions: [.send("second", captureIndex: 1, expandVariables: false)]
        )
        let effects = try await TriggerEngine().process(
            .init(text: "alert"),
            groups: [.init(triggers: [stop]), .init(triggers: [later])],
            variables: [:]
        )
        XCTAssertEqual(effects, [.send("first")])
    }

    func testTriggerStopProcessingRunsChildrenBeforeStoppingLaterTriggers() async throws {
        let child = Trigger(
            match: .init(text: "alert"),
            actions: [.send("child", captureIndex: 1, expandVariables: false)]
        )
        let stop = Trigger(
            match: .init(text: "alert"),
            stopProcessing: true,
            actions: [.send("parent", captureIndex: 1, expandVariables: false)],
            children: [child]
        )
        let later = Trigger(
            match: .init(text: "alert"),
            actions: [.send("later", captureIndex: 1, expandVariables: false)]
        )

        let effects = try await TriggerEngine().process(
            .init(text: "alert"),
            triggers: [stop, later],
            variables: [:]
        )

        XCTAssertEqual(effects, [.send("parent"), .send("child")])
    }

    func testDisabledTriggerActsAsContainerAndInactiveChildrenStayDisabled() async throws {
        let child = Trigger(match: .init(text: "alert"), actions: [.send("child", captureIndex: 1, expandVariables: false)])
        let enabledContainer = Trigger(match: .init(text: "never"), disabled: true, children: [child])
        let inactiveContainer = Trigger(match: .init(text: "never"), disabled: true, children: [child], childrenActive: false)

        let enabled = try await TriggerEngine().process(.init(text: "alert"), triggers: [enabledContainer], variables: [:])
        let inactive = try await TriggerEngine().process(.init(text: "alert"), triggers: [inactiveContainer], variables: [:])

        XCTAssertEqual(enabled, [.send("child")])
        XCTAssertTrue(inactive.isEmpty)
    }

    func testTriggerFolderProcessesChildrenWithoutMatchingItself() async throws {
        let child = Trigger(match: .init(text: "alert"), actions: [.send("child", captureIndex: 1, expandVariables: false)])
        let folder = Trigger(
            description: "Folder",
            match: .init(text: "never"),
            folder: true,
            actions: [.send("parent", captureIndex: 1, expandVariables: false)],
            children: [child]
        )
        let inactiveFolder = Trigger(
            description: "Inactive Folder",
            match: .init(text: "never"),
            folder: true,
            children: [child],
            childrenActive: false
        )

        let effects = try await TriggerEngine().process(.init(text: "alert"), triggers: [folder], variables: [:])
        let inactiveEffects = try await TriggerEngine().process(.init(text: "alert"), triggers: [inactiveFolder], variables: [:])

        XCTAssertEqual(effects, [.send("child")])
        XCTAssertTrue(inactiveEffects.isEmpty)
    }

    func testTriggerDecodesMissingFolderFlagAsFalse() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "description": "Legacy",
          "match": {
            "text": "legacy",
            "isRegularExpression": false,
            "matchCase": false,
            "startsWith": false,
            "endsWith": false,
            "wholeWord": false
          },
          "disabled": false,
          "stopProcessing": false,
          "oncePerLine": false,
          "awayPresent": false,
          "awayPresentOnce": false,
          "away": true,
          "actions": [],
          "children": [],
          "childrenActive": true
        }
        """

        let trigger = try JSONDecoder().decode(Trigger.self, from: Data(json.utf8))

        XCTAssertFalse(trigger.folder)
    }

    func testFilterMutatesTextSeenByLaterTriggersAndScriptCallbackLine() async throws {
        let filter = Trigger(match: .init(text: "old"), actions: [.replace("new", expandVariables: false)])
        let later = Trigger(match: .init(text: "new"), actions: [.script("afterFilter")])

        let effects = try await TriggerEngine().process(
            .init(text: "old value"),
            triggers: [filter, later],
            variables: [:]
        )

        XCTAssertEqual(effects.first, .replace(range: NSRange(location: 0, length: 3), with: "new"))
        guard case let .script(function, _, line) = effects.last else { return XCTFail("later trigger did not see filtered text") }
        XCTAssertEqual(function, "afterFilter")
        XCTAssertEqual(line.text, "new value")
    }

    func testTriggerAppearanceParagraphAndAvatarEffectsExpandCaptures() async throws {
        let patch = TextStylePatch(bold: true, underline: true)
        let paragraph = ParagraphPatch(alignment: .center, leftIndent: 12)
        let trigger = Trigger(
            match: .init(text: "(Hero)", isRegularExpression: true),
            actions: [
                .appearance(patch, wholeLine: false),
                .paragraph(paragraph),
                .avatar("https://example.test/$1.png"),
            ]
        )
        let effects = try await TriggerEngine().process(
            .init(text: "Hero"),
            triggers: [trigger],
            variables: [:]
        )
        XCTAssertEqual(effects, [
            .appearance(range: NSRange(location: 0, length: 4), patch: patch),
            .paragraph(paragraph),
            .avatar("https://example.test/Hero.png"),
        ])
    }

    func testMultilineTriggerArmsChildrenForTheConfiguredNumberOfFollowingLines() async throws {
        let child = Trigger(match: .init(text: "next"), actions: [.send("captured", captureIndex: 1, expandVariables: false)])
        let parent = Trigger(
            match: .init(text: "begin"),
            multiline: .init(lineLimit: 1),
            children: [child]
        )
        let engine = TriggerEngine()
        let now = Date()

        let activation = try await engine.process(.init(text: "begin next"), triggers: [parent], variables: [:], now: now)
        let captured = try await engine.process(.init(text: "next"), triggers: [parent], variables: [:], now: now.addingTimeInterval(1))
        let expired = try await engine.process(.init(text: "next"), triggers: [parent], variables: [:], now: now.addingTimeInterval(2))

        XCTAssertTrue(activation.isEmpty, "Multiline children start with the following line, not the activating line.")
        XCTAssertEqual(captured, [.send("captured")])
        XCTAssertTrue(expired.isEmpty)
    }

    func testMultilineTriggerExpiresAtItsConfiguredTimeLimit() async throws {
        let child = Trigger(match: .init(text: "next"), actions: [.activity(important: false)])
        let parent = Trigger(
            match: .init(text: "begin"),
            multiline: .init(timeLimit: 2),
            children: [child]
        )
        let engine = TriggerEngine()
        let now = Date()

        _ = try await engine.process(.init(text: "begin"), triggers: [parent], variables: [:], now: now)
        let expired = try await engine.process(.init(text: "next"), triggers: [parent], variables: [:], now: now.addingTimeInterval(3))

        XCTAssertTrue(expired.isEmpty)
    }

    func testMultilineTriggerCanRemainArmedAfterProcessingReturns() async throws {
        let child = Trigger(match: .init(text: "next"), actions: [.activity(important: false)])
        let parent = Trigger(
            match: .init(text: "begin"),
            multiline: .init(lineLimit: 2),
            children: [child]
        )

        let effects = try await TriggerEngine().process(.init(text: "begin"), triggers: [parent], variables: [:])

        XCTAssertTrue(effects.isEmpty)
    }

    func testScopedTriggerProcessingDoesNotRunPreviouslyArmedMultilineTrees() async throws {
        let unrelatedChild = Trigger(match: .init(text: "line"), actions: [.send("unrelated", captureIndex: 1, expandVariables: false)])
        let unrelatedParent = Trigger(
            match: .init(text: "begin"),
            multiline: .init(lineLimit: 2),
            children: [unrelatedChild]
        )
        let spawnChild = Trigger(match: .init(text: "line"), actions: [.send("spawn", captureIndex: 1, expandVariables: false)])
        let engine = TriggerEngine()
        let now = Date()

        _ = try await engine.process(.init(text: "begin"), triggers: [unrelatedParent], variables: [:], now: now)
        let effects = try await engine.processOnly(.init(text: "line"), triggers: [spawnChild], variables: [:], now: now.addingTimeInterval(1))

        XCTAssertEqual(effects, [.send("spawn")])
    }

    func testTriggerStatsExpandCapturesAndPreserveWindowsIntegerAddSemantics() async throws {
        let stat = TriggerStatAction(
            title: "Vitals",
            name: "HP",
            prefix: "01",
            value: "$1",
            kind: .integer,
            addsToExistingInteger: true,
            color: .init(red: 255, green: 0, blue: 0)
        )
        let trigger = Trigger(
            match: .init(text: "HP ([0-9]+)", isRegularExpression: true),
            actions: [.stat(stat)]
        )
        let engine = TriggerEngine()
        var store = TriggerStatisticStore()

        let first = try await engine.process(.init(text: "HP 40"), triggers: [trigger], variables: [:])
        let second = try await engine.process(.init(text: "HP 2"), triggers: [trigger], variables: [:])
        for effect in first + second {
            if case let .stat(update) = effect { store.apply(update) }
        }

        XCTAssertEqual(store.ordered, [
            .init(
                name: "HP",
                prefix: "01",
                value: .integer(42),
                color: .init(red: 255, green: 0, blue: 0)
            )
        ])
    }

    func testSpawnTriggerExpandsCaptureAndPreservesCaptureOptions() async throws {
        let action = TriggerSpawnAction(
            title: "Combat $1",
            tabGroup: "Group %zone% $1",
            captureUntil: "^END $1$",
            clear: true,
            gagLog: true,
            copy: false
        )
        let child = Trigger(match: .init(text: "child"), actions: [.activity(important: true)])
        let trigger = Trigger(
            match: .init(text: "BEGIN ([A-Z]+)", isRegularExpression: true),
            actions: [.spawn(action)],
            children: [child]
        )

        let effects = try await TriggerEngine().process(.init(text: "BEGIN ROOM"), triggers: [trigger], variables: ["zone": "Alpha"])

        guard effects.count == 1, case let .spawn(expanded, line, children) = effects[0] else {
            return XCTFail("missing spawn effect")
        }
        XCTAssertEqual(
            expanded,
            .init(
                title: "Combat ROOM",
                tabGroup: "Group Alpha $1",
                captureUntil: "^END ROOM$",
                clear: true,
                gagLog: true
            )
        )
        XCTAssertEqual(line.text, "BEGIN ROOM")
        XCTAssertEqual(children, [child])
    }

    func testCommandQuotingAndVariables() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/set target=Jane Doe", variables: [:]), .setVariable("target", "Jane Doe"))
        XCTAssertEqual(registry.parse("//look", variables: [:]), .send("/look"))
    }

    func testCommandOutcomes() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/ai explain this", variables: [:]), .ai("explain this"))
        XCTAssertEqual(registry.parse("/ai", variables: [:]), .ai(nil))
        XCTAssertEqual(registry.parse("/gag danger", variables: [:]), .gag("danger"))
        XCTAssertEqual(registry.parse("/grab #1/description", variables: [:]), .grab(object: "#1", property: "description"))
        XCTAssertEqual(registry.parse("/recall 12 warning", variables: [:]), .recall(lineCount: 12, search: "warning"))
        XCTAssertEqual(registry.parse("/rolltest", variables: [:]), .rollTest)
        XCTAssertEqual(registry.parse("/test utf8", variables: [:]), .compatibilityTest("utf8"))
        XCTAssertEqual(
            registry.parse("/test", variables: [:]),
            .display("What do you want to test? (ansi/html/emoji/international/utf8)")
        )
    }

    func testDiceFairnessIsDeterministicAndReportsEverySide() {
        let first = DiceFairnessReport.run(rollCount: 10_000, seed: 42)
        XCTAssertEqual(first, DiceFairnessReport.run(rollCount: 10_000, seed: 42))
        XCTAssertEqual(first.counts.reduce(0, +), first.rollCount)
        XCTAssertEqual(first.counts.count, 6)
        XCTAssertTrue(first.displayText.contains("Side 6 odds:"))
    }

    func testCommandCompatibilityFormsPreservePayloads() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/gmcp dump_on", variables: [:]), .gmcpDump(true))
        XCTAssertEqual(registry.parse("/tilemap on", variables: [:]), .tileMap(true))
        XCTAssertEqual(registry.parse("/tilemap OFF", variables: [:]), .tileMap(false))
        XCTAssertEqual(
            registry.parse("/tilemap maybe", variables: [:]),
            .display("Usage: '/tilemap on/off' to enable/disable tilemap tag parsing")
        )
        XCTAssertEqual(
            registry.parse(#"/switchtab "Chat Channels" Public"#, variables: [:]),
            .switchSpawnTab(group: "Chat Channels", title: "Public")
        )
        XCTAssertEqual(
            registry.parse("/switchtab only-one", variables: [:]),
            .display("Expected 'tab group' and 'tab name' as parameters")
        )
        XCTAssertEqual(
            registry.parse(#"/map_addroom "Crossroads Hotelry" east west"#, variables: [:]),
            .mapAddRoom(name: "Crossroads Hotelry", outward: "east", returnCommand: "west")
        )
        XCTAssertEqual(
            registry.parse("/map_addexit north south", variables: [:]),
            .mapAddExit(outward: "north", returnCommand: "south")
        )
        XCTAssertEqual(registry.parse("/map_guesslocation", variables: [:]), .mapGuessLocation)
        XCTAssertEqual(registry.parse("/map_look", variables: [:]), .mapLook)
        XCTAssertEqual(
            registry.parse(#"/webview url="https://example.com/page" position="10,20,640,480" state="maximized""#, variables: [:]),
            .webView(.init(
                url: URL(string: "https://example.com/page"),
                frame: .init(x: 10, y: 20, width: 640, height: 480),
                maximized: true
            ))
        )
        XCTAssertEqual(
            registry.parse(#"/webview source="&lt;h1&gt;Hello&lt;/h1&gt;""#, variables: [:]),
            .webView(.init(source: "<h1>Hello</h1>"))
        )
        XCTAssertEqual(
            registry.parse(#"/webview position="bad""#, variables: [:]),
            .display("Command error: Invalid rect")
        )
        XCTAssertEqual(registry.parse("/mcmp flush", variables: [:]), .mediaControl(.flush))
        XCTAssertEqual(registry.parse("/mcmp INFO", variables: [:]), .mediaControl(.info))
        XCTAssertEqual(
            registry.parse("/mcmp", variables: [:]),
            .display("MCMP No parameter specified, available options are flush and info")
        )
        XCTAssertEqual(
            registry.parse("/map_addroom missing", variables: [:]),
            .display("Command is in the form of <room name> <exit to get there> <exit to get back>")
        )
        XCTAssertEqual(
            registry.parse(#"/@ app.OutputDebugText("hello world")"#, variables: [:]),
            .script(#"app.OutputDebugText("hello world")"#)
        )
        XCTAssertEqual(registry.parse("/?", variables: [:]), registry.parse("/help", variables: [:]))
        XCTAssertEqual(registry.parse("/silent/set answer=42", variables: [:]), .setVariable("answer", "42"))
        XCTAssertEqual(registry.parse("/help delay", variables: [:]), .openCommandHelp("delay"))
        XCTAssertEqual(registry.parse("/capturecancel", variables: [:]), .cancelCapture)
        XCTAssertEqual(registry.parse("/debugaliases", variables: [:]), .debugAutomation(.aliases))
        XCTAssertEqual(registry.parse("/debugtriggers", variables: [:]), .debugAutomation(.triggers))
        XCTAssertEqual(registry.parse("/debugtimers", variables: [:]), .debugAutomation(.timers))
        XCTAssertEqual(registry.parse("/debugnetwork", variables: [:]), .debugNetwork)
        XCTAssertEqual(registry.parse("/restoreinfo", variables: [:]), .restoreInfo)
        guard case let .display(help) = registry.parse("/help", variables: [:]) else {
            return XCTFail("missing command help")
        }
        XCTAssertTrue(help.contains("/@ $ - Run an immediate script"))
        XCTAssertTrue(help.contains("/wall $ - Send text to all connected windows"))
        XCTAssertTrue(CommandRegistry.knownCommands.contains("lizards"))
    }

    func testLocalEchoAndANSIResetCommands() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/echo", variables: [:]), .localEcho(true))
        XCTAssertEqual(registry.parse("/echo ON", variables: [:]), .localEcho(true))
        XCTAssertEqual(registry.parse("/echo off", variables: [:]), .localEcho(false))
        XCTAssertEqual(
            registry.parse("/echo maybe", variables: [:]),
            .display("Usage: '/echo <ON/off>' Without on/off default is ON.")
        )
        XCTAssertEqual(registry.parse("/ansireset", variables: [:]), .resetANSI)
    }

    func testNAWSAndTerminalTypeCommands() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/naws auto", variables: [:]), .nawsAuto)
        XCTAssertEqual(registry.parse("/naws 132 43", variables: [:]), .naws(132, 43))
        XCTAssertEqual(
            registry.parse("/naws 0 43", variables: [:]),
            .display("Invalid usage, try '/help naws' to see help for this command")
        )
        XCTAssertEqual(registry.parse("/ttype", variables: [:]), .terminalType(nil))
        XCTAssertEqual(registry.parse("/ttype \"Beip Mac\"", variables: [:]), .terminalType("Beip Mac"))
    }

    func testExecutableConnectionAndInjectionCommands() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/connect example.org:8888", variables: [:]), .connect(address: "example.org:8888", character: nil))
        XCTAssertEqual(registry.parse("/connect World Character", variables: [:]), .connect(address: "World", character: "Character"))
        XCTAssertEqual(registry.parse("/disconnect all", variables: [:]), .disconnect(all: true))
        XCTAssertEqual(registry.parse("/reconnect", variables: [:]), .reconnect(all: false))
        XCTAssertEqual(registry.parse("/repeat 3 \"say hello\"", variables: [:]), .repeatCommand(count: 3, command: "say hello"))
        XCTAssertEqual(registry.parse("/receive ANSI text", variables: [:]), .receive("ANSI text"))
        XCTAssertEqual(
            registry.parse(#"/receivegmcp Char.Vitals {"hp":10}"#, variables: [:]),
            .receiveGMCP(.init(package: "Char.Vitals", payload: #"{"hp":10}"#))
        )
        XCTAssertEqual(registry.parse("/ping", variables: [:]), .ping(""))
        XCTAssertEqual(registry.parse("/idle 2 \"look\"", variables: [:]), .idle(minutes: 2, command: "look"))
        XCTAssertEqual(registry.parse("/idle", variables: [:]), .idle(minutes: nil, command: nil))
    }

    func testWindowProfileAndLoggingCommandsHaveTypedOutcomes() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/close", variables: [:]), .close)
        XCTAssertEqual(registry.parse("/new", variables: [:]), .newWindow)
        XCTAssertEqual(registry.parse("/newtab", variables: [:]), .newTab)
        XCTAssertEqual(registry.parse("/stats", variables: [:]), .statistics)
        XCTAssertEqual(registry.parse("/connectioninfo", variables: [:]), .connectionInfo)
        XCTAssertEqual(registry.parse("/opendialog settings ansi", variables: [:]), .openDialog("settings", parameter: "ansi"))
        XCTAssertEqual(registry.parse("/log file.txt", variables: [:]), .startLog(filename: "file.txt", history: .none))
        XCTAssertEqual(registry.parse("/logall all.html", variables: [:]), .startLog(filename: "all.html", history: .all))
        XCTAssertEqual(registry.parse("/stoplogs", variables: [:]), .stopLogs)
        XCTAssertEqual(registry.parse("/autolog", variables: [:]), .startAutoLog)
    }

    func testSecondaryInputAndEditWindowCommandsHaveTypedOutcomes() {
        let registry = CommandRegistry()
        XCTAssertEqual(
            registry.parse(#"/newinput /unique "say ""#, variables: [:]),
            .newInput(prefix: "say ", unique: true)
        )
        XCTAssertEqual(
            registry.parse("/newinput /unsupported", variables: [:]),
            .display("Unknown option: /unsupported")
        )
        XCTAssertEqual(
            registry.parse("/newinput say /unique", variables: [:]),
            .newInput(prefix: "", unique: true)
        )
        XCTAssertEqual(
            registry.parse(#"/newedit title='Description' capture='5' capture_skip='2' spellcheck='f' prepend='@desc me=&#10;' append='&#10;.'"#, variables: [:]),
            .newEdit(.init(
                title: "Description",
                captureLineCount: 5,
                captureSkipCount: 2,
                checksSpelling: false,
                prepend: "@desc me=\n",
                append: "\n."
            ))
        )
        XCTAssertEqual(
            registry.parse("/newedit capture='many'", variables: [:]),
            .display("Command error: Capture attribute is not a number")
        )
    }

    func testDelayCommandGrammarAndScheduler() async throws {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/delay list", variables: [:]), .delay(.list))
        XCTAssertEqual(registry.parse("/delay killall", variables: [:]), .delay(.killAll))
        XCTAssertEqual(registry.parse("/delay kill timer", variables: [:]), .delay(.kill("timer")))
        XCTAssertEqual(
            registry.parse("/delay id pulse every 2m \"look\"", variables: [:]),
            .delay(.schedule(id: "pulse", repeating: true, seconds: 120, command: "look"))
        )

        let scheduler = DelayScheduler()
        let fired = expectation(description: "delayed action")
        let id = await scheduler.schedule(repeating: false, seconds: 0.01, command: "look") { command in
            XCTAssertEqual(command, "look")
            fired.fulfill()
        }
        XCTAssertEqual(id, "1")
        let initialEntries = await scheduler.entries()
        XCTAssertEqual(initialEntries.map(\.id), ["1"])
        await fulfillment(of: [fired], timeout: 1)
        try await Task.sleep(for: .milliseconds(10))
        let finalEntries = await scheduler.entries()
        XCTAssertTrue(finalEntries.isEmpty)
    }

    func testReplacingTimerIDCannotEraseItsReplacementAfterOldActionCompletes() async throws {
        let scheduler = DelayScheduler()
        let oldStarted = expectation(description: "old timer action started")
        let releaseOld = expectation(description: "release old timer action")
        let replacementFired = expectation(description: "replacement timer fired")
        let oldReleaseGate = AsyncGate()

        _ = await scheduler.schedule(id: "shared", repeating: false, seconds: 0, command: "old") { _ in
            oldStarted.fulfill()
            await oldReleaseGate.wait()
            releaseOld.fulfill()
        }
        await fulfillment(of: [oldStarted], timeout: 1)
        _ = await scheduler.schedule(id: "shared", repeating: false, seconds: 0.05, command: "new") { command in
            XCTAssertEqual(command, "new")
            replacementFired.fulfill()
        }
        await oldReleaseGate.open()
        await fulfillment(of: [releaseOld, replacementFired], timeout: 1)
        try await Task.sleep(for: .milliseconds(10))
        let entries = await scheduler.entries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testEveryRegisteredCommandProducesACommandOutcome() {
        let registry = CommandRegistry()
        for command in CommandRegistry.knownCommands {
            let outcome = registry.parse("/\(command)", variables: [:])
            if case .unimplemented = outcome {
                XCTFail("Registered command still returns placeholder outcome: /\(command)")
            }
            if case let .display(message) = outcome, message.hasPrefix("Unrecognized Command,") {
                XCTFail("Registered command is not routed: /\(command)")
            }
        }
    }

    func testUnrecognizedCommandDiagnostic() {
        let registry = CommandRegistry()
        let message = "Unrecognized Command, use // to send text directly to the mu*, /help for a list of commands, or set 'Send unrecognized commands' in settings/input window"
        XCTAssertEqual(registry.parse("/unknown", variables: [:]), .display(message))
        XCTAssertEqual(registry.parse("/", variables: [:]), .display(message))
    }

}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
