import BeipAutomation
import AppKit
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class AutomationEditorTriggerDetailTests: XCTestCase {
    func testTriggerDetailMatchTesterShowsRegexCapturesAndRanges() throws {
        let detail = TriggerDetailView()

        detail.testingConfigureMatch(
            text: "(.+) pages: (.+)",
            testString: "Wizard pages: test",
            isRegularExpression: true
        )

        XCTAssertEqual(detail.testingMatchError, "")
        XCTAssertTrue(detail.testingMatchResult.contains("Matches: 1"))
        XCTAssertTrue(detail.testingMatchResult.contains("$1=Wizard [0-6]"))
        XCTAssertTrue(detail.testingMatchResult.contains("$2=test [14-18]"))
        XCTAssertNoThrow(try detail.validateForApply())
    }

    func testTriggerDetailMatchTesterHighlightsFullMatchAndCaptureRanges() throws {
        let detail = TriggerDetailView()

        detail.testingConfigureMatch(
            text: "(.+) pages: (.+)",
            testString: "Frank pages: Hello back!",
            isRegularExpression: true
        )

        let highlighted = detail.testingTestStringAttributedString
        let firstCapture = try XCTUnwrap(AutomationEditorTestSupport.backgroundColor(in: highlighted, at: 0))
        let literalMatch = try XCTUnwrap(AutomationEditorTestSupport.backgroundColor(in: highlighted, at: 6))
        let secondCapture = try XCTUnwrap(AutomationEditorTestSupport.backgroundColor(in: highlighted, at: 13))

        XCTAssertFalse(firstCapture.isEqual(literalMatch))
        XCTAssertFalse(secondCapture.isEqual(literalMatch))
        XCTAssertFalse(firstCapture.isEqual(secondCapture))
    }

    func testTriggerDetailMatchTesterReportsInvalidRegexAndBlocksApply() {
        let detail = TriggerDetailView()

        detail.testingConfigureMatch(text: "(", testString: "anything", isRegularExpression: true)

        XCTAssertTrue(detail.testingMatchError.contains("Invalid regular expression"))
        XCTAssertThrowsError(try detail.validateForApply())
    }

    func testTriggerDetailMatchTesterSummarizesLiteralRepeatedAndNoMatchResults() {
        let detail = TriggerDetailView()

        detail.testingConfigureMatch(text: "cat", testString: "cat scatter cat")
        XCTAssertTrue(detail.testingMatchResult.contains("Matches: 3"))

        detail.testingConfigureMatch(text: "dog", testString: "cat scatter cat")
        XCTAssertEqual(detail.testingMatchResult, "Matches: 0")
        XCTAssertNil(AutomationEditorTestSupport.backgroundColor(in: detail.testingTestStringAttributedString, at: 0))
    }

    func testTriggerDetailMatchTesterExposesAccessibilityValues() throws {
        let detail = TriggerDetailView()

        detail.testingConfigureMatch(text: "(.+)", testString: "hello", isRegularExpression: true)

        let result = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: detail)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "triggerTestResult" }
        )
        let error = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: detail)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "triggerTestError" }
        )
        XCTAssertEqual(result.accessibilityLabel(), "Trigger test result")
        XCTAssertTrue(result.accessibilityValue()?.contains("Matches: 1") == true)
        XCTAssertEqual(error.accessibilityLabel(), "Trigger test error")
    }

    func testTriggerDetailParagraphPreviewReflectsParagraphSettings() throws {
        let detail = TriggerDetailView()
        let patch = ParagraphPatch(
            alignment: .right,
            leftIndent: 12,
            rightIndent: 8,
            topPadding: 5,
            bottomPadding: 7,
            background: .black,
            borderWidth: 3,
            borderStyle: .round,
            strokeWidth: 2,
            strokeColor: .white,
            strokeStyle: .bottom
        )

        detail.testingConfigureParagraphPreview(patch)

        let preview = detail.testingParagraphPreviewStyle
        XCTAssertEqual(preview.alignment, .right)
        XCTAssertEqual(preview.leftIndent, 12)
        XCTAssertEqual(preview.rightIndent, 8)
        XCTAssertEqual(preview.topPadding, 5)
        XCTAssertEqual(preview.bottomPadding, 7)
        XCTAssertEqual(preview.background, .black)
        XCTAssertEqual(preview.borderWidth, 3)
        XCTAssertEqual(preview.borderStyle, .round)
        XCTAssertEqual(preview.strokeWidth, 2)
        XCTAssertEqual(preview.strokeColor, .white)
        XCTAssertEqual(preview.strokeStyle, .bottom)

        let tabs = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: detail)
                .compactMap { $0 as? NSTabView }
                .first { $0.accessibilityIdentifier() == "triggerActionTabs" }
        )
        tabs.selectTabViewItem(withIdentifier: "Paragraph")
        let previewView = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: detail)
                .first { $0.accessibilityIdentifier() == "triggerParagraphPreview" }
        )
        XCTAssertEqual(previewView.accessibilityLabel(), "Paragraph preview")
        XCTAssertTrue((previewView.accessibilityValue() as? String)?.contains("right aligned") == true)
    }

    func testTriggerDetailAppearancePreviewReflectsAppearanceSettings() throws {
        let detail = TriggerDetailView()

        detail.testingConfigureAppearancePreview(
            fontName: "Menlo",
            fontSize: 16,
            foreground: .systemYellow,
            background: .systemBlue,
            bold: true,
            italic: true,
            underline: true,
            strikeout: true,
            flashing: true,
            fastFlash: true,
            wholeLine: true
        )

        XCTAssertEqual(detail.testingAppearancePreviewFont.fontName, "Menlo-Regular")
        XCTAssertEqual(detail.testingAppearancePreviewFont.pointSize, 16)
        XCTAssertTrue(detail.testingAppearancePreviewForeground.isEqual(NSColor.systemYellow))
        XCTAssertTrue(detail.testingAppearancePreviewBackground.isEqual(NSColor.systemBlue))
        XCTAssertTrue(detail.testingAppearancePreviewIsBold)
        XCTAssertTrue(detail.testingAppearancePreviewIsItalic)
        XCTAssertTrue(detail.testingAppearancePreviewIsUnderlined)
        XCTAssertTrue(detail.testingAppearancePreviewIsStruckOut)
        XCTAssertTrue(detail.testingAppearancePreviewIsFlashing)
        XCTAssertTrue(detail.testingAppearancePreviewUsesFastFlash)
        XCTAssertTrue(detail.testingAppearancePreviewUsesWholeLine)

        let preview = try XCTUnwrap(
            AutomationEditorTestSupport.recursiveSubviews(of: detail)
                .first { $0.accessibilityIdentifier() == "triggerAppearancePreview" }
        )
        XCTAssertEqual(preview.accessibilityLabel(), "Appearance preview")
        XCTAssertTrue((preview.accessibilityValue() as? String)?.contains("fast flashing") == true)
    }

    func testTriggerDetailExposesEveryActionTabAndVoiceOverIdentifier() throws {
        let detail = TriggerDetailView()
        let views = AutomationEditorTestSupport.recursiveSubviews(of: detail)
        let tabView = try XCTUnwrap(
            views.compactMap { $0 as? NSTabView }
                .first { $0.accessibilityIdentifier() == "triggerActionTabs" }
        )

        XCTAssertEqual(
            tabView.tabViewItems.map(\.label),
            ["Appearance", "Paragraph", "Sound", "Spawn", "Stat", "Send", "Misc", "Activity", "Script"]
        )

        var identifiers = Set(views.compactMap { $0.accessibilityIdentifier() })
        for item in tabView.tabViewItems {
            tabView.selectTabViewItem(item)
            detail.layoutSubtreeIfNeeded()
            identifiers.formUnion(AutomationEditorTestSupport.recursiveSubviews(of: detail).compactMap { $0.accessibilityIdentifier() })
        }
        for identifier in [
            "triggerEnabled",
            "triggerFolder",
            "triggerProcessChildren",
            "triggerRegularExpression",
            "triggerMatchCase",
            "triggerWholeWord",
            "triggerStartsWith",
            "triggerEndsWith",
            "triggerStopProcessing",
            "triggerOncePerLine",
            "triggerCooldownEnabled",
            "triggerMultilineEnabled",
            "triggerAwayPresentEnabled",
            "triggerAway",
            "triggerPresent",
            "triggerAwayPresentOnce",
            "triggerFontEnabled",
            "triggerParagraphBackground",
            "triggerPlaySound",
            "triggerSpeechText",
            "triggerSpawnActive",
            "triggerStatName",
            "triggerSendText",
            "triggerSendTextBody",
            "triggerFilterText",
            "triggerAvatarURL",
            "triggerActivityImportant",
            "triggerActivateWindow",
            "triggerScriptEnabled",
        ] {
            XCTAssertTrue(identifiers.contains(identifier), "Missing trigger accessibility identifier: \(identifier)")
        }
    }

    func testTriggerDetailRoundTripsTopLevelOptionsAndActionPaneValues() throws {
        let patch = TextStylePatch(bold: true, italic: true, underline: true, strikeout: true, blink: .fast)
        let paragraph = ParagraphPatch(
            alignment: .right,
            leftIndent: 7,
            rightIndent: 9,
            topPadding: 3,
            bottomPadding: 4,
            background: .black,
            backgroundHash: true,
            borderWidth: 2,
            borderStyle: .round,
            strokeWidth: 5,
            strokeColor: .white,
            strokeHash: true,
            strokeStyle: .bottom
        )
        let stat = TriggerStatAction(
            title: "Stats",
            name: "HP",
            prefix: "01-",
            value: "42",
            kind: .range,
            addsToExistingInteger: true,
            lower: "0",
            upper: "100",
            color: .white,
            rangeColor: .black,
            nameAlignment: .right,
            font: .init(name: "Menlo", size: 14)
        )
        let trigger = Trigger(
            description: "Everything",
            match: .init(text: "(HP): (\\d+)", isRegularExpression: true, matchCase: true),
            folder: true,
            stopProcessing: true,
            oncePerLine: true,
            awayPresent: true,
            awayPresentOnce: true,
            away: false,
            cooldown: 12,
            multiline: .init(lineLimit: 3, timeLimit: 4),
            actions: [
                .color(foreground: .white, background: .black, wholeLine: true),
                .colorDefault(foreground: true, background: true, wholeLine: true),
                .colorHash(foreground: true, background: true, wholeLine: true),
                .font(face: "Menlo", size: 15, useDefault: false, wholeLine: true),
                .appearance(patch, wholeLine: true),
                .paragraph(paragraph),
                .gag(display: true, log: true),
                .spawn(.init(title: "Capture $1", tabGroup: "Group", captureUntil: "END", onlyChildrenDuringCapture: true, clear: true, showTab: true, gagLog: true, copy: true)),
                .stat(stat),
                .sound("notify.wav"),
                .speech("say $1", wholeLine: true),
                .send("look $2", captureIndex: 2, expandVariables: true, sendOnClick: true),
                .notification,
                .replaceHTML("<b>$2</b>", expandVariables: true),
                .avatar("https://example.invalid/avatar.png"),
                .activity(important: true),
                .activity(important: false),
                .activateWindow,
                .suppressActivity,
                .script("onTrigger"),
            ]
        )
        let detail = TriggerDetailView()

        detail.load(trigger)
        let updated = detail.updatedTrigger(preserving: trigger)

        XCTAssertEqual(updated.description, "Everything")
        XCTAssertTrue(updated.folder)
        XCTAssertTrue(updated.stopProcessing)
        XCTAssertTrue(updated.oncePerLine)
        XCTAssertTrue(updated.awayPresent)
        XCTAssertTrue(updated.awayPresentOnce)
        XCTAssertFalse(updated.away)
        XCTAssertEqual(updated.cooldown, 12)
        XCTAssertEqual(updated.multiline, .init(lineLimit: 3, timeLimit: 4))
        for action in trigger.actions {
            XCTAssertTrue(updated.actions.contains(action), "Missing action after UI round trip: \(action)")
        }
        let identifiers = AutomationEditorTestSupport.recursiveSubviews(of: detail).reduce(into: [String: NSView]()) { values, view in
            let identifier = view.accessibilityIdentifier()
            guard !identifier.isEmpty, values[identifier] == nil else { return }
            values[identifier] = view
        }
        XCTAssertEqual(identifiers["triggerStopProcessing"]?.accessibilityValue() as? String, "On")
        XCTAssertEqual(identifiers["triggerPresent"]?.accessibilityValue() as? String, "On")
    }
}
