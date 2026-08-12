import BeipCore
import BeipPersistence
import BeipTestSupport
@testable import BeipUI
import XCTest

@MainActor
final class ReconnectProfileRefreshTests: XCTestCase {
    func testReconnectRebuildsRequestFromRefreshedSavedCharacterProfile() async throws {
        let scriptedServer = try ScriptedMUServer()
        let port = try await scriptedServer.start()
        defer { scriptedServer.stop() }

        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer(named: "Reconnect World")
        let characterID = try workspace.addCharacter(toServerID: serverID, named: "Hero")
        try workspace.updateServer(id: serverID) {
            $0.profile.host = "127.0.0.1"
            $0.profile.port = port
        }
        try workspace.updateCharacter(id: characterID, inServerID: serverID) {
            $0.connectText = "old %NAME% %PASSWORD%"
            $0.password = "old-password"
        }

        let library = ProfileLibrary(workspace: workspace)
        let savedServer = try XCTUnwrap(library.workspace.servers.first)
        let savedCharacter = try XCTUnwrap(savedServer.characters.first)
        let controller = ClientWindowController(
            profileLibrary: library,
            runsScriptServices: false
        )
        defer { controller.close() }
        controller.restoreOpenTab(server: savedServer.profile, character: savedCharacter)
        controller.startSavedProfileSession(
            savedServer.profile,
            character: savedCharacter,
            policy: .init(connectTimeoutMilliseconds: 1_000, retryCount: 1)
        )

        try await scriptedServer.run(.init(actions: [
            .init(expect: "old Hero old-password\r\n"),
            .init(disconnect: true),
        ]))

        try library.mutate { workspace in
            try workspace.updateCharacter(id: characterID, inServerID: serverID) {
                $0.connectText = "new %NAME% %PASSWORD%"
                $0.password = "new-password"
            }
        }
        XCTAssertEqual(controller.currentCharacterForTesting?.connectText, "new %NAME% %PASSWORD%")
        XCTAssertEqual(controller.currentCharacterForTesting?.password, "new-password")
        await controller.testingReceiveLine("scrollback survives reconnect")

        let reconnectTask = Task {
            try await scriptedServer.run(.init(actions: [
                .init(expect: "new Hero new-password\r\n"),
                .init(disconnect: true),
            ]))
        }
        controller.reconnect()
        try await reconnectTask.value
        XCTAssertTrue(controller.testingOutputLines().contains("scrollback survives reconnect"))
    }

    func testReconnectFromRestoredProfileClearsWelcomeBeforeAutomaticLogStarts() async throws {
        let scriptedServer = try ScriptedMUServer()
        let port = try await scriptedServer.start()
        defer { scriptedServer.stop() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.ReconnectProfileRefreshTests.\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("automatic.txt")
        defer { try? FileManager.default.removeItem(at: directory) }

        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer(named: "Restored Reconnect World")
        let characterID = try workspace.addCharacter(toServerID: serverID, named: "Hero")
        try workspace.updateServer(id: serverID) {
            $0.profile.host = "127.0.0.1"
            $0.profile.port = port
        }
        try workspace.updateCharacter(id: characterID, inServerID: serverID) {
            $0.connectText = "connect %NAME% %PASSWORD%"
            $0.password = "password"
        }

        let library = ProfileLibrary(workspace: workspace)
        let savedServer = try XCTUnwrap(library.workspace.servers.first)
        let savedCharacter = try XCTUnwrap(savedServer.characters.first)
        let controller = ClientWindowController(
            profileLibrary: library,
            runsScriptServices: false,
            initialPreferences: WorkspacePreferences(
                logging: .init(autoLogEnabled: true, defaultLogFilename: logURL.path)
            )
        )
        defer { controller.close() }
        controller.restoreOpenTab(server: savedServer.profile, character: savedCharacter)
        XCTAssertTrue(controller.testingOutputLines().contains(
            "Welcome to BeipMU for Mac. Choose Connection → Connect… to begin."
        ))

        let serverTask = Task {
            try await scriptedServer.run(.init(actions: [
                .init(expect: "connect Hero password\r\n"),
            ]))
        }
        controller.reconnect()
        try await serverTask.value

        try await eventuallyOnMainActor("automatic reconnect log starts") {
            controller.activeLogCount == 1
        }
        XCTAssertFalse(controller.testingOutputLines().contains(
            "Welcome to BeipMU for Mac. Choose Connection → Connect… to begin."
        ))
        let activeLogURL = try XCTUnwrap(controller.activeLogURLsForTesting.first)
        let contents = try String(contentsOf: activeLogURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("Welcome to BeipMU for Mac. Choose Connection"))

        controller.disconnect()
        try await eventuallyOnMainActor("automatic reconnect log stops") {
            controller.activeLogCount == 0
        }
    }
}
