import BeipCore
import BeipAutomation
import BeipPersistence
import Foundation
import XCTest

final class LegacyConfigurationMigrationTests: XCTestCase {
    func testTypedProjectionRefusesNewerWindowsConfigurationVersions() throws {
        let supportedVersion = WindowsCompatibilityVersion.current
        let newerVersion = supportedVersion + 1
        let document = try LegacyConfigurationDocument(
            source: "Version=\(newerVersion)\nConnections { Shortcuts {} }\n"
        )
        XCTAssertThrowsError(try LegacyConfigurationProjection(document: document)) { error in
            XCTAssertEqual(
                error as? LegacyConfigurationProjection.ProjectionError,
                .newerConfiguration(found: newerVersion, supported: supportedVersion)
            )
        }
    }

    func testExplicitlyAllowedNewerConfigurationKeepsItsVersionOnWrite() throws {
        let newerVersion = WindowsCompatibilityVersion.current + 9
        let document = try LegacyConfigurationDocument(source: """
        Version=\(newerVersion)
        FutureRoot="preserve me"
        Connections {
          Shortcuts {
            World { Host="before.example:4000" FutureWorld="keep" }
          }
        }
        """)
        var workspace = try LegacyConfigurationWorkspace(
            document: document,
            allowsNewerVersion: true
        )
        let world = try XCTUnwrap(workspace.servers.first)
        try workspace.updateServer(id: world.profile.id) {
            $0.profile.host = "after.example"
            $0.profile.port = 5000
        }

        let saved = try workspace.renderedDocument()
        XCTAssertEqual(saved.configurationVersion, newerVersion)
        XCTAssertEqual(saved.value(at: ["FutureRoot"]), "preserve me")
        XCTAssertEqual(saved.value(at: ["Connections", "Shortcuts", "World", "FutureWorld"]), "keep")
        XCTAssertEqual(saved.value(at: ["Connections", "Shortcuts", "World", "Host"]), "after.example:5000")
    }

    func testNewerWorldAndAutomationImportsRetainDestinationVersion() throws {
        let newerVersion = WindowsCompatibilityVersion.current + 9
        let worldSource = try LegacyConfigurationDocument(source: """
        Version=\(newerVersion)
        Connections { Shortcuts {
          Imported { Host="world.example:4000" FutureWorld="keep" }
        } }
        """)
        var worldTarget = try LegacyConfigurationWorkspace.empty()
        _ = try worldTarget.mergeProfileHierarchy(from: worldSource, allowsNewerVersion: true)
        let mergedWorld = try worldTarget.renderedDocument()
        XCTAssertEqual(mergedWorld.configurationVersion, WindowsCompatibilityVersion.current)
        XCTAssertEqual(mergedWorld.value(at: ["Connections", "Shortcuts", "Imported", "FutureWorld"]), "keep")

        let aliasSource = try LegacyConfigurationDocument(source: """
        Version=\(newerVersion)
        Connections { Aliases {
          { Description="Imported alias" FindString.MatchText="x" Replace="north" FutureAlias="keep" }
        } }
        """)
        var automationTarget = try LegacyConfigurationWorkspace.empty()
        let imported = try automationTarget.importAutomation(
            from: aliasSource,
            kind: .aliases,
            destination: .scope(.global),
            allowsNewerVersion: true
        )
        XCTAssertEqual(imported.paths, [[0]])
        let mergedAutomation = try automationTarget.renderedDocument()
        XCTAssertEqual(mergedAutomation.configurationVersion, WindowsCompatibilityVersion.current)
        XCTAssertTrue(mergedAutomation.serialized().contains("FutureAlias=\"keep\""))

        let contextualTriggerSource = try LegacyConfigurationDocument(source: """
        Version=\(newerVersion)
        Connections { Shortcuts {
          Imported {
            Host="trigger.example:4000"
            Triggers { { Description="Future trigger" FindString.MatchText="future" FutureTrigger="keep" } }
          }
        } }
        """)
        var contextualTarget = try LegacyConfigurationWorkspace.empty()
        let contextualImport = try contextualTarget.importAutomation(
            from: contextualTriggerSource,
            kind: .triggers,
            destination: .scope(.global),
            allowsNewerVersion: true
        )
        let mergedContextual = try contextualTarget.renderedDocument()
        XCTAssertEqual(contextualImport.scope, .server(try XCTUnwrap(contextualTarget.servers.first?.profile.id)))
        XCTAssertEqual(mergedContextual.configurationVersion, WindowsCompatibilityVersion.current)
        XCTAssertTrue(mergedContextual.serialized().contains("FutureTrigger=\"keep\""))
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
        XCTAssertEqual(migrated.value(at: ["Version"]), String(WindowsCompatibilityVersion.current))
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
