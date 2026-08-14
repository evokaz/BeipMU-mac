import BeipCore
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class SessionRecoveryReplayTests: XCTestCase {
    func testReplayRestoresRenderedPromptSpawnHistoryAndGMCPWithoutConnecting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.SessionRecoveryReplayTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = """
        Version=331
        Connections
        {
          Logging { RestoreLogs=true RestoreBufferSize=256 }
          Shortcuts
          {
            World
            {
              Host="example.test:4000"
              Characters { Hero { RestoreLog=true } }
            }
          }
        }
        """
        let library = ProfileLibrary(workspace: try LegacyConfigurationWorkspace(
            document: LegacyConfigurationDocument(source: source)
        ))
        let server = try XCTUnwrap(library.workspace.servers.first)
        let character = try XCTUnwrap(server.characters.first)
        let store = try SessionRecoveryStore(
            url: directory.appendingPathComponent("Recovery.dat"),
            capacity: 16_384
        )
        let id = try store.beginSession(
            serverID: server.profile.id,
            characterID: character.id,
            serverName: server.profile.name,
            characterName: character.name
        )
        try store.append(.renderedLine(.init(text: "room output")), to: id)
        try store.append(.prompt(.init(text: "prompt>")), to: id)
        try store.append(
            .spawnOutput(title: "Channel", tabGroup: nil, line: .init(text: "spawned")),
            to: id
        )
        try store.append(.inputHistory(["look", "inventory"]), to: id)
        try store.append(
            .gmcp(.init(
                package: "room.info",
                payload: #"{"id":"room-1","area":"Town","name":"Square","description":"","coordinates":{"floor":0,"x":1,"y":2},"size":{"x":1,"y":1},"exits":[]}"#
            )),
            to: id
        )

        let controller = ClientWindowController(
            profileLibrary: library,
            recoveryStore: store,
            runsScriptServices: false
        )
        controller.restoreOpenTab(server: server.profile, character: character)

        XCTAssertFalse(controller.ownsNetworkSession)
        XCTAssertTrue(controller.isDisconnectedSavedProfileForQuickConnect)
        XCTAssertTrue(controller.testingOutputLines().contains("room output"))
        XCTAssertTrue(controller.testingOutputLines().contains("prompt>"))
        XCTAssertFalse(controller.testingOutputLines().contains { $0.localizedCaseInsensitiveContains("crash") })
        XCTAssertEqual(controller.testingSpawnLines(named: "Channel"), ["spawned"])
        XCTAssertEqual(controller.testingInputHistory(), ["look", "inventory"])
        XCTAssertEqual(controller.testingGMCPRoom()?.name, "Square")

        controller.reconnect()
        XCTAssertTrue(controller.testingOutputLines().contains("room output"))
        XCTAssertTrue(controller.testingOutputLines().contains("prompt>"))
        XCTAssertEqual(controller.testingSpawnLines(named: "Channel"), ["spawned"])
        XCTAssertEqual(store.sessionCount, 1)
        XCTAssertEqual(store.sessions.first?.id, id)
        XCTAssertTrue(store.session(id: id)?.records.contains {
            if case let .renderedLine(line) = $0.event { return line.text == "room output" }
            return false
        } == true)
        controller.prepareForApplicationTermination()
        XCTAssertNotNil(store.session(id: id))
        controller.close()
    }
}
