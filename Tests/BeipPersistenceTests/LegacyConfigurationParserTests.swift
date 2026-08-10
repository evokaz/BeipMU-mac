import BeipCore
import BeipAutomation
import BeipPersistence
import Foundation
import XCTest

final class LegacyConfigurationParserTests: XCTestCase {
    func testLosslessRoundTrip() throws {
        let document = try LegacyConfigurationDocument(source: LegacyConfigurationTestSupport.sourceFixture)
        XCTAssertEqual(document.serialized(), LegacyConfigurationTestSupport.sourceFixture)
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
        var document = try LegacyConfigurationDocument(source: LegacyConfigurationTestSupport.sourceFixture)
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
}
