import BeipCore
import BeipPersistence
import Foundation
import XCTest

final class AtlasEditorTests: XCTestCase {
    func testV2ModelRoundTripsEveryEditableElementAndUnknownAttributes() throws {
        let source = Data("""
        <?xml version='1.0' encoding='UTF-8'?>
        <atlas version='2' color_background='#101010' future='root'>
          <font_rooms name='Menlo' size='11' weight='bold'/>
          <font_exits name='Arial' size='6'/>
          <font_labels name='Arial' size='9'/>
          <palette name='Night' room='#123456'/>
          <future_root enabled='yes'/>
          <map name='Main' grid='20'>
            <rectangle rect='0,0,400,300' color='#222222' locked='t'/>
            <image src='images/map.png' rect='10,20,110,120' opacity='0.5'/>
            <label text='District' rect='20,30,80,50' color='#ffffff' angle='15'/>
            <room name='Start &amp; Hall' rect='100,100,180,160' color='#4400aa' color_outline='#ffffff' text_angle='270' under_construction='t' server-id='one'/>
            <room name='North' rect='100,0,180,60'/>
            <exit from='0' to='1' name_from='north' name_to='south' points='140,90|140,70' points_split='1' dashed='t'/>
            <future_object answer='42'/>
          </map>
          <map name='Other'><room name='Portal' rect='0,0,50,50'/></map>
          <far_exits><exit map_from='0' map_to='1' from='1' to='0' name_from='portal' name_to='back'/></far_exits>
        </atlas>
        """.utf8)

        let atlas = try AtlasReader.read(from: source)
        XCTAssertEqual(atlas.attributes["future"], "root")
        XCTAssertEqual(atlas.roomFont?.attributes["weight"], "bold")
        XCTAssertEqual(atlas.maps[0].images.first?.source, "images/map.png")
        XCTAssertEqual(atlas.maps[0].labels.first?.text, "District")
        XCTAssertEqual(atlas.maps[0].rooms.first?.outlineColor, "#ffffff")
        XCTAssertEqual(atlas.maps[0].rooms.first?.textAngle, 270)
        XCTAssertEqual(atlas.maps[0].rooms.first?.isUnderConstruction, true)
        XCTAssertEqual(atlas.maps[0].exits.first?.pointsSplit, 1)
        XCTAssertEqual(atlas.maps[0].unknownElements.first?.attributes["answer"], "42")

        let reparsed = try AtlasReader.read(from: AtlasWriter.data(for: atlas))
        XCTAssertEqual(reparsed, atlas)
    }

    func testSeededAtlasRoundTripPropertyAndMalformedInputSafety() throws {
        var random = AtlasSeededRandom(seed: 0xA71A_500D)
        for iteration in 0..<96 {
            let roomCount = random.nextInt(upperBound: 12) + 1
            let rooms = (0..<roomCount).map { roomIndex in
                let x = Double(random.nextInt(upperBound: 2_000) - 1_000)
                let y = Double(random.nextInt(upperBound: 2_000) - 1_000)
                return Atlas.Room(
                    name: "Room \(iteration)-\(roomIndex) 🌍",
                    rect: .init(x1: x, y1: y, x2: x + 20, y2: y + 15),
                    color: String(format: "#%06X", random.nextInt(upperBound: 0x10_00000)),
                    outlineColor: "#ffffff",
                    textAngle: Double(random.nextInt(upperBound: 360)),
                    isUnderConstruction: random.nextInt(upperBound: 2) == 1,
                    attributes: ["future_room": "value-\(random.next())"]
                )
            }
            let exits = (0..<max(0, roomCount - 1)).map { roomIndex in
                Atlas.Exit(
                    nameFrom: "go-\(roomIndex)",
                    nameTo: "back-\(roomIndex)",
                    from: "\(roomIndex)",
                    to: "\(roomIndex + 1)",
                    points: [.init(x: Double(roomIndex), y: Double(iteration))],
                    attributes: ["future_exit": "\(random.next())"]
                )
            }
            let atlas = Atlas(
                maps: [.init(
                    name: "Map \(iteration) & 🗺️",
                    rooms: rooms,
                    exits: exits,
                    rectangles: [.init(
                        rect: .init(x1: -10, y1: -20, x2: 30, y2: 40),
                        attributes: ["future_rectangle": "kept"]
                    )],
                    labels: [.init(
                        text: "Label <\(iteration)>",
                        rect: .init(x1: 1, y1: 2, x2: 3, y2: 4),
                        attributes: ["future_label": "kept"]
                    )],
                    attributes: ["future_map": "\(random.next())"],
                    unknownElements: [.init(name: "future_object", attributes: ["answer": "42"])]
                )],
                attributes: ["future_root": "\(random.next())"],
                unknownElements: [.init(name: "future_root_object", attributes: ["iteration": "\(iteration)"])]
            )

            let reparsed = try AtlasReader.read(from: AtlasWriter.data(for: atlas))
            XCTAssertEqual(reparsed, atlas, "iteration \(iteration)")
        }

        for length in 0..<256 {
            let malformed = Data((0..<length).map { _ in UInt8(truncatingIfNeeded: random.next()) })
            _ = try? AtlasReader.read(from: malformed)
        }
    }

    func testArchiveRoundTripPreservesEmbeddedResourcesAndRejectsUnsafePaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Editable.atlas")
        let atlas = Atlas(maps: [.init(
            name: "Images",
            images: [.init(source: "images/pin.png", rect: .init(x1: 1, y1: 2, x2: 3, y2: 4))]
        )])
        let resource = Data([0x89, 0x50, 0x4e, 0x47])

        try AtlasWriter.write(.init(atlas: atlas, resources: ["images/pin.png": resource]), to: url)
        let loaded = try AtlasReader.readArchive(from: url)
        XCTAssertEqual(loaded.atlas, atlas)
        XCTAssertEqual(loaded.resources["images/pin.png"], resource)
        XCTAssertThrowsError(try AtlasWriter.write(
            .init(atlas: atlas, resources: ["../escape": Data()]),
            to: directory.appendingPathComponent("Unsafe.atlas")
        ))
    }

    func testEditingUndoSelectionOrderingFindAndViewport() {
        var editor = AtlasEditor(atlas: Atlas(maps: [.init(name: "Main")]))
        let background = editor.addRectangle(rect: .init(x1: 0, y1: 0, x2: 300, y2: 300))!
        let room = editor.addRoom(name: "Crossroads", rect: .init(x1: 20, y1: 20, x2: 100, y2: 80))!
        _ = editor.addLabel(text: "Town", rect: .init(x1: 0, y1: 0, x2: 60, y2: 20))
        XCTAssertEqual(editor.findRooms("road").map(\.name), ["Crossroads"])

        editor.selection = [background, room]
        editor.moveSelection(dx: 13, dy: 17, snap: 10)
        XCTAssertEqual(editor.atlas.maps[0].rooms[0].rect.x1, 30)
        XCTAssertEqual(editor.atlas.maps[0].rectangles[0].rect.y1, 20)
        editor.bringSelectionToFront()
        XCTAssertEqual(Set(editor.selection.map(\.elementIndex)), [1, 2])
        editor.undo()
        editor.undo()
        XCTAssertEqual(editor.atlas.maps[0].rooms[0].rect.x1, 20)
        editor.redo()
        XCTAssertEqual(editor.atlas.maps[0].rooms[0].rect.x1, 30)

        var viewport = AtlasViewport()
        viewport.zoom(by: 2, around: .init(x: 50, y: 50))
        XCTAssertEqual(viewport.scale, 2)
        XCTAssertEqual(viewport.origin, .init(x: -50, y: -50))
    }

    func testSelectionFragmentRewritesExitsAndPastesWithOffset() throws {
        var editor = AtlasEditor(atlas: Atlas(maps: [.init(name: "Main")]))
        let first = try XCTUnwrap(editor.addRoom(name: "A", rect: .init(x1: 0, y1: 0, x2: 40, y2: 30)))
        let second = try XCTUnwrap(editor.addRoom(name: "B", rect: .init(x1: 100, y1: 0, x2: 140, y2: 30)))
        let exit = try XCTUnwrap(editor.addExit(from: 0, to: 1, nameFrom: "east"))
        editor.selection = [first, second, exit]

        let fragment = try XCTUnwrap(editor.selectionFragment())
        XCTAssertEqual(fragment.rooms.map(\.name), ["A", "B"])
        XCTAssertEqual(fragment.exits.first?.from, "0")
        XCTAssertEqual(fragment.exits.first?.to, "1")

        let inserted = editor.paste(fragment, offset: .init(x: 25, y: 35))
        XCTAssertEqual(inserted.count, 3)
        XCTAssertEqual(editor.atlas.maps[0].rooms.map(\.name), ["A", "B", "A", "B"])
        XCTAssertEqual(editor.atlas.maps[0].rooms[2].rect.x1, 25)
        XCTAssertEqual(editor.atlas.maps[0].rooms[2].rect.y1, 35)
        XCTAssertEqual(editor.atlas.maps[0].exits.last?.from, "2")
        XCTAssertEqual(editor.atlas.maps[0].exits.last?.to, "3")
        XCTAssertEqual(editor.selection, Set(inserted))
    }

    func testPathsTypedSeenTrackingAndMapCommands() {
        var editor = AtlasEditor(atlas: Atlas(maps: [.init(name: "Main")]))
        let start = editor.addRoom(name: "Start", rect: .init(x1: 0, y1: 0, x2: 80, y2: 60))!
        XCTAssertEqual(start.elementIndex, 0)
        editor.setCurrentLocation(.init(mapIndex: 0, roomIndex: 0))
        let north = editor.addRoomAndExit(name: "North Road", outward: "north", returnCommand: "south")!
        let east = editor.addRoomAndExit(name: "East Road", outward: "east", returnCommand: "west")!
        _ = editor.addExit(from: north.roomIndex, to: east.roomIndex, nameFrom: "southeast", nameTo: "northwest")

        let path = editor.shortestPath(to: east)
        XCTAssertEqual(path?.map(\.command), ["east"])
        XCTAssertEqual(editor.recordTypedExit("EAST"), east)
        XCTAssertTrue(editor.typedExitNames.contains("east"))
        editor.liveTracking = true
        XCTAssertEqual(editor.observeOutput("You arrive at Start."), .init(mapIndex: 0, roomIndex: 0))
        XCTAssertTrue(editor.seenExitNames.contains("west"))
        XCTAssertEqual(editor.guessLocation(in: ["noise", "North Road"]), north)

        editor.setCurrentLocation(.init(mapIndex: 0, roomIndex: 0))
        XCTAssertTrue(editor.addExitToDirectionalRoom(outward: "north", returnCommand: "south"))
        XCTAssertFalse(editor.addExitToDirectionalRoom(outward: "downstairs", returnCommand: "upstairs"))
    }

    func testRoomInfoCreatesAndUpdatesAtlasLocation() {
        var editor = AtlasEditor(atlas: Atlas(maps: []))
        let info = GMCPRoomInfo(
            id: "room-1",
            area: "Harbor",
            name: "Dock",
            coordinates: .init(floor: 2, x: 100, y: 200),
            size: .init(x: 40, y: 30),
            exits: [.init(id: "north", destination: "room-2", direction: "north", name: "Gate", description: "")]
        )
        let location = editor.integrate(info)
        XCTAssertEqual(location, .init(mapIndex: 0, roomIndex: 0))
        XCTAssertEqual(editor.atlas.maps[0].name, "Harbor")
        XCTAssertEqual(editor.atlas.maps[0].rooms[0].rect, .init(x1: 100, y1: 200, x2: 140, y2: 230))
        XCTAssertEqual(editor.atlas.maps[0].rooms[0].attributes["gmcp_id"], "room-1")
        XCTAssertNotNil(editor.atlas.maps[0].rooms[0].attributes["gmcp_exit_north"])

        var changed = info
        changed.name = "Moonlit Dock"
        changed.coordinates.x = 120
        _ = editor.integrate(changed)
        XCTAssertEqual(editor.atlas.maps[0].rooms.count, 1)
        XCTAssertEqual(editor.atlas.maps[0].rooms[0].name, "Moonlit Dock")
        XCTAssertEqual(editor.atlas.maps[0].rooms[0].rect.x1, 120)

        _ = editor.integrate(.init(
            id: "room-2", area: "Harbor", name: "North Gate",
            coordinates: .init(floor: 2, x: 120, y: 120), size: .init(x: 40, y: 30)
        ))
        XCTAssertEqual(editor.atlas.maps[0].exits.first?.nameFrom, "north")
        XCTAssertNil(editor.atlas.maps[0].rooms[0].attributes["gmcp_exit_north"])
        editor.setCurrentLocation(.init(mapIndex: 0, roomIndex: 0))
        XCTAssertEqual(editor.shortestPath(to: .init(mapIndex: 0, roomIndex: 1))?.map(\.command), ["north"])
    }

    func testDeletingRoomsRemovesAttachedExitsAndReindexesSurvivors() {
        let rooms = [
            Atlas.Room(name: "A", rect: .init(x1: 0, y1: 0, x2: 10, y2: 10)),
            Atlas.Room(name: "B", rect: .init(x1: 20, y1: 0, x2: 30, y2: 10)),
            Atlas.Room(name: "C", rect: .init(x1: 40, y1: 0, x2: 50, y2: 10)),
        ]
        let exits = [
            Atlas.Exit(nameFrom: "b", from: "0", to: "1"),
            Atlas.Exit(nameFrom: "c", from: "0", to: "2"),
        ]
        var editor = AtlasEditor(atlas: .init(maps: [.init(name: "Main", rooms: rooms, exits: exits)]))
        editor.setCurrentLocation(.init(mapIndex: 0, roomIndex: 2))
        editor.selection = [try! XCTUnwrap(editor.objectID(for: .init(mapIndex: 0, roomIndex: 1)))]
        editor.deleteSelection()

        XCTAssertEqual(editor.atlas.maps[0].rooms.map(\.name), ["A", "C"])
        XCTAssertEqual(editor.atlas.maps[0].exits.count, 1)
        XCTAssertEqual(editor.atlas.maps[0].exits[0].to, "1")
        XCTAssertEqual(editor.currentLocation, .init(mapIndex: 0, roomIndex: 1))
        editor.undo()
        XCTAssertEqual(editor.atlas.maps[0].rooms.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(editor.atlas.maps[0].exits.count, 2)
    }

    func testShippedV1AndV2AtlasesHaveSemanticWriteRoundTrips() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let maps = repository.deletingLastPathComponent().appendingPathComponent("BeipMU-win/Maps")
        for name in ["FurryMUCK.atlas", "Fluff.atlas", "Arx_Map_by_Precisi.atlas"] {
            let original = try AtlasReader.read(from: maps.appendingPathComponent(name))
            XCTAssertEqual(try AtlasReader.read(from: AtlasWriter.data(for: original)), original, name)
        }
    }
}

private struct AtlasSeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}
