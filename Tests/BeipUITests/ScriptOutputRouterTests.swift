import BeipScriptRuntime
import XCTest
@testable import BeipUI

final class ScriptOutputRouterTests: XCTestCase {
    func testEveryScriptOutputKindRoutesToOneTypedAction() {
        let operation = #"{"identifier":"window","kind":"text","action":"create","strings":["hello"],"numbers":[]}"#
        let fixtures: [(kind: ScriptOutputKind, value: String, action: String)] = [
            (.debugText, "debug", "debug.text"),
            (.debugHTML, "<b>debug</b>", "debug.html"),
            (.display, "display", "display"),
            (.displayHTML, "<b>html</b>", "displayHTML"),
            (.send, "send", "send"),
            (.transmit, "transmit", "transmit"),
            (.receive, "receive", "receive"),
            (.setInput, "input", "setInput"),
            (.setVariable, #"{"name":"answer","value":"42"}"#, "setVariable"),
            (.deleteVariable, "answer", "deleteVariable"),
            (.closeWindow, "", "closeWindow"),
            (.activity, "", "activity"),
            (.importantActivity, "", "importantActivity"),
            (.runFile, "~/startup.js", "runFile"),
            (.playSound, "~/ding.wav", "playSound"),
            (.stopSounds, "", "stopSounds"),
            (.scriptError, "script failed", "scriptError"),
            (.reconnect, "", "reconnect"),
            (.logWrite, "raw log", "logWrite"),
            (.logWriteLine, "line log", "logWriteLine"),
            (.setInputPrefix, "> ", "setInputPrefix"),
            (.setInputTitle, "Command", "setInputTitle"),
            (.setTitlePrefix, "[MUD] ", "setTitlePrefix"),
            (.runCommand, "/help\nlook", "runCommand"),
            (.openConnectDialog, "", "openConnectDialog"),
            (.scriptWindow, operation, "scriptWindow"),
            (.newMainWindow, "", "newMainWindow"),
            (.secondaryInput, operation, "secondaryInput"),
        ]
        let allKinds: [ScriptOutputKind] = [
            .debugText, .debugHTML, .display, .displayHTML, .send, .transmit,
            .receive, .setInput, .setVariable, .deleteVariable, .closeWindow,
            .activity, .importantActivity, .runFile, .playSound, .stopSounds,
            .scriptError, .reconnect, .logWrite, .logWriteLine, .setInputPrefix,
            .setInputTitle, .setTitlePrefix, .runCommand, .openConnectDialog,
            .scriptWindow, .newMainWindow, .secondaryInput,
        ]

        XCTAssertEqual(Set(fixtures.map(\.kind)), Set(allKinds))
        for fixture in fixtures {
            let actions = ScriptOutputRouter.route(
                .init(outputs: [.init(kind: fixture.kind, value: fixture.value)]),
                showValue: false
            )
            XCTAssertEqual(actions.count, 1, "Unexpected action count for \(fixture.kind)")
            XCTAssertEqual(actionLabel(actions[0]), fixture.action, "Unexpected action for \(fixture.kind)")
        }
    }

    func testMalformedJSONOutputsAreIgnoredExceptScriptWindow() {
        let malformed = [
            ScriptOutput(kind: .setVariable, value: "not-json"),
            ScriptOutput(kind: .secondaryInput, value: "not-json"),
        ]
        XCTAssertEqual(ScriptOutputRouter.route(.init(outputs: malformed), showValue: false).count, 0)

        let actions = ScriptOutputRouter.route(
            .init(outputs: [.init(kind: .scriptWindow, value: "not-json")]),
            showValue: false
        )
        guard case .malformedScriptWindow = actions.first else {
            return XCTFail("Malformed script-window output must remain observable")
        }
    }

    func testFinalValueFollowsAllScriptOutputs() {
        let actions = ScriptOutputRouter.route(
            .init(value: "final", outputs: [
                .init(kind: .runFile, value: "script.js"),
                .init(kind: .logWriteLine, value: "line"),
                .init(kind: .setInput, value: "typed"),
            ]),
            showValue: true
        )
        XCTAssertEqual(actions.map(actionLabel), ["runFile", "logWriteLine", "setInput", "display"])
        guard case .display("final") = actions.last else {
            return XCTFail("Final value was not last")
        }
    }

    func testRoutesOutputsBeforeFinalError() {
        let result = ScriptEvaluation(
            error: "runtime failed",
            outputs: [
                .init(kind: .display, value: "before"),
                .init(kind: .setVariable, value: #"{"name":"answer","value":"42"}"#),
            ]
        )

        let actions = ScriptOutputRouter.route(result, showValue: true)
        guard actions.count == 4 else {
            return XCTFail("Expected output actions followed by final error actions")
        }
        guard case .display("before") = actions[0] else { return XCTFail("display order changed") }
        guard case let .setVariable(name, value) = actions[1] else { return XCTFail("variable was not decoded") }
        XCTAssertEqual(name, "answer")
        XCTAssertEqual(value, "42")
        guard case .debug(.error, "runtime failed") = actions[2] else { return XCTFail("error debug action missing") }
        guard case .evaluationError("runtime failed") = actions[3] else { return XCTFail("final error action missing") }
    }

    func testMalformedScriptWindowIsAnExplicitAction() {
        let result = ScriptEvaluation(outputs: [.init(kind: .scriptWindow, value: "not-json")])
        let actions = ScriptOutputRouter.route(result, showValue: false)
        XCTAssertEqual(actions.count, 1)
        guard case .malformedScriptWindow = actions[0] else {
            return XCTFail("Malformed script-window output was silently accepted")
        }
    }

    func testDisplayHTMLIsConvertedWithoutControllerEffects() {
        let result = ScriptEvaluation(outputs: [.init(kind: .displayHTML, value: "<b>hello</b>")])
        let actions = ScriptOutputRouter.route(result, showValue: false)
        guard case let .displayHTML(lines) = actions.first else {
            return XCTFail("HTML output was not converted")
        }
        XCTAssertEqual(lines.map(\.text), ["hello"])
    }

    private func actionLabel(_ action: ScriptOutputRouter.Action) -> String {
        switch action {
        case let .debug(kind, _):
            switch kind {
            case .text: return "debug.text"
            case .html: return "debug.html"
            case .error: return "debug.error"
            }
        case .display: return "display"
        case .displayHTML: return "displayHTML"
        case .send: return "send"
        case .transmit: return "transmit"
        case .receive: return "receive"
        case .setInput: return "setInput"
        case .setVariable: return "setVariable"
        case .deleteVariable: return "deleteVariable"
        case .closeWindow: return "closeWindow"
        case let .activity(important): return important ? "importantActivity" : "activity"
        case .runFile: return "runFile"
        case .playSound: return "playSound"
        case .stopSounds: return "stopSounds"
        case .scriptError: return "scriptError"
        case .evaluationError: return "evaluationError"
        case .reconnect: return "reconnect"
        case let .logWrite(_, line): return line ? "logWriteLine" : "logWrite"
        case .setInputPrefix: return "setInputPrefix"
        case .setInputTitle: return "setInputTitle"
        case .setTitlePrefix: return "setTitlePrefix"
        case .runCommand: return "runCommand"
        case .openConnectDialog: return "openConnectDialog"
        case .scriptWindow: return "scriptWindow"
        case .malformedScriptWindow: return "malformedScriptWindow"
        case .newMainWindow: return "newMainWindow"
        case .secondaryInput: return "secondaryInput"
        }
    }
}
