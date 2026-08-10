@testable import BeipAutomation
import BeipCore
import BeipTestSupport
import Foundation
import XCTest

final class TriggerEngineTests: XCTestCase {
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

    func testTriggerTraceExposesDiagnosticSkipReasons() async throws {
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
}
