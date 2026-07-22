import BeipCore
import Foundation
@preconcurrency import JavaScriptCore

public struct ScriptEvaluation: Sendable, Equatable {
    public var value: String?
    public var error: String?
    public var outputs: [ScriptOutput]

    public init(value: String? = nil, error: String? = nil, outputs: [ScriptOutput] = []) {
        self.value = value
        self.error = error
        self.outputs = outputs
    }
}

public enum ScriptOutputKind: String, Codable, Sendable, Equatable {
    case debugText
    case debugHTML
    case display
    case displayHTML
    case send
    case receive
    case setInput
    case setVariable
    case deleteVariable
    case closeWindow
    case activity
    case importantActivity
    case runFile
    case playSound
    case stopSounds
}

public struct ScriptHostSnapshot: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var name: String
        public var description: String
        public var matchText: String

        public init(name: String = "", description: String = "", matchText: String = "") {
            self.name = name
            self.description = description
            self.matchText = matchText
        }
    }

    public struct World: Codable, Sendable, Equatable {
        public var name: String
        public var info: String
        public var host: String
        public var characters: [Item]

        public init(name: String, info: String = "", host: String, characters: [Item] = []) {
            self.name = name
            self.info = info
            self.host = host
            self.characters = characters
        }
    }

    public struct Window: Codable, Sendable, Equatable {
        public var title: String
        public var input: String
        public var connected: Bool
        public var logging: Bool
        public var variables: [String: String]

        public init(
            title: String = "",
            input: String = "",
            connected: Bool = false,
            logging: Bool = false,
            variables: [String: String] = [:]
        ) {
            self.title = title
            self.input = input
            self.connected = connected
            self.logging = logging
            self.variables = variables
        }
    }

    public var buildNumber: Int
    public var version: Int
    public var configPath: String
    public var worlds: [World]
    public var aliases: [Item]
    public var triggers: [Item]
    public var window: Window

    public init(
        buildNumber: Int = 331,
        version: Int = 331,
        configPath: String = "",
        worlds: [World] = [],
        aliases: [Item] = [],
        triggers: [Item] = [],
        window: Window = .init()
    ) {
        self.buildNumber = buildNumber
        self.version = version
        self.configPath = configPath
        self.worlds = worlds
        self.aliases = aliases
        self.triggers = triggers
        self.window = window
    }
}

/// A synchronous host call made by a JavaScript evaluation.  The XPC caller
/// replays these in order after the evaluation completes, keeping script
/// output deterministic without allowing the script service to touch AppKit.
public struct ScriptOutput: Codable, Sendable, Equatable {
    public var kind: ScriptOutputKind
    public var value: String

    public init(kind: ScriptOutputKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public actor ScriptRuntime {
    private var virtualMachine: JSVirtualMachine
    private var context: JSContext

    public init() {
        virtualMachine = JSVirtualMachine()
        context = JSContext(virtualMachine: virtualMachine)!
        Self.configure(context)
    }

    public func evaluate(_ source: String, host: ScriptHostSnapshot = .init()) -> ScriptEvaluation {
        beginEvaluation()
        install(host)
        let value = context.evaluateScript(source)
        if let error = exceptionError() {
            return .init(error: error, outputs: outputs())
        }
        return .init(value: value?.isUndefined == false ? value?.toString() : nil, outputs: outputs())
    }

    /// Invokes a named global function without source interpolation.  Trigger
    /// captures therefore remain data rather than executable JavaScript.
    public func call(_ function: String, arguments: [String], host: ScriptHostSnapshot = .init()) -> ScriptEvaluation {
        beginEvaluation()
        install(host)
        guard let callback = context.objectForKeyedSubscript(function), !callback.isUndefined, !callback.isNull else {
            return .init(error: "JavaScript callback '\(function)' is not defined.")
        }
        guard callback.isObject else {
            return .init(error: "JavaScript callback '\(function)' is not a function.")
        }
        let value = callback.call(withArguments: arguments)
        if let error = exceptionError() {
            return .init(error: error, outputs: outputs())
        }
        return .init(value: value?.isUndefined == false ? value?.toString() : nil, outputs: outputs())
    }

    /// Reproduces the Windows trigger callback contract: a flat start/end
    /// range array, a line object, and the active main-window proxy.
    public func callTrigger(
        _ function: String,
        ranges: [Int],
        line: RenderedLine,
        host: ScriptHostSnapshot = .init()
    ) -> ScriptEvaluation {
        beginEvaluation()
        install(host)
        guard let callback = context.objectForKeyedSubscript(function), !callback.isUndefined, !callback.isNull else {
            return .init(error: "JavaScript callback '\(function)' is not defined.")
        }
        guard let data = try? JSONEncoder().encode(line), let lineJSON = String(data: data, encoding: .utf8) else {
            return .init(error: "Unable to encode the trigger line for JavaScript.")
        }
        context.setObject(ranges as NSArray, forKeyedSubscript: "__beipTriggerRanges" as NSString)
        context.setObject(lineJSON as NSString, forKeyedSubscript: "__beipTriggerLineJSON" as NSString)
        let rangeObject = context.evaluateScript("globalThis.__beipUIntArray(globalThis.__beipTriggerRanges)")
        let lineObject = context.evaluateScript("globalThis.__beipLine(JSON.parse(globalThis.__beipTriggerLineJSON))")
        let windowObject = context.objectForKeyedSubscript("window")
        let value = callback.call(withArguments: [rangeObject as Any, lineObject as Any, windowObject as Any])
        context.setObject(nil, forKeyedSubscript: "__beipTriggerRanges" as NSString)
        context.setObject(nil, forKeyedSubscript: "__beipTriggerLineJSON" as NSString)
        if let error = exceptionError() { return .init(error: error, outputs: outputs()) }
        return .init(value: value?.isUndefined == false ? value?.toString() : nil, outputs: outputs())
    }

    public func reset() {
        virtualMachine = JSVirtualMachine()
        context = JSContext(virtualMachine: virtualMachine)!
        Self.configure(context)
    }

    public func helpTypes() -> [String] {
        ["Alias", "Aliases", "App", "Character", "Connection", "FindString", "Puppet", "Socket", "TextWindowLine", "Timer", "Trigger", "Window_Main", "Window_Text", "World"]
    }

    public func help(for type: String) -> String? {
        Self.help[type.lowercased()]
    }

    private static func configure(_ activeContext: JSContext) {
        activeContext.exceptionHandler = { [weak activeContext] _, exception in
            activeContext?.setObject(exception, forKeyedSubscript: "__beipLastException" as NSString)
        }
        activeContext.evaluateScript(Self.compatibilitySource)
    }

    private func beginEvaluation() {
        context.setObject(nil, forKeyedSubscript: "__beipLastException" as NSString)
        _ = context.evaluateScript("globalThis.__beipOutput = []")
    }

    private func install(_ host: ScriptHostSnapshot) {
        guard let data = try? JSONEncoder().encode(host),
              let json = String(data: data, encoding: .utf8) else { return }
        context.setObject(json as NSString, forKeyedSubscript: "__beipHostJSON" as NSString)
        _ = context.evaluateScript("globalThis.__beipSetHostState(JSON.parse(globalThis.__beipHostJSON))")
        context.setObject(nil, forKeyedSubscript: "__beipHostJSON" as NSString)
    }

    private func exceptionError() -> String? {
        guard let exception = context.objectForKeyedSubscript("__beipLastException"), !exception.isNull, !exception.isUndefined else {
            return nil
        }
        return exception.toString()
    }

    private func outputs() -> [ScriptOutput] {
        guard let json = context.evaluateScript("JSON.stringify(globalThis.__beipOutput || [])")?.toString(),
              let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([ScriptOutput].self, from: data)
        else {
            return []
        }
        return values
    }

    private static let compatibilitySource = """
        globalThis.__beipOutput = [];
        globalThis.__beipRecordOutput = function(kind, value) {
          globalThis.__beipOutput.push({ kind: kind, value: String(value) });
          return String(value);
        };
        globalThis.__beipState = { worlds: [], aliases: [], triggers: [], window: { variables: {} } };
        globalThis.__beipCollection = function(values) {
          var items = values || [];
          var collection = function(index) { return collection.Item(index); };
          collection.Item = collection.item = function(index) {
            if (typeof index === 'number') return items[index];
            var key = String(index).toLowerCase();
            return items.find(function(value) {
              return String(value.Name || value.name || value.Description || value.description || '').toLowerCase() === key;
            });
          };
          Object.defineProperty(collection, 'Count', { get: function() { return items.length; } });
          Object.defineProperty(collection, 'count', { get: function() { return items.length; } });
          return collection;
        };
        globalThis.__beipAlias = function(value) {
          return {
            Name: value.name || '', Description: value.description || '',
            FindString: { MatchText: value.matchText || '' },
            StopProcessing: !!value.stopProcessing, Folder: !!value.folder
          };
        };
        globalThis.__beipTrigger = function(value) {
          return {
            Name: value.name || '', Description: value.description || '',
            FindString: { MatchText: value.matchText || '', RegularExpression: false, MatchCase: false, StartsWith: false, EndsWith: false, WholeWord: false },
            Disabled: false, StopProcessing: false, OncePerLine: false,
            Triggers: globalThis.__beipCollection([]), Aliases: globalThis.__beipCollection([])
          };
        };
        globalThis.__beipLine = function(value) {
          var text = String((value && value.text) || '');
          return { String: text, string: text, HTMLString: text, htmlString: text, Length: text.length, length: text.length };
        };
        globalThis.__beipUIntArray = function(values) {
          var result = Array.from(values || []);
          result.Item = result.item = function(index) { return result[Number(index)]; };
          Object.defineProperty(result, 'Count', { get: function() { return result.length; } });
          return result;
        };
        globalThis.beip = { platform: 'macOS', runtime: 'JavaScriptCore' };
        globalThis.app = {};
        globalThis.window = { UserData: null };
        globalThis.window.output = globalThis.window.Output = {
          Write: function(text) { return globalThis.__beipRecordOutput('display', text); },
          write: function(text) { return globalThis.__beipRecordOutput('display', text); },
          WriteHTML: function(text) { return globalThis.__beipRecordOutput('displayHTML', text); },
          writeHTML: function(text) { return globalThis.__beipRecordOutput('displayHTML', text); },
          Create: function(text) { return { String: String(text), HTMLString: String(text), Length: String(text).length }; },
          create: function(text) { return this.Create(text); },
          Add: function(line) { return globalThis.__beipRecordOutput('display', line.String || String(line)); },
          add: function(line) { return this.Add(line); },
          Paused: false
        };
        globalThis.window.history = globalThis.window.History = globalThis.window.output;
        globalThis.window.input = globalThis.window.Input = {
          _selection: [0, 0],
          Get: function() { return String(globalThis.__beipState.window.input || ''); },
          get: function() { return this.Get(); },
          Set: function(text) { globalThis.__beipState.window.input = String(text); return globalThis.__beipRecordOutput('setInput', text); },
          set: function(text) { return this.Set(text); },
          SetSel: function(start, end) { this._selection = [Number(start), Number(end)]; },
          GetSelStart: function() { return this._selection[0]; },
          GetSelEnd: function() { return this._selection[1]; }
        };
        Object.defineProperty(globalThis.window.input, 'Length', { get: function() { return globalThis.window.input.Get().length; } });
        globalThis.window.connection = globalThis.window.Connection = {
          Send: function(text) { return globalThis.__beipRecordOutput('send', text); },
          send: function(text) { return this.Send(text); },
          Transmit: function(text) { return globalThis.__beipRecordOutput('send', text); },
          Receive: function(text) { return globalThis.__beipRecordOutput('receive', text); },
          Display: function(text) { return globalThis.__beipRecordOutput('display', text); },
          IsConnected: function() { return !!globalThis.__beipState.window.connected; },
          IsLogging: function() { return !!globalThis.__beipState.window.logging; },
          Window_Main: globalThis.window
        };
        globalThis.window.GetVariable = function(name) { return globalThis.__beipState.window.variables[String(name)]; };
        globalThis.window.SetVariable = function(name, value) {
          globalThis.__beipState.window.variables[String(name)] = String(value);
          return globalThis.__beipRecordOutput('setVariable', JSON.stringify({ name: String(name), value: String(value) }));
        };
        globalThis.window.DeleteVariable = function(name) {
          delete globalThis.__beipState.window.variables[String(name)];
          return globalThis.__beipRecordOutput('deleteVariable', name);
        };
        globalThis.window.Close = function() { return globalThis.__beipRecordOutput('closeWindow', ''); };
        globalThis.window.Activity = function() { return globalThis.__beipRecordOutput('activity', ''); };
        globalThis.window.AddImportantActivity = function() { return globalThis.__beipRecordOutput('importantActivity', ''); };
        globalThis.window.Run = function(source) { return globalThis.eval(String(source)); };
        globalThis.window.RunFile = function(path) { return globalThis.__beipRecordOutput('runFile', path); };
        globalThis.window.getVariable = globalThis.window.GetVariable;
        globalThis.window.setVariable = globalThis.window.SetVariable;
        globalThis.window.deleteVariable = globalThis.window.DeleteVariable;
        globalThis.window.close = globalThis.window.Close;
        globalThis.window.activity = globalThis.window.Activity;
        globalThis.window.addImportantActivity = globalThis.window.AddImportantActivity;
        globalThis.window.run = globalThis.window.Run;
        globalThis.window.runFile = globalThis.window.RunFile;
        globalThis.window.connection.transmit = globalThis.window.connection.Transmit;
        globalThis.window.connection.receive = globalThis.window.connection.Receive;
        globalThis.window.connection.display = globalThis.window.connection.Display;
        globalThis.window.connection.isConnected = globalThis.window.connection.IsConnected;
        globalThis.window.connection.isLogging = globalThis.window.connection.IsLogging;
        globalThis.window.Properties = {};
        Object.defineProperty(globalThis.window.Properties, 'HWND', { get: function() { throw new Error('HWND is not supported on macOS'); } });
        Object.defineProperty(globalThis.window.Properties, 'Title', { get: function() { return globalThis.window.Title || ''; } });
        globalThis.__beipSetHostState = function(state) {
          globalThis.__beipState = state || globalThis.__beipState;
          globalThis.__beipState.window = globalThis.__beipState.window || { variables: {} };
          globalThis.__beipState.window.variables = globalThis.__beipState.window.variables || {};
          var worldValues = (globalThis.__beipState.worlds || []).map(function(value) {
            var world = { Name: value.name, name: value.name, Info: value.info, info: value.info, Host: value.host, host: value.host };
            world.Characters = world.characters = globalThis.__beipCollection((value.characters || []).map(function(character) {
              return { Name: character.name, name: character.name, Description: character.description || '' };
            }));
            return world;
          });
          globalThis.worlds = globalThis.app.Worlds = globalThis.app.worlds = globalThis.__beipCollection(worldValues);
          globalThis.aliases = globalThis.app.Aliases = globalThis.app.aliases = globalThis.__beipCollection((globalThis.__beipState.aliases || []).map(globalThis.__beipAlias));
          globalThis.triggers = globalThis.app.Triggers = globalThis.app.triggers = globalThis.__beipCollection((globalThis.__beipState.triggers || []).map(globalThis.__beipTrigger));
          globalThis.windows = globalThis.app.Windows = globalThis.app.windows = globalThis.__beipCollection([globalThis.window]);
          globalThis.connections = globalThis.__beipCollection([globalThis.window.connection]);
          globalThis.timers = globalThis.__beipCollection([]);
          globalThis.logs = globalThis.__beipCollection([]);
          globalThis.sockets = globalThis.__beipCollection([]);
          globalThis.lines = globalThis.__beipCollection([]);
          globalThis.window.Title = globalThis.__beipState.window.title || '';
        };
        Object.defineProperties(globalThis.app, {
          BuildNumber: { get: function() { return globalThis.__beipState.buildNumber || 0; } },
          Version: { get: function() { return globalThis.__beipState.version || 0; } },
          ConfigPath: { get: function() { return globalThis.__beipState.configPath || ''; } }
        });
        globalThis.app.ActiveXObject = function(name) { throw new Error('ActiveXObject is not supported on macOS: ' + name); };
        globalThis.ActiveXObject = globalThis.app.ActiveXObject;
        globalThis.app.OutputDebugText = function(text) { return globalThis.__beipRecordOutput('debugText', text); };
        globalThis.app.OutputDebugHTML = function(html) { return globalThis.__beipRecordOutput('debugHTML', html); };
        globalThis.app.Display = function(text) { return globalThis.__beipRecordOutput('display', text); };
        globalThis.app.Send = function(text) { return globalThis.__beipRecordOutput('send', text); };
        globalThis.app.PlaySound = function(path) { return globalThis.__beipRecordOutput('playSound', path); };
        globalThis.app.StopSounds = function() { return globalThis.__beipRecordOutput('stopSounds', ''); };
        globalThis.app.NewTrigger = function() { return globalThis.__beipTrigger({}); };
        globalThis.app.outputDebugText = globalThis.app.OutputDebugText;
        globalThis.app.outputDebugHTML = globalThis.app.OutputDebugHTML;
        globalThis.app.display = globalThis.app.Display;
        globalThis.app.send = globalThis.app.Send;
        globalThis.app.playSound = globalThis.app.PlaySound;
        globalThis.app.stopSounds = globalThis.app.StopSounds;
        globalThis.app.newTrigger = globalThis.app.NewTrigger;
        globalThis.beip.App = globalThis.app;
        globalThis.beip.Window = globalThis.window;
        globalThis.__beipSetHostState(globalThis.__beipState);
        """

    private static let help: [String: String] = [
        "app": "App: BuildNumber, Version, ConfigPath, Worlds, Windows, Triggers, Aliases, OutputDebugText, OutputDebugHTML, PlaySound, StopSounds, NewTrigger",
        "window_main": "Window_Main: Output, History, Input, Connection, Run, RunFile, Close, Activity, AddImportantActivity, GetVariable, SetVariable, DeleteVariable",
        "window_text": "Window_Text: Write, WriteHTML, Create, Add, Paused",
        "connection": "Connection: Send, Transmit, Receive, Display, IsConnected, IsLogging, Window_Main",
        "world": "World: Name, Info, Host, Characters",
        "character": "Character: Name, Description",
        "findstring": "FindString: MatchText, RegularExpression, MatchCase, StartsWith, EndsWith, WholeWord",
        "alias": "Alias: FindString, StopProcessing, Folder",
        "aliases": "Aliases: Item(index-or-name), Count",
        "trigger": "Trigger: FindString, Disabled, StopProcessing, OncePerLine, Triggers, Aliases",
        "timer": "Timer: UserData, Kill (full asynchronous timer support is Milestone 5)",
        "socket": "Socket: unavailable until Milestone 5; external COM/ActiveX activation is unsupported on macOS",
        "puppet": "Puppet: Name, Description (connection routing is exposed by the native client)",
        "textwindowline": "TextWindowLine: String, HTMLString, Length",
    ]
}
