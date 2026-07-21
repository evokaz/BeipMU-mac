import BeipCore
import BeipPersistence
import Foundation
import XCTest

final class LegacyConfigTests: XCTestCase {
    private struct PlaybackProcessor: ByteStreamProcessor {
        var resetCount = 0
        mutating func reset() { resetCount += 1 }
        mutating func consume(_ data: Data) -> [ProtocolOutput] {
            [.line(.init(text: String(decoding: data.dropLast(), as: UTF8.self)))]
        }
        mutating func encode(_ text: String) throws -> Data { Data(text.utf8) }
    }

    func testRestorePlaybackResetsParserRestoresTimestampsGMCPAndSentHistory() {
        let unixEpochFileTime: UInt64 = 116_444_736_000_000_000
        let records: [RestoreLogRecord] = [
            .init(kind: .received, windowsFileTime: unixEpochFileTime, payload: Data("old".utf8)),
            .init(kind: .start, windowsFileTime: unixEpochFileTime, payload: Data()),
            .init(kind: .received, windowsFileTime: unixEpochFileTime + 10_000_000, payload: Data("room".utf8)),
            .init(kind: .receivedGMCP, windowsFileTime: unixEpochFileTime, payload: Data("Char.Status {\"hp\":100}".utf8)),
            .init(kind: .sent, windowsFileTime: unixEpochFileTime + 20_000_000, payload: Data("look".utf8)),
        ]
        var processor = PlaybackProcessor()
        let playback = RestoreLogPlayback.replay(records, through: &processor)

        XCTAssertEqual(processor.resetCount, 1)
        XCTAssertEqual(playback.sentHistory, ["look"])
        guard case let .renderedLine(room) = playback.events[1] else { return XCTFail("missing restored line") }
        XCTAssertEqual(room.text, "room")
        XCTAssertEqual(room.source, .replay)
        XCTAssertEqual(room.timestamp, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(playback.events[2], .gmcp(.init(package: "Char.Status", payload: "{\"hp\":100}")))
        guard case let .renderedLine(echo) = playback.events[3] else { return XCTFail("missing sent echo") }
        XCTAssertEqual(echo.text, "look")
        XCTAssertEqual(echo.timestamp, Date(timeIntervalSince1970: 2))
    }

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

    func testWindowsV331GoldenConfigurationParsesLosslesslyAndProjectsProfiles() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Golden/windows-v331-Config.txt")
        let source = try String(contentsOf: url, encoding: .utf8)
        let document = try LegacyConfigurationDocument(source: source)
        let projection = try LegacyConfigurationProjection(document: document)

        XCTAssertEqual(document.serialized(), source)
        XCTAssertEqual(document.value(at: ["Windows", "Positions", "Position"]), nil)
        XCTAssertEqual(projection.sourceVersion, 331)
        XCTAssertEqual(projection.servers.count, 1)
        XCTAssertEqual(projection.servers[0].profile.name, "GoldenFixture")
        XCTAssertEqual(projection.servers[0].profile.host, "127.0.0.1")
        XCTAssertEqual(projection.servers[0].profile.port, 45_678)
        XCTAssertTrue(projection.servers[0].profile.prompts)
        XCTAssertEqual(projection.servers[0].characters.first?.name, "Golden")
        XCTAssertEqual(projection.servers[0].characters.first?.connectText, "connect golden")
        XCTAssertTrue(projection.servers[0].characters.first?.autoConnect == true)
    }

    func testTypedProjectionUsesWindowsDefaultsAndPortableSettings() throws {
        let source = """
        Version=331
        TCP_KeepAlive=false
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
        let server = try XCTUnwrap(projection.servers.first)
        XCTAssertEqual(server.profile.host, "::1")
        XCTAssertEqual(server.profile.port, 7777)
        XCTAssertEqual(server.profile.encoding, .utf8)
        XCTAssertTrue(server.profile.usesTLS)
        XCTAssertTrue(server.profile.verifiesCertificate)
        XCTAssertTrue(server.profile.pueblo)
        XCTAssertTrue(server.profile.mcp)
        XCTAssertTrue(server.profile.mcmp)
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

        try workspace.updateServer(id: newID) {
            $0.profile.name = "New World"
            $0.profile.host = "new.example"
            $0.profile.port = 4321
            $0.profile.usesTLS = true
        }
        let characterID = try workspace.addCharacter(toServerID: newID, named: "Player")
        try workspace.updateCharacter(id: characterID, inServerID: newID) {
            $0.connectText = "connect player"
            $0.autoConnect = true
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
        let sidecar = MacConfigurationSidecar(keyEquivalents: ["Connect": "@["])
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

    func testRestoreLogRoundTripPreservesMultipleBuffers() throws {
        let logs: [[RestoreLogRecord]] = [
            [.init(kind: .start, windowsFileTime: 1, payload: Data()), .init(kind: .received, windowsFileTime: 2, payload: Data("hello".utf8))],
            [.init(kind: .sent, windowsFileTime: 3, payload: Data("say hi".utf8))],
        ]
        let encoded = try RestoreLogCodec.write(logs, bufferSize: 64)
        XCTAssertEqual(try RestoreLogCodec.read(encoded, bufferSize: 64), logs)
    }

    func testRestoreLogEvictsOldestRecordsWhenRingWraps() throws {
        let records = [
            RestoreLogRecord(kind: .received, windowsFileTime: 1, payload: Data("first".utf8)),
            RestoreLogRecord(kind: .received, windowsFileTime: 2, payload: Data("second".utf8)),
            RestoreLogRecord(kind: .sent, windowsFileTime: 3, payload: Data("third".utf8)),
        ]
        let encoded = try RestoreLogCodec.write([records], bufferSize: 56)
        XCTAssertEqual(try RestoreLogCodec.read(encoded, bufferSize: 56), [[records[1], records[2]]])
    }

    func testRestoreLogDropsRecordThatCannotFitInItsBuffer() throws {
        let oversized = RestoreLogRecord(kind: .received, windowsFileTime: 1, payload: Data(repeating: 1, count: 29))
        let encoded = try RestoreLogCodec.write([[oversized]], bufferSize: 40)
        XCTAssertEqual(try RestoreLogCodec.read(encoded, bufferSize: 40), [[]])
    }

    func testRestoreLogStoreSavesAndLoadsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Restore.dat")
        let logs = [[RestoreLogRecord(kind: .receivedGMCP, windowsFileTime: 42, payload: Data("Char.Status {\"hp\":100}".utf8))]]

        try RestoreLogStore.save(logs, to: url, bufferSize: 128)
        XCTAssertEqual(try RestoreLogStore.load(from: url, bufferSize: 128), logs)
    }

    func testRestoreLogRejectsTrailingPartialRecord() throws {
        var encoded = try RestoreLogCodec.write([[
            .init(kind: .received, windowsFileTime: 1, payload: Data("ok".utf8)),
        ]], bufferSize: 64)
        // Extend the logical byte count by one without adding a complete record.
        encoded[4] += 1
        XCTAssertThrowsError(try RestoreLogCodec.read(encoded, bufferSize: 64)) { error in
            guard case RestoreLogError.corruptRecord = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRestoreLogRepairSalvagesValidPrefixAndRewritesCorruptTail() throws {
        let records = [
            RestoreLogRecord(kind: .received, windowsFileTime: 1, payload: Data("valid".utf8)),
            RestoreLogRecord(kind: .sent, windowsFileTime: 2, payload: Data("tail".utf8)),
        ]
        var encoded = try RestoreLogCodec.write([records], bufferSize: 80)
        // Make the second record claim a payload longer than the remaining data.
        let secondRecordOffset = 8 + 12 + records[0].payload.count
        encoded[secondRecordOffset + 1] = 0xff

        let repaired = try RestoreLogCodec.repair(encoded, bufferSize: 80)
        XCTAssertEqual(repaired.logs, [[records[0]]])
        XCTAssertEqual(repaired.repairedBufferIndices, [0])
        XCTAssertEqual(try RestoreLogCodec.read(repaired.repairedData, bufferSize: 80), [[records[0]]])
    }

    func testWindowsV331GoldenRestoreLogIsReadable() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Golden/windows-v331-Restore.dat")
        let logs = try RestoreLogStore.load(from: url, bufferSize: 256 * 1024)

        XCTAssertEqual(logs.count, 1)
        XCTAssertFalse(logs[0].isEmpty)
        let combinedPayload = logs[0].reduce(into: Data()) { $0.append($1.payload) }
        XCTAssertNotNil(combinedPayload.range(of: Data("Golden prompt> ".utf8)))
        XCTAssertNotNil(combinedPayload.range(of: Data("Golden room".utf8)))
    }
}
