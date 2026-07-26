import BeipCore
import XCTest

final class AdvancedGMCPTests: XCTestCase {

    func testAIResponseShapesAndConfiguredPrompt() throws {
        XCTAssertEqual(
            AIClient.decodeText(Data(#"{"response":"hello"}"#.utf8)),
            "hello"
        )
        XCTAssertEqual(
            AIClient.decodeText(Data(#"{"choices":[{"message":{"content":"world"}}]}"#.utf8)),
            "world"
        )
        XCTAssertNil(AIClient.decodeText(Data("{}".utf8)))
    }

    func testAIClientRejectsNonHTTPURLs() async {
        let client = AIClient()
        do {
            _ = try await client.request(.init(prompt: "hello"), endpoint: URL(string: "file:///tmp/ai"))
            XCTFail("Expected an invalid endpoint error")
        } catch {
            XCTAssertEqual(error as? AIClientError, .invalidEndpoint)
        }
    }

    func testMutableTileEditorSupportsUndoRedoAndWireEncoding() throws {
        let map = GMCPTileMap(name: "edit", columns: 2, rows: 2, encoding: .hex8, tiles: [1, 2, 3, 4])
        var editor = TileMapEditor(map: map)
        try editor.setTile(column: 1, row: 0, value: 42)
        XCTAssertEqual(editor.map.tiles, [1, 42, 3, 4])
        XCTAssertEqual(editor.encodedTiles(), "012A0304")
        XCTAssertTrue(editor.undo())
        XCTAssertEqual(editor.map, map)
        XCTAssertTrue(editor.redo())
        XCTAssertEqual(editor.map.tiles[1], 42)
        XCTAssertThrowsError(try editor.setTile(column: 4, row: 0, value: 1))
        XCTAssertThrowsError(try editor.setTile(column: 0, row: 0, value: 256))

        let selection = TileMapEditor.Selection(column: 0, row: 0, columns: 2, rows: 1)
        let scrap = try editor.copy(selection)
        XCTAssertEqual(scrap.tiles, [1, 42])
        _ = try editor.cut(selection)
        XCTAssertEqual(editor.map.tiles, [0, 0, 3, 4])
        try editor.paste(scrap, at: .init(column: 0, row: 1))
        XCTAssertEqual(editor.map.tiles, [0, 0, 1, 42])
        let moved = try editor.move(
            .init(column: 0, row: 1, columns: 2, rows: 1),
            by: .init(column: 0, row: -1)
        )
        XCTAssertEqual(moved, selection)
        XCTAssertEqual(editor.map.tiles, [1, 42, 0, 0])
        XCTAssertTrue(editor.clipboardPayload().contains("beip.tilemap.data"))

        var hex4 = TileMapEditor(map: .init(
            name: "hex", columns: 1, rows: 1, encoding: .hex4, tiles: [0]
        ))
        XCTAssertThrowsError(try hex4.setTile(column: 0, row: 0, value: 16))
        try hex4.setEncoding(.hex8)
        try hex4.setTile(column: 0, row: 0, value: 16)
        XCTAssertThrowsError(try hex4.setEncoding(.hex4))
    }
    func testStatisticsApplyPartialUpdatesColorsProgressAndDeletion() throws {
        var state = AdvancedGMCPState()
        let initial = ##"{"Player":{"background-color":"#002040","values":{"0_Name":{"prefix-length":2,"string":"Bennet","name-color":"Ansi256(56)"},"1_HP":{"prefix-length":2,"range":{"value":80,"max":100,"bar-fill":"#00ff00"}},"2_XP":{"prefix-length":2,"progress":{"label":"75%","value":0.75,"outline-color":"transparent"}}}}}"##
        XCTAssertEqual(
            try state.consume(.init(package: "beip.stats", payload: initial)),
            [.statisticsPane("Player")]
        )

        var pane = try XCTUnwrap(state.statisticsPanes["Player"])
        XCTAssertEqual(pane.background, .rgb(.init(red: 0, green: 32, blue: 64)))
        XCTAssertEqual(pane.orderedValues.map(\.name), ["Name", "HP", "XP"])
        XCTAssertEqual(pane.values["0_Name"]?.nameColor, .rgb(.init(red: 95, green: 0, blue: 215)))
        XCTAssertEqual(pane.values["1_HP"]?.value, .range(.init(
            value: 80,
            lower: 0,
            upper: 100,
            style: .init(fill: .rgb(.init(red: 0, green: 255, blue: 0)))
        )))
        XCTAssertEqual(pane.values["2_XP"]?.value, .progress(.init(
            label: "75%",
            value: 0.75,
            style: .init(outline: .transparent)
        )))

        _ = try state.consume(.init(
            package: "Beip.Stats",
            payload: #"{"Player":{"values":{"1_HP":{"range":{"value":65}},"0_Name":null}}}"#
        ))
        pane = try XCTUnwrap(state.statisticsPanes["Player"])
        XCTAssertNil(pane.values["0_Name"])
        XCTAssertEqual(pane.values["1_HP"]?.value, .range(.init(
            value: 65,
            lower: 0,
            upper: 100,
            style: .init(fill: .rgb(.init(red: 0, green: 255, blue: 0)))
        )))

        _ = try state.consume(.init(package: "beip.stats", payload: #"{"Player":{"values":null}}"#))
        XCTAssertTrue(try XCTUnwrap(state.statisticsPanes["Player"]).values.isEmpty)
    }

    func testAvatarIDsRequestOnceAndDecorateNextLine() throws {
        var state = AdvancedGMCPState()
        let first = try state.consume(.init(package: "beip.line.id", payload: #""1234""#))
        XCTAssertEqual(first, [.transmit(.init(package: "beip.id.request", payload: #""1234""#))])
        XCTAssertTrue(try state.consume(.init(package: "beip.line.id", payload: #""1234""#)).isEmpty)

        _ = try state.consume(.init(
            package: "beip.ids",
            payload: #"{"1234":{"url":"https://example.test/avatar.png","click-url":"https://example.test/profile","hover-text":"Bennet"}}"#
        ))
        _ = try state.consume(.init(package: "beip.line.id", payload: #""1234""#))
        let decorated = state.decorate(.init(text: "Bennet says hello"))
        XCTAssertEqual(decorated.assets, [.init(
            kind: .avatar,
            source: URL(string: "https://example.test/avatar.png")!,
            altText: "Bennet",
            characterOffset: 0
        )])
        XCTAssertTrue(state.decorate(.init(text: "next line")).assets.isEmpty)

        _ = try state.consume(.init(package: "beip.line.image-url", payload: #""https://example.test/direct.gif""#))
        XCTAssertEqual(state.decorate(.init(text: "direct")).assets.first?.source.absoluteString, "https://example.test/direct.gif")
    }

    func testRoomInfoNormalizesOptionalFieldsAndTracksExits() throws {
        var state = AdvancedGMCPState()
        let payload = #"{"id":"r1","area":"Arborwatch","name":"Lounge","coords":{"floor":-1,"x":-100,"y":40},"size":{"x":10,"y":12},"exits":[{"id":"e1","destination":"r2","direction":"up","name":"Third Floor"}]}"#
        let events = try state.consume(.init(package: "room.info", payload: payload))
        guard case let .roomInfo(room) = events.first else { return XCTFail("missing room event") }
        XCTAssertEqual(room.id, "r1")
        XCTAssertEqual(room.coordinates, .init(floor: -1, x: -100, y: 40))
        XCTAssertEqual(room.size, .init(x: 10, y: 12))
        XCTAssertEqual(room.exits.first?.destination, "r2")
        XCTAssertEqual(room.exits.first?.description, "")
        XCTAssertEqual(state.currentRoom, room)
    }

    func testAllTileMapEncodingsAndValidation() throws {
        var state = AdvancedGMCPState()
        _ = try state.consume(.init(
            package: "beip.tilemap.info",
            payload: #"{"Hex4":{"tile-url":"https://example.test/tiles.png","tile-size":"16,16","map-size":"4,1","encoding":"Hex_4"},"Hex8":{"map-size":"3,1","encoding":"Hex_8"},"Base64":{"map-size":"4,1","encoding":"base64_8"}}"#
        ))
        _ = try state.consume(.init(package: "beip.tilemap.data", payload: #"{"Hex4":"01af","Hex8":"0010ff","Base64":"AAEC/w=="}"#))
        XCTAssertEqual(state.tileMaps["Hex4"]?.tiles, [0, 1, 10, 15])
        XCTAssertEqual(state.tileMaps["Hex8"]?.tiles, [0, 16, 255])
        XCTAssertEqual(state.tileMaps["Base64"]?.tiles, [0, 1, 2, 255])

        _ = try state.consume(.init(
            package: "beip.tilemap.info",
            payload: #"{"Lighthouse":{"map-size":"32,32","encoding":"zbase64_8"}}"#
        ))
        let compressedFixture = "tZBBCsIwEEVXuc5g9Qqz9h9AvVNRcS0URGh13YXo1mM5bRI6xsmiWj80/eHNHz5xbjqRZWnq3fSfxqPYSMErtxdgBk5q5gPzs5+5QStywdwPLblabzrzwIXPmodEKbblcCQ8IjFbRt0YXL7rDry/H5DkvcSV4aibFXR/3xGt0T8OAIVcFvb7dUGX4xH8xGcixUn/i2HUzs+9cvy9Rk5Hk1Oap2/3W/wF"
        _ = try state.consume(.init(package: "beip.tilemap.data", payload: "{\"Lighthouse\":\"\(compressedFixture)\"}"))
        XCTAssertEqual(state.tileMaps["Lighthouse"]?.tiles.count, 1024)

        XCTAssertThrowsError(try state.consume(.init(
            package: "beip.tilemap.info",
            payload: #"{"Bad":{"map-size":"257,1"}}"#
        ))) { XCTAssertEqual($0 as? AdvancedGMCPError, .sizeTooLarge("map-size")) }
    }
}
