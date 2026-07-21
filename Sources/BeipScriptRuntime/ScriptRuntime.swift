import BeipCore
import Foundation
@preconcurrency import JavaScriptCore

public struct ScriptEvaluation: Sendable, Equatable {
    public var value: String?
    public var error: String?

    public init(value: String? = nil, error: String? = nil) {
        self.value = value
        self.error = error
    }
}

public actor ScriptRuntime {
    private let virtualMachine: JSVirtualMachine
    private let context: JSContext
    private var lastError: String?

    public init() {
        virtualMachine = JSVirtualMachine()
        context = JSContext(virtualMachine: virtualMachine)!
        context.exceptionHandler = { [weak context] _, exception in
            context?.setObject(exception, forKeyedSubscript: "__beipLastException" as NSString)
        }
        context.evaluateScript(Self.compatibilitySource)
    }

    public func evaluate(_ source: String) -> ScriptEvaluation {
        context.setObject(nil, forKeyedSubscript: "__beipLastException" as NSString)
        let value = context.evaluateScript(source)
        if let exception = context.objectForKeyedSubscript("__beipLastException"), !exception.isNull, !exception.isUndefined {
            return .init(value: nil, error: exception.toString())
        }
        return .init(value: value?.isUndefined == false ? value?.toString() : nil, error: nil)
    }

    public func reset() {
        context.evaluateScript(Self.compatibilitySource)
    }

    public func helpTypes() -> [String] {
        ["Alias", "Aliases", "App", "Character", "Connection", "FindString", "Puppet", "Socket", "TextWindowLine", "Timer", "Trigger", "Window_Main", "Window_Text", "World"]
    }

    private static let compatibilitySource = """
        globalThis.beip = globalThis.beip || {};
        globalThis.app = globalThis.app || {
          ActiveXObject: function(name) { throw new Error('ActiveXObject is not supported on macOS: ' + name); },
          OutputDebugText: function(text) { return String(text); },
          OutputDebugHTML: function(html) { return String(html); }
        };
        globalThis.window = globalThis.window || {};
        globalThis.worlds = globalThis.worlds || [];
        globalThis.windows = globalThis.windows || [];
        globalThis.triggers = globalThis.triggers || [];
        globalThis.aliases = globalThis.aliases || [];
        """
}
