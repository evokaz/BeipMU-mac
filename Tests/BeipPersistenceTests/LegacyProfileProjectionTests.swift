import BeipCore
import BeipAutomation
import BeipPersistence
import Foundation
import XCTest

final class LegacyProfileProjectionTests: XCTestCase {
    func testANSIProjectionReadsLegacyColorsAndWritesCanonicalLosslessly() throws {
        let source = """
        Version=331
        Ansi {
          Colors {
            Red="#010203"
            BoldRed="RGB( 4, 5, 6)"
          }
          Flag FontBold=true
          Flag PreventInvisible=false
          Flag Parse=false
          FlashSpeed=0
          Flag Beep=false
          Flag BeepSystem=false
          BeepFileName="Sounds/bell.wav"
          Flag ResetOnNewLine=true
          FutureAnsiField="preserve"
        }
        Connections { Shortcuts { World { Host="example.test:1" } } }
        UnknownRoot="preserve"
        """
        let document = try LegacyConfigurationDocument(source: source)
        var workspace = try LegacyConfigurationWorkspace(document: document)
        XCTAssertEqual(workspace.ansi.colors[.red], RGBColor(red: 1, green: 2, blue: 3))
        XCTAssertEqual(workspace.ansi.colors[.boldRed], RGBColor(red: 4, green: 5, blue: 6))
        XCTAssertTrue(workspace.ansi.fontBold)
        XCTAssertFalse(workspace.ansi.preventInvisible)
        XCTAssertFalse(workspace.ansi.parse)
        XCTAssertFalse(workspace.ansi.parseBlinking)
        XCTAssertFalse(workspace.ansi.beep)
        XCTAssertFalse(workspace.ansi.beepSystem)
        XCTAssertTrue(workspace.ansi.resetOnNewLine)

        workspace.updateANSISettings { $0.colors[.red] = RGBColor(red: 7, green: 8, blue: 9, alpha: 0) }
        let rendered = try workspace.renderedDocument()
        XCTAssertEqual(rendered.value(at: ["Ansi", "Colors", "Red"]), "RGB(7,8,9)")
        XCTAssertEqual(rendered.value(at: ["Ansi", "Colors", "BoldRed"]), "RGB(4,5,6)")
        XCTAssertTrue(rendered.serialized().contains("FutureAnsiField=\"preserve\""))
        XCTAssertTrue(rendered.serialized().contains("UnknownRoot=\"preserve\""))
    }

    func testANSIProjectionPreservesLegacyFlashIntervalDuringUnrelatedEdits() throws {
        let source = """
        Version=331
        Ansi { FlashSpeed=250 Colors { Red="RGB(1,2,3)" } }
        Connections { Shortcuts { } }
        """
        let document = try LegacyConfigurationDocument(source: source)
        var workspace = try LegacyConfigurationWorkspace(document: document)
        XCTAssertEqual(workspace.ansi.flashSpeed, 250)

        workspace.updateANSISettings { $0.colors[.red] = RGBColor(red: 7, green: 8, blue: 9) }
        let rendered = try workspace.renderedDocument()
        XCTAssertEqual(rendered.value(at: ["Ansi", "FlashSpeed"]), "250")
    }

    func testANSIMissingFlashSpeedUsesLegacyDefault() throws {
        let document = try LegacyConfigurationDocument(source: "Version=331\nAnsi { }\nConnections { Shortcuts { } }\n")
        let projection = try LegacyConfigurationProjection(document: document)

        XCTAssertEqual(projection.ansi.flashSpeed, 500)
        XCTAssertTrue(projection.ansi.parseBlinking)
    }

    func testANSIDefaultsAreOmittedWhenMissing() throws {
        let document = try LegacyConfigurationDocument(source: "Version=331\nConnections { Shortcuts { } }\n")
        let projection = try LegacyConfigurationProjection(document: document)
        let rendered = try projection.applying(to: document)
        XCTAssertNil(rendered.value(at: ["Ansi"]))
    }

    func testTaskbarOnTopUsesOnlyRootBooleanAndWritesLosslessly() throws {
        let cases: [(String?, Bool)] = [
            ("true", true),
            ("false", false),
            (nil, true),
            ("invalid", true),
            ("yes", true),
            ("no", false),
            ("1", true),
            ("0", false),
        ]

        for (value, expected) in cases {
            let root = value.map { "TaskbarOnTop=\($0)\n" } ?? ""
            let source = """
            Version=331
            \(root)Connections { Shortcuts { World { TaskbarOnTop=false Host="example.test:1" } } }
            """
            let document = try LegacyConfigurationDocument(source: source)
            let projection = try LegacyConfigurationProjection(document: document)
            XCTAssertEqual(projection.taskbarOnTop, expected, "value=\(String(describing: value))")

            var updated = projection
            updated.taskbarOnTop = false
            let rendered = try updated.applying(to: document)
            XCTAssertEqual(rendered.value(at: ["TaskbarOnTop"]), "false")
            XCTAssertEqual(
                rendered.value(at: ["Connections", "Shortcuts", "World", "TaskbarOnTop"]),
                "false"
            )
        }

        let missing = try LegacyConfigurationDocument(source: "Version=331\nConnections { Shortcuts { } }\n")
        let projection = try LegacyConfigurationProjection(document: missing)
        XCTAssertEqual(try projection.applying(to: missing).value(at: ["TaskbarOnTop"]), nil)
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
}
