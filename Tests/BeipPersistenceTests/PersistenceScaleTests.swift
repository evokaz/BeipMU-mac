import BeipPersistence
import Foundation
import XCTest

final class PersistenceScaleTests: XCTestCase {
    func testPersistenceScaleLargeConfigurationLoadEditSaveReloadPreservesUnknownSyntax() throws {
        let fixture = try String(
            contentsOf: LegacyConfigurationTestSupport.fixtureURL("Scale/large-config.txt"),
            encoding: .utf8
        )
        var document = try LegacyConfigurationDocument(source: fixture)
        let projection = try LegacyConfigurationProjection(document: document)

        XCTAssertEqual(projection.servers.count, 64)
        XCTAssertEqual(projection.servers.flatMap(\.characters).count, 256)
        XCTAssertEqual(fixture.components(separatedBy: "Description=\"Scale trigger ").count - 1, 2_048)
        XCTAssertEqual(fixture.components(separatedBy: "Description=\"Scale alias ").count - 1, 2_048)

        try document.setValue(
            "127.0.0.1:47999",
            at: ["Connections", "Shortcuts", "Scale World 63", "Host"]
        )
        let saved = document.serialized()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU-Scale-Config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Config.txt")
        try saved.write(to: output, atomically: true, encoding: .utf8)

        let reloadedSource = try String(contentsOf: output, encoding: .utf8)
        let reloaded = try LegacyConfigurationDocument(source: reloadedSource)
        let reloadedProjection = try LegacyConfigurationProjection(document: reloaded)
        XCTAssertEqual(reloadedProjection.servers.count, 64)
        XCTAssertEqual(reloaded.value(at: ["Connections", "Shortcuts", "Scale World 63", "Host"]), "127.0.0.1:47999")
        XCTAssertEqual(reloaded.value(at: ["ScaleUnknownRoot"]), "preserve-root")
        XCTAssertEqual(
            reloaded.value(at: ["Connections", "Shortcuts", "Scale World 00", "ScaleWindowsOnly00"]),
            "preserve-world-00"
        )
        XCTAssertEqual(
            reloaded.value(at: [
                "Connections", "Shortcuts", "Scale World 63", "Characters",
                "Character 63-03", "ScaleUnknownCharacter",
            ]),
            "preserve-63-03"
        )
        XCTAssertEqual(reloaded.value(at: ["ScaleTrailingUnknown"]), "preserve-trailing")
    }

    func testPersistenceScaleLargeAtlasNavigationTrackingPathfindingEditingAndReload() throws {
        let archive = try AtlasReader.readArchive(
            from: LegacyConfigurationTestSupport.fixtureURL("Scale/large-atlas.atlas")
        )
        XCTAssertEqual(archive.atlas.maps.count, 1)
        XCTAssertEqual(archive.atlas.maps[0].rooms.count, 400)
        XCTAssertEqual(archive.atlas.maps[0].exits.count, 760)
        XCTAssertEqual(archive.atlas.attributes["scale_unknown_root"], "preserve-root")
        XCTAssertEqual(archive.atlas.maps[0].attributes["scale_map_unknown"], "preserve-map")
        XCTAssertEqual(archive.atlas.maps[0].rooms[399].attributes["scale_room_unknown"], "preserve-399")

        var editor = AtlasEditor(atlas: archive.atlas)
        editor.viewport.zoom(by: 1.75, around: .init(x: 500, y: 350))
        XCTAssertEqual(editor.viewport.scale, 1.75)
        editor.setCurrentLocation(.init(mapIndex: 0, roomIndex: 0))
        let path = try XCTUnwrap(editor.shortestPath(to: .init(mapIndex: 0, roomIndex: 399)))
        XCTAssertEqual(path.count, 38)
        XCTAssertEqual(path.last?.destination, .init(mapIndex: 0, roomIndex: 399))

        editor.liveTracking = true
        XCTAssertEqual(editor.observeOutput("Room 001"), .init(mapIndex: 0, roomIndex: 1))
        XCTAssertEqual(editor.observeOutput("Room 021"), .init(mapIndex: 0, roomIndex: 21))
        XCTAssertEqual(editor.findRooms("Room 399").first?.location, .init(mapIndex: 0, roomIndex: 399))

        let originalLabelCount = editor.atlas.maps[0].labels.count
        _ = editor.addLabel(
            text: "Scale edited label",
            rect: .init(x1: 20, y1: 1_500, x2: 280, y2: 1_540),
            color: "#00ffcc"
        )
        XCTAssertEqual(editor.atlas.maps[0].labels.count, originalLabelCount + 1)
        editor.undo()
        XCTAssertEqual(editor.atlas.maps[0].labels.count, originalLabelCount)
        editor.redo()
        XCTAssertEqual(editor.atlas.maps[0].labels.count, originalLabelCount + 1)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU-Scale-Atlas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Scale-RoundTrip.atlas")
        try AtlasWriter.write(.init(atlas: editor.atlas, resources: archive.resources), to: output)
        let reloaded = try AtlasReader.readArchive(from: output).atlas
        XCTAssertEqual(reloaded.maps[0].rooms.count, 400)
        XCTAssertEqual(reloaded.maps[0].exits.count, 760)
        XCTAssertEqual(reloaded.maps[0].labels.last?.text, "Scale edited label")
        XCTAssertEqual(reloaded.attributes["scale_unknown_root"], "preserve-root")
        XCTAssertEqual(reloaded.maps[0].attributes["scale_map_unknown"], "preserve-map")
        XCTAssertEqual(reloaded.maps[0].rooms[399].attributes["scale_room_unknown"], "preserve-399")
    }
}
