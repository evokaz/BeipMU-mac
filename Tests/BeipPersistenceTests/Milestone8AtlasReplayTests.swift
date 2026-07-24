import BeipCore
import Foundation
import XCTest
@testable import BeipPersistence

/// Milestone 8 Windows differential: the checked-in
/// `Tests/Fixtures/milestone8-atlas.atlas` seed fixture (two maps, a room
/// with a bent local exit, and one cross-map `map_from`/`map_to` exit) was
/// loaded by the v4.331 reference, edited (create/select/delete/undo/redo,
/// an exit-path drag edit) and saved through `Ctrl+S`. This test round-trips
/// both the seed fixture and the v4.331-saved result
/// (`windows-m8-atlas-final.atlas`) through the portable `AtlasReader` and
/// asserts the same room/exit semantics the Windows capture in `ATLAS.md`
/// documents.
final class Milestone8AtlasReplayTests: XCTestCase {
    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private static func evidenceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Documentation/Evidence/M8/win11-dev")
            .appendingPathComponent(name)
    }

    /// The seed fixture is raw XML (not zipped); `AtlasReader` must read it
    /// directly, matching how v4.331 opened it before its first save.
    func testSeedFixtureParsesWithCrossMapExitAndTwoMaps() throws {
        let atlas = try AtlasReader.read(from: Self.fixtureURL("milestone8-atlas.atlas"))
        XCTAssertEqual(atlas.maps.map(\.name), ["Main", "Annex"])

        let main = try XCTUnwrap(atlas.maps.first { $0.name == "Main" })
        XCTAssertEqual(main.rooms.map(\.name), ["Audit Plaza", "North Hall", "East Wing"])

        let annex = try XCTUnwrap(atlas.maps.first { $0.name == "Annex" })
        XCTAssertEqual(annex.rooms.map(\.name), ["Annex Landing"])

        // The cross-map exit lives in the root-level <far_exits> wrapper (not
        // inside either <map> element), matching the shipped v331 sample
        // maps (e.g. Maps/Fluff.atlas) rather than either <map> block.
        let crossMapExit = try XCTUnwrap(atlas.farExits.first)
        XCTAssertEqual(crossMapExit.mapFrom, "0")
        XCTAssertEqual(crossMapExit.mapTo, "1")
        XCTAssertEqual(crossMapExit.nameFrom, "portal")
        XCTAssertEqual(crossMapExit.nameTo, "out")
    }

    /// v4.331 always saves through the documented ZIP container (`Atlas.xml`
    /// plus an optional images folder) per `Documentation/Mapping.md`, even
    /// when the source file being edited was raw XML; the portable reader
    /// must accept both transparently.
    func testWindowsSavedResultIsAZIPContainerAndReadsIdentically() throws {
        let url = Self.evidenceURL("windows-m8-atlas-final.atlas")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "v4.331 must save as a ZIP container")

        let atlas = try AtlasReader.read(from: url)
        let main = try XCTUnwrap(atlas.maps.first { $0.name == "Main" })

        // The Vault room, created live via /map_addroom against the running
        // v4.331 client, survived a delete/undo/redo/undo cycle: the final
        // saved file must still contain it (proving the undo stack nets out
        // correctly rather than merely toggling a dirty flag).
        XCTAssertTrue(main.rooms.contains { $0.name == "Vault" })
        XCTAssertTrue(main.rooms.contains { $0.name == "East Wing" })
        XCTAssertTrue(main.rooms.contains { $0.name == "North Hall" })

        // v4.331 promotes the version attribute on every save.
        XCTAssertGreaterThanOrEqual(atlas.version, 2)
    }

    /// The exit-path drag-edit evidence in `ATLAS.md`
    /// (`windows-m8-atlas-exit-edit-before.xml` /
    /// `windows-m8-atlas-exit-edit-after.xml`) shows v4.331 inserting a bend
    /// point into an exit's `points` attribute in response to a mouse drag.
    /// The portable `Atlas` model must be able to represent that exact
    /// mutation losslessly.
    func testExitPathBendPointFromWindowsDragEditRoundTrips() throws {
        let before = try AtlasReader.read(from: Self.evidenceURL("windows-m8-atlas-exit-edit-before.xml"))
        let after = try AtlasReader.read(from: Self.evidenceURL("windows-m8-atlas-exit-edit-after.xml"))

        let beforeMain = try XCTUnwrap(before.maps.first { $0.name == "Main" })
        let afterMain = try XCTUnwrap(after.maps.first { $0.name == "Main" })

        let beforeExit = try XCTUnwrap(beforeMain.exits.first { $0.nameFrom == "east" })
        XCTAssertTrue(beforeExit.points.isEmpty, "the exit starts as a straight line with no bend points")

        let afterExit = try XCTUnwrap(afterMain.exits.first { $0.nameFrom == "east" })
        XCTAssertEqual(afterExit.points, [Atlas.Point(x: 360, y: -130)])

        // Re-serializing the edited exit must preserve the bend point.
        let written = AtlasWriter.data(for: after)
        let reparsed = try AtlasReader.read(from: written)
        let reparsedMain = try XCTUnwrap(reparsed.maps.first { $0.name == "Main" })
        let reparsedExit = try XCTUnwrap(reparsedMain.exits.first { $0.nameFrom == "east" })
        XCTAssertEqual(reparsedExit.points, [Atlas.Point(x: 360, y: -130)])
    }

    /// A follow-up Windows capture loaded the corrected `<far_exits>`-wrapped
    /// seed fixture and saved it back through v4.331. Rather than preserving
    /// the `<far_exits>` wrapper, v4.331 normalizes the cross-map exit into a
    /// per-map `<far_exit>`/`<far_exit_opposite>` pair (one half in each
    /// map's own element list) — this is the real, live-observed v331 save
    /// representation for cross-map exits, distinct from the wrapper form.
    /// `AtlasReader` has no typed model for this pair, but its generic
    /// unknown-element fallback must still preserve both halves losslessly
    /// (not silently drop them) so the exit survives further edit/save
    /// cycles even without semantic understanding.
    func testWindowsFarExitOppositePairRoundTripsAsUnknownElements() throws {
        let url = Self.evidenceURL("windows-m8-atlas-farexit-roundtrip.atlas")
        let atlas = try AtlasReader.read(from: url)

        let main = try XCTUnwrap(atlas.maps.first { $0.name == "Main" })
        let farExit = try XCTUnwrap(main.unknownElements.first { $0.name == "far_exit" })
        XCTAssertEqual(farExit.attributes["from"], "5")
        XCTAssertEqual(farExit.attributes["to"], "1")
        XCTAssertEqual(farExit.attributes["name_from"], "portal")
        XCTAssertEqual(farExit.attributes["name_to"], "out")

        let annex = try XCTUnwrap(atlas.maps.first { $0.name == "Annex" })
        let farExitOpposite = try XCTUnwrap(annex.unknownElements.first { $0.name == "far_exit_opposite" })
        XCTAssertEqual(farExitOpposite.attributes["from_map"], "0")
        XCTAssertEqual(farExitOpposite.attributes["from_object"], "4")

        // Re-serializing and re-reading must not drop either half.
        let written = AtlasWriter.data(for: atlas)
        let reparsed = try AtlasReader.read(from: written)
        let reparsedMain = try XCTUnwrap(reparsed.maps.first { $0.name == "Main" })
        XCTAssertTrue(reparsedMain.unknownElements.contains { $0.name == "far_exit" })
        let reparsedAnnex = try XCTUnwrap(reparsed.maps.first { $0.name == "Annex" })
        XCTAssertTrue(reparsedAnnex.unknownElements.contains { $0.name == "far_exit_opposite" })
    }
}
