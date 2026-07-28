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

    private static func workspace(_ source: String) throws -> LegacyConfigurationWorkspace {
        try LegacyConfigurationWorkspace(document: .init(source: source))
    }
}
