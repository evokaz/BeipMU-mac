import BeipAutomation
import BeipCore
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class ClientInputRoutingTests: XCTestCase {
    private let unrecognizedCommandMessage = "Unrecognized Command, use // to send text directly to the mu*, /help for a list of commands, or set 'Send unrecognized commands' in settings/input window"

    func testUnrecognizedSlashCommandCanRunAliasAndProcessCommandsInResult() throws {
        let controller = try makeController()
        defer { controller.close() }

        controller.testingProcessInput("/heal")
        controller.testingProcessInput("greet")

        let snapshot = controller.testingAutomationSnapshot()
        XCTAssertEqual(snapshot.variables["healed"], "yes")
        XCTAssertEqual(snapshot.variables["greeted"], "yes")
        XCTAssertFalse(controller.testingOutputLines().contains(unrecognizedCommandMessage))
    }

    func testUnmatchedSlashCommandDisplaysDiagnosticInsteadOfSending() throws {
        let controller = try makeController()
        defer { controller.close() }

        controller.testingProcessInput("/unknown")

        XCTAssertEqual(controller.testingOutputLines().last, unrecognizedCommandMessage)
        XCTAssertFalse(controller.testingOutputLines().contains("Not connected."))
    }

    func testReservedAndMalformedRecognizedCommandsBypassAliases() throws {
        let controller = try makeController()
        defer { controller.close() }

        controller.testingProcessInput("/help")
        controller.testingProcessInput("/reconnect extra arguments")

        let snapshot = controller.testingAutomationSnapshot()
        XCTAssertNil(snapshot.variables["reserved"])
        XCTAssertNil(snapshot.variables["malformed"])
        XCTAssertTrue(controller.testingOutputLines().contains { $0.contains("BeipMU - Command Line Help") })
        XCTAssertTrue(controller.testingOutputLines().contains("Usage: /reconnect [all]"))
    }

    func testDoubleSlashEscapeBypassesAliases() throws {
        let controller = try makeController()
        defer { controller.close() }

        controller.testingProcessInput("//look")

        XCTAssertNil(controller.testingAutomationSnapshot().variables["escaped"])
        XCTAssertEqual(controller.testingOutputLines().last, "Not connected.")
    }

    private func makeController() throws -> ClientWindowController {
        let workspace = try LegacyConfigurationWorkspace(document: .init(source: """
        Version=331
        Connections {
          Aliases {
            Active=true Echo=false ProcessCommands=true
            { Description="Slash alias" Replace="/set healed=yes"
              FindString { MatchText="/heal" MatchCase=true StartsWith=true EndsWith=true } }
            { Description="Ordinary alias" Replace="/set greeted=yes"
              FindString { MatchText="greet" MatchCase=true StartsWith=true EndsWith=true } }
            { Description="Reserved alias" Replace="/set reserved=yes"
              FindString { MatchText="/help" MatchCase=true StartsWith=true EndsWith=true } }
            { Description="Malformed reserved alias" Replace="/set malformed=yes"
              FindString { MatchText="/reconnect extra arguments" MatchCase=true StartsWith=true EndsWith=true } }
            { Description="Escaped slash alias" Replace="/set escaped=yes"
              FindString { MatchText="//look" MatchCase=true StartsWith=true EndsWith=true } }
          }
          Shortcuts {
            TestServer { Host="testserver.example:8888" }
          }
        }
        """))
        let server = try XCTUnwrap(workspace.servers.first?.profile)
        let controller = ClientWindowController(
            profileLibrary: ProfileLibrary(workspace: workspace),
            runsScriptServices: false
        )
        controller.restoreOpenTab(server: server, character: nil)
        return controller
    }
}
