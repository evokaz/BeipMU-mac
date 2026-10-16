import BeipCore
import BeipPersistence
import Foundation
import XCTest
@testable import BeipUI

@MainActor
final class SessionStartupOrderingTests: XCTestCase {
    func testTransportConnectedStartsLoggingButDefersStartupHooksUntilReadyIncludingPuppetReconnect() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.SessionStartupOrderingTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("automatic.txt")

        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let master = ClientWindowController(
            profileLibrary: library,
            runsScriptServices: false,
            initialPreferences: WorkspacePreferences(
                logging: .init(autoLogEnabled: true, defaultLogFilename: logURL.path)
            )
        )
        let existingPuppet = ClientWindowController(profileLibrary: library, runsScriptServices: false)
        defer {
            existingPuppet.close()
            master.close()
        }

        let server = ServerProfile(name: "Startup World", host: "example.invalid", port: 8888)
        let puppet = PuppetProfile(
            name: "Helper",
            receivePrefix: "Helper> ",
            sendPrefix: "tell Helper ",
            connectWithPlayer: true
        )
        let character = CharacterProfile(name: "Player", puppets: [puppet])
        master.restoreOpenTab(server: server, character: character)

        await master.applyTransportConnectedForTesting()
        existingPuppet.startPuppetSession(
            master: master,
            server: server,
            character: character,
            puppet: puppet
        )
        XCTAssertTrue(master.isSessionConnectedForTesting)
        XCTAssertFalse(master.isSessionStartupReadyForTesting)
        XCTAssertEqual(master.activeLogCount, 1, "Automatic logging starts as soon as the transport connects")
        XCTAssertEqual(master.connectionCallbackDispatchCountForTesting, 0)
        XCTAssertEqual(master.connectWithPlayerStartupCountForTesting, 0)
        XCTAssertTrue(existingPuppet.isSessionConnectedForTesting)
        XCTAssertFalse(existingPuppet.isSessionStartupReadyForTesting)
        XCTAssertEqual(existingPuppet.connectionCallbackDispatchCountForTesting, 0)

        await master.applyStartupReadyForTesting()
        XCTAssertTrue(master.isSessionStartupReadyForTesting)
        XCTAssertEqual(master.connectionCallbackDispatchCountForTesting, 1)
        XCTAssertEqual(master.connectWithPlayerStartupCountForTesting, 1)
        XCTAssertTrue(existingPuppet.isSessionConnectedForTesting)
        XCTAssertEqual(existingPuppet.connectionCallbackDispatchCountForTesting, 1)

        // A reconnect begins a new startup window while the already-attached
        // puppet can still display the previous connected state.
        await master.applyTransportConnectedForTesting()
        XCTAssertFalse(master.isSessionStartupReadyForTesting)
        XCTAssertEqual(master.connectionCallbackDispatchCountForTesting, 1)
        XCTAssertEqual(master.connectWithPlayerStartupCountForTesting, 1)
        XCTAssertEqual(existingPuppet.connectionCallbackDispatchCountForTesting, 1)

        await master.applyStartupReadyForTesting()
        XCTAssertEqual(master.connectionCallbackDispatchCountForTesting, 2)
        XCTAssertEqual(master.connectWithPlayerStartupCountForTesting, 2)
        XCTAssertTrue(existingPuppet.isSessionConnectedForTesting)
        XCTAssertEqual(existingPuppet.connectionCallbackDispatchCountForTesting, 2)

        await master.applyConnectionStateForTesting(.disconnected)
        XCTAssertEqual(master.activeLogCount, 0)
    }
}
