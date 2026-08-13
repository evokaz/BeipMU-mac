import BeipPersistence
import AppKit
import BeipCore
@testable import BeipUI
import Foundation
import XCTest

final class PreferencePersistenceTests: XCTestCase {
    func testWorkspacePreferencesRoundTrip() throws {
        let isolatedDefaults = try WorkspaceUITestSupport.makeIsolatedDefaults()
        let suiteName = isolatedDefaults.suiteName
        let defaults = isolatedDefaults.defaults
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = WorkspacePreferences(
            outputHistoryLimit: 2_000,
            showsTimestamps: true,
            usesFanFoldBackgrounds: true,
            outputSplit: true,
            showsInlineImagePreviews: true,
            stickyInput: true,
            inputPrefix: "say ",
            inputHeight: 142,
            checksSpelling: false,
            speechVoiceIdentifier: "com.apple.voice.compact.en-US.Samantha",
            theme: .init(mode: .custom, foregroundHex: "#112233", backgroundHex: "#445566", accentHex: "#778899"),
            logging: .init(logsSentText: true, logsTypedText: true, includesTime: true, wrapWidth: 100),
            dockPlacement: .floating,
            lastDockedPlacement: .left,
            dockThickness: 333,
            workspaceLayout: .splitSidebars,
            workspaceLayouts: ["world/character": .stackedBottom],
            characterNotes: ["example": "Remember the hidden door."],
            spawnSurfaces: [
                "world/character": .init(
                    standaloneWindows: ["WHO"],
                    tabGroups: [.init(title: "Channels", tabs: ["Public", "Staff"], selectedTab: "Staff")]
                ),
            ],
            atlasSurfaces: [
                "world/character": .init(
                    filePath: "/tmp/map.atlas", mapIndex: 2,
                    currentMapIndex: 1, currentRoomIndex: 4,
                    scale: 1.75, originX: 120, originY: -30,
                    selectionFilterRaw: AtlasSelectionFilter.rooms.rawValue,
                    liveTracking: true
                ),
            ],
            webViewPanes: [
                "world/character": [try XCTUnwrap(SavedWebViewPane(.init(
                    id: "status",
                    url: try XCTUnwrap(URL(string: "https://example.invalid/status")),
                    dock: .right,
                    width: 480,
                    height: 320
                )))],
            ],
            tileMapEdits: [
                "world/character": ["surface": .init(name: "surface", columns: 2, rows: 1, encoding: .hex8, tiles: [3, 4])],
            ],
        )
        WorkspacePreferencesStore.save(preferences, defaults: defaults)
        XCTAssertEqual(WorkspacePreferencesStore.load(defaults: defaults), preferences)
        let savedJSON = try XCTUnwrap(defaults.data(forKey: "BeipMU.WorkspacePreferences.v1"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: savedJSON) as? [String: Any])
        XCTAssertNil(object["menuStripPosition"])
    }

    func testWorkspacePreferencesUseSafeDefaultsForMissingOrCorruptData() throws {
        let isolatedDefaults = try WorkspaceUITestSupport.makeIsolatedDefaults()
        let suiteName = isolatedDefaults.suiteName
        let defaults = isolatedDefaults.defaults
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(WorkspacePreferencesStore.load(defaults: defaults), .init())
        defaults.set(Data("not json".utf8), forKey: "BeipMU.WorkspacePreferences.v1")
        XCTAssertEqual(WorkspacePreferencesStore.load(defaults: defaults), .init())
    }

    func testWorkspacePreferencesResetClearsSavedWorkspaceState() throws {
        let isolatedDefaults = try WorkspaceUITestSupport.makeIsolatedDefaults()
        let suiteName = isolatedDefaults.suiteName
        let defaults = isolatedDefaults.defaults
        defer { defaults.removePersistentDomain(forName: suiteName) }

        WorkspacePreferencesStore.save(
            .init(
                workspaceLayouts: ["world": .mainOnly.inserting(.spawn("Pages"), side: .right)],
                spawnSurfaces: ["world": .init(standaloneWindows: ["Pages"])]
            ),
            defaults: defaults
        )
        WorkspacePreferencesStore.reset(defaults: defaults)

        XCTAssertEqual(WorkspacePreferencesStore.load(defaults: defaults), .init())
    }

    func testSessionPreferenceWritesDoNotEraseOtherSessionsSpawnState() throws {
        let isolatedDefaults = try WorkspaceUITestSupport.makeIsolatedDefaults()
        let suiteName = isolatedDefaults.suiteName
        let defaults = isolatedDefaults.defaults
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var first = WorkspacePreferences()
        var second = WorkspacePreferences()
        first.spawnSurfaces["world/first"] = .init(standaloneWindows: ["Pages"])
        first.workspaceLayouts["world/first"] = .mainOnly.inserting(.spawn("Pages"), side: .right)
        second.spawnSurfaces["world/second"] = .init(standaloneWindows: ["WHO"])
        second.workspaceLayouts["world/second"] = .mainOnly

        _ = WorkspacePreferencesStore.saveMergingSessionState(
            first,
            sessionKey: "world/first",
            defaults: defaults
        )
        _ = WorkspacePreferencesStore.saveMergingSessionState(
            second,
            sessionKey: "world/second",
            defaults: defaults
        )

        let restored = WorkspacePreferencesStore.load(defaults: defaults)
        XCTAssertEqual(restored.spawnSurfaces["world/first"]?.standaloneWindows, ["Pages"])
        XCTAssertEqual(restored.spawnSurfaces["world/second"]?.standaloneWindows, ["WHO"])
        XCTAssertTrue(restored.workspaceLayouts["world/first"]?.panes.contains(.spawn("Pages")) == true)
    }

    func testOlderPreferencesDecodeWithoutWorkspaceLayoutFields() throws {
        let isolatedDefaults = try WorkspaceUITestSupport.makeIsolatedDefaults()
        let suiteName = isolatedDefaults.suiteName
        let defaults = isolatedDefaults.defaults
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = #"{"outputHistoryLimit":3000,"showsTimestamps":true,"usesFanFoldBackgrounds":false,"stickyInput":true,"inputPrefix":"pose ","checksSpelling":false}"#
        defaults.set(Data(legacy.utf8), forKey: "BeipMU.WorkspacePreferences.v1")
        let decoded = WorkspacePreferencesStore.load(defaults: defaults)
        XCTAssertEqual(decoded.outputHistoryLimit, 3_000)
        XCTAssertTrue(decoded.showsTimestamps)
        XCTAssertEqual(decoded.inputPrefix, "pose ")
        XCTAssertEqual(decoded.inputHeight, 64)
        XCTAssertEqual(decoded.dockPlacement, .hidden)
        XCTAssertEqual(decoded.lastDockedPlacement, .right)
        XCTAssertFalse(decoded.outputSplit)
        XCTAssertFalse(decoded.showsInlineImagePreviews)
        XCTAssertNil(decoded.workspaceLayout)
        XCTAssertEqual(decoded.characterNotes, [:])
        XCTAssertEqual(decoded.spawnSurfaces, [:])
        XCTAssertEqual(decoded.atlasSurfaces, [:])
        XCTAssertEqual(decoded.workspaceLayouts, [:])
        XCTAssertEqual(decoded.webViewPanes, [:])
        XCTAssertEqual(decoded.tileMapEdits, [:])
    }

    func testRetiredMenuStripFieldCanBeReadAndConsumedWithoutASecondSourceOfTruth() throws {
        let isolatedDefaults = try WorkspaceUITestSupport.makeIsolatedDefaults()
        let suiteName = isolatedDefaults.suiteName
        let defaults = isolatedDefaults.defaults
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let data = try JSONSerialization.data(withJSONObject: [
            "menuStripPosition": "bottom",
            "outputHistoryLimit": 2_000,
        ])
        defaults.set(data, forKey: "BeipMU.WorkspacePreferences.v1")
        XCTAssertTrue(WorkspacePreferencesStore.hasLegacyMenuStripPosition(defaults: defaults))
        XCTAssertEqual(WorkspacePreferencesStore.legacyMenuStripPosition(defaults: defaults), .bottom)
        XCTAssertTrue(WorkspacePreferencesStore.consumeLegacyMenuStripPosition(defaults: defaults))
        XCTAssertFalse(WorkspacePreferencesStore.hasLegacyMenuStripPosition(defaults: defaults))
        XCTAssertEqual(WorkspacePreferencesStore.load(defaults: defaults).outputHistoryLimit, 2_000)
    }

    func testUnsafeLayoutValuesAreNormalizedOnLoad() throws {
        let isolatedDefaults = try WorkspaceUITestSupport.makeIsolatedDefaults()
        let suiteName = isolatedDefaults.suiteName
        let defaults = isolatedDefaults.defaults
        defer { defaults.removePersistentDomain(forName: suiteName) }
        WorkspacePreferencesStore.save(.init(
            outputHistoryLimit: 1,
            inputHeight: 5_000,
            lastDockedPlacement: .floating,
            dockThickness: 5_000,
            workspaceLayout: .split(
                axis: .columns,
                fraction: 20,
                first: .pane(.main),
                second: .pane(.notes)
            )
        ), defaults: defaults)
        let decoded = WorkspacePreferencesStore.load(defaults: defaults)
        XCTAssertEqual(decoded.outputHistoryLimit, 100)
        XCTAssertEqual(decoded.inputHeight, 1_000)
        XCTAssertEqual(decoded.lastDockedPlacement, .right)
        XCTAssertEqual(decoded.dockThickness, 600)
        guard case let .split(_, fraction, _, _) = decoded.workspaceLayout else {
            return XCTFail("Expected saved split layout")
        }
        XCTAssertEqual(fraction, 0.85)
    }
}
