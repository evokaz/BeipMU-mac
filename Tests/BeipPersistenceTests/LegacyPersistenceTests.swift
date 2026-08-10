import BeipCore
import BeipAutomation
import BeipPersistence
import Foundation
import XCTest

final class LegacyPersistenceTests: XCTestCase {
    func testSidecarRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Config.mac.json")
        let serverID = UUID()
        let characterID = UUID()
        let sidecar = MacConfigurationSidecar(
            keyEquivalents: ["Connect": "@["],
            openTabGroups: [
                .init(
                    tabs: [
                        .init(
                            serverID: serverID,
                            characterID: characterID,
                            serverName: "LambdaMOO",
                            characterName: "Player"
                        ),
                        .init(),
                    ],
                    selectedTab: 1,
                    frame: "{{20, 30}, {980, 700}}"
                ),
            ]
        )
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
}
