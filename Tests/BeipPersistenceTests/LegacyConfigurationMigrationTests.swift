import BeipCore
import BeipAutomation
import BeipPersistence
import Foundation
import XCTest

final class LegacyConfigurationMigrationTests: XCTestCase {
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
}
