import BeipPersistence
import Foundation
import XCTest

final class M10ScalePersistenceTests: XCTestCase {
    func testM10ScaleLargeConfigurationLoadEditSaveReloadPreservesUnknownSyntax() throws {
        let fixture = try String(contentsOf: fixtureURL("large-config.txt"), encoding: .utf8)
        let started = ContinuousClock.now
        var document = try LegacyConfigurationDocument(source: fixture)
        let projection = try LegacyConfigurationProjection(document: document)

        XCTAssertEqual(projection.servers.count, 64)
        XCTAssertEqual(projection.servers.flatMap(\.characters).count, 256)
        XCTAssertEqual(fixture.components(separatedBy: "Description=\"M10 trigger ").count - 1, 2_048)
        XCTAssertEqual(fixture.components(separatedBy: "Description=\"M10 alias ").count - 1, 2_048)

        try document.setValue(
            "127.0.0.1:47999",
            at: ["Connections", "Shortcuts", "M10 World 63", "Host"]
        )
        let saved = document.serialized()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU-M10-Config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("Config.txt")
        try saved.write(to: output, atomically: true, encoding: .utf8)

        let reloadedSource = try String(contentsOf: output, encoding: .utf8)
        let reloaded = try LegacyConfigurationDocument(source: reloadedSource)
        let reloadedProjection = try LegacyConfigurationProjection(document: reloaded)
        XCTAssertEqual(reloadedProjection.servers.count, 64)
        XCTAssertEqual(reloaded.value(at: ["Connections", "Shortcuts", "M10 World 63", "Host"]), "127.0.0.1:47999")
        XCTAssertEqual(reloaded.value(at: ["M10UnknownRoot"]), "preserve-root")
        XCTAssertEqual(
            reloaded.value(at: ["Connections", "Shortcuts", "M10 World 00", "M10WindowsOnly00"]),
            "preserve-world-00"
        )
        XCTAssertEqual(
            reloaded.value(at: [
                "Connections", "Shortcuts", "M10 World 63", "Characters",
                "Character 63-03", "M10UnknownCharacter",
            ]),
            "preserve-63-03"
        )
        XCTAssertEqual(reloaded.value(at: ["M10TrailingUnknown"]), "preserve-trailing")
        XCTAssertLessThan(started.duration(to: .now), .seconds(10))
    }

    func testM10ScaleLargeAtlasNavigationTrackingPathfindingEditingAndReload() throws {
        let started = ContinuousClock.now
        let archive = try AtlasReader.readArchive(from: fixtureURL("large-atlas.atlas"))
        XCTAssertEqual(archive.atlas.maps.count, 1)
        XCTAssertEqual(archive.atlas.maps[0].rooms.count, 400)
        XCTAssertEqual(archive.atlas.maps[0].exits.count, 760)
        XCTAssertEqual(archive.atlas.attributes["m10_unknown_root"], "preserve-root")
        XCTAssertEqual(archive.atlas.maps[0].attributes["m10_map_unknown"], "preserve-map")
        XCTAssertEqual(archive.atlas.maps[0].rooms[399].attributes["m10_room_unknown"], "preserve-399")

        var editor = AtlasEditor(atlas: archive.atlas)
        editor.viewport.zoom(by: 1.75, around: .init(x: 500, y: 350))
        XCTAssertEqual(editor.viewport.scale, 1.75)
        editor.setCurrentLocation(.init(mapIndex: 0, roomIndex: 0))
        let path = try XCTUnwrap(editor.shortestPath(to: .init(mapIndex: 0, roomIndex: 399)))
        XCTAssertEqual(path.count, 38)
        XCTAssertEqual(path.last?.destination, .init(mapIndex: 0, roomIndex: 399))

        editor.liveTracking = true
        XCTAssertEqual(editor.recordTypedExit("east"), .init(mapIndex: 0, roomIndex: 1))
        XCTAssertEqual(editor.observeOutput("You enter Room 021."), .init(mapIndex: 0, roomIndex: 21))
        XCTAssertEqual(editor.findRooms("Room 399").first?.location, .init(mapIndex: 0, roomIndex: 399))

        let originalLabelCount = editor.atlas.maps[0].labels.count
        _ = editor.addLabel(
            text: "M10 edited label",
            rect: .init(x1: 20, y1: 1_500, x2: 280, y2: 1_540),
            color: "#00ffcc"
        )
        XCTAssertEqual(editor.atlas.maps[0].labels.count, originalLabelCount + 1)
        editor.undo()
        XCTAssertEqual(editor.atlas.maps[0].labels.count, originalLabelCount)
        editor.redo()
        XCTAssertEqual(editor.atlas.maps[0].labels.count, originalLabelCount + 1)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU-M10-Atlas-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("M10-RoundTrip.atlas")
        try AtlasWriter.write(.init(atlas: editor.atlas, resources: archive.resources), to: output)
        let reloaded = try AtlasReader.readArchive(from: output).atlas
        XCTAssertEqual(reloaded.maps[0].rooms.count, 400)
        XCTAssertEqual(reloaded.maps[0].exits.count, 760)
        XCTAssertEqual(reloaded.maps[0].labels.last?.text, "M10 edited label")
        XCTAssertEqual(reloaded.attributes["m10_unknown_root"], "preserve-root")
        XCTAssertEqual(reloaded.maps[0].attributes["m10_map_unknown"], "preserve-map")
        XCTAssertEqual(reloaded.maps[0].rooms[399].attributes["m10_room_unknown"], "preserve-399")
        XCTAssertLessThan(started.duration(to: .now), .seconds(10))
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/M10/\(name)")
    }
}
