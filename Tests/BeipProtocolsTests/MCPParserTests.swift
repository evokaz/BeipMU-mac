import BeipCore
@testable import BeipProtocols
import XCTest

final class MCPParserTests: XCTestCase {
    func testActivationAdvertisesBundledPackagesAndHidesControlLine() {
        var parser = MCPParser(authenticationKey: "deadbeef")
        let events = parser.consume("#$#mcp version: 2.1 to: 2.1")
        let frames = events.compactMap { event -> String? in
            guard case let .transmit(data) = event else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        XCTAssertEqual(frames.count, 7)
        XCTAssertEqual(frames.first, "#$#mcp authentication-key: deadbeef version: 2.1 to: 2.1\n")
        XCTAssertTrue(frames.contains { $0.contains("package: \"dns-org-mud-moo-simpleedit\"") })
        XCTAssertTrue(frames.contains { $0.contains("package: \"dns-com-awns-status\"") })
        XCTAssertTrue(frames.contains { $0.contains("package: \"dns-com-vmoo-client\"") })
        XCTAssertTrue(frames.contains { $0.contains("package: \"dns-com-awns-ping\"") })
        XCTAssertEqual(frames.last, "#$#mcp-negotiate-end deadbeef\n")
    }

    func testResetRotatesGeneratedAuthenticationKeysButKeepsInjectedFixtureKey() {
        var generated = MCPParser()
        let first = generated.authenticationKey
        generated.reset()
        XCTAssertNotEqual(generated.authenticationKey, first)

        var fixed = MCPParser(authenticationKey: "deadbeef")
        fixed.reset()
        XCTAssertEqual(fixed.authenticationKey, "deadbeef")
    }

    func testNegotiationMultilineSimpleEditQuotedEscapesAndAuthentication() throws {
        var parser = MCPParser(authenticationKey: "deadbeef")
        _ = parser.consume("#$#mcp version: 2.1 to: 2.1")
        XCTAssertTrue(parser.consume("#$#mcp-negotiate-can wrongkey package: \"dns-org-mud-moo-simpleedit\" min-version: \"1.0\" max-version: \"1.0\"").contains {
            if case .diagnostic = $0 { return true }
            return false
        })
        XCTAssertTrue(parser.consume("#$#mcp-negotiate-can deadbeef package: \"dns-org-mud-moo-simpleedit\" min-version: \"1.0\" max-version: \"1.0\"").isEmpty)
        XCTAssertTrue(parser.negotiatedPackages.contains("dns-org-mud-moo-simpleedit"))

        XCTAssertTrue(parser.consume("#$#dns-org-mud-moo-simpleedit deadbeef reference: \"obj-1\" type: \"text\" name: \"A \\\"quoted\\\" name\" content*: \"\" _data-tag: tag1").isEmpty)
        XCTAssertTrue(parser.consume("#$#* tag1 content: first line").isEmpty)
        XCTAssertTrue(parser.consume("#$#* tag1 content: second: line * preserved").isEmpty)
        let completed = parser.consume("#$#: tag1")
        guard case let .message(message) = try XCTUnwrap(completed.first) else { return XCTFail("missing SimpleEdit message") }
        XCTAssertEqual(message.package, "dns-org-mud-moo-simpleedit")
        XCTAssertEqual(message[parameter: "reference"], "obj-1")
        XCTAssertEqual(message[parameter: "name"], "A \"quoted\" name")
        XCTAssertEqual(message.values(for: "content"), ["first line", "second: line * preserved"])
    }

    func testPingRepliesAndEscapedOrdinaryLinesDisplay() throws {
        var parser = MCPParser(authenticationKey: "deadbeef")
        _ = parser.consume("#$#mcp")
        _ = parser.consume("#$#mcp-negotiate-can deadbeef package: \"dns-com-awns-ping\" min-version: \"1.0\" max-version: \"1.0\"")
        let reply = parser.consume("#$#dns-com-awns-ping deadbeef id: \"42\"")
        guard case let .transmit(data) = try XCTUnwrap(reply.first) else { return XCTFail("missing ping reply") }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "#$#dns-com-awns-ping-reply deadbeef id: \"42\"\n")
        XCTAssertEqual(parser.consume("#$\"literal MCP-looking text"), [.display("literal MCP-looking text")])
        XCTAssertEqual(parser.consume("ordinary line"), [.display("ordinary line")])
    }

    func testOutgoingMultilineMessageUsesSingleTagAndRoundTrips() throws {
        var parser = MCPParser(authenticationKey: "deadbeef")
        _ = parser.consume("#$#mcp")
        _ = parser.consume("#$#mcp-negotiate-can deadbeef package: \"dns-org-mud-moo-simpleedit\" min-version: \"1.0\" max-version: \"1.0\"")
        let frames = parser.encode(.init(
            package: "dns-org-mud-moo-simpleedit",
            message: "set",
            parameters: ["reference": "obj-1", "type": "text"],
            multiline: ["content": ["one", "two"]]
        ))
        XCTAssertEqual(frames.count, 4)
        var result: MCPMessage?
        for frame in frames {
            let line = String(decoding: frame.dropLast(), as: UTF8.self)
            for event in parser.consume(line) {
                if case let .message(message) = event { result = message }
            }
        }
        XCTAssertEqual(result?.message, "set")
        XCTAssertEqual(result?.values(for: "content"), ["one", "two"])
    }

    func testPipelineRoutesMCPWithoutRenderingProtocolLines() {
        var pipeline = MUDProtocolPipeline(encoding: .utf8, mcp: true, mcpAuthenticationKey: "deadbeef")
        let activation = pipeline.consume(Data("#$#mcp version: 2.1\n".utf8))
        XCTAssertEqual(activation.filter { if case .transmit = $0 { true } else { false } }.count, 7)
        XCTAssertFalse(activation.contains { if case .line = $0 { true } else { false } })

        let escaped = pipeline.consume(Data("#$\"visible\n".utf8))
        guard case let .line(line) = escaped.first else { return XCTFail("escaped line was not rendered") }
        XCTAssertEqual(line.text, "visible")
    }
}
