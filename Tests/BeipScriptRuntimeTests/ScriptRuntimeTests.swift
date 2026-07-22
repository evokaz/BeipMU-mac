import BeipCore
import BeipScriptRuntime
import XCTest

final class ScriptRuntimeTests: XCTestCase {
    func testPersistentJavaScriptContext() async {
        let runtime = ScriptRuntime()
        _ = await runtime.evaluate("var counter = 40")
        let result = await runtime.evaluate("counter += 2; counter")
        XCTAssertEqual(result, ScriptEvaluation(value: "42", error: nil))
    }

    func testActiveXIsExplicitPlatformException() async {
        let runtime = ScriptRuntime()
        let result = await runtime.evaluate("app.ActiveXObject('Example.Object')")
        XCTAssertNil(result.value)
        XCTAssertTrue(result.error?.contains("not supported on macOS") == true)

        let globalResult = await runtime.evaluate("ActiveXObject('Example.Object')")
        XCTAssertTrue(globalResult.error?.contains("not supported on macOS") == true)
    }

    func testResetCreatesFreshContext() async {
        let runtime = ScriptRuntime()
        _ = await runtime.evaluate("globalThis.sessionValue = 99")
        await runtime.reset()

        let result = await runtime.evaluate("typeof sessionValue")

        XCTAssertEqual(result.value, "undefined")
    }

    func testHostOutputIsOrderedAndCaptured() async {
        let runtime = ScriptRuntime()

        let result = await runtime.evaluate("app.OutputDebugText('first'); app.Send('north'); app.Display('second')")

        XCTAssertEqual(result.outputs, [
            .init(kind: .debugText, value: "first"),
            .init(kind: .send, value: "north"),
            .init(kind: .display, value: "second")
        ])
    }

    func testNamedCallbackReceivesCaptureArgumentsWithoutSourceInterpolation() async {
        let runtime = ScriptRuntime()
        _ = await runtime.evaluate("function onTrigger(first, second) { app.OutputDebugText(first + ':' + second); }")

        let result = await runtime.call("onTrigger", arguments: ["O'Reilly", "$(not code)"])

        XCTAssertNil(result.error)
        XCTAssertEqual(result.outputs, [.init(kind: .debugText, value: "O'Reilly:$(not code)")])
    }

    func testTriggerCallbackReceivesWindowsRangeLineAndWindowArguments() async {
        let runtime = ScriptRuntime()
        _ = await runtime.evaluate("function onTrigger(ranges, line, main) { app.OutputDebugText(ranges.Count + ':' + ranges.Item(2) + ':' + ranges.join(',') + '|' + line.String + '|' + (main === window)); }")
        let line = RenderedLine(text: "HP: 42")

        let result = await runtime.callTrigger(
            "onTrigger",
            ranges: [0, 6, 4, 6],
            line: line,
            host: .init(window: .init(title: "Hero"))
        )

        XCTAssertNil(result.error)
        XCTAssertEqual(result.outputs, [.init(kind: .debugText, value: "4:4:0,6,4,6|HP: 42|true")])
    }

    func testHostSnapshotPopulatesDocumentedCollectionsAndWindowState() async {
        let runtime = ScriptRuntime()
        let host = ScriptHostSnapshot(
            buildNumber: 331,
            configPath: "/tmp/Config.txt",
            worlds: [.init(name: "Lambda", host: "lambda.test:8888", characters: [.init(name: "Guest")])],
            aliases: [.init(description: "North", matchText: "n")],
            triggers: [.init(description: "Health", matchText: "HP:")],
            window: .init(title: "Guest @ Lambda", input: "look", connected: true, logging: true, variables: ["target": "Ada"])
        )

        let result = await runtime.evaluate(
            "[app.BuildNumber, app.ConfigPath, app.worlds.Count, app.worlds(0).characters(0).name, aliases.Count, triggers.Count, window.input.get(), window.connection.IsConnected(), window.GetVariable('target')].join('|')",
            host: host
        )

        XCTAssertEqual(result.value, "331|/tmp/Config.txt|1|Guest|1|1|look|true|Ada")
        XCTAssertNil(result.error)
    }

    func testHostProxyOperationsAreReplayedInSynchronousOrder() async {
        let runtime = ScriptRuntime()

        let result = await runtime.evaluate("window.output.write('one'); window.input.set('two'); window.SetVariable('target', 'Ada'); window.connection.Send('three'); window.Activity()")

        XCTAssertEqual(result.outputs, [
            .init(kind: .display, value: "one"),
            .init(kind: .setInput, value: "two"),
            .init(kind: .setVariable, value: #"{"name":"target","value":"Ada"}"#),
            .init(kind: .send, value: "three"),
            .init(kind: .activity, value: ""),
        ])
    }

    func testHostProxyLowerCamelCaseAliasesMatchDocumentedDispatchBehavior() async {
        let runtime = ScriptRuntime()

        let result = await runtime.evaluate("app.outputDebugText('one'); window.setVariable('x', 'two'); window.connection.transmit('three'); app.playSound('four')")

        XCTAssertEqual(result.outputs, [
            .init(kind: .debugText, value: "one"),
            .init(kind: .setVariable, value: #"{"name":"x","value":"two"}"#),
            .init(kind: .send, value: "three"),
            .init(kind: .playSound, value: "four"),
        ])
    }

    func testHWNDIsExplicitPlatformExceptionAndSHelpHasMemberDetails() async {
        let runtime = ScriptRuntime()
        let result = await runtime.evaluate("window.Properties.HWND")
        let help = await runtime.help(for: "Connection")

        XCTAssertTrue(result.error?.contains("HWND is not supported on macOS") == true)
        XCTAssertTrue(help?.contains("IsConnected") == true)
    }
}
