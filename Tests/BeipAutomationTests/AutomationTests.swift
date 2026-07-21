import BeipAutomation
import BeipCore
import XCTest

final class AutomationTests: XCTestCase {
    func testAliasCaptureAndVariables() throws {
        let alias = Alias(
            match: .init(text: "^say (.+)$", isRegularExpression: true),
            replacement: "pose says $1 to %target%",
            expandVariables: true
        )
        let result = try AliasEngine.process("say hello", groups: [.init(aliases: [alias])], variables: ["target": "Sam"])
        XCTAssertEqual(result.text, "pose says hello to Sam")
        XCTAssertEqual(result.matchedAliases, [alias.id])
    }

    func testTriggerCooldown() async throws {
        let trigger = Trigger(match: .init(text: "alert"), cooldown: 5, actions: [.activity(important: true)])
        let engine = TriggerEngine()
        let now = Date()
        let first = try await engine.process(.init(text: "alert"), triggers: [trigger], variables: [:], now: now)
        let second = try await engine.process(.init(text: "alert"), triggers: [trigger], variables: [:], now: now.addingTimeInterval(1))
        XCTAssertEqual(first, [.activity(important: true)])
        XCTAssertTrue(second.isEmpty)
    }

    func testCommandQuotingAndVariables() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/set target=Jane Doe", variables: [:]), .setVariable("target", "Jane Doe"))
        XCTAssertEqual(registry.parse("//look", variables: [:]), .send("/look"))
    }

    func testCommandCompatibilityFormsPreservePayloads() {
        let registry = CommandRegistry()
        XCTAssertEqual(
            registry.parse(#"/gmcp Core.Hello {"client":"BeipMU for Mac"}"#, variables: [:]),
            .gmcp(.init(package: "Core.Hello", payload: #"{"client":"BeipMU for Mac"}"#))
        )
        XCTAssertEqual(
            registry.parse(#"/@ app.OutputDebugText("hello world")"#, variables: [:]),
            .script(#"app.OutputDebugText("hello world")"#)
        )
        XCTAssertEqual(registry.parse("/?", variables: [:]), registry.parse("/help", variables: [:]))
        XCTAssertEqual(registry.parse("/silent/set answer=42", variables: [:]), .setVariable("answer", "42"))
        XCTAssertTrue(CommandRegistry.knownCommands.contains("lizards"))
    }
}
