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

    func testPuppetRoutingSupportsLiteralRegexHiddenPrefixesAndOutgoingText() {
        let literal = PuppetProfile(name: "Bot", receivePrefix: "Bot> ", sendPrefix: "tell Bot ")
        let regex = PuppetProfile(name: "Numbered", receivePrefix: #"^P\d+: "#, receivePrefixIsRegex: true, hideReceivePrefix: false)

        XCTAssertEqual(PuppetRouter.route("Bot> hello", through: [literal])?.text, "hello")
        XCTAssertEqual(PuppetRouter.route("P12: status", through: [regex])?.text, "P12: status")
        XCTAssertNil(PuppetRouter.route("ordinary", through: [literal, regex]))
        XCTAssertEqual(PuppetRouter.outgoing("look", for: literal), "tell Bot look")
    }
}
