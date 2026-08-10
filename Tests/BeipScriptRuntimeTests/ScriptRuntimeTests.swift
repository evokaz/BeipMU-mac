import BeipCore
@testable import BeipScriptRuntime
import BeipTestSupport
import XCTest

final class ScriptRuntimeTests: XCTestCase {
    func testConfigurationSpecificScriptServiceIdentifier() {
        XCTAssertEqual(
            ScriptServiceClient.serviceName(for: "org.beipmu.BeipMU"),
            "org.beipmu.BeipMU.ScriptService"
        )
        XCTAssertEqual(
            ScriptServiceClient.serviceName(for: "org.beipmu.BeipMU.Debug"),
            "org.beipmu.BeipMU.Debug.ScriptService"
        )
    }

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

    func testWindowRunQueuesClientCommandInsteadOfEvaluatingJavaScript() async {
        let runtime = ScriptRuntime()

        let result = await runtime.evaluate(
            "window.run('buy torch'); app.OutputDebugText('after')"
        )

        XCTAssertNil(result.error)
        XCTAssertEqual(result.outputs, [
            .init(kind: .runCommand, value: "buy torch"),
            .init(kind: .debugText, value: "after"),
        ])

        let returnValue = await runtime.evaluate("window.Run('look')")
        XCTAssertNil(returnValue.error)
        XCTAssertNil(returnValue.value)
        XCTAssertEqual(returnValue.outputs, [.init(kind: .runCommand, value: "look")])
    }

    func testHostProxyLowerCamelCaseAliasesMatchDocumentedDispatchBehavior() async {
        let runtime = ScriptRuntime()

        let result = await runtime.evaluate("app.outputDebugText('one'); window.setVariable('x', 'two'); window.connection.transmit('three'); app.playSound('four')")

        XCTAssertEqual(result.outputs, [
            .init(kind: .debugText, value: "one"),
            .init(kind: .setVariable, value: #"{"name":"x","value":"two"}"#),
            .init(kind: .transmit, value: "three"),
            .init(kind: .playSound, value: "four"),
        ])
    }

    func testHWNDIsExplicitPlatformExceptionAndSHelpHasMemberDetails() async {
        let runtime = ScriptRuntime()
        let result = await runtime.evaluate("window.Properties.HWND")
        let help = await runtime.help(for: "Connection")
        let types = await runtime.helpTypes()

        XCTAssertTrue(result.error?.contains("HWND is not supported on macOS") == true)
        XCTAssertTrue(help?.contains("IsConnected") == true)
        XCTAssertTrue(types.contains("ArrayUInt"))
        XCTAssertTrue(types.contains("Window_Events"))
        XCTAssertTrue(types.contains("Window_Graphics"))
        XCTAssertTrue(types.contains("Worlds"))
    }

    func testTimeoutRunsAsynchronouslyAndPreservesUserData() async throws {
        let sleeper = TestSleeper()
        let runtime = ScriptRuntime(timerSleep: sleeper.sleep(for:))
        let result = await runtime.evaluate(
            "app.CreateTimeout(10, function(value) { app.OutputDebugText('timeout:' + value); }, 'payload')"
        )
        XCTAssertNil(result.error)
        XCTAssertTrue(result.outputs.isEmpty)

        try await eventually("JavaScript timeout to be scheduled") {
            await sleeper.pendingCount() == 1
        }
        await sleeper.advance()
        try await eventually("JavaScript timeout callback") {
            await runtime.asyncOutputCountForTesting() == 1
        }
        let outputs = await runtime.drainAsyncOutputs()

        XCTAssertEqual(outputs, [
            .init(kind: .debugText, value: "timeout:payload")
        ])
    }

    func testIntervalStopsWhenCallbackReturnsTrueAndKillIsIdempotent() async throws {
        let sleeper = TestSleeper()
        let runtime = ScriptRuntime(timerSleep: sleeper.sleep(for:))
        let created = await runtime.evaluate(
            "var ticks = 0; var timer = app.CreateInterval(5, function() { ticks++; app.OutputDebugText(ticks); return ticks === 2; }); timer.Active"
        )
        XCTAssertEqual(created.value, "true")

        try await eventually("JavaScript interval to be scheduled") {
            await sleeper.pendingCount() == 1
        }
        await sleeper.advance()
        try await eventually("first JavaScript interval callback") {
            let outputCount = await runtime.asyncOutputCountForTesting()
            let pendingCount = await sleeper.pendingCount()
            return outputCount == 1 && pendingCount == 1
        }
        await sleeper.advance()
        try await eventually("second JavaScript interval callback") {
            await runtime.asyncOutputCountForTesting() == 2
        }
        let outputs = await runtime.drainAsyncOutputs()
        let state = await runtime.evaluate("timer.Active + '|' + timers.Count")
        let killed = await runtime.evaluate("timer.Kill(); timer.Kill()")

        XCTAssertEqual(outputs.map(\.value), ["1", "2"])
        XCTAssertEqual(state.value, "false|0")
        XCTAssertNil(killed.error)
    }

    func testAddressValidationAndAsynchronousDNSCallbacks() async throws {
        let runtime = ScriptRuntime()
        let validation = await runtime.evaluate(
            "[app.IsAddress('127.0.0.1'), app.isAddress('::1'), app.IsAddress('not an address')].join('|')"
        )
        XCTAssertEqual(validation.value, "true|true|false")

        let lookup = await runtime.evaluate(
            "app.ForwardDNSLookup('localhost', function(result, tag) { app.OutputDebugText(tag + ':' + (result.length > 0)); }, 'dns')"
        )
        XCTAssertNil(lookup.error)

        let outputs = try await eventually(
            "DNS callback",
            observe: { await runtime.drainAsyncOutputs() },
            until: { !$0.isEmpty }
        )
        XCTAssertEqual(outputs, [.init(kind: .debugText, value: "dns:true")])
    }

    func testNativeSocketConnectSendReceiveAndDisconnectCallbacks() async throws {
        let server = try ScriptedMUServer()
        let port = try await server.start()
        let serverTask = Task {
            try await server.run(.init(actions: [
                .init(expect: "ping"),
                .init(send: "pong", disconnect: true)
            ]))
        }
        let runtime = ScriptRuntime()
        let setup = await runtime.evaluate(
            """
            var socket = app.New_Socket();
            socket.UserData = 'marker';
            socket.SetOnConnect(function(value) { app.OutputDebugText('connect:' + value.UserData); });
            socket.SetOnReceive(function(value, text) { app.OutputDebugText('receive:' + text); });
            socket.SetOnDisconnect(function(value) { app.OutputDebugText('disconnect:' + value.IsConnected()); });
            socket.Connect('127.0.0.1', \(port));
            """
        )
        XCTAssertNil(setup.error)

        let collector = ScriptOutputCollector()
        var observed = try await eventually(
            "script socket connection callback",
            observe: { await collector.collect(from: runtime) },
            until: { $0.contains(where: { $0.value == "connect:marker" }) }
        )
        XCTAssertTrue(observed.contains(.init(kind: .debugText, value: "connect:marker")))
        let connected = await runtime.evaluate("socket.IsConnected()")
        XCTAssertEqual(connected.value, "true")

        let sent = await runtime.evaluate("socket.Send('ping')")
        XCTAssertNil(sent.error)
        try await serverTask.value
        observed = try await eventually(
            "script socket receive and disconnect callbacks",
            observe: { await collector.collect(from: runtime) },
            until: { $0.contains(where: { $0.value == "disconnect:false" }) }
        )
        server.stop()

        XCTAssertTrue(observed.contains(.init(kind: .debugText, value: "receive:pong")))
        XCTAssertTrue(observed.contains(.init(kind: .debugText, value: "disconnect:false")))
    }

    func testTextWindowLineMutationAndRichDisplaySurface() async {
        let runtime = ScriptRuntime()
        let result = await runtime.evaluate(
            """
            var line = window.Output.Create('Hello');
            var suffix = window.Output.Create(' world');
            line.Insert(5, suffix);
            line.Delete(0, 1);
            line.Bold(0, 4);
            line.Color(5, 10, 255);
            window.Output.Add(line);
            [line.String, line.Length, line.HTMLString.indexOf('font-weight:bold') >= 0, line.HTMLString.indexOf('rgb(255,0,0)') >= 0].join('|');
            """
        )

        XCTAssertEqual(result.value, "ello world|10|true|true")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.outputs.count, 1)
        XCTAssertEqual(result.outputs.first?.kind, .displayHTML)
        XCTAssertTrue(result.outputs.first?.value.contains("<p>") == true)
    }

    func testBuildConnectionAndLogProxiesReflectHostSnapshot() async {
        let runtime = ScriptRuntime()
        let host = ScriptHostSnapshot(
            buildDate: "2026-07-22T08:00:00Z",
            worlds: [.init(name: "Lambda", info: "Test", host: "lambda.test:8888")],
            activeWorld: "Lambda",
            activeCharacter: "Ada",
            window: .init(connected: false, logging: true, logFileName: "/tmp/lambda.log")
        )
        let result = await runtime.evaluate(
            """
            var line = window.Output.Create('rich');
            window.Connection.Log.Write('raw');
            window.Connection.Log.WriteLine(line);
            var reconnect = window.Connection.Reconnect();
            [app.BuildDate.getUTCFullYear(), window.Connection.World.Name, window.Connection.Character.Name, window.Connection.Puppet, window.Connection.Log.FileName, reconnect].join('|');
            """,
            host: host
        )

        XCTAssertEqual(result.value, "2026|Lambda|Ada||/tmp/lambda.log|true")
        XCTAssertEqual(result.outputs, [
            .init(kind: .logWrite, value: "raw"),
            .init(kind: .logWriteLine, value: "rich"),
            .init(kind: .reconnect, value: "")
        ])
    }

    func testPersistentConnectionHooksReceiveEventsAndCanMutateDisplayLines() async {
        let runtime = ScriptRuntime()
        let setup = await runtime.evaluate(
            """
            window.Connection.SetOnConnect(function(tag) { app.OutputDebugText('connected:' + tag); }, 'C');
            window.Connection.SetOnReceive(function(text, tag) { app.OutputDebugText(tag + ':' + text); }, 'R');
            window.Connection.SetOnGMCP(function(text) { app.OutputDebugText('gmcp:' + text); });
            window.Connection.SetOnDisplay(function(line) { line.Delete(0, 1); line.Bold(0, line.Length); });
            """
        )
        XCTAssertNil(setup.error)

        let connected = await runtime.dispatchConnectionEvent("connect")
        let received = await runtime.dispatchConnectionEvent("receive", arguments: ["hello"])
        let gmcp = await runtime.dispatchConnectionEvent("gmcp", arguments: ["Char.Vitals {}"])
        let displayed = await runtime.dispatchConnectionEvent("display", line: .init(text: "Hello"))

        XCTAssertEqual(connected.outputs, [.init(kind: .debugText, value: "connected:C")])
        XCTAssertEqual(received.outputs, [.init(kind: .debugText, value: "R:hello")])
        XCTAssertEqual(gmcp.outputs, [.init(kind: .debugText, value: "gmcp:Char.Vitals {}")])
        struct ChangedLine: Decodable { var text: String; var html: String }
        let changed = displayed.value
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(ChangedLine.self, from: $0) }
        XCTAssertEqual(changed?.text, "ello")
        XCTAssertTrue(changed?.html.contains("font-weight:bold") == true)
    }

    func testConnectionAndCommandHooksReturnHandledState() async {
        let runtime = ScriptRuntime()
        _ = await runtime.evaluate(
            "window.connection.SetOnSend(function() { return true; }); window.SetOnCommand(function() { return true; }); window.connection.SetOnDisplay(function(line) { return true; });"
        )

        let send = await runtime.dispatchConnectionEvent("send", arguments: ["north"])
        let command = await runtime.dispatchConnectionEvent("window:command", arguments: ["help", ""])
        let display = await runtime.dispatchConnectionEvent("display", line: .init(text: "hidden"))

        XCTAssertEqual(send.value, "true")
        XCTAssertEqual(command.value, "true")
        XCTAssertTrue(display.value?.contains("\"handled\":true") == true)
    }

    func testInputAndMainWindowMutablePropertiesReplayToNativeHost() async {
        let runtime = ScriptRuntime()
        let host = ScriptHostSnapshot(window: .init(
            input: "look",
            inputPrefix: "say ",
            inputTitle: "Command",
            titlePrefix: "[AFK] "
        ))
        let result = await runtime.evaluate(
            """
            var before = [window.Input.Prefix, window.Input.Title, window.TitlePrefix].join('|');
            window.Input.Prefix = 'pose ';
            window.Input.Title = 'Roleplay';
            window.TitlePrefix = '[IC] ';
            var opened = window.CreateDialogConnect();
            before + '|' + opened;
            """,
            host: host
        )

        XCTAssertEqual(result.value, "say |Command|[AFK] |true")
        XCTAssertEqual(result.outputs, [
            .init(kind: .setInputPrefix, value: "pose "),
            .init(kind: .setInputTitle, value: "Roleplay"),
            .init(kind: .setTitlePrefix, value: "[IC] "),
            .init(kind: .openConnectDialog, value: "")
        ])
    }

    func testScriptWindowFactoriesEmitOrderedNativeOperationsAndKeepSynchronousState() async throws {
        let runtime = ScriptRuntime()
        let result = await runtime.evaluate(
            """
            var text = app.NewWindow_Text(400, 250);
            text.Properties.Title = 'Notes'; text.Write('plain'); text.WriteHTML('<b>rich</b>'); text.Dock(2);
            var fixed = app.NewWindow_FixedText(40, 10);
            fixed.CursorX = 3; fixed.CursorY = 2; fixed.Write('status'); fixed.Clear();
            var graphics = app.NewWindow_Graphics(320, 200);
            graphics.Clear(255); graphics.SetPixel(4, 5, 65280); graphics.SetPen(16711680, 2); graphics.MoveTo(1, 2); graphics.LineTo(8, 9); graphics.Text(10, 11, 'map');
            [graphics.Width, graphics.Height, graphics.GetPixel(4, 5), fixed.CursorX, fixed.CursorY].join('|');
            """
        )

        XCTAssertEqual(result.value, "320|200|65280|0|0")
        XCTAssertNil(result.error)
        let operations = try result.outputs.map { output -> ScriptWindowOperation in
            XCTAssertEqual(output.kind, .scriptWindow)
            return try JSONDecoder().decode(ScriptWindowOperation.self, from: Data(output.value.utf8))
        }
        XCTAssertEqual(operations.filter { $0.action == "create" }.map(\.kind), ["text", "fixed", "graphics"])
        XCTAssertTrue(operations.contains { $0.kind == "text" && $0.action == "html" })
        XCTAssertTrue(operations.contains { $0.kind == "fixed" && $0.action == "writeAt" && $0.numbers == [3, 2] })
        XCTAssertTrue(operations.contains { $0.kind == "graphics" && $0.action == "line" })
    }

    func testMainWindowLifecycleAndCommandHooksPersist() async {
        let runtime = ScriptRuntime()
        _ = await runtime.evaluate(
            """
            window.SetOnCommand(function(command, parameters, tag) { app.OutputDebugText(tag + ':' + command + ':' + parameters); }, 'cmd');
            window.SetOnActivate(function(tag, active) { app.OutputDebugText(tag + ':' + active); }, 'active');
            window.SetOnClose(function(tag) { app.OutputDebugText(tag); }, 'closed');
            """
        )

        let command = await runtime.dispatchConnectionEvent("window:command", arguments: ["echo", "hello world"])
        let activate = await runtime.dispatchConnectionEvent("window:activate", arguments: ["true"])
        let close = await runtime.dispatchConnectionEvent("window:close")

        XCTAssertEqual(command.outputs, [.init(kind: .debugText, value: "cmd:echo:hello world")])
        XCTAssertEqual(activate.outputs, [.init(kind: .debugText, value: "active:true")])
        XCTAssertEqual(close.outputs, [.init(kind: .debugText, value: "closed")])
    }

    func testNewMainWindowFactoryAndGlobalHook() async {
        let runtime = ScriptRuntime()
        let created = await runtime.evaluate(
            "app.SetOnNewWindow(function(tag) { app.OutputDebugText('new:' + tag); }, 'window'); app.NewWindow()"
        )
        let callback = await runtime.dispatchConnectionEvent("app:newWindow")

        XCTAssertEqual(created.outputs, [.init(kind: .newMainWindow, value: "")])
        XCTAssertEqual(callback.outputs, [.init(kind: .debugText, value: "new:window")])
    }

    func testSpawnTabActivationHookUsesNamedGroup() async {
        let runtime = ScriptRuntime()
        let setup = await runtime.evaluate(
            "var tabs = window.GetSpawnTabs('Chat'); tabs.SetOnTabActivate(function(name, tag) { app.OutputDebugText(tag + ':' + name); }, 'tab'); window.GetSpawnTabs('Missing') === null",
            host: .init(spawnTabGroups: ["Chat"])
        )
        let callback = await runtime.dispatchConnectionEvent("spawnTabs:Chat", arguments: ["Public"])

        XCTAssertEqual(setup.value, "true")
        XCTAssertEqual(callback.outputs, [.init(kind: .debugText, value: "tab:Public")])
    }

    func testGetInputReturnsNamedSecondaryInputProxyAndReplaysChanges() async throws {
        let runtime = ScriptRuntime()
        let result = await runtime.evaluate(
            """
            var input = window.GetInput('Input — say ');
            var before = [input.Get(), input.Prefix, input.Title, input.Length].join('|');
            input.Set('hello'); input.Prefix = 'pose '; input.Title = 'Roleplay';
            before + '|' + (window.GetInput('Missing') === null);
            """,
            host: .init(secondaryInputs: [.init(title: "Input — say ", prefix: "say ", text: "hi")])
        )

        XCTAssertEqual(result.value, "hi|say |Input — say |2|true")
        let operations = try result.outputs.map {
            try JSONDecoder().decode(ScriptWindowOperation.self, from: Data($0.value.utf8))
        }
        XCTAssertEqual(operations.map(\.action), ["set", "prefix", "title"])
        XCTAssertTrue(result.outputs.allSatisfy { $0.kind == .secondaryInput })
    }

    func testScriptWindowCloseKeyAndPointerEventsDispatchWithUserData() async throws {
        let runtime = ScriptRuntime()
        let setup = await runtime.evaluate(
            """
            var graphics = app.NewWindow_Graphics(100, 100);
            graphics.Events.SetOnClose(function(tag) { app.OutputDebugText('close:' + tag); }, 'C');
            graphics.Events.SetOnKey(function(key, tag) { app.OutputDebugText('key:' + key + ':' + tag); }, 'K');
            graphics.Events.SetOnMouseMove(function(x, y, tag) { app.OutputDebugText('move:' + x + ',' + y + ':' + tag); }, 'M');
            """
        )
        let create = try setup.outputs
            .map { try JSONDecoder().decode(ScriptWindowOperation.self, from: Data($0.value.utf8)) }
            .first { $0.action == "create" }
        let prefix = "scriptWindow:\(create?.identifier ?? ""):"

        let close = await runtime.dispatchConnectionEvent(prefix + "close")
        let key = await runtime.dispatchConnectionEvent(prefix + "key", arguments: ["36"])
        let move = await runtime.dispatchConnectionEvent(prefix + "mouseMove", arguments: ["12", "34"])

        XCTAssertEqual(close.outputs.first?.value, "close:C")
        XCTAssertEqual(key.outputs.first?.value, "key:36:K")
        XCTAssertEqual(move.outputs.first?.value, "move:12,34:M")
    }

    func testScriptTextWindowPauseCallbackTracksNativeScrollState() async throws {
        let runtime = ScriptRuntime()
        let setup = await runtime.evaluate(
            "var text = app.NewWindow_Text(); text.SetOnPause(function(paused) { app.OutputDebugText('paused:' + paused); });"
        )
        let create = try setup.outputs
            .map { try JSONDecoder().decode(ScriptWindowOperation.self, from: Data($0.value.utf8)) }
            .first { $0.action == "create" }
        let paused = await runtime.dispatchConnectionEvent("scriptWindow:\(create?.identifier ?? ""):pause", arguments: ["true"])
        let state = await runtime.evaluate("text.Paused")

        XCTAssertEqual(paused.outputs, [.init(kind: .debugText, value: "paused:true")])
        XCTAssertEqual(state.value, "true")
    }
}

private actor ScriptOutputCollector {
    private var outputs: [ScriptOutput] = []

    func collect(from runtime: ScriptRuntime) async -> [ScriptOutput] {
        outputs.append(contentsOf: await runtime.drainAsyncOutputs())
        return outputs
    }
}
