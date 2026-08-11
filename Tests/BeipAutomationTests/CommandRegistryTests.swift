@testable import BeipAutomation
import BeipCore
import BeipTestSupport
import Foundation
import XCTest

final class CommandRegistryTests: XCTestCase {
    func testCommandQuotingAndVariables() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/set target=Jane Doe", variables: [:]), .setVariable("target", "Jane Doe"))
        XCTAssertEqual(registry.parse("//look", variables: [:]), .send("/look"))
    }

    func testCommandOutcomes() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/ai explain this", variables: [:]), .ai("explain this"))
        XCTAssertEqual(registry.parse("/ai", variables: [:]), .ai(nil))
        XCTAssertEqual(registry.parse("/gag danger", variables: [:]), .gag("danger"))
        XCTAssertEqual(registry.parse("/grab #1/description", variables: [:]), .grab(object: "#1", property: "description"))
        XCTAssertEqual(registry.parse("/recall 12 warning", variables: [:]), .recall(lineCount: 12, search: "warning"))
        XCTAssertEqual(registry.parse("/rolltest", variables: [:]), .rollTest)
        XCTAssertEqual(registry.parse("/test utf8", variables: [:]), .compatibilityTest("utf8"))
        XCTAssertEqual(
            registry.parse("/test", variables: [:]),
            .display("What do you want to test? (ansi/html/emoji/international/utf8)")
        )
    }

    func testDiceFairnessIsDeterministicAndReportsEverySide() {
        let first = DiceFairnessReport.run(rollCount: 10_000, seed: 42)
        XCTAssertEqual(first, DiceFairnessReport.run(rollCount: 10_000, seed: 42))
        XCTAssertEqual(first.counts.reduce(0, +), first.rollCount)
        XCTAssertEqual(first.counts.count, 6)
        XCTAssertTrue(first.displayText.contains("Side 6 odds:"))
    }

    func testCommandCompatibilityFormsPreservePayloads() {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/gmcp dump_on", variables: [:]), .gmcpDump(true))
        XCTAssertEqual(registry.parse("/tilemap on", variables: [:]), .tileMap(true))
        XCTAssertEqual(registry.parse("/tilemap OFF", variables: [:]), .tileMap(false))
        XCTAssertEqual(
            registry.parse("/tilemap maybe", variables: [:]),
            .display("Usage: '/tilemap on/off' to enable/disable tilemap tag parsing")
        )
        XCTAssertEqual(
            registry.parse(#"/switchtab "Chat Channels" Public"#, variables: [:]),
            .switchSpawnTab(group: "Chat Channels", title: "Public")
        )
        XCTAssertEqual(
            registry.parse("/switchtab only-one", variables: [:]),
            .display("Expected 'tab group' and 'tab name' as parameters")
        )
        XCTAssertEqual(
            registry.parse(#"/map_addroom "Crossroads Hotelry" east west"#, variables: [:]),
            .mapAddRoom(name: "Crossroads Hotelry", outward: "east", returnCommand: "west")
        )
        XCTAssertEqual(
            registry.parse("/map_addexit north south", variables: [:]),
            .mapAddExit(outward: "north", returnCommand: "south")
        )
        XCTAssertEqual(registry.parse("/map_guesslocation", variables: [:]), .mapGuessLocation)
        XCTAssertEqual(registry.parse("/map_look", variables: [:]), .mapLook)
        XCTAssertEqual(
            registry.parse(#"/webview url="https://example.com/page" position="10,20,640,480" state="maximized""#, variables: [:]),
            .webView(.init(
                url: URL(string: "https://example.com/page"),
                frame: .init(x: 10, y: 20, width: 640, height: 480),
                maximized: true
            ))
        )
        XCTAssertEqual(
            registry.parse(#"/webview source="&lt;h1&gt;Hello&lt;/h1&gt;""#, variables: [:]),
            .webView(.init(source: "<h1>Hello</h1>"))
        )
        XCTAssertEqual(
            registry.parse(#"/webview position="bad""#, variables: [:]),
            .display("Command error: Invalid rect")
        )
        XCTAssertEqual(registry.parse("/mcmp flush", variables: [:]), .mediaControl(.flush))
        XCTAssertEqual(registry.parse("/mcmp INFO", variables: [:]), .mediaControl(.info))
        XCTAssertEqual(
            registry.parse("/mcmp", variables: [:]),
            .display("MCMP No parameter specified, available options are flush and info")
        )
        XCTAssertEqual(
            registry.parse("/map_addroom missing", variables: [:]),
            .display("Command is in the form of <room name> <exit to get there> <exit to get back>")
        )
        XCTAssertEqual(
            registry.parse(#"/@ app.OutputDebugText("hello world")"#, variables: [:]),
            .script(#"app.OutputDebugText("hello world")"#)
        )
        XCTAssertEqual(registry.parse("/?", variables: [:]), registry.parse("/help", variables: [:]))
        XCTAssertEqual(registry.parse("/silent/set answer=42", variables: [:]), .setVariable("answer", "42"))
        XCTAssertEqual(registry.parse("/help delay", variables: [:]), .openCommandHelp("delay"))
        XCTAssertEqual(registry.parse("/capturecancel", variables: [:]), .cancelCapture)
        XCTAssertEqual(registry.parse("/debugaliases", variables: [:]), .debugAutomation(.aliases))
        XCTAssertEqual(registry.parse("/debugtriggers", variables: [:]), .debugAutomation(.triggers))
        XCTAssertEqual(registry.parse("/debugtimers", variables: [:]), .debugAutomation(.timers))
        XCTAssertEqual(registry.parse("/debugnetwork", variables: [:]), .debugNetwork)
        guard case let .display(help) = registry.parse("/help", variables: [:]) else {
            return XCTFail("missing command help")
        }
        XCTAssertTrue(help.contains("/@ $ - Run an immediate script"))
        XCTAssertTrue(help.contains("/wall $ - Send text to all connected windows"))
        XCTAssertTrue(CommandRegistry.knownCommands.contains("lizards"))
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
        XCTAssertEqual(registry.parse("/autolog", variables: [:]), .startAutoLog)
    }

    func testSecondaryInputAndEditWindowCommandsHaveTypedOutcomes() {
        let registry = CommandRegistry()
        XCTAssertEqual(
            registry.parse(#"/newinput /unique "say ""#, variables: [:]),
            .newInput(prefix: "say ", unique: true)
        )
        XCTAssertEqual(
            registry.parse("/newinput /unsupported", variables: [:]),
            .display("Unknown option: /unsupported")
        )
        XCTAssertEqual(
            registry.parse("/newinput say /unique", variables: [:]),
            .newInput(prefix: "", unique: true)
        )
        XCTAssertEqual(
            registry.parse(#"/newedit title='Description' capture='5' capture_skip='2' spellcheck='f' prepend='@desc me=&#10;' append='&#10;.'"#, variables: [:]),
            .newEdit(.init(
                title: "Description",
                captureLineCount: 5,
                captureSkipCount: 2,
                checksSpelling: false,
                prepend: "@desc me=\n",
                append: "\n."
            ))
        )
        XCTAssertEqual(
            registry.parse("/newedit capture='many'", variables: [:]),
            .display("Command error: Capture attribute is not a number")
        )
    }

    func testEveryRegisteredCommandProducesACommandOutcome() {
        let registry = CommandRegistry()
        for command in CommandRegistry.knownCommands {
            let outcome = registry.parse("/\(command)", variables: [:])
            if case .unimplemented = outcome {
                XCTFail("Registered command still returns placeholder outcome: /\(command)")
            }
            if case .unrecognizedCommand = outcome {
                XCTFail("Registered command is not routed: /\(command)")
            }
        }
    }

    func testUnrecognizedCommandDiagnostic() {
        let registry = CommandRegistry()
        let message = "Unrecognized Command, use // to send text directly to the mu*, /help for a list of commands, or set 'Send unrecognized commands' in settings/input window"
        XCTAssertEqual(registry.parse("/heal", variables: [:]), .unrecognizedCommand(message))
        XCTAssertEqual(registry.parse("/unknown", variables: [:]), .unrecognizedCommand(message))
        XCTAssertEqual(registry.parse("/", variables: [:]), .unrecognizedCommand(message))
    }

}
