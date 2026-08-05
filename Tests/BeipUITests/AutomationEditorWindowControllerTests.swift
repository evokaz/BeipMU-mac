import AppKit
import BeipAutomation
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class AutomationEditorWindowControllerTests: XCTestCase {
    func testTriggerDetailMatchTesterShowsRegexCapturesAndRanges() throws {
        let detail = TriggerDetailView()

        detail.testingConfigureMatch(
            text: "(.+) pages: (.+)",
            testString: "Wizard pages: test",
            isRegularExpression: true
        )

        XCTAssertEqual(detail.testingMatchError, "")
        XCTAssertTrue(detail.testingMatchResult.contains("Matches: 1"))
        XCTAssertTrue(detail.testingMatchResult.contains("$1=Wizard [0-5]"))
        XCTAssertTrue(detail.testingMatchResult.contains("$2=test [13-17]"))
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
        let firstCapture = try XCTUnwrap(Self.backgroundColor(in: highlighted, at: 0))
        let literalMatch = try XCTUnwrap(Self.backgroundColor(in: highlighted, at: 6))
        let secondCapture = try XCTUnwrap(Self.backgroundColor(in: highlighted, at: 13))

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
        XCTAssertNil(Self.backgroundColor(in: detail.testingTestStringAttributedString, at: 0))
    }

    func testTriggerDetailMatchTesterExposesAccessibilityValues() throws {
        let detail = TriggerDetailView()

        detail.testingConfigureMatch(text: "(.+)", testString: "hello", isRegularExpression: true)

        let result = try XCTUnwrap(
            recursiveSubviews(of: detail)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "triggerTestResult" }
        )
        let error = try XCTUnwrap(
            recursiveSubviews(of: detail)
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
            recursiveSubviews(of: detail)
                .compactMap { $0 as? NSTabView }
                .first { $0.accessibilityIdentifier() == "triggerActionTabs" }
        )
        tabs.selectTabViewItem(withIdentifier: "Paragraph")
        let previewView = try XCTUnwrap(
            recursiveSubviews(of: detail)
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
            recursiveSubviews(of: detail)
                .first { $0.accessibilityIdentifier() == "triggerAppearancePreview" }
        )
        XCTAssertEqual(preview.accessibilityLabel(), "Appearance preview")
        XCTAssertTrue((preview.accessibilityValue() as? String)?.contains("fast flashing") == true)
    }

    private static func backgroundColor(in value: NSAttributedString, at location: Int) -> NSColor? {
        value.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    func testTriggerOutlineNewTargetsSelectedCharacterScope() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer(named: "TestServer")
        let characterID = try workspace.addCharacter(toServerID: serverID, named: "Wizard")
        let library = ProfileLibrary(workspace: workspace)
        let characterScope = LegacyConfigurationWorkspace.AutomationScope.character(
            server: serverID,
            character: characterID
        )
        let controller = AutomationEditorWindowController(
            library: library,
            kind: .triggers,
            scope: characterScope
        )
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "triggerScopeOutline" }
        )
        let characterRow = try XCTUnwrap(row(titled: "Wizard", in: outline))
        outline.selectRowIndexes(.init(integer: characterRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let new = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSButton }
                .first { $0.title == "New" }
        )
        new.performClick(nil)

        let savedServer = try XCTUnwrap(
            library.workspace.servers.first { $0.profile.name == "TestServer" }
        )
        let savedCharacter = try XCTUnwrap(
            savedServer.characters.first { $0.name == "Wizard" }
        )
        let savedCharacterScope = LegacyConfigurationWorkspace.AutomationScope.character(
            server: savedServer.profile.id,
            character: savedCharacter.id
        )
        XCTAssertEqual(library.workspace.triggers(in: savedCharacterScope).count, 1)
        XCTAssertEqual(library.workspace.globalTriggers.count, 0)
    }

    func testTriggerOutlineRendersAndEditsNestedChildren() throws {
        let library = ProfileLibrary(workspace: try Self.workspaceWithNestedGlobalTrigger())
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try triggerOutline(in: content)
        let childRow = try XCTUnwrap(row(titled: "Child", in: outline))
        outline.selectRowIndexes(.init(integer: childRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let description = try textField(identifier: "triggerDescription", in: content)
        description.stringValue = "Edited Child"
        let apply = try button(titled: "Apply", in: content)
        apply.performClick(nil)

        XCTAssertEqual(library.workspace.trigger(at: [0, 0], in: .global)?.description, "Edited Child")
        XCTAssertEqual(library.workspace.trigger(at: [0], in: .global)?.description, "Parent")
    }

    func testTriggerOutlineNewCopyAndDeleteWorkAtNestedDepth() throws {
        let library = ProfileLibrary(workspace: try Self.workspaceWithNestedGlobalTrigger())
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try triggerOutline(in: content)
        let parentRow = try XCTUnwrap(row(titled: "Parent", in: outline))
        outline.selectRowIndexes(.init(integer: parentRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        try button(titled: "New", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).first?.children.count, 2)
        XCTAssertEqual(library.workspace.trigger(at: [0, 1], in: .global)?.description, "New Trigger")

        let newRow = try XCTUnwrap(row(titled: "New Trigger", in: outline))
        outline.selectRowIndexes(.init(integer: newRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try button(titled: "Copy", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).first?.children.count, 3)
        XCTAssertEqual(library.workspace.trigger(at: [0, 2], in: .global)?.description, "Copy of New Trigger")

        let copiedRow = try XCTUnwrap(row(titled: "Copy of New Trigger", in: outline))
        outline.selectRowIndexes(.init(integer: copiedRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try button(titled: "Delete", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).first?.children.count, 2)
        XCTAssertNil(library.workspace.trigger(at: [0, 2], in: .global))
    }

    func testTriggerSamplesRenderAndCopyIntoSelectedScope() throws {
        let library = ProfileLibrary(workspace: try Self.workspace(
            """
            Version=331
            Connections {
              Triggers { Active=true }
            }
            """
        ))
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let editable = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "triggerScopeOutline" }
        )
        let samples = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "triggerSamplesOutline" }
        )

        for title in [
            "Activity Sound",
            "Speak all text",
            "Highlight words",
            "Censor bad words",
            "Rainbow Text (Hash coloring)",
        ] {
            XCTAssertNotNil(row(titled: title, in: samples), "Missing trigger sample: \(title)")
        }

        let globalRow = try XCTUnwrap(row(titled: "Global", in: editable))
        editable.selectRowIndexes(.init(integer: globalRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: editable
        ))
        let sampleRow = try XCTUnwrap(row(titled: "Rainbow Text (Hash coloring)", in: samples))
        samples.selectRowIndexes(.init(integer: sampleRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: samples
        ))

        try button(identifier: "triggerCopy", in: content).performClick(nil)

        let copied = try XCTUnwrap(library.workspace.trigger(at: [0], in: .global))
        XCTAssertEqual(copied.description, "Rainbow Text (Hash coloring)")
        XCTAssertTrue(copied.actions.contains(.colorHash(foreground: true, background: false, wholeLine: true)))
    }

    func testTriggerOutlineMoveButtonsReorderIndentAndOutdent() throws {
        let library = ProfileLibrary(workspace: try Self.workspace(
            """
            Version=331
            Connections {
              Triggers {
                Active=true
                { Description="Parent" Folder=true FindString { MatchText="parent" }
                  Triggers { { Description="Child" FindString { MatchText="child" } } }
                }
                { Description="Second" FindString { MatchText="second" } }
                { Description="Third" FindString { MatchText="third" } }
              }
            }
            """
        ))
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try triggerOutline(in: content)

        outline.selectRowIndexes(.init(integer: try XCTUnwrap(row(titled: "Second", in: outline))), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try button(titled: "Up", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).map(\.description), ["Second", "Parent", "Third"])

        outline.selectRowIndexes(.init(integer: try XCTUnwrap(row(titled: "Third", in: outline))), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try button(titled: "In", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).map(\.description), ["Second", "Parent"])
        XCTAssertEqual(library.workspace.trigger(at: [1], in: .global)?.children.map(\.description), ["Child", "Third"])

        outline.selectRowIndexes(.init(integer: try XCTUnwrap(row(titled: "Third", in: outline))), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try button(titled: "Out", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).map(\.description), ["Second", "Parent", "Third"])
        XCTAssertEqual(library.workspace.trigger(at: [1], in: .global)?.children.map(\.description), ["Child"])

        outline.selectRowIndexes(.init(integer: try XCTUnwrap(row(titled: "Second", in: outline))), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        try button(titled: "Down", in: content).performClick(nil)
        XCTAssertEqual(library.workspace.triggers(in: .global).map(\.description), ["Parent", "Second", "Third"])
    }

    func testTriggerOutlinePreservesSelectionByIdentityAfterReloadedReorder() throws {
        let library = ProfileLibrary(workspace: try Self.workspace(
            """
            Version=331
            Connections {
              Triggers {
                Active=true
                { Description="First" FindString { MatchText="first" } }
                { Description="Second" FindString { MatchText="second" } }
              }
            }
            """
        ))
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try triggerOutline(in: content)
        outline.selectRowIndexes(.init(integer: try XCTUnwrap(row(titled: "Second", in: outline))), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        XCTAssertEqual(try textField(identifier: "triggerDescription", in: content).stringValue, "Second")

        try library.mutate {
            _ = try $0.moveTrigger(at: [1], in: .global, toParentPath: [], index: 0)
        }
        let afterCount = try textField(identifier: "triggerScopeAfterCount", in: content)
        afterCount.stringValue = "1"
        try button(titled: "Save Post Count", in: content).performClick(nil)

        XCTAssertEqual(library.workspace.triggers(in: .global).map(\.description), ["Second", "First"])
        XCTAssertEqual(try textField(identifier: "triggerDescription", in: content).stringValue, "Second")
        let selectedRow = outline.selectedRow
        let selectedCell = outline.view(atColumn: 0, row: selectedRow, makeIfNecessary: true) as? NSTableCellView
        XCTAssertEqual(selectedCell?.textField?.stringValue, "Second")
    }

    func testTriggerOutlineIncludesPuppetScopes() throws {
        let workspace = try Self.workspace(
            """
            Version=331
            Connections {
              Shortcuts {
                World {
                  Host="world.example:8888"
                  Characters {
                    Hero {
                      Puppets {
                        Bot {
                          Triggers { Active=true { Description="Puppet Trigger" FindString { MatchText="bot" } } }
                        }
                      }
                    }
                  }
                }
              }
            }
            """
        )
        let controller = AutomationEditorWindowController(library: ProfileLibrary(workspace: workspace), kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try triggerOutline(in: content)

        XCTAssertNotNil(row(titled: "Bot", in: outline))
        XCTAssertNotNil(row(titled: "Puppet Trigger", in: outline))
    }

    func testTriggerEditorKeepsScopeActiveAndPersistsAfterCount() throws {
        let library = ProfileLibrary(workspace: try Self.workspaceWithNestedGlobalTrigger())
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try triggerOutline(in: content)
        let globalRow = try XCTUnwrap(row(titled: "Global", in: outline))
        outline.selectRowIndexes(.init(integer: globalRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let afterCount = try textField(identifier: "triggerScopeAfterCount", in: content)
        afterCount.stringValue = "1"
        try button(titled: "Save Post Count", in: content).performClick(nil)

        let group = library.workspace.triggerGroup(in: .global)
        XCTAssertTrue(group.active)
        XCTAssertEqual(group.afterCount, 1)
    }

    func testTriggerEditorPersistsFolderCheckbox() throws {
        let library = ProfileLibrary(workspace: try Self.workspaceWithNestedGlobalTrigger())
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try triggerOutline(in: content)
        let parentRow = try XCTUnwrap(row(titled: "Parent", in: outline))
        outline.selectRowIndexes(.init(integer: parentRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let folder = try button(titled: "Folder", in: content)
        folder.state = .on
        try button(titled: "Apply", in: content).performClick(nil)

        XCTAssertTrue(library.workspace.trigger(at: [0], in: .global)?.folder == true)
        XCTAssertEqual(library.workspace.trigger(at: [0], in: .global)?.children.first?.description, "Child")
    }

    func testTriggerDetailExposesEveryActionTabAndVoiceOverIdentifier() throws {
        let detail = TriggerDetailView()
        let views = recursiveSubviews(of: detail)
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
            identifiers.formUnion(recursiveSubviews(of: detail).compactMap { $0.accessibilityIdentifier() })
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
        let identifiers = recursiveSubviews(of: detail).reduce(into: [String: NSView]()) { values, view in
            let identifier = view.accessibilityIdentifier()
            guard !identifier.isEmpty, values[identifier] == nil else { return }
            values[identifier] = view
        }
        XCTAssertEqual(identifiers["triggerStopProcessing"]?.accessibilityValue() as? String, "On")
        XCTAssertEqual(identifiers["triggerPresent"]?.accessibilityValue() as? String, "On")
    }

    func testTriggerEditorProvidesKeyboardReachableOutlineControlsAndApply() throws {
        let library = ProfileLibrary(workspace: try Self.workspaceWithNestedGlobalTrigger())
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let outline = try triggerOutline(in: content)
        XCTAssertTrue(outline.acceptsFirstResponder)
        let childRow = try XCTUnwrap(row(titled: "Child", in: outline))
        outline.selectRowIndexes(.init(integer: childRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let apply = try button(identifier: "triggerApply", in: content)
        XCTAssertEqual(apply.keyEquivalent, "\r")
        for identifier in [
            "triggerNew",
            "triggerCopy",
            "triggerDelete",
            "triggerMoveUp",
            "triggerMoveDown",
            "triggerMoveIn",
            "triggerMoveOut",
            "triggerScopeApply",
        ] {
            XCTAssertNotNil(try? button(identifier: identifier, in: content), "Missing keyboard-reachable control: \(identifier)")
        }
    }

    func testTriggerEditorHandlesVeryLongStringsAndLargeTriggerTrees() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let longMatch = String(repeating: "very-long-match-", count: 600)
        let longSend = String(repeating: "send-long-action ", count: 600)
        for index in 0..<240 {
            try workspace.addTrigger(
                in: .global,
                trigger: Trigger(
                    description: "Bulk \(index)",
                    match: .init(text: index == 239 ? longMatch : "match-\(index)"),
                    actions: [.send(index == 239 ? longSend : "send-\(index)", captureIndex: 0, expandVariables: false)]
                )
            )
        }
        let library = ProfileLibrary(workspace: workspace)
        let controller = AutomationEditorWindowController(library: library, kind: .triggers)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try triggerOutline(in: content)

        let bulkRow = try XCTUnwrap(row(titled: "Bulk 239", in: outline))
        outline.selectRowIndexes(.init(integer: bulkRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        XCTAssertEqual(try textField(identifier: "triggerMatch", in: content).stringValue, longMatch)

        let description = try textField(identifier: "triggerDescription", in: content)
        description.stringValue = "Bulk 239 Edited"
        try button(identifier: "triggerApply", in: content).performClick(nil)

        XCTAssertEqual(library.workspace.triggers(in: .global).count, 240)
        XCTAssertEqual(library.workspace.trigger(at: [239], in: .global)?.description, "Bulk 239 Edited")
    }

    func testAliasEditorRendersReferenceLayoutAndEditsNestedAlias() throws {
        let library = ProfileLibrary(workspace: try Self.workspaceWithNestedGlobalAlias())
        let controller = AutomationEditorWindowController(library: library, kind: .aliases)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let outline = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "aliasScopeOutline" }
        )
        XCTAssertNotNil(try? button(identifier: "aliasApply", in: content))
        XCTAssertNotNil(try? button(identifier: "aliasHelp", in: content))

        let childRow = try XCTUnwrap(row(titled: "Child", in: outline))
        outline.selectRowIndexes(.init(integer: childRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let description = try textField(identifier: "aliasDescription", in: content)
        description.stringValue = "Edited Child"
        let example = try textView(identifier: "aliasTestString", in: content)
        example.string = "x"
        let replacement = try textView(identifier: "aliasReplacement", in: content)
        replacement.string = "edited"
        try button(identifier: "aliasApply", in: content).performClick(nil)

        let edited = try XCTUnwrap(library.workspace.alias(at: [0, 0], in: .global))
        XCTAssertEqual(edited.description, "Edited Child")
        XCTAssertEqual(edited.example, "x")
        XCTAssertEqual(edited.replacement, "edited")
    }

    func testAliasProcessingOptionsBelongToSelectedAliasAndPersist() throws {
        let library = ProfileLibrary(workspace: try Self.workspaceWithNestedGlobalAlias())
        let controller = AutomationEditorWindowController(library: library, kind: .aliases)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "aliasScopeOutline" }
        )
        let childRow = try XCTUnwrap(row(titled: "Child", in: outline))
        outline.selectRowIndexes(.init(integer: childRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        let process = try button(identifier: "aliasProcessAliases", in: content)
        let echo = try button(identifier: "aliasEcho", in: content)
        let commands = try button(identifier: "aliasProcessCommands", in: content)
        XCTAssertEqual(process.state, .on)
        XCTAssertEqual(echo.state, .on)
        XCTAssertEqual(commands.state, .off)

        process.performClick(nil)
        echo.performClick(nil)
        commands.performClick(nil)
        XCTAssertEqual(process.state, .off)
        XCTAssertEqual(echo.state, .off)
        XCTAssertEqual(commands.state, .on)
        try button(identifier: "aliasApply", in: content).performClick(nil)

        let edited = try XCTUnwrap(library.workspace.alias(at: [0, 0], in: .global))
        XCTAssertFalse(edited.active)
        XCTAssertFalse(edited.echo)
        XCTAssertTrue(edited.processCommands)
        XCTAssertTrue(try library.workspace.renderedDocument().serialized().contains("ProcessCommands=true"))
    }

    func testAliasFolderDisablesProcessingControlsAndSamplesCopyIndependently() throws {
        let library = ProfileLibrary(workspace: try Self.workspaceWithNestedGlobalAlias())
        let controller = AutomationEditorWindowController(library: library, kind: .aliases)
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "aliasScopeOutline" }
        )
        let folderRow = try XCTUnwrap(row(titled: "Folder", in: outline))
        outline.selectRowIndexes(.init(integer: folderRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))

        XCTAssertEqual(try button(identifier: "aliasFolder", in: content).state, .on)
        XCTAssertFalse(try button(identifier: "aliasRegularExpression", in: content).isEnabled)
        XCTAssertFalse(try textView(identifier: "aliasTestString", in: content).isEditable)
        XCTAssertFalse(try textView(identifier: "aliasReplacement", in: content).isEditable)

        let samples = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "aliasSamplesOutline" }
        )
        let sampleRow = try XCTUnwrap(row(titled: "Repeat 'buy torch' command n times", in: samples))
        samples.selectRowIndexes(.init(integer: sampleRow), byExtendingSelection: false)
        try button(identifier: "aliasCopy", in: content).performClick(nil)

        XCTAssertEqual(library.workspace.alias(at: [0, 1], in: .global)?.description, "Repeat 'buy torch' command n times")
        XCTAssertEqual(library.workspace.alias(at: [0, 1], in: .global)?.example, "bt 5")
    }

    func testMacroEditorUsesWindowsLayoutAndStagesApply() throws {
        let workspace = try Self.workspace(
            """
            Version=331
            Connections {
              KeyboardMacros2 { Active=true
                { Description="Folder" Folder=true Custom="keep"
                  KeyboardMacros2 { { Description="Child" Macro="north" key=Control+Alt+N Type=true } }
                }
              }
            }
            """
        )
        let library = ProfileLibrary(workspace: workspace)
        let controller = AutomationEditorWindowController(library: library, kind: .macros)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).width, 760, accuracy: 2)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).height, 525, accuracy: 25)
        let outline = try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "macroScopeOutline" }
        )
        XCTAssertNotNil(try? button(identifier: "macroApply", in: content))
        XCTAssertNotNil(try? button(identifier: "macroOK", in: content))
        XCTAssertNotNil(try? button(identifier: "macroCancel", in: content))
        XCTAssertNotNil(try? button(identifier: "macroHelp", in: content))

        let childRow = try XCTUnwrap(row(titled: "Child", in: outline))
        outline.selectRowIndexes(.init(integer: childRow), byExtendingSelection: false)
        controller.outlineViewSelectionDidChange(.init(
            name: NSOutlineView.selectionDidChangeNotification,
            object: outline
        ))
        let keyField = try textField(identifier: "macroKeyCapture", in: content)
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        keyField.mouseDown(with: click)
        XCTAssertTrue(controller.window?.firstResponder === keyField)
        keyField.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .shift],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "m",
            charactersIgnoringModifiers: "m",
            isARepeat: false,
            keyCode: 46
        )))
        XCTAssertEqual(keyField.stringValue, "Control + Shift + M")
        XCTAssertEqual(keyField.accessibilityValue(), "Control + Shift + M")

        let description = try textField(identifier: "macroDescription", in: content)
        description.stringValue = "Edited Child"
        try button(identifier: "macroApply", in: content).performClick(nil)

        XCTAssertEqual(library.workspace.macro(at: [0, 0], in: .global)?.description, "Edited Child")
        XCTAssertEqual(library.workspace.macro(at: [0, 0], in: .global)?.key, "Control+Shift+M")
        XCTAssertTrue(try library.workspace.renderedDocument().serialized().contains("Custom=\"keep\""))
        XCTAssertTrue(try library.workspace.renderedDocument().serialized().contains("Type=true"))
    }

    func testAutomationDebuggerDisplaysTriggerSkipReasons() throws {
        let controller = AutomationDebugWindowController(kind: .triggers)
        defer { controller.close() }

        controller.append([
            .init(
                engine: .trigger,
                description: "Cooldown",
                pattern: "alert",
                input: "alert",
                matchCount: 0,
                output: "alert",
                reason: "Skipped: cooldown active"
            ),
        ])

        let text = try XCTUnwrap(
            recursiveSubviews(of: controller.window?.contentView)
                .compactMap { $0 as? NSTextView }
                .first { $0.accessibilityIdentifier() == "triggersDebuggerLog" }
        )
        XCTAssertTrue(text.string.contains("reason: Skipped: cooldown active"))
    }

    private func row(titled title: String, in outline: NSOutlineView) -> Int? {
        for row in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  cell.textField?.stringValue == title else { continue }
            return row
        }
        return nil
    }

    private func recursiveSubviews(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { recursiveSubviews(of: $0) }
    }

    private func triggerOutline(in content: NSView) throws -> NSOutlineView {
        try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSOutlineView }
                .first { $0.accessibilityIdentifier() == "triggerScopeOutline" }
        )
    }

    private func textField(identifier: String, in content: NSView) throws -> NSTextField {
        try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == identifier }
        )
    }

    private func textView(identifier: String, in content: NSView) throws -> NSTextView {
        try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSTextView }
                .first { $0.accessibilityIdentifier() == identifier }
        )
    }

    private func button(titled title: String, in content: NSView) throws -> NSButton {
        try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSButton }
                .first { $0.title == title }
        )
    }

    private func button(identifier: String, in content: NSView) throws -> NSButton {
        try XCTUnwrap(
            recursiveSubviews(of: content)
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == identifier }
        )
    }

    private static func workspaceWithNestedGlobalTrigger() throws -> LegacyConfigurationWorkspace {
        try workspace(
            """
            Version=331
            Connections {
              Triggers {
                Active=true
                { Description="Parent" FindString { MatchText="parent" }
                  Triggers {
                    Active=true
                    { Description="Child" FindString { MatchText="child" } }
                  }
                }
              }
            }
            """
        )
    }

    private static func workspaceWithNestedGlobalAlias() throws -> LegacyConfigurationWorkspace {
        try workspace(
            """
            Version=331
            Connections {
              Aliases {
                Active=true Echo=true ProcessCommands=false
                { Description="Folder" Folder=true FindString.MatchText=""
                  Aliases { Active=true AfterCount=0
                    { Description="Child" Example="old" Replace="old" FindString.MatchText="x" }
                  }
                }
              }
            }
            """
        )
    }

    private static func workspace(_ source: String) throws -> LegacyConfigurationWorkspace {
        try LegacyConfigurationWorkspace(document: .init(source: source))
    }
}
