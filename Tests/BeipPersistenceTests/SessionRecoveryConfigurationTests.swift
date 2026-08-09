import BeipPersistence
import XCTest

final class SessionRecoveryConfigurationTests: XCTestCase {
    func testImportedRecoverySettingsUseGlobalAndCharacterControls() throws {
        let source = """
        Version=331
        Connections
        {
          Logging
          {
            RestoreLogs=false
            RestoreBufferSize=2048
            RestoreBufferSizeCurrent=999
          }
          Shortcuts
          {
            World
            {
              Host="example.test:4000"
              Characters
              {
                Hero
                {
                  RestoreLog=false
                  RestoreLogIndex=37
                }
              }
            }
          }
        }
        """
        let document = try LegacyConfigurationDocument(source: source)
        let projection = try LegacyConfigurationProjection(document: document)

        XCTAssertFalse(projection.logging.restoreLogs)
        XCTAssertEqual(projection.logging.restoreBufferSize, 2_048 * 1_024)
        XCTAssertFalse(projection.servers[0].characters[0].restoreLog)

        // The old index remains lossless source text but is not projected into
        // the Mac recovery model.
        XCTAssertEqual(document.value(at: ["Connections", "Shortcuts", "World", "Characters", "Hero", "RestoreLogIndex"]), "37")
    }

    func testMissingRecoverySettingsUseNativeDefaults() throws {
        let document = try LegacyConfigurationDocument(source: "Version=331\nConnections { Shortcuts {} }\n")
        let projection = try LegacyConfigurationProjection(document: document)

        XCTAssertTrue(projection.logging.restoreLogs)
        XCTAssertEqual(projection.logging.restoreBufferSize, 10 * 1_024 * 1_024)
    }
}
