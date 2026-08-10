import BeipCore
import BeipAutomation
import BeipPersistence
import Foundation
import XCTest

final class LegacyTriggerProjectionTests: XCTestCase {
    func testProjectionLoadsHierarchicalAliasesAndOrderedTriggers() async throws {
        let source = """
        Version=331
        Connections {
          Aliases {
            Active=true
            Echo=false
            ProcessCommands=true
            AfterCount=1
            { FindString { MatchText="g" StartsWith=true } Replace="go" }
            { Folder=true Aliases { { FindString { MatchText="go" } Replace="north" } } }
          }
          Triggers {
            Active=true
            { FindString { MatchText="HP: ([0-9]+)" RegularExpression=true }
              Color { UseForeColor=true Fore="#FF0000" WholeLine=true }
              Style { SetBold=true Bold=true WholeLine=true }
              Paragraph { UseAlignment=true Alignment=1 UseIndent_Left=true Indent_Left=10 }
              Avatar { URL="https://example.test/$1.png" }
              Send { Active=true Send="score $1" ExpandVariables=true }
              Gag { Active=true Log=true }
            }
          }
          Shortcuts {
            World {
              Host="example.test:8888"
              Aliases { { FindString { MatchText="north" } Replace="n" } }
              Characters {
                Hero {
                  Aliases { { FindString { MatchText="n" } Replace="north" } }
                }
              }
            }
          }
        }
        """
        let projection = try LegacyConfigurationProjection(
            document: .init(source: source)
        )
        let server = try XCTUnwrap(projection.servers.first)
        let hero = try XCTUnwrap(server.characters.first)
        let automation = projection.automationGroups(for: server.profile, character: hero)

        XCTAssertEqual(automation.aliases.count, 4)
        XCTAssertFalse(projection.automation.aliases.echo)
        XCTAssertTrue(projection.automation.aliases.processCommands)
        let parsedTrigger = try XCTUnwrap(projection.automation.triggers.triggers.first)
        XCTAssertTrue(parsedTrigger.actions.contains(.color(
            foreground: .init(red: 255, green: 0, blue: 0),
            background: nil,
            wholeLine: true
        )))
        XCTAssertTrue(parsedTrigger.actions.contains(.appearance(.init(bold: true), wholeLine: true)))
        XCTAssertTrue(parsedTrigger.actions.contains(.paragraph(.init(alignment: .center, leftIndent: 10))))
        XCTAssertTrue(parsedTrigger.actions.contains(.avatar("https://example.test/$1.png")))
        let aliases = try AliasEngine.process("g", groups: automation.aliases, variables: [:])
        XCTAssertEqual(aliases.text, "north")

        let effects = try await TriggerEngine().process(
            .init(text: "HP: 42"),
            groups: automation.triggers,
            variables: [:]
        )
        XCTAssertEqual(effects, [
            .style(
                range: NSRange(location: 0, length: 6),
                foreground: .init(red: 255, green: 0, blue: 0),
                background: nil
            ),
            .appearance(range: NSRange(location: 0, length: 6), patch: .init(bold: true)),
            .paragraph(.init(alignment: .center, leftIndent: 10)),
            .gagDisplay,
            .gagLog,
            .send("score 42"),
            .avatar("https://example.test/42.png"),
        ])
    }

    func testProjectionLoadsV331CanonicalDottedFindStringAssignments() throws {
        let source = """
        Version=331
        Connections {
          Aliases {
            Active=true
            {
              Description="Dotted alias"
              Replace="look"
              FindString.MatchText="l"
              FindString.StartsWith=true
            }
          }
          Triggers {
            Active=true
            {
              Description="Dotted trigger"
              FindString.MatchText="HP:"
              FindString.MatchCase=true
            }
          }
        }
        """
        let projection = try LegacyConfigurationProjection(document: .init(source: source))
        let alias = try XCTUnwrap(projection.automation.aliases.aliases.first)
        XCTAssertEqual(alias.match.text, "l")
        XCTAssertTrue(alias.match.startsWith)
        let trigger = try XCTUnwrap(projection.automation.triggers.triggers.first)
        XCTAssertEqual(trigger.match.text, "HP:")
        XCTAssertTrue(trigger.match.matchCase)
    }

    func testProjectionLoadsExtendedV331TriggerOptions() throws {
        let source = """
        Version=331
        Connections {
          Triggers { Active=true
            { FindString { MatchText="(Hero)" RegularExpression=true }
              Color { FontFace="Menlo" FontSize=16 ForeHash=true BackDefault=true }
              Paragraph { UseBorder=true Border=3 UseBorderStyle=true BorderStyle=1 UseStroke=true StrokeWidth=2 StrokeHash=true StrokeStyle=2 UseHorizontalRule=true }
              Activate { Active=true ImportantActivity=true NoActivity=true }
              Spawn { Active=true Title="$1" TabGroup="Combat-%group%" CaptureUntil="END" }
              Send { Active=true Send="look $1" CaptureIndex=1 SendOnClick=true ExpandVariables=true }
              Filter { Active=true HTML=true Replace="<b>$1</b>" }
            }
          }
        }
        """
        let projection = try LegacyConfigurationProjection(document: .init(source: source))
        let actions = try XCTUnwrap(projection.automation.triggers.triggers.first).actions

        XCTAssertTrue(actions.contains(.colorHash(foreground: true, background: false, wholeLine: false)))
        XCTAssertTrue(actions.contains(.colorDefault(foreground: false, background: true, wholeLine: false)))
        XCTAssertTrue(actions.contains(.font(face: "Menlo", size: 16, useDefault: false, wholeLine: false)))
        XCTAssertTrue(actions.contains(.activateWindow))
        XCTAssertTrue(actions.contains(.activity(important: true)))
        XCTAssertTrue(actions.contains(.suppressActivity))
        XCTAssertTrue(actions.contains(.send("look $1", captureIndex: 1, expandVariables: true, sendOnClick: true)))
        XCTAssertTrue(actions.contains(.replaceHTML("<b>$1</b>", expandVariables: false)))
        let spawn = actions.compactMap { action -> TriggerSpawnAction? in
            if case let .spawn(value) = action { return value }
            return nil
        }.first
        XCTAssertEqual(spawn?.tabGroup, "Combat-%group%")
        let paragraph = actions.compactMap { action -> ParagraphPatch? in
            if case let .paragraph(value) = action { return value }
            return nil
        }.first
        XCTAssertEqual(paragraph?.borderWidth, 3)
        XCTAssertEqual(paragraph?.borderStyle, .round)
        XCTAssertEqual(paragraph?.strokeStyle, .bottom)
        XCTAssertEqual(paragraph?.horizontalRule, true)
    }

    func testWorkspaceUpdatesFullTriggerSurfaceAndPreservesUnknownFields() throws {
        let source = """
        Version=331
        Connections {
          Triggers { Active=true
            { Description="Old" FutureTriggerField="keep me" FindString { MatchText="old" }
              Send { Active=true Send="old send" }
            }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))
        let trigger = Trigger(
            description: "Updated",
            match: .init(
                text: "HP: ([0-9]+)",
                isRegularExpression: true,
                matchCase: true,
                startsWith: true,
                endsWith: true,
                wholeWord: true
            ),
            disabled: true,
            stopProcessing: true,
            oncePerLine: true,
            awayPresent: true,
            awayPresentOnce: true,
            away: false,
            cooldown: 12,
            multiline: .init(lineLimit: 3, timeLimit: 4),
            actions: [
                .color(foreground: .init(red: 1, green: 2, blue: 3), background: .init(red: 4, green: 5, blue: 6), wholeLine: true),
                .colorDefault(foreground: true, background: false, wholeLine: true),
                .colorHash(foreground: false, background: true, wholeLine: true),
                .font(face: "Menlo", size: 15, useDefault: false, wholeLine: true),
                .appearance(.init(bold: true, italic: true, underline: true, strikeout: true, blink: .fast), wholeLine: true),
                .paragraph(.init(alignment: .right, leftIndent: 1, rightIndent: 2, topPadding: 3, bottomPadding: 4, background: .black, borderWidth: 5, borderStyle: .round, strokeWidth: 6, strokeColor: .white, strokeStyle: .bottom)),
                .gag(display: true, log: true),
                .activateWindow,
                .activity(important: true),
                .suppressActivity,
                .spawn(.init(title: "Pages", tabGroup: "Tells", captureUntil: "END", onlyChildrenDuringCapture: true, clear: true, showTab: true, gagLog: true, copy: true)),
                .stat(.init(title: "Stats", name: "HP", prefix: "01", value: "$1", kind: .range, addsToExistingInteger: true, lower: "0", upper: "100", color: .white, rangeColor: .init(red: 0, green: 255, blue: 0), nameAlignment: .left, font: .init(name: "Menlo", size: 13, bold: true))),
                .sound("notify.wav"),
                .speech("hit $1", wholeLine: true),
                .send("score $1", captureIndex: 1, expandVariables: true, sendOnClick: true),
                .notification,
                .replaceHTML("<b>$1</b>", expandVariables: true),
                .avatar("https://example.test/avatar.png"),
                .script("Sample"),
            ]
        )

        try workspace.updateGlobalTrigger(at: 0, trigger: trigger)
        let rendered = try workspace.renderedDocument()
        let serialized = rendered.serialized()
        let reloaded = try LegacyConfigurationProjection(document: rendered)
        let actions = try XCTUnwrap(reloaded.automation.triggers.triggers.first?.actions)

        XCTAssertTrue(serialized.contains("FutureTriggerField=\"keep me\""))
        XCTAssertTrue(serialized.contains("Description=\"Updated\""))
        XCTAssertTrue(serialized.contains("Disabled=true"))
        XCTAssertTrue(actions.contains(.send("score $1", captureIndex: 1, expandVariables: true, sendOnClick: true)))
        XCTAssertTrue(actions.contains(.replaceHTML("<b>$1</b>", expandVariables: true)))
        XCTAssertTrue(actions.contains(.speech("hit $1", wholeLine: true)))
        XCTAssertTrue(actions.contains(.avatar("https://example.test/avatar.png")))
        XCTAssertTrue(actions.contains(.script("Sample")))
        XCTAssertTrue(actions.contains { if case .stat = $0 { return true }; return false })
        XCTAssertTrue(actions.contains { if case .spawn = $0 { return true }; return false })
    }

    func testV331AutomationFixtureProjectsEndToEnd() throws {
        let source = try String(
            contentsOf: LegacyConfigurationTestSupport.fixtureURL("v331-automation-config.txt"),
            encoding: .utf8
        )
        let projection = try LegacyConfigurationProjection(document: .init(source: source))
        let server = try XCTUnwrap(projection.servers.first)
        let character = try XCTUnwrap(server.characters.first)
        let groups = projection.automationGroups(for: server.profile, character: character)
        let macros = projection.macroGroups(for: server.profile, character: character)

        XCTAssertEqual(try AliasEngine.process("n", groups: groups.aliases, variables: [:]).text, "north")
        XCTAssertEqual(macros.first?.macros.first?.macro, "inventory")
        XCTAssertEqual(projection.loggingPath, "~/Shared Logs")
        XCTAssertEqual(projection.logging.wrapWidth, 72)
        XCTAssertEqual(projection.automaticLog(for: server.profile, character: character)?.filename, "Hero.html")
        let actions = try XCTUnwrap(projection.automation.triggers.triggers.first).actions
        XCTAssertTrue(actions.contains(.colorHash(foreground: true, background: false, wholeLine: false)))
        XCTAssertTrue(actions.contains(.send("look $1", captureIndex: 1, expandVariables: true, sendOnClick: true)))
        XCTAssertTrue(actions.contains(.replaceHTML("<b>$1</b>", expandVariables: false)))
        XCTAssertTrue(actions.contains { if case .stat = $0 { return true }; return false })
    }

    func testV331TriggerCorpusProjectsEveryScopeAndStandardTriggerField() throws {
        let source = try String(contentsOf: LegacyConfigurationTestSupport.fixtureURL("trigger-parity-v331-corpus.txt"), encoding: .utf8)
        let projection = try LegacyConfigurationProjection(document: .init(source: source))
        let server = try XCTUnwrap(projection.servers.first)
        let character = try XCTUnwrap(server.characters.first)
        let puppet = try XCTUnwrap(character.puppets.first)
        let trigger = try XCTUnwrap(projection.automation.triggers.triggers.first)

        XCTAssertEqual(projection.sourceVersion, LegacyConfigurationProjection.currentWindowsVersion)
        XCTAssertEqual(projection.automation.triggers.afterCount, 1)
        XCTAssertEqual(projection.automation.triggers.triggers.map(\.description), [
            "Global pre corpus",
            "Global post corpus",
        ])
        XCTAssertEqual(
            projection.automationGroups(for: server.profile, character: character, puppet: puppet)
                .triggers.flatMap(\.triggers).map(\.description),
            [
                "Global pre corpus",
                "World pre corpus",
                "Character corpus",
                "Puppet corpus",
                "World post corpus",
                "Global post corpus",
            ]
        )

        XCTAssertEqual(trigger.match.text, "^HP: ([0-9]+)/([0-9]+)$")
        XCTAssertTrue(trigger.match.isRegularExpression)
        XCTAssertTrue(trigger.match.matchCase)
        XCTAssertTrue(trigger.match.startsWith)
        XCTAssertTrue(trigger.match.endsWith)
        XCTAssertTrue(trigger.match.wholeWord)
        XCTAssertFalse(trigger.disabled)
        XCTAssertTrue(trigger.stopProcessing)
        XCTAssertTrue(trigger.oncePerLine)
        XCTAssertTrue(trigger.awayPresent)
        XCTAssertTrue(trigger.awayPresentOnce)
        XCTAssertFalse(trigger.away)
        XCTAssertEqual(trigger.cooldown, 7.5)
        XCTAssertEqual(trigger.multiline?.lineLimit, 4)
        XCTAssertEqual(trigger.multiline?.timeLimit, 9)
        XCTAssertFalse(trigger.childrenActive)
        XCTAssertEqual(trigger.children.first?.description, "Nested child")

        XCTAssertTrue(trigger.actions.contains(.color(
            foreground: .init(red: 1, green: 2, blue: 3),
            background: .init(red: 4, green: 5, blue: 6),
            wholeLine: true
        )))
        XCTAssertTrue(trigger.actions.contains(.colorDefault(foreground: true, background: false, wholeLine: true)))
        XCTAssertTrue(trigger.actions.contains(.colorHash(foreground: false, background: true, wholeLine: true)))
        XCTAssertTrue(trigger.actions.contains(.font(face: "Menlo", size: 15, useDefault: false, wholeLine: true)))
        XCTAssertTrue(trigger.actions.contains(.appearance(
            .init(bold: true, italic: true, underline: true, strikeout: true, blink: .fast),
            wholeLine: true
        )))
        XCTAssertTrue(trigger.actions.contains(.paragraph(.init(
            alignment: .right,
            leftIndent: 1,
            rightIndent: 2,
            topPadding: 3,
            bottomPadding: 4,
            background: .init(red: 7, green: 8, blue: 9),
            backgroundHash: true,
            borderWidth: 5,
            borderStyle: .round,
            strokeWidth: 6,
            strokeColor: .init(red: 10, green: 11, blue: 12),
            strokeHash: true,
            strokeStyle: .bottom,
            horizontalRule: true
        ))))
        XCTAssertTrue(trigger.actions.contains(.gag(display: true, log: true)))
        XCTAssertTrue(trigger.actions.contains(.activateWindow))
        XCTAssertTrue(trigger.actions.contains(.activity(important: true)))
        XCTAssertTrue(trigger.actions.contains(.suppressActivity))
        XCTAssertTrue(trigger.actions.contains(.spawn(.init(
            title: "Vitals $1",
            tabGroup: "Vitals-%character%",
            captureUntil: "END $2",
            onlyChildrenDuringCapture: true,
            clear: true,
            showTab: true,
            gagLog: true,
            copy: true
        ))))
        XCTAssertTrue(trigger.actions.contains(.stat(.init(
            title: "Vitals",
            name: "HP",
            prefix: "01",
            value: "$1",
            kind: .range,
            addsToExistingInteger: true,
            lower: "0",
            upper: "$2",
            color: .white,
            rangeColor: .init(red: 0, green: 255, blue: 0),
            nameAlignment: .left,
            font: .init(name: "Menlo", size: 13, bold: true, italic: true, underline: true, strikeout: true)
        ))))
        XCTAssertTrue(trigger.actions.contains(.sound("notify.wav")))
        XCTAssertTrue(trigger.actions.contains(.speech("HP $1", wholeLine: true)))
        XCTAssertTrue(trigger.actions.contains(.send("score $1", captureIndex: 1, expandVariables: true, sendOnClick: true)))
        XCTAssertTrue(trigger.actions.contains(.notification))
        XCTAssertTrue(trigger.actions.contains(.replaceHTML("<b>$1</b>", expandVariables: true)))
        XCTAssertTrue(trigger.actions.contains(.avatar("https://example.test/avatar.png")))
        XCTAssertTrue(trigger.actions.contains(.script("OnHp")))
    }

    func testV331TriggerCorpusEditsSavesReparsesAndPreservesInteropPayloads() throws {
        let source = try String(contentsOf: LegacyConfigurationTestSupport.fixtureURL("trigger-parity-v331-corpus.txt"), encoding: .utf8)
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))
        var edited = try XCTUnwrap(workspace.trigger(at: [0], in: .global))
        edited.description = "Global pre corpus edited on Mac"
        edited.match.text = "^HP: ([0-9]+)/([0-9]+)$"
        edited.actions = [.gag(display: true, log: true)]

        try workspace.updateTrigger(at: [0], in: .global, trigger: edited)
        let saved = try workspace.renderedDocument()
        let serialized = saved.serialized()
        let reloaded = try LegacyConfigurationProjection(document: saved)
        let reparsed = try XCTUnwrap(reloaded.automation.triggers.triggers.first)

        XCTAssertEqual(reloaded.sourceVersion, LegacyConfigurationProjection.currentWindowsVersion)
        XCTAssertEqual(reparsed.description, "Global pre corpus edited on Mac")
        XCTAssertEqual(reparsed.actions, [.gag(display: true, log: true)])
        XCTAssertEqual(reparsed.children.first?.description, "Nested child")
        XCTAssertTrue(serialized.contains("// V331 trigger interoperability corpus"))
        XCTAssertLessThan(
            try XCTUnwrap(serialized.range(of: "Description=\"Global pre corpus edited on Mac\"")?.lowerBound),
            try XCTUnwrap(serialized.range(of: "Description=\"Global post corpus\"")?.lowerBound)
        )
        XCTAssertTrue(serialized.contains("FutureRoot=\"keep-root\""))
        XCTAssertTrue(serialized.contains("FutureConnections=\"keep-connections\""))
        XCTAssertTrue(serialized.contains("FutureTriggerField=\"keep-global-pre\""))
        XCTAssertTrue(serialized.contains("FutureChildField=\"keep-child\""))
        XCTAssertTrue(serialized.contains("FutureWorldField=\"keep-world\""))
        XCTAssertTrue(serialized.contains("FutureCharacterField=\"keep-character\""))
        XCTAssertTrue(serialized.contains("FuturePuppetField=\"keep-puppet\""))
        XCTAssertTrue(serialized.contains("GUID=\"{01234567-89AB-CDEF-0123-456789ABCDEF}\""))
        XCTAssertTrue(serialized.contains("OpaqueBytes=\"00 FF 10\""))
        XCTAssertTrue(serialized.contains("NestedOpaque { Payload=\"keep-extension\" }"))
        XCTAssertTrue(serialized.contains("Send { Active=false Send=\"inactive child send\" CaptureIndex=9 ExpandVariables=true SendOnClick=true }"))
        XCTAssertTrue(serialized.contains("Filter { Active=false HTML=true Replace=\"inactive filter\" ExpandVariables=true }"))
        XCTAssertTrue(serialized.contains("Sound { Active=false Sound=\"inactive.wav\" }"))
    }

    func testTriggerScopeOrderingUsesGlobalWorldCharacterPuppetThenWorldAndGlobalPost() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            Active=true
            AfterCount=1
            { Description="Global Pre" FindString { MatchText="global pre" } }
            { Description="Global Post" FindString { MatchText="global post" } }
          }
          Shortcuts {
            World {
              Host="world.example:8888"
              Triggers {
                Active=true
                AfterCount=1
                { Description="World Pre" FindString { MatchText="world pre" } }
                { Description="World Post" FindString { MatchText="world post" } }
              }
              Characters {
                Hero {
                  Triggers {
                    Active=true
                    { Description="Character" FindString { MatchText="character" } }
                  }
                  Puppets {
                    Bot {
                      Triggers {
                        Active=true
                        { Description="Puppet" FindString { MatchText="puppet" } }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """
        let projection = try LegacyConfigurationProjection(document: .init(source: source))
        let server = try XCTUnwrap(projection.servers.first)
        let character = try XCTUnwrap(server.characters.first)
        let puppet = try XCTUnwrap(character.puppets.first)

        let ordered = projection.automationGroups(
            for: server.profile,
            character: character,
            puppet: puppet
        ).triggers.flatMap(\.triggers).map(\.description)

        XCTAssertEqual(ordered, [
            "Global Pre",
            "World Pre",
            "Character",
            "Puppet",
            "World Post",
            "Global Post",
        ])
    }

    func testProjectionReadsMultilineTriggerLimits() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            { FindString { MatchText="begin" }
              Multiline=true
              Multiline_Limit=2
              Multiline_Time=5
              AwayPresent=true
              AwayPresentOnce=true
              Away=true
              Triggers { { FindString { MatchText="next" } } }
            }
          }
        }
        """
        let projection = try LegacyConfigurationProjection(document: .init(source: source))
        let trigger = try XCTUnwrap(projection.automation.triggers.triggers.first)

        XCTAssertEqual(trigger.multiline, .init(lineLimit: 2, timeLimit: 5))
        XCTAssertTrue(trigger.awayPresent)
        XCTAssertTrue(trigger.awayPresentOnce)
        XCTAssertTrue(trigger.away)
        XCTAssertEqual(trigger.children.first?.match.text, "next")
    }

    func testProjectionReadsTriggerStatAction() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            { FindString { MatchText="HP ([0-9]+)" RegularExpression=true }
              Stat {
                Title="Vitals"
                Prefix="01"
                Name="HP"
                Value="$1"
                UseColor=true
                Color=RGB(255,0,0)
                NameAlignment=2
                UseFont=true
                Font { Name="Menlo" Size=14 Bold=true }
                Type=0
                Int { Add=true }
              }
            }
          }
        }
        """
        let projection = try LegacyConfigurationProjection(document: .init(source: source))
        let trigger = try XCTUnwrap(projection.automation.triggers.triggers.first)

        XCTAssertEqual(trigger.actions, [.stat(.init(
            title: "Vitals",
            name: "HP",
            prefix: "01",
            value: "$1",
            kind: .integer,
            addsToExistingInteger: true,
            color: .init(red: 255, green: 0, blue: 0),
            nameAlignment: .right,
            font: .init(name: "Menlo", size: 14, bold: true)
        ))])
    }

    func testProjectionReadsSpawnCaptureOptions() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            { FindString { MatchText="BEGIN" }
              Spawn {
                Active=true
                Title="Combat"
                CaptureUntil="^END$"
                OnlyChildrenDuringCapture=true
                Clear=true
                ShowTab=true
                GagLog=true
                Copy=false
              }
            }
          }
        }
        """
        let projection = try LegacyConfigurationProjection(document: .init(source: source))
        let trigger = try XCTUnwrap(projection.automation.triggers.triggers.first)

        XCTAssertEqual(trigger.actions, [.spawn(.init(
            title: "Combat",
            captureUntil: "^END$",
            onlyChildrenDuringCapture: true,
            clear: true,
            showTab: true,
            gagLog: true,
            copy: false
        ))])
    }

    func testTriggerExtensionGUIDAndUnknownPayloadRemainLossless() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            {
              Description="Extension-backed trigger"
              FindString { String="ready" }
              Extensions {
                {
                  GUID="{01234567-89AB-CDEF-0123-456789ABCDEF}"
                  FutureExtensionPayload="opaque"
                }
              }
            }
          }
        }
        """
        let document = try LegacyConfigurationDocument(source: source)
        var workspace = try LegacyConfigurationWorkspace(document: document)
        try workspace.updateGlobalTrigger(
            at: 0,
            description: "Portable edit",
            match: .init(text: "ready"),
            action: .gag(display: true, log: false)
        )
        let saved = try workspace.renderedDocument()
        XCTAssertTrue(saved.serialized().contains("Description=\"Portable edit\""))
        XCTAssertTrue(saved.serialized().contains("GUID=\"{01234567-89AB-CDEF-0123-456789ABCDEF}\""))
        XCTAssertTrue(saved.serialized().contains("FutureExtensionPayload=\"opaque\""))
    }
}
