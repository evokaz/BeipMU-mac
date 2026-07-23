import XCTest
@testable import BeipCore

final class ClientMediaTests: XCTestCase {
    func testDefaultLoadPlayStopAndFlushState() throws {
        var state = ClientMediaState()
        XCTAssertTrue(try state.consume(.init(package: "Client.Media.Default", payload: #"{"url":"https://media.example/"}"#)).isEmpty)
        let load = try state.consume(.init(package: "client.media.load", payload: #"{"name":"sounds/chime.mp3","url":"https://cdn.example/"}"#))
        XCTAssertTrue(state.isActive)
        guard case let .load(loaded) = load.first else { return XCTFail("missing load") }
        XCTAssertEqual(loaded.source.absoluteString, "https://cdn.example/sounds/chime.mp3")
        XCTAssertTrue(try state.consume(.init(package: "Client.Media.Load", payload: #"{"name":"sounds/chime.mp3","url":"https://other.example/"}"#)).isEmpty)

        let play = try state.consume(.init(package: "Client.Media.Play", payload: #"{"name":"sounds/chime.mp3","volume":80,"loops":3,"continue":false}"#))
        guard case let .play(item) = play.first else { return XCTFail("missing play") }
        XCTAssertEqual(item.volume, 0.8, accuracy: 0.0001)
        XCTAssertEqual(item.loops, 3)
        XCTAssertFalse(item.continues)

        let replay = try state.consume(.init(package: "Client.Media.Play", payload: #"{"name":"sounds/chime.mp3","url":"https://ignored.example/"}"#))
        guard case let .play(replayed) = replay.first else { return XCTFail("missing replay") }
        XCTAssertEqual(replayed.source.absoluteString, "https://cdn.example/sounds/chime.mp3")
        XCTAssertEqual(replayed.volume, 0.5)
        XCTAssertEqual(replayed.loops, 1)
        XCTAssertTrue(replayed.continues)

        XCTAssertEqual(try state.consume(.init(package: "Client.Media.Stop", payload: #"{"name":"sounds/chime.mp3"}"#)), [.stop(name: "sounds/chime.mp3")])
        XCTAssertEqual(try state.consume(.init(package: "Client.Media.Stop", payload: #"{}"#)), [.stop(name: nil)])
        XCTAssertTrue(state.information.contains("sounds/chime.mp3"))
        XCTAssertEqual(state.flush(), [.stop(name: nil)])
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.defaultURL, "")
    }

    func testPlayDefersToDefaultURLAndValidatesInputs() throws {
        var state = ClientMediaState()
        _ = try state.consume(.init(package: "Client.Media.Default", payload: #"{"url":"https://media.example/base/"}"#))
        let play = try state.consume(.init(package: "Client.Media.Play", payload: #"{"name":"theme.ogg"}"#))
        guard case let .play(item) = play.first else { return XCTFail("missing play") }
        XCTAssertEqual(item.source.absoluteString, "https://media.example/base/theme.ogg")
        XCTAssertEqual(item.volume, 0.5)
        XCTAssertEqual(item.loops, 1)
        XCTAssertTrue(item.continues)

        var empty = ClientMediaState()
        XCTAssertThrowsError(try empty.consume(.init(package: "Client.Media.Play", payload: #"{"name":"theme.ogg"}"#))) {
            XCTAssertEqual($0 as? ClientMediaError, .missingURL("theme.ogg"))
        }
        XCTAssertThrowsError(try empty.consume(.init(package: "Client.Media.Load", payload: #"{"url":"https://example/"}"#))) {
            XCTAssertEqual($0 as? ClientMediaError, .missingParameter("name"))
        }
        XCTAssertThrowsError(try empty.consume(.init(package: "Client.Media.Unknown", payload: #"{}"#))) {
            XCTAssertEqual($0 as? ClientMediaError, .unsupportedCommand("unknown"))
        }
        XCTAssertTrue(try empty.consume(.init(package: "Other.Package", payload: #"{}"#)).isEmpty)
    }
}
