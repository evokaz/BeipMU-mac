import BeipCore
import XCTest

final class RenderedLineTests: XCTestCase {
    func testRenderedLineRoundTripsThroughJSON() throws {
        let line = RenderedLine(
            text: "Hello 🌍",
            runs: [.init(range: 0..<5, style: .init(foreground: .init(red: 1, green: 2, blue: 3), bold: true))],
            source: .server
        )
        let decoded = try JSONDecoder().decode(RenderedLine.self, from: JSONEncoder().encode(line))
        XCTAssertEqual(decoded, line)
    }

    func testConnectPlaceholders() {
        let character = CharacterProfile(name: "Guest", connectText: "connect %NAME% %PASSWORD%", password: "secret")
        XCTAssertEqual(character.name, "Guest")
        XCTAssertEqual(character.connectText, "connect %NAME% %PASSWORD%")
    }
}

