import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class ProfileLibraryPersistenceTests: XCTestCase {
    func testTaskbarPlacementPersistsThroughWorkspaceAndExport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.ProfileLibraryTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try ProfileLibrary(storageDirectory: directory)
        try library.mutate { workspace in
            workspace.setTaskbarOnTop(false)
        }
        XCTAssertFalse(library.workspace.taskbarOnTop)

        let relaunched = try ProfileLibrary(storageDirectory: directory)
        XCTAssertFalse(relaunched.workspace.taskbarOnTop)
        let export = directory.appendingPathComponent("Export.txt")
        try relaunched.export(to: export)
        XCTAssertTrue(try String(contentsOf: export, encoding: .utf8).contains("TaskbarOnTop=false"))
    }

    func testClearOpenTabGroupsRemovesSavedSessionPersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.ProfileLibraryTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try ProfileLibrary(storageDirectory: directory)
        try library.saveOpenTabGroups([.init(tabs: [.init(serverName: "Old World")])])
        XCTAssertEqual(library.openTabGroups?.count, 1)

        try library.clearOpenTabGroups()

        XCTAssertNil(library.openTabGroups)
    }

    func testResetToPristineConfigurationRemovesManagedStateButPreservesUserFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.ProfileLibraryTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try ProfileLibrary(storageDirectory: directory)
        _ = try library.mutate { _ = $0.addServer(named: "Erase Me") }
        try library.saveKeyEquivalents(["newTab": "⌘T"])
        try library.saveOpenTabGroups([.init(tabs: [.init(serverName: "Erase Me")])])
        try Data("old backup".utf8).write(to: directory.appendingPathComponent("Config.backup.txt"))
        let userFile = directory.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("keep.log")
        try FileManager.default.createDirectory(at: userFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: userFile)

        try library.resetToPristineConfiguration()

        XCTAssertTrue(library.workspace.servers.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Config.backup.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Config.mac.json").path))
        XCTAssertNil(library.openTabGroups)
        XCTAssertTrue(library.keyEquivalents.isEmpty)
        XCTAssertEqual(try String(contentsOf: userFile), "keep")

        let relaunched = try ProfileLibrary(storageDirectory: directory)
        XCTAssertTrue(relaunched.workspace.servers.isEmpty)
    }

    func testImportOverwritesPersistentConfigurationAndExportRetainsAppState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.ProfileLibraryTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let backup = directory.appendingPathComponent("Backup.txt")
        try Data(
            """
            Version=331
            Windows
            {
              Positions
              {
                {
                  ActiveTab=0
                  Tabs
                  {
                    {
                      Server="Example"
                      Character="Player"
                    }
                  }
                }
              }
            }
            Connections
            {
              Shortcuts
              {
                Example
                {
                  Host="mud.example:4201"
                  Characters
                  {
                    Player
                    {
                      Password="not-real"
                      Docking
                      {
                        SpawnWindow
                        {
                          Title="Channels"
                        }
                      }
                    }
                  }
                }
              }
            }
            """.utf8
        ).write(to: backup)

        let library = try ProfileLibrary(storageDirectory: directory)
        try library.importConfiguration(from: backup)
        let serverID = try XCTUnwrap(library.workspace.servers.first?.profile.id)
        try library.mutate {
            try $0.updateServer(id: serverID) { $0.profile.port = 8888 }
        }

        let relaunched = try ProfileLibrary(storageDirectory: directory)
        XCTAssertEqual(relaunched.workspace.servers.first?.profile.port, 8888)
        XCTAssertEqual(
            relaunched.workspace.document.value(at: ["Windows", "Positions"]),
            nil,
            "The state is a block, not a scalar; its nested source must still survive."
        )

        let exported = directory.appendingPathComponent("Export.txt")
        try relaunched.export(to: exported)
        let text = try String(contentsOf: exported, encoding: .utf8)
        XCTAssertTrue(text.contains("ActiveTab=0"))
        XCTAssertTrue(text.contains("Title=\"Channels\""))
        XCTAssertTrue(text.contains("Password=\"not-real\""))
        XCTAssertTrue(text.contains("Host=\"mud.example:8888\""))
    }

    func testInvalidImportDoesNotReplacePersistentConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.ProfileLibraryTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try ProfileLibrary(storageDirectory: directory)
        try library.mutate { _ = $0.addServer(named: "Keep Me") }
        let invalid = directory.appendingPathComponent("Invalid.txt")
        try Data("Version={".utf8).write(to: invalid)

        XCTAssertThrowsError(try library.importConfiguration(from: invalid))
        let relaunched = try ProfileLibrary(storageDirectory: directory)
        XCTAssertEqual(relaunched.workspace.servers.first?.profile.name, "Keep Me")
    }

    func testAcceptedNewerFullImportSurvivesEditExportAndRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.ProfileLibraryTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let version = LegacyConfigurationVersion.currentWindows + 9
        let document = try LegacyConfigurationDocument(source: """
        Version=\(version)
        FutureRoot="preserve root"
        Connections { Shortcuts {
          FutureWorld { Host="before.example:4000" FutureWorld="preserve world" }
        } }
        """)
        let library = try ProfileLibrary(storageDirectory: directory)
        try library.importConfiguration(document: document, allowsNewerVersion: true)
        let world = try XCTUnwrap(library.workspace.servers.first)
        try library.mutate { workspace in
            try workspace.updateServer(id: world.profile.id) {
                $0.profile.host = "after.example"
                $0.profile.port = 5000
            }
        }

        let export = directory.appendingPathComponent("Export.txt")
        try library.export(to: export)
        let exported = try LegacyConfigurationDocument(
            source: String(contentsOf: export, encoding: .utf8)
        )
        XCTAssertEqual(exported.configurationVersion, version)
        XCTAssertEqual(exported.value(at: ["FutureRoot"]), "preserve root")
        XCTAssertEqual(exported.value(at: ["Connections", "Shortcuts", "FutureWorld", "FutureWorld"]), "preserve world")
        XCTAssertEqual(exported.value(at: ["Connections", "Shortcuts", "FutureWorld", "Host"]), "after.example:5000")

        let relaunched = try ProfileLibrary(storageDirectory: directory)
        XCTAssertEqual(relaunched.workspace.projection.sourceVersion, version)
        XCTAssertEqual(relaunched.workspace.servers.first?.profile.host, "after.example")
        XCTAssertEqual(relaunched.workspace.servers.first?.profile.port, 5000)
    }

    func testAcceptedNewerConfigurationRecoversFromBackupAfterPrimaryDamage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.ProfileLibraryTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let version = LegacyConfigurationVersion.currentWindows + 9
        let document = try LegacyConfigurationDocument(source: """
        Version=\(version)
        FutureRoot="preserve root"
        Connections { Shortcuts {
          FutureWorld { Host="before.example:4000" FutureWorld="preserve world" }
        } }
        """)
        let library = try ProfileLibrary(storageDirectory: directory)
        try library.importConfiguration(document: document, allowsNewerVersion: true)
        let world = try XCTUnwrap(library.workspace.servers.first)
        try library.mutate { workspace in
            try workspace.updateServer(id: world.profile.id) {
                $0.profile.host = "after.example"
                $0.profile.port = 5000
            }
        }

        let backupURL = directory.appendingPathComponent("Config.backup.txt")
        let preservedBackup = try Data(contentsOf: backupURL)
        try Data("Version={".utf8).write(to: directory.appendingPathComponent("Config.txt"))

        let recovered = try ProfileLibrary(storageDirectory: directory)

        XCTAssertEqual(recovered.workspace.projection.sourceVersion, version)
        XCTAssertEqual(recovered.workspace.servers.first?.profile.host, "before.example")
        XCTAssertEqual(recovered.workspace.servers.first?.profile.port, 4000)
        XCTAssertEqual(recovered.workspace.document.value(at: ["FutureRoot"]), "preserve root")
        XCTAssertEqual(
            recovered.workspace.document.value(at: ["Connections", "Shortcuts", "FutureWorld", "FutureWorld"]),
            "preserve world"
        )
        XCTAssertEqual(try Data(contentsOf: backupURL), preservedBackup)
        XCTAssertNoThrow(
            try LegacyConfigurationDocument(
                source: String(
                    contentsOf: directory.appendingPathComponent("Config.txt"),
                    encoding: .utf8
                )
            )
        )
    }

    func testFailedStartupRecoveryPreservesFixedBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.ProfileLibraryTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try ProfileLibrary(storageDirectory: directory)
        let primaryURL = directory.appendingPathComponent("Config.txt")
        let backupURL = directory.appendingPathComponent("Config.backup.txt")
        try Data("Version={".utf8).write(to: primaryURL)
        let invalidBackup = Data([0xff, 0xfe, 0xfd])
        try invalidBackup.write(to: backupURL)

        let relaunched = try ProfileLibrary(storageDirectory: directory)

        XCTAssertTrue(relaunched.workspace.servers.isEmpty)
        XCTAssertEqual(try Data(contentsOf: backupURL), invalidBackup)
    }

    func testRelaunchRecoversLastValidPersistentBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.ProfileLibraryTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = try ProfileLibrary(storageDirectory: directory)
        try library.mutate { _ = $0.addServer(named: "Recover Me") }
        try library.mutate { workspace in
            let id = try XCTUnwrap(workspace.servers.first?.profile.id)
            try workspace.updateServer(id: id) { $0.profile.host = "saved.example" }
        }
        try Data("Version={".utf8).write(to: directory.appendingPathComponent("Config.txt"))

        let recovered = try ProfileLibrary(storageDirectory: directory)
        XCTAssertEqual(recovered.workspace.servers.first?.profile.name, "Recover Me")
        XCTAssertEqual(recovered.workspace.servers.first?.profile.host, "example.com")
        XCTAssertNoThrow(
            try LegacyConfigurationDocument(
                source: String(
                    contentsOf: directory.appendingPathComponent("Config.txt"),
                    encoding: .utf8
                )
            )
        )
    }
}
