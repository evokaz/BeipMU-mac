import BeipCore
import BeipPersistence
import Foundation
import XCTest
@testable import BeipUI

@MainActor
final class SessionLoggingLifecycleTests: XCTestCase {
    func testAutomaticLogStopsFinalizesWriterAndClearsDailyRolloverOnDisconnect() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let template = directory.appendingPathComponent("%date%.html").path
        let controller = try Self.makeController(
            logging: .init(autoLogEnabled: true, defaultLogFilename: template)
        )
        defer { controller.close() }

        await controller.applyConnectionStateForTesting(.connected)
        XCTAssertEqual(controller.activeLogCount, 1)
        XCTAssertTrue(controller.hasDailyLogRolloverTimerForTesting)
        let logURL = try XCTUnwrap(controller.activeLogURLsForTesting.first)

        await controller.applyConnectionStateForTesting(.disconnecting)
        XCTAssertEqual(controller.activeLogCount, 0)
        XCTAssertFalse(controller.hasDailyLogRolloverTimerForTesting)
        XCTAssertTrue(try String(contentsOf: logURL, encoding: .utf8).contains("Logging stopped"))
    }

    func testConfiguredAutomaticLogRestartsAfterReconnect() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("automatic.txt")
        let controller = try Self.makeController(
            logging: .init(autoLogEnabled: true, defaultLogFilename: logURL.path)
        )
        defer { controller.close() }

        await controller.applyConnectionStateForTesting(.connected)
        XCTAssertEqual(controller.activeLogURLsForTesting, [logURL])
        await controller.applyConnectionStateForTesting(.disconnected)
        XCTAssertEqual(controller.activeLogCount, 0)

        await controller.applyConnectionStateForTesting(.connected)
        XCTAssertEqual(controller.activeLogURLsForTesting, [logURL])
        await controller.applyConnectionStateForTesting(.disconnected)

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(contents.components(separatedBy: "Logging started").count - 1, 2)
        XCTAssertEqual(contents.components(separatedBy: "Logging stopped").count - 1, 2)
    }

    func testNoAutomaticLogStartsWithoutConfiguration() async throws {
        let controller = try Self.makeController()
        defer { controller.close() }

        await controller.applyConnectionStateForTesting(.connected)
        XCTAssertEqual(controller.activeLogCount, 0)
        await controller.applyConnectionStateForTesting(.disconnected)
        await controller.applyConnectionStateForTesting(.connected)
        XCTAssertEqual(controller.activeLogCount, 0)
    }

    func testManualLogStopsOnDisconnectAndIsNotReopenedOnReconnect() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("manual.txt")
        let controller = try Self.makeController()
        defer { controller.close() }

        controller.startLogForTesting(at: logURL)
        await controller.applyConnectionStateForTesting(.connected)
        XCTAssertEqual(controller.activeLogCount, 1)
        await controller.applyConnectionStateForTesting(.disconnected)
        XCTAssertEqual(controller.activeLogCount, 0)

        await controller.applyConnectionStateForTesting(.connected)
        XCTAssertEqual(controller.activeLogCount, 0)
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(contents.components(separatedBy: "Logging started").count - 1, 1)
        XCTAssertEqual(contents.components(separatedBy: "Logging stopped").count - 1, 1)
    }

    func testRepeatedDisconnectAndFailureStatesStopWritersOnce() async throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("repeated-terminal-state.txt")
        let controller = try Self.makeController(
            logging: .init(autoLogEnabled: true, defaultLogFilename: logURL.path)
        )
        defer { controller.close() }

        await controller.applyConnectionStateForTesting(.connected)
        await controller.applyConnectionStateForTesting(.disconnecting)
        await controller.applyConnectionStateForTesting(.disconnected)
        await controller.applyConnectionStateForTesting(.failed("connection lost"))
        await controller.applyConnectionStateForTesting(.disconnected)

        XCTAssertEqual(controller.activeLogCount, 0)
        let stopNotice = "Logging to \(logURL.path) stopped."
        XCTAssertEqual(controller.testingOutputLines().filter { $0 == stopNotice }.count, 1)
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(contents.components(separatedBy: "Logging stopped").count - 1, 1)
    }

    func testReplacingSessionStopsLogsWhenNoTerminalStateArrives() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("replaced-session.txt")
        let controller = try Self.makeController()
        defer { controller.close() }

        controller.startLogForTesting(at: logURL)
        controller.startSavedProfileSession(
            .init(name: "Replacement World", host: "example.invalid", port: 0),
            character: nil,
            policy: .init(retryCount: 1)
        )

        XCTAssertEqual(controller.activeLogCount, 0)
        XCTAssertTrue(try String(contentsOf: logURL, encoding: .utf8).contains("Logging stopped"))
    }

    private static func makeController(
        logging: SessionLogOptions = .init()
    ) throws -> ClientWindowController {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(
            profileLibrary: library,
            runsScriptServices: false,
            initialPreferences: WorkspacePreferences(logging: logging)
        )
        controller.restoreOpenTab(
            server: .init(name: "Logging World", host: "example.invalid", port: 8888),
            character: nil
        )
        return controller
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.SessionLoggingLifecycleTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
