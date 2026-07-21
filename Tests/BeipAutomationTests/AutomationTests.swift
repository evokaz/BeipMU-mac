import BeipAutomation
import BeipCore
import Foundation
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
        XCTAssertEqual(registry.parse("/gmcp dump_on", variables: [:]), .gmcpDump(true))
        XCTAssertEqual(
            registry.parse(#"/@ app.OutputDebugText("hello world")"#, variables: [:]),
            .script(#"app.OutputDebugText("hello world")"#)
        )
        XCTAssertEqual(registry.parse("/?", variables: [:]), registry.parse("/help", variables: [:]))
        XCTAssertEqual(registry.parse("/silent/set answer=42", variables: [:]), .setVariable("answer", "42"))
        XCTAssertEqual(registry.parse("/help delay", variables: [:]), .openCommandHelp("delay"))
        guard case let .display(help) = registry.parse("/help", variables: [:]) else {
            return XCTFail("missing command help")
        }
        XCTAssertTrue(help.contains("/@ $ - Run an immediate script"))
        XCTAssertTrue(help.contains("/wall $ - Send text to all connected windows"))
        XCTAssertTrue(CommandRegistry.knownCommands.contains("lizards"))
    }

    func testLocalEchoAndANSIResetCommands() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/echo", variables: [:]), .localEcho(true))
        XCTAssertEqual(registry.parse("/echo ON", variables: [:]), .localEcho(true))
        XCTAssertEqual(registry.parse("/echo off", variables: [:]), .localEcho(false))
        XCTAssertEqual(
            registry.parse("/echo maybe", variables: [:]),
            .display("Usage: '/echo <ON/off>' Without on/off default is ON.")
        )
        XCTAssertEqual(registry.parse("/ansireset", variables: [:]), .resetANSI)
    }

    func testNAWSAndTerminalTypeCommands() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/naws auto", variables: [:]), .nawsAuto)
        XCTAssertEqual(registry.parse("/naws 132 43", variables: [:]), .naws(132, 43))
        XCTAssertEqual(
            registry.parse("/naws 0 43", variables: [:]),
            .display("Invalid usage, try '/help naws' to see help for this command")
        )
        XCTAssertEqual(registry.parse("/ttype", variables: [:]), .terminalType(nil))
        XCTAssertEqual(registry.parse("/ttype \"Beip Mac\"", variables: [:]), .terminalType("Beip Mac"))
    }

    func testExecutableConnectionAndInjectionCommands() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/connect example.org:8888", variables: [:]), .connect(address: "example.org:8888", character: nil))
        XCTAssertEqual(registry.parse("/connect World Character", variables: [:]), .connect(address: "World", character: "Character"))
        XCTAssertEqual(registry.parse("/disconnect all", variables: [:]), .disconnect(all: true))
        XCTAssertEqual(registry.parse("/reconnect", variables: [:]), .reconnect(all: false))
        XCTAssertEqual(registry.parse("/repeat 3 \"say hello\"", variables: [:]), .repeatCommand(count: 3, command: "say hello"))
        XCTAssertEqual(registry.parse("/receive ANSI text", variables: [:]), .receive("ANSI text"))
        XCTAssertEqual(
            registry.parse(#"/receivegmcp Char.Vitals {"hp":10}"#, variables: [:]),
            .receiveGMCP(.init(package: "Char.Vitals", payload: #"{"hp":10}"#))
        )
        XCTAssertEqual(registry.parse("/ping", variables: [:]), .ping(""))
        XCTAssertEqual(registry.parse("/idle 2 \"look\"", variables: [:]), .idle(minutes: 2, command: "look"))
        XCTAssertEqual(registry.parse("/idle", variables: [:]), .idle(minutes: nil, command: nil))
    }

    func testWindowProfileAndLoggingCommandsHaveTypedOutcomes() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/close", variables: [:]), .close)
        XCTAssertEqual(registry.parse("/new", variables: [:]), .newWindow)
        XCTAssertEqual(registry.parse("/newtab", variables: [:]), .newTab)
        XCTAssertEqual(registry.parse("/stats", variables: [:]), .statistics)
        XCTAssertEqual(registry.parse("/connectioninfo", variables: [:]), .connectionInfo)
        XCTAssertEqual(registry.parse("/opendialog settings ansi", variables: [:]), .openDialog("settings", parameter: "ansi"))
        XCTAssertEqual(registry.parse("/log file.txt", variables: [:]), .startLog(filename: "file.txt", history: .none))
        XCTAssertEqual(registry.parse("/logall all.html", variables: [:]), .startLog(filename: "all.html", history: .all))
        XCTAssertEqual(registry.parse("/stoplogs", variables: [:]), .stopLogs)
    }

    func testDelayCommandGrammarAndScheduler() async throws {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/delay list", variables: [:]), .delay(.list))
        XCTAssertEqual(registry.parse("/delay killall", variables: [:]), .delay(.killAll))
        XCTAssertEqual(registry.parse("/delay kill timer", variables: [:]), .delay(.kill("timer")))
        XCTAssertEqual(
            registry.parse("/delay id pulse every 2m \"look\"", variables: [:]),
            .delay(.schedule(id: "pulse", repeating: true, seconds: 120, command: "look"))
        )

        let scheduler = DelayScheduler()
        let fired = expectation(description: "delayed action")
        let id = await scheduler.schedule(repeating: false, seconds: 0.01, command: "look") { command in
            XCTAssertEqual(command, "look")
            fired.fulfill()
        }
        XCTAssertEqual(id, "1")
        let initialEntries = await scheduler.entries()
        XCTAssertEqual(initialEntries.map(\.id), ["1"])
        await fulfillment(of: [fired], timeout: 1)
        try await Task.sleep(for: .milliseconds(10))
        let finalEntries = await scheduler.entries()
        XCTAssertTrue(finalEntries.isEmpty)
    }

    func testEveryRegisteredCommandProducesACommandOutcome() {
        let registry = CommandRegistry()
        for command in CommandRegistry.knownCommands {
            let outcome = registry.parse("/\(command)", variables: [:])
            if case .unimplemented = outcome {
                XCTFail("Registered command still returns placeholder outcome: /\(command)")
            }
            if case let .display(message) = outcome, message.hasPrefix("Unrecognized Command,") {
                XCTFail("Registered command is not routed: /\(command)")
            }
        }
    }

    func testUnrecognizedCommandDiagnosticMatchesPinnedV331Text() {
        let registry = CommandRegistry()
        let message = "Unrecognized Command, use // to send text directly to the mu*, /help for a list of commands, or set 'Send unrecognized commands' in settings/input window"
        XCTAssertEqual(registry.parse("/unknown", variables: [:]), .display(message))
        XCTAssertEqual(registry.parse("/", variables: [:]), .display(message))
    }

    func testRegistryExactlyCoversPinnedV331ReleaseCommands() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Documentation/PARITY_ITEMS.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let items = try XCTUnwrap(root["items"] as? [[String: Any]])
        var expected = Set(items.compactMap { item -> String? in
            guard item["category"] as? String == "command",
                  item["macStatus"] as? String != "compile-time-excluded",
                  let identifier = item["identifier"] as? String,
                  identifier.hasPrefix("/"), identifier != "//", identifier != "/silent/…"
            else { return nil }
            return String(identifier.dropFirst())
        })
        // The source scanner records the first spelling in combined branches;
        // these release-visible aliases share their implementation.
        expected.formUnion(["@", "world"])
        XCTAssertEqual(CommandRegistry.knownCommands, expected)
    }
}
