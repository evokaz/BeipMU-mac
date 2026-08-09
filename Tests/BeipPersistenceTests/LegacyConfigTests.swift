import BeipCore
import BeipAutomation
import BeipPersistence
import Foundation
import XCTest

final class LegacyConfigTests: XCTestCase {
    private let fixture = """
    // Keep this comment byte-for-byte
    Version=265
    Connections
    {
      Shortcuts
      {
        LambdaMOO
        {
          Host="lambda.moo.mud.org:8888"
          Encoding=CP1252
          Triggers { { Disabled=false } }
        }
      }
    }
    Unknown.Future.Value="preserve me"
    """

    func testLosslessRoundTrip() throws {
        let document = try LegacyConfigurationDocument(source: fixture)
        XCTAssertEqual(document.serialized(), fixture)
        XCTAssertEqual(document.value(at: ["Connections", "Shortcuts", "LambdaMOO", "Host"]), "lambda.moo.mud.org:8888")
    }

    func testSeededConfigParseSaveParsePropertyPreservesUnknownFields() throws {
        var random = PersistenceSeededRandom(seed: 0xC0FF_EE33_1)
        for iteration in 0..<96 {
            let token = String(format: "%08X", random.next())
            let source = """
            Version=331
            FutureRoot_\(iteration)="\(token)"
            Connections {
              FutureConnections_\(iteration)="keep-\(token)"
              Shortcuts {
                World_\(iteration) {
                  Host="127.0.0.1:\(8_000 + random.nextInt(upperBound: 1_000))"
                  FutureServer="\(token)"
                  Characters {
                    Hero { Connect="connect hero" FutureCharacter="\(token)" }
                  }
                }
              }
            }
            """
            let original = try LegacyConfigurationDocument(source: source)
            let projection = try LegacyConfigurationProjection(document: original)
            let firstSave = try projection.applying(to: original)
            let reparsed = try LegacyConfigurationProjection(document: firstSave)
            let secondSave = try reparsed.applying(to: firstSave)

            XCTAssertEqual(firstSave.serialized(), secondSave.serialized(), "iteration \(iteration)")
            XCTAssertEqual(firstSave.value(at: ["FutureRoot_\(iteration)"]), token)
            XCTAssertEqual(
                firstSave.value(at: ["Connections", "Shortcuts", "World_\(iteration)", "FutureServer"]),
                token
            )
            XCTAssertEqual(
                firstSave.value(at: ["Connections", "Shortcuts", "World_\(iteration)", "Characters", "Hero", "FutureCharacter"]),
                token
            )
        }
    }

    func testTargetedReplacementPreservesUnknownText() throws {
        var document = try LegacyConfigurationDocument(source: fixture)
        try document.setValue("example.org:1234", at: ["Connections", "Shortcuts", "LambdaMOO", "Host"])
        XCTAssertTrue(document.serialized().contains("Host=\"example.org:1234\""))
        XCTAssertTrue(document.serialized().contains("// Keep this comment byte-for-byte"))
        XCTAssertTrue(document.serialized().contains("Unknown.Future.Value=\"preserve me\""))
    }

    func testCollectionEntryRemovalSupportsBlocksAndDottedShorthand() throws {
        let source = """
        Connections {
          Shortcuts {
            Keep { Host="keep.example:1" Future="untouched" }
            Remove {
              Host="remove.example:2"
            }
          }
        }
        Characters {
          Guest.Connect="connect guest"
          Guest.Future="legacy extension"
          Keep.Connect="connect keep"
        }
        Unknown="preserve me"
        """
        var document = try LegacyConfigurationDocument(source: source)

        XCTAssertTrue(try document.removeCollectionEntry(
            named: "Remove",
            at: ["Connections", "Shortcuts"]
        ))
        XCTAssertTrue(try document.removeCollectionEntry(named: "Guest", at: ["Characters"]))
        XCTAssertFalse(try document.removeCollectionEntry(named: "Missing", at: ["Characters"]))

        let serialized = document.serialized()
        XCTAssertFalse(serialized.contains("remove.example"))
        XCTAssertFalse(serialized.contains("Guest."))
        XCTAssertTrue(serialized.contains("Keep { Host=\"keep.example:1\" Future=\"untouched\" }"))
        XCTAssertTrue(serialized.contains("Keep.Connect=\"connect keep\""))
        XCTAssertTrue(serialized.contains("Unknown=\"preserve me\""))
    }

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

    func testProjectionLoadsKeyboardMacrosAtEveryConnectionScope() throws {
        let source = """
        Version=331
        Connections {
          KeyboardMacros2 { Active=true { Macro="global" key=Control+G } }
          Shortcuts {
            World {
              Host="example.test:8888"
              KeyboardMacros2 { { Macro="server" key=Control+G } }
              Characters {
                Hero { KeyboardMacros2 { { Folder=true KeyboardMacros2 { { Macro="character" key=Control+G Type=true } } } } }
              }
            }
          }
        }
        """
        let projection = try LegacyConfigurationProjection(document: .init(source: source))
        let server = try XCTUnwrap(projection.servers.first)
        let character = try XCTUnwrap(server.characters.first)
        let macro = KeyboardMacroEngine.macro(
            for: "Control+G",
            groups: projection.macroGroups(for: server.profile, character: character)
        )

        XCTAssertEqual(macro?.macro, "character")
        XCTAssertTrue(macro?.typeIntoInput == true)
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

    func testProjectionLoadsWindowsLoggingDefaultsAndCharacterAutolog() throws {
        let source = """
        Version=331
        Connections {
          Logging.DefaultLogFileName="Logs/%server%-%character%.html"
          Logging.Path="~/Shared Logs"
          Logging.FileDateFormat="yyyy-MM-dd"
          Logging.LogSent=true
          Logging.SentPrefix="S>"
          Logging.LogTyped=true
          Logging.TypedPrefix="T>"
          Logging.TimeFormat=14
          Logging.Wrap=true
          Logging.WrapChars=72
          Logging.HangingIndent=true
          Logging.HangingIndentChars=4
          Logging.DoubleSpace=true
          Shortcuts {
            World { Host="example.test:8888" Characters { Hero { LogFileName="Hero.html" LogFileNameTimeFormat=2 } } }
          }
        }
        """
        let projection = try LegacyConfigurationProjection(document: .init(source: source))
        let server = try XCTUnwrap(projection.servers.first)
        let character = try XCTUnwrap(server.characters.first)

        XCTAssertEqual(projection.logging.defaultLogFilename, "Logs/%server%-%character%.html")
        XCTAssertEqual(projection.loggingPath, "~/Shared Logs")
        XCTAssertTrue(projection.logging.logsSentText)
        XCTAssertTrue(projection.logging.logsTypedText)
        XCTAssertTrue(projection.logging.includesTime)
        XCTAssertTrue(projection.logging.includesDate)
        XCTAssertTrue(projection.logging.uses24HourTime)
        XCTAssertEqual(projection.logging.wrapWidth, 72)
        XCTAssertEqual(projection.logging.hangingIndent, 4)
        XCTAssertTrue(projection.logging.doubleSpaces)
        XCTAssertEqual(
            projection.automaticLog(for: server.profile, character: character)?.filename,
            "Hero.html"
        )
        XCTAssertTrue(projection.automaticLog(for: server.profile, character: character)?.appendsDate == true)
    }

    func testMilestone4SourcePinnedAutomationFixtureProjectsEndToEnd() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/milestone4-automation-config.txt")
        let source = try String(contentsOf: url, encoding: .utf8)
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

    func testPhase5TriggerCorpusProjectsEveryScopeAndStandardTriggerField() throws {
        let source = try String(contentsOf: Self.fixtureURL("trigger-parity-v331-corpus.txt"), encoding: .utf8)
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

    func testPhase5TriggerCorpusEditsSavesReparsesAndPreservesInteropPayloads() throws {
        let source = try String(contentsOf: Self.fixtureURL("trigger-parity-v331-corpus.txt"), encoding: .utf8)
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
        XCTAssertTrue(serialized.contains("// Phase 5 trigger interoperability corpus"))
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

    func testPuppetAutomationAndAIProfileRoundTrip() throws {
        let source = """
        Version=331
        Connections {
          Shortcuts {
            World {
              Host="example.test:8888"
              AIEndpoint="https://ai.example.test/generate"
              AIModel="test-model"
              Characters {
                Hero {
                  Variables { mood="quiet" }
                  Puppets {
                    Scout {
                      ReceivePrefix="[Scout] "
                      SendPrefix="scout "
                      Aliases { Active=true { FindString { MatchText="north" } Replace="scout north" } }
                      KeyboardMacros2 { Active=true { Macro="inventory" key=F1 } }
                      Variables { mood="scouting" }
                    }
                  }
                }
              }
            }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))
        let server = try XCTUnwrap(workspace.servers.first)
        let character = try XCTUnwrap(server.characters.first)
        let puppet = try XCTUnwrap(character.puppets.first)
        XCTAssertEqual(server.profile.aiEndpoint?.absoluteString, "https://ai.example.test/generate")
        XCTAssertEqual(server.profile.aiModel, "test-model")

        let groups = workspace.projection.automationGroups(for: server.profile, character: character, puppet: puppet)
        XCTAssertEqual(try AliasEngine.process("north", groups: groups.aliases, variables: [:]).text, "scout north")
        XCTAssertEqual(workspace.projection.variables(for: server.profile, character: character, puppet: puppet)["mood"], "scouting")
        XCTAssertEqual(workspace.projection.macroGroups(for: server.profile, character: character, puppet: puppet).first?.macros.first?.macro, "inventory")

        _ = try workspace.addAlias(
            in: .puppet(server: server.profile.id, character: character.id, puppet: puppet.id),
            description: "South",
            match: .init(text: "south"),
            replacement: "scout south"
        )
        let rendered = try workspace.renderedDocument().serialized()
        XCTAssertTrue(rendered.contains("scout south"))
        XCTAssertTrue(rendered.contains("AIEndpoint=\"https://ai.example.test/generate\""))

        try workspace.updateServer(id: try XCTUnwrap(workspace.servers.first?.profile.id)) {
            $0.profile.aiEndpoint = nil
            $0.profile.aiModel = ""
        }
        let cleared = try workspace.renderedDocument()
        let reloaded = try LegacyConfigurationProjection(document: cleared)
        XCTAssertNil(reloaded.servers.first?.profile.aiEndpoint)
        XCTAssertEqual(reloaded.servers.first?.profile.aiModel, "")
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

    func testTypedProjectionUsesWindowsDefaultsAndPortableSettings() throws {
        let source = """
        Version=331
        TCP_KeepAlive=false
        ScriptStartup="scripts/start.js"
        ScriptDebug=true
        Connections {
          ConnectTimeout=12000
          ConnectRetry=3
          RetryForever=true
          Shortcuts {
            Secure {
              Host="[::1]:7777"
              Encoding=UTF8
              TLS=true
              VerifyCertificate=true
              IPV4=false
              Pueblo=true
              MCP=true
              MCMP=true
              GMCP_WebView=1
              NAWSOnResize=true
              LimitTelnetCharset=true
              Characters {
                User {
                  Connect="connect User %PASSWORD%"
                  Password="s\\\"ecret"
                  IdleEnabled=true
                  IdleTimeout=90
                  IdleString="idle"
                  Variables { Theme="dark" }
                  Puppets {
                    Helper {
                      ReceivePrefix="Helper> "
                      SendPrefix="tell Helper "
                      RegularExpression=false
                      ConnectWithPlayer=true
                    }
                  }
                }
              }
            }
          }
        }
        """
        let projection = try LegacyConfigurationProjection(
            document: LegacyConfigurationDocument(source: source)
        )

        XCTAssertEqual(projection.settings.connectTimeoutMilliseconds, 12_000)
        XCTAssertEqual(projection.settings.connectRetryCount, 3)
        XCTAssertTrue(projection.settings.retryForever)
        XCTAssertFalse(projection.settings.tcpKeepAlive)
        XCTAssertTrue(projection.settings.tcpNoDelay)
        XCTAssertEqual(projection.scripting.startupPath, "scripts/start.js")
        XCTAssertTrue(projection.scripting.debugEnabled)
        let server = try XCTUnwrap(projection.servers.first)
        XCTAssertEqual(server.profile.host, "::1")
        XCTAssertEqual(server.profile.port, 7777)
        XCTAssertEqual(server.profile.encoding, .utf8)
        XCTAssertTrue(server.profile.usesTLS)
        XCTAssertTrue(server.profile.verifiesCertificate)
        XCTAssertTrue(server.profile.pueblo)
        XCTAssertTrue(server.profile.mcp)
        XCTAssertTrue(server.profile.mcmp)
        XCTAssertEqual(server.profile.gmcpWebViewPolicy, .allow)
        XCTAssertTrue(server.profile.sendNAWSOnResize)
        XCTAssertTrue(server.profile.limitTelnetCharset)
        let character = try XCTUnwrap(server.characters.first)
        XCTAssertEqual(character.password, "s\"ecret")
        XCTAssertEqual(character.idleTimeout, 90 * 60)
        XCTAssertEqual(character.variables, ["Theme": "dark"])
        XCTAssertEqual(character.puppets.first?.name, "Helper")
        XCTAssertEqual(character.puppets.first?.sendPrefix, "tell Helper ")
        XCTAssertTrue(character.puppets.first?.connectWithPlayer == true)
        XCTAssertEqual(projection.connectionPolicy.connectTimeoutMilliseconds, 12_000)
        XCTAssertEqual(projection.connectionPolicy.retryCount, 3)
        XCTAssertFalse(projection.connectionPolicy.keepAlive)
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

    func testWorkspaceEditsNestedTriggersByPathAndPreservesUnknownChildFields() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            Active=true
            { Description="Parent" FindString { MatchText="parent" }
              Triggers {
                Active=true
                { Description="Child" UnknownChild="keep me" FindString { MatchText="child" }
                  Send { Active=true Send="old" }
                }
              }
            }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))
        let updatedChild = Trigger(
            description: "Updated Child",
            match: .init(text: "child ([0-9]+)", isRegularExpression: true),
            actions: [.send("score $1", captureIndex: 1, expandVariables: true)]
        )

        try workspace.updateTrigger(at: [0, 0], in: .global, trigger: updatedChild)
        let rendered = try workspace.renderedDocument()
        let serialized = rendered.serialized()
        let reloaded = try LegacyConfigurationProjection(document: rendered)
        let child = try XCTUnwrap(reloaded.automation.triggers.triggers.first?.children.first)

        XCTAssertTrue(serialized.contains("UnknownChild=\"keep me\""))
        XCTAssertEqual(child.description, "Updated Child")
        XCTAssertEqual(child.match.text, "child ([0-9]+)")
        XCTAssertEqual(child.actions, [.send("score $1", captureIndex: 1, expandVariables: true)])
    }

    func testWorkspaceAddsAndRemovesNestedTriggersByPath() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            Active=true
            { Description="Parent" FindString { MatchText="parent" } }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))

        let addedPath = try workspace.addTrigger(
            in: .global,
            parentPath: [0],
            trigger: Trigger(description: "Child", match: .init(text: "child"), actions: [.gag(display: true, log: false)])
        )
        XCTAssertEqual(addedPath, [0, 0])
        XCTAssertEqual(workspace.trigger(at: [0, 0], in: .global)?.description, "Child")

        try workspace.removeTrigger(at: [0, 0], in: .global)
        XCTAssertTrue(workspace.triggers(in: .global).first?.children.isEmpty == true)
    }

    func testWorkspaceMovesTriggersWithinAndAcrossNestedParentsPreservingUnknownFields() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            Active=true
            { Description="First" FutureFirst="keep first" FindString { MatchText="first" } }
            { Description="Folder" Folder=true FindString { MatchText="folder" }
              Triggers {
                Active=true
                { Description="Child" FutureChild="keep child" FindString { MatchText="child" } }
              }
            }
            { Description="Third" FutureThird="keep third" FindString { MatchText="third" } }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))

        let reorderedPath = try workspace.moveTrigger(at: [2], in: .global, toParentPath: [], index: 0)
        XCTAssertEqual(reorderedPath, [0])
        XCTAssertEqual(workspace.triggers(in: .global).map(\.description), ["Third", "First", "Folder"])

        let nestedPath = try workspace.moveTrigger(at: [1], in: .global, toParentPath: [2], index: 1)
        XCTAssertEqual(nestedPath, [1, 1])
        XCTAssertEqual(workspace.triggers(in: .global).map(\.description), ["Third", "Folder"])
        XCTAssertEqual(workspace.trigger(at: [1], in: .global)?.children.map(\.description), ["Child", "First"])

        let outdentedPath = try workspace.moveTrigger(at: [1, 0], in: .global, toParentPath: [], index: 2)
        XCTAssertEqual(outdentedPath, [2])
        XCTAssertEqual(workspace.triggers(in: .global).map(\.description), ["Third", "Folder", "Child"])
        XCTAssertEqual(workspace.trigger(at: [1], in: .global)?.children.map(\.description), ["First"])

        let serialized = (try workspace.renderedDocument()).serialized()
        XCTAssertTrue(serialized.contains("FutureFirst=\"keep first\""))
        XCTAssertTrue(serialized.contains("FutureChild=\"keep child\""))
        XCTAssertTrue(serialized.contains("FutureThird=\"keep third\""))
    }

    func testWorkspaceRejectsMovingTriggerIntoItsOwnDescendant() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            { Description="Parent" FindString { MatchText="parent" }
              Triggers { { Description="Child" FindString { MatchText="child" } } }
            }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))

        XCTAssertThrowsError(try workspace.moveTrigger(at: [0], in: .global, toParentPath: [0, 0], index: 0)) {
            XCTAssertEqual(
                $0 as? LegacyConfigurationWorkspace.WorkspaceError,
                .automationEntryNotFound
            )
        }
    }

    func testWorkspaceUpdatesTriggerGroupActiveAndAfterCount() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            Active=true
            AfterCount=1
            { Description="One" FindString { MatchText="one" } }
            { Description="Two" FindString { MatchText="two" } }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))

        try workspace.updateTriggerGroupSettings(in: .global, active: false, afterCount: 2)
        let rendered = try workspace.renderedDocument()
        let reloaded = try LegacyConfigurationProjection(document: rendered)

        XCTAssertFalse(reloaded.automation.triggers.active)
        XCTAssertEqual(reloaded.automation.triggers.afterCount, 2)
        XCTAssertTrue(rendered.serialized().contains("Active=false"))
        XCTAssertTrue(rendered.serialized().contains("AfterCount=2"))
    }

    func testWorkspaceReadsAndWritesTriggerFolderFlag() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            Active=true
            { Description="Container" Folder=true FindString { MatchText="" }
              Triggers { Active=true { Description="Child" FindString { MatchText="child" } } }
            }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))
        var folder = try XCTUnwrap(workspace.trigger(at: [0], in: .global))

        XCTAssertTrue(folder.folder)
        folder.folder = false
        try workspace.updateTrigger(at: [0], in: .global, trigger: folder)
        XCTAssertFalse(workspace.trigger(at: [0], in: .global)?.folder == true)
        XCTAssertTrue((try workspace.renderedDocument()).serialized().contains("Folder=false"))
    }

    func testWorkspaceWritesNestedChildrenWhenAddingFullTriggerTree() throws {
        var workspace = try LegacyConfigurationWorkspace.empty()
        let parent = Trigger(
            description: "Parent",
            match: .init(text: "parent"),
            actions: [.activity(important: false)],
            children: [
                Trigger(description: "Child", match: .init(text: "child"), actions: [.gag(display: true, log: true)]),
            ]
        )

        try workspace.addTrigger(in: .global, trigger: parent)
        let rendered = try workspace.renderedDocument()
        let reloaded = try LegacyConfigurationProjection(document: rendered)

        XCTAssertEqual(reloaded.automation.triggers.triggers.first?.children.first?.description, "Child")
        XCTAssertEqual(reloaded.automation.triggers.triggers.first?.children.first?.actions, [.gag(display: true, log: true)])
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

    func testScriptingStartupPathWritesBackLosslessly() throws {
        let source = """
        Version=331
        ScriptStartup="old.js"
        Connections { Shortcuts { } }
        Future="keep"
        """
        let document = try LegacyConfigurationDocument(source: source)
        var projection = try LegacyConfigurationProjection(document: document)
        projection.scripting.startupPath = "scripts/startup.js"
        projection.scripting.debugEnabled = true

        let updated = try projection.applying(to: document)

        XCTAssertEqual(updated.value(at: ["ScriptStartup"]), "scripts/startup.js")
        XCTAssertEqual(updated.value(at: ["ScriptDebug"]), "true")
        XCTAssertEqual(updated.value(at: ["Future"]), "keep")
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

    func testTypedProjectionRefusesNewerWindowsConfigurationVersions() throws {
        let document = try LegacyConfigurationDocument(source: "Version=999\nConnections { Shortcuts {} }\n")
        XCTAssertThrowsError(try LegacyConfigurationProjection(document: document)) { error in
            XCTAssertEqual(
                error as? LegacyConfigurationProjection.ProjectionError,
                .newerConfiguration(found: 999, supported: 331)
            )
        }
    }

    func testPre261PortableMigrationsMatchWindowsVersionGates() throws {
        let source = """
        Version=214
        Connections {
          Shortcuts {
            Legacy {
              Host="legacy.example"
              Port=7777
              Name="The Legacy World"
              Info="existing"
              Client={11111111-2222-3333-4444-555555555555}
              Characters {
                Hero {
                  Name="Sir Hero"
                  Connect="connect hero"
                }
              }
            }
          }
        }
        """
        let document = try LegacyConfigurationDocument(source: source)
        let projection = try LegacyConfigurationProjection(document: document)
        let server = try XCTUnwrap(projection.servers.first)
        XCTAssertEqual(server.profile.host, "legacy.example")
        XCTAssertEqual(server.profile.port, 7777)
        XCTAssertTrue(server.profile.usesTLS)

        let migrated = try projection.applying(to: document)
        XCTAssertEqual(migrated.value(at: ["Version"]), "331")
        XCTAssertEqual(migrated.value(at: ["Connections", "Shortcuts", "Legacy", "Host"]), "legacy.example:7777")
        XCTAssertEqual(migrated.value(at: ["Connections", "Shortcuts", "Legacy", "TLS"]), "true")
        XCTAssertEqual(migrated.value(at: ["Connections", "Shortcuts", "Legacy", "Info"]), "existing\r\nName:The Legacy World")
        XCTAssertEqual(
            migrated.value(at: ["Connections", "Shortcuts", "Legacy", "Characters", "Hero", "Info"]),
            "Name:Sir Hero"
        )
        XCTAssertTrue(migrated.serialized().contains("Client={11111111-2222-3333-4444-555555555555}"))
    }

    func testV265DottedCharacterShorthandProjectsAndMigratesWithoutLoss() throws {
        let source = """
        Version=265
        Connections
        {
          Shortcuts
          {
            LambdaMOO
            {
              Host="lambda.moo.mud.org:8888"
              Characters
              {
                Guest.Connect="connect guest"
                Guest.ConnectAtStartup=true
              }
            }
          }
        }
        """
        let document = try LegacyConfigurationDocument(source: source)
        var projection = try LegacyConfigurationProjection(document: document)
        XCTAssertEqual(projection.servers[0].characters.map(\.name), ["Guest"])
        XCTAssertEqual(projection.servers[0].characters[0].connectText, "connect guest")
        XCTAssertTrue(projection.servers[0].characters[0].autoConnect)

        projection.servers[0].characters[0].password = "portable secret"
        let migrated = try projection.applying(to: document)
        XCTAssertEqual(
            migrated.value(at: ["Connections", "Shortcuts", "LambdaMOO", "Characters", "Guest", "Connect"]),
            "connect guest"
        )
        XCTAssertEqual(
            migrated.value(at: ["Connections", "Shortcuts", "LambdaMOO", "Characters", "Guest", "Password"]),
            "portable secret"
        )
        XCTAssertTrue(migrated.serialized().contains("Guest.Connect=\"connect guest\""))
        XCTAssertTrue(migrated.serialized().contains("Guest\n        {"))
        let reparsed = try LegacyConfigurationProjection(document: migrated)
        XCTAssertEqual(reparsed.servers[0].characters.count, 1)
        XCTAssertEqual(reparsed.servers[0].characters[0].password, "portable secret")
    }

    func testProjectionDeletionRemovesOnlySelectedProfilesAndPreservesExtensions() throws {
        let source = """
        Version=331
        Connections {
          Shortcuts {
            Keep {
              Host="keep.example:1"
              FutureServerField="preserve"
              Characters {
                KeepChar {
                  Connect="keep"
                  FutureCharacterField="preserve"
                  Puppets {
                    KeepPuppet { ReceivePrefix="keep> " FuturePuppetField="preserve" }
                    RemovePuppet { ReceivePrefix="remove> " }
                  }
                }
                RemoveChar.Connect="remove"
                RemoveChar.Future="remove with profile"
              }
            }
            Remove { Host="remove.example:2" }
          }
        }
        WindowsOnly="untouched"
        """
        let document = try LegacyConfigurationDocument(source: source)
        var projection = try LegacyConfigurationProjection(document: document)
        projection.servers.removeAll { $0.profile.name == "Remove" }
        projection.servers[0].characters.removeAll { $0.name == "RemoveChar" }
        projection.servers[0].characters[0].puppets.removeAll { $0.name == "RemovePuppet" }

        let saved = try projection.applying(to: document)
        let serialized = saved.serialized()
        XCTAssertFalse(serialized.contains("remove.example"))
        XCTAssertFalse(serialized.contains("RemoveChar"))
        XCTAssertFalse(serialized.contains("RemovePuppet"))
        XCTAssertTrue(serialized.contains("FutureServerField=\"preserve\""))
        XCTAssertTrue(serialized.contains("FutureCharacterField=\"preserve\""))
        XCTAssertTrue(serialized.contains("FuturePuppetField=\"preserve\""))
        XCTAssertTrue(serialized.contains("WindowsOnly=\"untouched\""))
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

    func testEditableConfigurationWorkspaceAddsRenamesAndRemovesProfiles() throws {
        let source = """
        Version=331
        Connections {
          Shortcuts {
            Existing {
              Host="existing.example:7777"
              WindowsOnly="preserve"
              Characters { Hero { Connect="connect hero" } }
            }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(
            document: LegacyConfigurationDocument(source: source)
        )
        let existingID = try XCTUnwrap(workspace.servers.first?.profile.id)
        let newID = workspace.addServer(named: "Existing")
        XCTAssertEqual(workspace.servers.map(\.profile.name), ["Existing", "Existing 2"])
        XCTAssertEqual(workspace.servers.last?.profile.encoding, .utf8)

        try workspace.updateServer(id: newID) {
            $0.profile.name = "New World"
            $0.profile.host = "new.example"
            $0.profile.port = 4321
            $0.profile.usesTLS = true
        }
        let characterID = try workspace.addCharacter(toServerID: newID, named: "Player")
        try workspace.updateCharacter(id: characterID, inServerID: newID) {
            $0.connectText = "connect player"
            $0.info = "Primary character"
            $0.autoConnect = true
            $0.logFilename = "logs/player.html"
            $0.logAppendsDate = true
        }
        let puppetID = try workspace.addPuppet(
            toCharacterID: characterID,
            inServerID: newID,
            named: "Helper"
        )
        try workspace.updatePuppet(
            id: puppetID,
            inCharacterID: characterID,
            serverID: newID
        ) {
            $0.receivePrefix = "Helper> "
            $0.sendPrefix = "tell Helper "
        }
        try workspace.removeServer(id: existingID)

        XCTAssertTrue(workspace.isDirty)
        let rendered = try workspace.renderedDocument()
        let reparsed = try LegacyConfigurationProjection(document: rendered)
        XCTAssertEqual(reparsed.servers.map(\.profile.name), ["New World"])
        XCTAssertEqual(reparsed.servers[0].profile.host, "new.example")
        XCTAssertEqual(reparsed.servers[0].characters[0].connectText, "connect player")
        XCTAssertEqual(reparsed.servers[0].characters[0].info, "Primary character")
        XCTAssertEqual(reparsed.servers[0].characters[0].logFilename, "logs/player.html")
        XCTAssertTrue(reparsed.servers[0].characters[0].logAppendsDate)
        XCTAssertEqual(reparsed.servers[0].characters[0].puppets[0].sendPrefix, "tell Helper ")
        XCTAssertFalse(rendered.serialized().contains("WindowsOnly=\"preserve\""))

        let destination = URL(fileURLWithPath: "/tmp/Config.txt")
        workspace.acceptSavedDocument(rendered, at: destination)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(workspace.sourceURL, destination)
    }

    func testEditableConfigurationWorkspaceRejectsDuplicateSiblingNames() throws {
        var workspace = try LegacyConfigurationWorkspace.empty()
        let first = workspace.addServer(named: "Alpha")
        let second = workspace.addServer(named: "Beta")

        XCTAssertThrowsError(try workspace.updateServer(id: second) { $0.profile.name = "alpha" }) {
            XCTAssertEqual(
                $0 as? LegacyConfigurationWorkspace.WorkspaceError,
                .duplicateName("alpha")
            )
        }
        XCTAssertEqual(workspace.servers.first { $0.profile.id == first }?.profile.name, "Alpha")
        XCTAssertEqual(workspace.servers.first { $0.profile.id == second }?.profile.name, "Beta")
    }

    func testEditableConfigurationWorkspaceUpdatesStartupScript() throws {
        var workspace = try LegacyConfigurationWorkspace.empty()
        workspace.updateScripting { $0.startupPath = "Scripts/startup.js" }

        XCTAssertTrue(workspace.isDirty)
        let rendered = try workspace.renderedDocument()
        XCTAssertEqual(try LegacyConfigurationProjection(document: rendered).scripting.startupPath, "Scripts/startup.js")
    }

    func testUnnamedCollectionEntriesCanBeEditedWithoutRewritingNeighbors() throws {
        var document = try LegacyConfigurationDocument(source: """
        Connections {
          Aliases {
            // retained comment
            { FindString { MatchText="north" } Replace="n" WindowsOnly="keep" }
          }
        }
        """)
        try document.upsertValue("northward", inUnnamedBlockAt: 0, collectionPath: ["Connections", "Aliases"], relativePath: ["Replace"])
        let newIndex = try document.appendUnnamedBlock(at: ["Connections", "Aliases"])
        try document.upsertValue("south", inUnnamedBlockAt: newIndex, collectionPath: ["Connections", "Aliases"], relativePath: ["FindString", "MatchText"])
        try document.upsertValue("s", inUnnamedBlockAt: newIndex, collectionPath: ["Connections", "Aliases"], relativePath: ["Replace"])
        XCTAssertTrue(try document.removeUnnamedBlock(at: newIndex, collectionPath: ["Connections", "Aliases"]))

        let serialized = document.serialized()
        XCTAssertTrue(serialized.contains("// retained comment"))
        XCTAssertTrue(serialized.contains("MatchText=\"north\""))
        XCTAssertTrue(serialized.contains("Replace=\"northward\""))
        XCTAssertTrue(serialized.contains("WindowsOnly=\"keep\""))
        XCTAssertFalse(serialized.contains("MatchText=\"south\""))
    }

    func testEditableWorkspaceAddsUpdatesAndRemovesGlobalAutomation() throws {
        var workspace = try LegacyConfigurationWorkspace.empty()
        let alias = try workspace.addGlobalAlias(
            description: "Go north",
            match: .init(text: "n", startsWith: true),
            replacement: "north"
        )
        let trigger = try workspace.addGlobalTrigger(
            description: "Score",
            match: .init(text: "score", matchCase: true),
            action: .send("score")
        )
        let macro = try workspace.addGlobalMacro(
            description: "Quick score",
            key: "Control+Alt+S",
            macro: "score",
            typeIntoInput: true
        )
        try workspace.updateGlobalAlias(
            at: alias,
            description: "Go south",
            match: .init(text: "s", startsWith: true),
            replacement: "south"
        )
        try workspace.updateGlobalTrigger(
            at: trigger,
            description: "Hide score",
            match: .init(text: "score"),
            action: .gag(display: true, log: true)
        )

        XCTAssertEqual(workspace.globalAliases.map(\.description), ["Go south"])
        XCTAssertEqual(workspace.globalAliases.first?.replacement, "south")
        XCTAssertEqual(workspace.globalTriggers.map(\.description), ["Hide score"])
        XCTAssertTrue(workspace.globalTriggers.first?.actions.contains(.gag(display: true, log: true)) == true)
        XCTAssertEqual(workspace.globalMacros.first?.macro, "score")
        XCTAssertTrue(workspace.globalMacros.first?.typeIntoInput == true)

        try workspace.removeGlobalAlias(at: alias)
        try workspace.removeGlobalTrigger(at: trigger)
        try workspace.removeGlobalMacro(at: macro)
        XCTAssertTrue(workspace.globalAliases.isEmpty)
        XCTAssertTrue(workspace.globalTriggers.isEmpty)
        XCTAssertTrue(workspace.globalMacros.isEmpty)
    }

    func testKeyboardMacroNestedCRUDMovesAndRawImportExport() throws {
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: """
        Version=331
        Connections {
          KeyboardMacros2 { Active=true
            // retained macro comment
            { Description="Folder" Folder=true Custom="keep"
              KeyboardMacros2 { Active=true
                { Description="Child" Macro="north" key=?Control+Alt+N Type=true Unknown="keep" }
              }
            }
            { Description="Second" Macro="south" key=F1 }
          }
        }
        """))

        XCTAssertEqual(workspace.macro(at: [0, 0], in: .global)?.macro, "north")
        var copied = try workspace.copyMacro(
            at: [0, 0],
            in: .global,
            to: .global,
            parentPath: [],
            index: 2
        )
        XCTAssertEqual(copied, [2])
        copied = try workspace.moveMacro(
            at: [1],
            in: .global,
            to: .global,
            parentPath: [0],
            index: 1
        )
        XCTAssertEqual(copied, [0, 1])
        var edited = try XCTUnwrap(workspace.macro(at: [0, 0], in: .global))
        edited.description = "Edited"
        edited.macro = "east"
        edited.key = "Control+E"
        try workspace.updateMacro(at: [0, 0], in: .global, macro: edited)
        XCTAssertEqual(workspace.macro(at: [0, 0], in: .global)?.description, "Edited")
        let rendered = try workspace.renderedDocument().serialized()
        XCTAssertTrue(rendered.contains("retained macro comment"))
        XCTAssertTrue(rendered.contains("Custom=\"keep\""))
        XCTAssertTrue(rendered.contains("Unknown=\"keep\""))

        let imported = try LegacyConfigurationDocument(source: """
        Version=331
        Connections {
          Shortcuts { World { KeyboardMacros2 {
            { Description="Imported" Macro="west" key=NumPad4 Vendor="preserve" }
          } } }
        }
        """)
        XCTAssertEqual(try workspace.importMacros(from: imported, into: .global), 1)
        XCTAssertEqual(workspace.globalMacros.last?.description, "Imported")
        let exported = try workspace.exportMacros(in: .global, path: [2])
        XCTAssertTrue(exported.serialized().contains("Vendor=\"preserve\""))
    }

    func testAliasWindowsFieldsAndNestedCRUDPreserveUnknownPayloads() throws {
        let source = """
        Version=331
        Connections {
          Aliases {
            Active=true Echo=false ProcessCommands=true AfterCount=1
            { Description="First" Example="go north" Replace="north" Custom="keep"
              FindString { MatchText="go" RegularExpression=false }
            }
            { Description="Folder" Folder=true FindString.MatchText=""
              Aliases { Active=true AfterCount=1
                { Description="Child" Example="x" Replace="y" UnknownChild="keep"
                  FindString { MatchText="x" } }
              }
            }
          }
          Shortcuts {
            World {
              Host="world.example:8888"
              Aliases { Active=true { Description="World alias" Replace="world" FindString.MatchText="w" } }
            }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))
        XCTAssertEqual(workspace.aliasGroup(in: .global).afterCount, 1)
        XCTAssertFalse(workspace.aliasGroup(in: .global).echo)
        XCTAssertTrue(workspace.alias(at: [1], in: .global)?.folder == true)
        XCTAssertEqual(workspace.alias(at: [1, 0], in: .global)?.example, "x")
        let first = try XCTUnwrap(workspace.alias(at: [0], in: .global))
        var updated = first
        updated.example = "updated"
        updated.replacement = "northward"
        try workspace.updateAlias(at: [0], in: .global, alias: updated)
        XCTAssertTrue(try workspace.renderedDocument().serialized().contains("Custom=\"keep\""))

        let added = try workspace.addAlias(
            in: .global,
            parentPath: [1],
            alias: .init(description: "Added", match: .init(text: "a"), replacement: "b")
        )
        XCTAssertEqual(workspace.alias(at: added, in: .global)?.description, "Added")
        _ = try workspace.copyAlias(at: [1, 0], in: .global)
        XCTAssertEqual(workspace.alias(at: [1], in: .global)?.children.count, 3)
        _ = try workspace.removeAlias(at: added, in: .global)
        XCTAssertEqual(workspace.alias(at: [1], in: .global)?.children.count, 2)
        XCTAssertTrue(try workspace.renderedDocument().serialized().contains("UnknownChild=\"keep\""))

        let world = try XCTUnwrap(workspace.servers.first)
        _ = try workspace.moveAlias(at: [0], in: .global, to: .server(world.profile.id), toParentPath: [], index: 0)
        XCTAssertEqual(workspace.aliases(in: .global).count, 1)
        XCTAssertEqual(workspace.aliases(in: .server(world.profile.id)).first?.description, "First")
        XCTAssertTrue(try workspace.renderedDocument().serialized().contains("Custom=\"keep\""))
    }

    func testAliasScopeOrderingAndImportExportRoundTrip() throws {
        let source = """
        Version=331
        Connections {
          Aliases { Active=true AfterCount=1
            { Description="Global pre" FindString.MatchText="global-pre" }
            { Description="Global post" FindString.MatchText="global-post" }
          }
          Shortcuts {
            World {
              Host="world.example:8888"
              Aliases { Active=true AfterCount=1
                { Description="World pre" FindString.MatchText="world-pre" }
                { Description="World post" FindString.MatchText="world-post" }
              }
              Characters {
                Hero {
                  Aliases { Active=true { Description="Character" FindString.MatchText="character" } }
                  Puppets {
                    Scout { Aliases { Active=true { Description="Puppet" FindString.MatchText="puppet" } } }
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
        let groups = projection.automationGroups(
            for: server.profile,
            character: character,
            puppet: puppet
        )
        XCTAssertEqual(
            groups.aliases.flatMap(\AliasGroup.aliases).map(\.description),
            ["Global pre", "World pre", "Character", "Puppet", "World post", "Global post"]
        )

        let importSource = try LegacyConfigurationDocument(source: """
        Version=331
        Connections {
          Aliases { Active=true
            { Description="Imported folder" Folder=true FindString.MatchText=""
              Aliases { { Description="Imported child" Example="test" Replace="done" FindString.MatchText="test" } }
            }
          }
        }
        """)
        var target = try LegacyConfigurationWorkspace.empty()
        XCTAssertEqual(try target.importAliases(from: importSource, into: .global), [[0]])
        let exported = try target.exportAliases(in: .global, path: [0])
        let reparsed = try LegacyConfigurationProjection(document: exported)
        XCTAssertEqual(reparsed.automation.aliases.aliases.first?.description, "Imported folder")
        XCTAssertEqual(reparsed.automation.aliases.aliases.first?.children.first?.example, "test")
    }

    func testAliasExampleCodableRemainsBackwardCompatible() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "description": "Legacy",
          "match": {
            "text": "old",
            "isRegularExpression": false,
            "matchCase": false,
            "startsWith": false,
            "endsWith": false,
            "wholeWord": false
          },
          "replacement": "new",
          "folder": false,
          "stopProcessing": false,
          "expandVariables": false,
          "children": []
        }
        """
        let alias = try JSONDecoder().decode(Alias.self, from: Data(json.utf8))
        XCTAssertEqual(alias.example, "")
    }

    func testStartupConnectionsUseAutoConnectCharactersAndGlobalPolicy() throws {
        let document = try LegacyConfigurationDocument(source: """
        Version=331
        Connections {
          ConnectTimeout=4000
          ConnectRetry=2
          Shortcuts {
            One { Host="one.test:1111" Characters { A { ConnectAtStartup=true } B { ConnectAtStartup=false } } }
            Two { Host="two.test:2222" Characters { C { ConnectAtStartup=true } } }
          }
        }
        """)
        let projection = try LegacyConfigurationProjection(document: document)
        let requests = projection.startupConnections()
        XCTAssertEqual(requests.map { $0.character?.name }, ["A", "C"])
        XCTAssertEqual(requests.map { $0.server.port }, [1111, 2222])
        XCTAssertTrue(requests.allSatisfy { $0.policy.connectTimeoutMilliseconds == 4_000 && $0.policy.retryCount == 2 })
    }

    func testTypedWritebackUpdatesPortableFieldsAndPreservesUnknownWindowsData() throws {
        let source = """
        // preserved header
        Version=214
        Windows { Position=(1,2,3,4) Future="untouched" }
        Connections {
          Shortcuts {
            Legacy {
              Host="old.example"
              Port=7777
              Characters { User { Connect="old" UnknownCharacter=42 } }
              UnknownServer="keep"
            }
          }
        }
        """
        let document = try LegacyConfigurationDocument(source: source)
        var projection = try LegacyConfigurationProjection(document: document)
        XCTAssertEqual(projection.servers[0].profile.host, "old.example")
        XCTAssertEqual(projection.servers[0].profile.port, 7777)
        projection.settings.connectTimeoutMilliseconds = 9_000
        projection.settings.tcpNoDelay = false
        projection.servers[0].profile.host = "new.example"
        projection.servers[0].profile.port = 9999
        projection.servers[0].profile.usesTLS = true
        projection.servers[0].characters[0].connectText = "connect new"

        let updated = try projection.applying(to: document)
        let serialized = updated.serialized()
        XCTAssertTrue(serialized.contains("// preserved header"))
        XCTAssertTrue(serialized.contains("Position=(1,2,3,4)"))
        XCTAssertTrue(serialized.contains("Future=\"untouched\""))
        XCTAssertTrue(serialized.contains("UnknownCharacter=42"))
        XCTAssertTrue(serialized.contains("UnknownServer=\"keep\""))
        XCTAssertEqual(updated.value(at: ["Version"]), "331")
        XCTAssertEqual(updated.value(at: ["Connections", "ConnectTimeout"]), "9000")
        XCTAssertEqual(updated.value(at: ["Connections", "Shortcuts", "Legacy", "Host"]), "new.example:9999")
        XCTAssertEqual(updated.value(at: ["Connections", "Shortcuts", "Legacy", "TLS"]), "true")
        XCTAssertEqual(updated.value(at: ["Connections", "Shortcuts", "Legacy", "Characters", "User", "Connect"]), "connect new")

        let reparsed = try LegacyConfigurationProjection(document: updated)
        XCTAssertEqual(reparsed.servers[0].profile.host, "new.example")
        XCTAssertEqual(reparsed.servers[0].profile.port, 9999)
        XCTAssertTrue(reparsed.servers[0].profile.usesTLS)
    }

    func testSidecarRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Config.mac.json")
        let serverID = UUID()
        let characterID = UUID()
        let sidecar = MacConfigurationSidecar(
            keyEquivalents: ["Connect": "@["],
            openTabGroups: [
                .init(
                    tabs: [
                        .init(
                            serverID: serverID,
                            characterID: characterID,
                            serverName: "LambdaMOO",
                            characterName: "Player"
                        ),
                        .init(),
                    ],
                    selectedTab: 1,
                    frame: "{{20, 30}, {980, 700}}"
                ),
            ]
        )
        try MacSidecarStore.save(sidecar, to: url)
        XCTAssertEqual(try MacSidecarStore.load(from: url), sidecar)
    }

    func testConfigurationRecoversNewestReadableBackupWithoutOverwritingPrimary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = directory.appendingPathComponent("Config.txt")
        let backup = directory.appendingPathComponent("Config.backup-2026-07-21.txt")
        try Data("Version={".utf8).write(to: primary)
        try Data("Version=331\nUnknown=keep\n".utf8).write(to: backup)

        let recovery = try await LegacyConfigurationStore(url: primary).loadRecoveringFromBackup()
        XCTAssertEqual(
            recovery.recoveredFrom?.resolvingSymlinksInPath().path,
            backup.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(recovery.document.value(at: ["Version"]), "331")
        XCTAssertEqual(try String(contentsOf: primary, encoding: .utf8), "Version={")
    }

    func testAtlasReader() throws {
        let xml = Data("<atlas version='1'><font_rooms name='Menlo' size='10'/><map name='Main'><room name='Start' rect='1,2,3,4'/><rectangle rect='0,0,9,9' color='#123456'/><exit from='0' name_from='out' points='5,6|7,8'/></map><far_exits><exit map_from='0' map_to='1' from='0' to='2'/></far_exits></atlas>".utf8)
        let atlas = try AtlasReader.read(from: xml)
        XCTAssertEqual(atlas.maps.first?.rooms.first?.name, "Start")
        XCTAssertEqual(atlas.maps.first?.rooms.first?.rect.y2, 4)
        XCTAssertEqual(atlas.roomFont, .init(name: "Menlo", size: 10))
        XCTAssertEqual(atlas.maps.first?.rectangles.first?.color, "#123456")
        XCTAssertEqual(atlas.maps.first?.exits.first?.nameFrom, "out")
        XCTAssertEqual(atlas.maps.first?.exits.first?.points.last, .init(x: 7, y: 8))
        XCTAssertEqual(atlas.farExits.first?.mapTo, "1")
    }

    func testZippedAtlasContainerLoadsAtlasXML() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let xmlURL = directory.appendingPathComponent("Atlas.xml")
        let archiveURL = directory.appendingPathComponent("Map.atlas")
        try Data("<atlas version='1'><map name='Zip'><room name='Inside' rect='1,2,3,4'/></map></atlas>".utf8).write(to: xmlURL)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = directory
        zip.arguments = ["-q", archiveURL.lastPathComponent, xmlURL.lastPathComponent]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let atlas = try AtlasReader.read(from: archiveURL)
        XCTAssertEqual(atlas.maps.first?.name, "Zip")
        XCTAssertEqual(atlas.maps.first?.rooms.first?.name, "Inside")
    }

    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

}

private struct PersistenceSeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}
