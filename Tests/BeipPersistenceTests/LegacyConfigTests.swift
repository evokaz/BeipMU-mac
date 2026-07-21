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
}
