import BeipPersistence
import AppKit
import BeipCore
@testable import BeipUI
import Foundation
import XCTest

final class ToolSurfaceTests: XCTestCase {
    @MainActor
    func testAdvancedGMCPPanesExposeNativeAccessibleContent() throws {
        let stats = GMCPStatisticsWindowController(title: "Player")
        stats.update(.init(
            title: "Player",
            background: .rgb(.init(red: 0, green: 32, blue: 64)),
            values: [
                "0_Health": .init(
                    key: "0_Health",
                    prefixLength: 2,
                    value: .range(.init(value: 80, lower: 0, upper: 100))
                ),
            ]
        ))
        let statsContent = try XCTUnwrap(stats.window?.contentView)
        statsContent.layoutSubtreeIfNeeded()
        let statsViews = WorkspaceUITestSupport.recursiveSubviews(of: statsContent)
        XCTAssertTrue(statsViews.contains { $0.accessibilityLabel() == "Health: 80 [0…100]" })
        XCTAssertTrue(statsViews.contains { $0.accessibilityLabel() == "Progress" })

        let tileMap = TileMapWindowController(title: "Castle")
        let tileMapWindow = try XCTUnwrap(tileMap.window)
        XCTAssertEqual(tileMapWindow.minSize, NSSize(width: 320, height: 220))
        tileMap.update(.init(
            name: "Castle",
            tileWidth: 16,
            tileHeight: 16,
            columns: 4,
            rows: 3,
            encoding: .hex4,
            tiles: Array(repeating: 0, count: 12)
        ))
        let mapContent = try XCTUnwrap(tileMap.window?.contentView)
        let mapViews = WorkspaceUITestSupport.recursiveSubviews(of: mapContent)
        XCTAssertTrue(mapViews.contains { $0.accessibilityLabel() == "Tile map Castle" })
        XCTAssertTrue(mapViews.contains { ($0.accessibilityValue() as? String) == "4 columns by 3 rows" })
        XCTAssertTrue(mapViews.contains { $0.accessibilityIdentifier() == "tileMapEditMode" })
        XCTAssertTrue(mapViews.contains { $0.accessibilityIdentifier() == "tileMapEncoding" })
        XCTAssertTrue(mapViews.contains { $0.accessibilityLabel() == "Tile picker" })
    }

    @MainActor
    func testMCPStatusSurfaceAndEmptyMediaStateAreAccessibleAndSafe() throws {
        let status = MCPStatusWindowController()
        status.update("Connected as Builder")
        let content = try XCTUnwrap(status.window?.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(WorkspaceUITestSupport.recursiveSubviews(of: content).contains { $0.accessibilityLabel() == "MCP status: Connected as Builder" })

        let media = ClientMediaController()
        XCTAssertEqual(media.information, "No Client.Media assets are loaded.")
        media.stop(name: nil)
        media.flush()
    }

    @MainActor
    func testEmbeddedHelpFiltersCommandsAndIsAccessible() throws {
        let help = EmbeddedHelpWindowController()
        help.show(topic: "switchtab")
        let content = try XCTUnwrap(help.window?.contentView)
        let views = WorkspaceUITestSupport.recursiveSubviews(of: content)
        XCTAssertTrue(views.contains { $0.accessibilityIdentifier() == "embeddedHelpSearch" })
        let text = try XCTUnwrap(views.compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(text.string.contains("/switchtab"))
        XCTAssertFalse(text.string.contains("/connect "))
    }

    @MainActor
    func testWebViewBridgeRoutesCommandsAndTracksDisplayCaptureAndGMCPHooks() throws {
        let controller = WebViewWindowController(id: "Character editor")
        defer { controller.close() }
        var commands: [WebViewBridgeCommand] = []
        controller.onCommand = { command in
            commands.append(command)
            if command == .isConnected { return true }
            if case let .property(name) = command { return name == "ID" ? "Character editor" : nil }
            return true
        }
        XCTAssertEqual(try controller.handleBridge(method: "isConnected", arguments: [:]) as? Bool, true)
        _ = try controller.handleBridge(method: "send", arguments: ["text": "look", "processAliases": true])
        XCTAssertTrue(commands.contains(.send(text: "look", processAliases: true)))
        XCTAssertEqual(try controller.handleBridge(method: "getPropertyString", arguments: ["property": "ID"]) as? String, "Character editor")

        _ = try controller.handleBridge(method: "setOnDisplay", arguments: ["id": 7, "regex": "^HP:", "gag": true])
        XCTAssertTrue(controller.observeDisplay(.init(text: "HP: 10")))
        XCTAssertFalse(controller.observeDisplay(.init(text: "Mana: 5")))
        _ = try controller.handleBridge(method: "clearOnDisplay", arguments: ["id": 7])
        XCTAssertFalse(controller.observeDisplay(.init(text: "HP: 10")))

        _ = try controller.handleBridge(method: "setOnDisplayCapture", arguments: ["id": 3, "begin": "^BEGIN$", "end": "^END$"])
        XCTAssertTrue(controller.observeDisplay(.init(text: "BEGIN")))
        XCTAssertTrue(controller.observeDisplay(.init(text: "inside")))
        XCTAssertTrue(controller.observeDisplay(.init(text: "END")))
        XCTAssertEqual(try controller.handleBridge(method: "clearOnDisplayCapture", arguments: ["id": 3]) as? Bool, true)

        _ = try controller.handleBridge(method: "setOnGMCP", arguments: ["prefix": "Char"])
        controller.observeGMCP(.init(package: "Char.Vitals", payload: #"{"hp":10}"#))
        XCTAssertEqual(try controller.handleBridge(method: "clearOnGMCP", arguments: ["prefix": "Char"]) as? Bool, true)
        XCTAssertThrowsError(try controller.handleBridge(method: "setOnDisplay", arguments: ["id": 1, "regex": "["]))
        XCTAssertEqual(controller.webView.accessibilityLabel(), "Web content: Character editor")
    }

    @MainActor
    func testAtlasEditorIntegratesRoomInfoAndExposesNativeAccessibleControls() throws {
        let controller = AtlasWindowController(atlas: Atlas(maps: []))
        XCTAssertFalse(controller.editor.liveTracking)
        controller.integrate(.init(
            id: "dock",
            area: "Harbor",
            name: "Moonlit Dock",
            coordinates: .init(floor: 0, x: 20, y: 30),
            size: .init(x: 100, y: 70)
        ))

        XCTAssertEqual(controller.editor.currentLocation, .init(mapIndex: 0, roomIndex: 0))
        XCTAssertEqual(controller.editor.currentMap?.name, "Harbor")
        XCTAssertFalse(controller.editor.liveTracking, "GMCP integration must not enable or depend on Live track")
        XCTAssertEqual(controller.lookDescription(), "Location: Moonlit Dock\nExits: (none)")
        try controller.restore(.init(
            mapIndex: 0, currentMapIndex: 0, currentRoomIndex: 0,
            scale: 1.5, originX: 44, originY: -12,
            selectionFilterRaw: AtlasSelectionFilter.rooms.rawValue,
            liveTracking: true
        ))
        XCTAssertEqual(controller.editor.viewport, .init(scale: 1.5, origin: .init(x: 44, y: -12)))
        XCTAssertEqual(controller.editor.selectionFilter, .rooms)
        XCTAssertTrue(controller.editor.liveTracking)
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let views = WorkspaceUITestSupport.recursiveSubviews(of: content)
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Atlas map canvas" })
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Atlas editing tool" })
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Atlas map" })
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Known exits" })
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Map zoom" })
        let liveTracking = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Live track" })
        XCTAssertEqual(liveTracking.accessibilityLabel(), "Live track")
        XCTAssertEqual(
            liveTracking.accessibilityHelp(),
            "Track your location when game output matches a reachable room title"
        )
        XCTAssertEqual(liveTracking.toolTip, liveTracking.accessibilityHelp())
        XCTAssertEqual(liveTracking.state, .on)
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.title == "Palette" })
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.title == "Export" })
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.title == "Zoom in" })
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.title == "Fit map" })
        XCTAssertTrue(views.compactMap { $0 as? NSButton }.contains { $0.title == "Create room" })
        for group in ["File", "Navigation", "Create", "Select", "View"] {
            XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == group })
        }
        XCTAssertTrue(content.wantsLayer)
        let openButton = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == "Open" })
        XCTAssertTrue(openButton.wantsLayer)
        let openButtonParent = try XCTUnwrap(openButton.superview)
        XCTAssertFalse(sequence(first: openButtonParent, next: \.superview).contains { $0 is NSClipView })
        for title in ["Open", "Save", "Save As", "Locate", "Create room", "Select", "Add map", "Remove map", "Zoom in", "Fit map", "Palette", "Export"] {
            let button = try XCTUnwrap(
                views.compactMap { $0 as? NSButton }.first { $0.title == title },
                "Missing Atlas toolbar button: \(title)"
            )
            XCTAssertGreaterThan(button.image?.size.width ?? 0, 0, "Missing icon for Atlas toolbar button: \(title)")
            XCTAssertGreaterThan(button.frame.width, 0, "Atlas toolbar button has no width: \(title)")
            XCTAssertGreaterThan(button.frame.height, 0, "Atlas toolbar button has no height: \(title)")
        }
        let canvas = try XCTUnwrap(views.first { $0.accessibilityLabel() == "Atlas map canvas" })
        let mapBarLabel = try XCTUnwrap(views.first { $0.accessibilityLabel() == "Map zoom" })
        XCTAssertGreaterThan(mapBarLabel.superview?.layer?.zPosition ?? 0, canvas.layer?.zPosition ?? 0)

        let location = try XCTUnwrap(controller.editor.currentLocation)
        let roomID = try XCTUnwrap(controller.editor.objectID(for: location))
        controller.editor.selection = [roomID]
        XCTAssertTrue(controller.copySelection())
        XCTAssertTrue(controller.pasteSelection())
        XCTAssertEqual(controller.editor.atlas.maps[0].rooms.count, 2)

        XCTAssertTrue(controller.addRoomAndExit(name: "Harbor Road", outward: "east", returnCommand: "west"))
        var sentCommands: [String] = []
        controller.onSendCommands = { sentCommands += $0 }
        let exits = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "Known exits"
        })
        XCTAssertTrue(exits.isEnabled)
        XCTAssertEqual(exits.numberOfItems, 2)
        exits.selectItem(at: 1)
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(exits.action), to: exits.target, from: exits))
        XCTAssertEqual(sentCommands, ["east"])
    }
}
