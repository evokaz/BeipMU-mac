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
            .init(send: "Welcome\r\n"),
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
                .init(send: "Welcome\r\n"),
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
                logging: .init(
                    autoLogEnabled: true,
                    defaultLogFilename: logURL.path,
                    logsSentText: true,
                    logsTypedText: true
                )
            )
        )
        defer { controller.close() }
        controller.restoreOpenTab(server: savedServer.profile, character: savedCharacter)
        XCTAssertTrue(controller.testingOutputLines().contains(
            "Welcome to BeipMU for Mac. Choose Connection → Connect… to begin."
        ))

        let serverTask = Task {
            try await scriptedServer.run(.init(actions: [
                .init(send: "Welcome, Hero\r\n"),
                .init(expect: "connect Hero password\r\n"),
                .init(expect: "ordinary input\r\n"),
                .init(disconnect: true),
            ]))
        }
        controller.reconnect()

        try await eventuallyOnMainActor("automatic reconnect log starts") {
            controller.activeLogCount == 1
        }
        XCTAssertFalse(controller.testingOutputLines().contains(
            "Welcome to BeipMU for Mac. Choose Connection → Connect… to begin."
        ))
        let activeLogURL = try XCTUnwrap(controller.activeLogURLsForTesting.first)
        controller.testingSubmitInput("ordinary input")
        try await serverTask.value
        try await eventuallyOnMainActor("automatic reconnect log stops") {
            controller.activeLogCount == 0
        }
        let contents = try String(contentsOf: activeLogURL, encoding: .utf8)
        XCTAssertFalse(contents.contains("Welcome to BeipMU for Mac. Choose Connection"))
        XCTAssertFalse(contents.contains("connect Hero password"))
        XCTAssertFalse(contents.contains("password"))
        XCTAssertTrue(contents.contains("Typed>ordinary input"))
        XCTAssertTrue(contents.contains("Sent>ordinary input"))
    }

    func testAutomaticLoginEchoIsFilteredFromHistoryAndAutomaticLog() async throws {
        let scriptedServer = try ScriptedMUServer()
        let port = try await scriptedServer.start()
        defer { scriptedServer.stop() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.ConnectTextEchoTests.\(UUID().uuidString)", isDirectory: true)
        let logURL = directory.appendingPathComponent("automatic.txt")
        defer { try? FileManager.default.removeItem(at: directory) }

        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer(named: "Greeting World")
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
                logging: .init(
                    autoLogEnabled: true,
                    defaultLogFilename: logURL.path,
                    logsSentText: true,
                    logsTypedText: true
                )
            )
        )
        defer { controller.close() }
        controller.restoreOpenTab(server: savedServer.profile, character: savedCharacter)

        let serverTask = Task {
            try await scriptedServer.run(.init(actions: [
                .init(send: "Welcome"),
                .init(delayMilliseconds: 50),
                .init(send: ", Hero\r\n"),
                .init(expect: "connect Hero password\r\n"),
                .init(delayMilliseconds: 150),
                .init(send: "connect Hero password\r\n"),
                .init(send: "You are now in the world.\r\n"),
                .init(disconnect: true),
            ]))
        }
        controller.startSavedProfileSession(
            savedServer.profile,
            character: savedCharacter,
            policy: .init(connectTimeoutMilliseconds: 1_000, retryCount: 1)
        )

        try await eventuallyOnMainActor("automatic greeting log starts") {
            controller.activeLogCount == 1
                && controller.testingOutputLines().contains("Welcome, Hero")
        }
        try await serverTask.value
        try await eventuallyOnMainActor("automatic greeting log stops") {
            controller.activeLogCount == 0
                && controller.testingOutputLines().contains("You are now in the world.")
        }

        let history = controller.testingOutputLines()
        XCTAssertTrue(history.contains("Welcome, Hero"))
        XCTAssertTrue(history.contains("You are now in the world."))
        XCTAssertFalse(history.contains("connect Hero password"))
        XCTAssertFalse(history.contains { $0.contains("password") })

        let activeLogURL = try XCTUnwrap(controller.activeLogURLsForTesting.first ?? logURL)
        let contents = try String(contentsOf: activeLogURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("Welcome, Hero"))
        XCTAssertTrue(contents.contains("You are now in the world."))
        XCTAssertFalse(contents.contains("connect Hero password"))
        XCTAssertFalse(contents.contains("password"))
    }
}
