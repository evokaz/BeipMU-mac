import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class ProfileLibraryPersistenceTests: XCTestCase {
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
