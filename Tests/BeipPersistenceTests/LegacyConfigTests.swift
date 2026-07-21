import BeipPersistence
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

    func testTargetedReplacementPreservesUnknownText() throws {
        var document = try LegacyConfigurationDocument(source: fixture)
        try document.setValue("example.org:1234", at: ["Connections", "Shortcuts", "LambdaMOO", "Host"])
        XCTAssertTrue(document.serialized().contains("Host=\"example.org:1234\""))
        XCTAssertTrue(document.serialized().contains("// Keep this comment byte-for-byte"))
        XCTAssertTrue(document.serialized().contains("Unknown.Future.Value=\"preserve me\""))
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

    func testAtlasReader() throws {
        let xml = Data("<atlas version='1'><map name='Main'><room name='Start' rect='1,2,3,4'/></map></atlas>".utf8)
        let atlas = try AtlasReader.read(from: xml)
        XCTAssertEqual(atlas.maps.first?.rooms.first?.name, "Start")
        XCTAssertEqual(atlas.maps.first?.rooms.first?.rect.y2, 4)
    }
}

