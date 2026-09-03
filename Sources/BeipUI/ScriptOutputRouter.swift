import BeipCore
import BeipProtocols
import BeipScriptRuntime
import Foundation

/// Pure decoding/ordering layer for script results.  The controller consumes
/// these actions and is the only place where AppKit, sessions, and windows are
/// touched.
struct ScriptOutputRouter {
    enum DebugKind {
        case text
        case html
        case error
    }

    enum Action {
        case debug(DebugKind, String)
        case display(String)
        case displayHTML([RenderedLine])
        case send(String)
        case transmit(String)
        case receive(String)
        case setInput(String)
        case setVariable(name: String, value: String)
        case deleteVariable(String)
        case closeWindow
        case activity(important: Bool)
        case runFile(String)
        case playSound(String)
        case stopSounds
        case scriptError(String)
        case evaluationError(String)
        case reconnect
        case logWrite(String, line: Bool)
        case setInputPrefix(String)
        case setInputTitle(String)
        case setTitlePrefix(String)
        case runCommand(String)
        case openConnectDialog
        case scriptWindow(ScriptWindowOperation)
        case malformedScriptWindow
        case newMainWindow
        case secondaryInput(ScriptWindowOperation)
    }

    static func route(
        _ result: ScriptEvaluation,
        showValue: Bool,
        ansiSettings: ANSISettings = .default
    ) -> [Action] {
        var actions = result.outputs.compactMap { route($0, ansiSettings: ansiSettings) }
        // Evaluation errors and values are intentionally appended after all
        // host outputs.  This preserves the runtime's observable ordering.
        if let error = result.error {
            actions.append(.debug(.error, error))
            actions.append(.evaluationError(error))
        } else if showValue, let value = result.value {
            actions.append(.display(value))
        }
        return actions
    }

    private static func route(_ output: ScriptOutput, ansiSettings: ANSISettings) -> Action? {
        switch output.kind {
        case .debugText: return .debug(.text, output.value)
        case .debugHTML: return .debug(.html, output.value)
        case .display: return .display(output.value)
        case .displayHTML:
            var parser = MUDProtocolPipeline(
                encoding: .utf8,
                pueblo: true,
                puebloActive: true,
                ansi: ansiSettings
            )
            let lines = parser.consume(Data((output.value + "\n").utf8)).compactMap { event -> RenderedLine? in
                if case let .line(line) = event { return line }
                return nil
            }
            return .displayHTML(lines)
        case .send: return .send(output.value)
        case .transmit: return .transmit(output.value)
        case .receive: return .receive(output.value)
        case .setInput: return .setInput(output.value)
        case .setVariable:
            struct Variable: Decodable { var name: String; var value: String }
            guard let data = output.value.data(using: .utf8),
                  let variable = try? JSONDecoder().decode(Variable.self, from: data) else { return nil }
            return .setVariable(name: variable.name, value: variable.value)
        case .deleteVariable: return .deleteVariable(output.value)
        case .closeWindow: return .closeWindow
        case .activity: return .activity(important: false)
        case .importantActivity: return .activity(important: true)
        case .runFile: return .runFile(output.value)
        case .playSound: return .playSound(output.value)
        case .stopSounds: return .stopSounds
        case .scriptError: return .scriptError(output.value)
        case .reconnect: return .reconnect
        case .logWrite: return .logWrite(output.value, line: false)
        case .logWriteLine: return .logWrite(output.value, line: true)
        case .setInputPrefix: return .setInputPrefix(output.value)
        case .setInputTitle: return .setInputTitle(output.value)
        case .setTitlePrefix: return .setTitlePrefix(output.value)
        case .runCommand: return .runCommand(output.value)
        case .openConnectDialog: return .openConnectDialog
        case .scriptWindow:
            guard let data = output.value.data(using: .utf8),
                  let operation = try? JSONDecoder().decode(ScriptWindowOperation.self, from: data) else {
                return .malformedScriptWindow
            }
            return .scriptWindow(operation)
        case .newMainWindow: return .newMainWindow
        case .secondaryInput:
            guard let data = output.value.data(using: .utf8),
                  let operation = try? JSONDecoder().decode(ScriptWindowOperation.self, from: data) else {
                return nil
            }
            return .secondaryInput(operation)
        }
    }
}
