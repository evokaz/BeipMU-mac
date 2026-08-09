import Foundation
import XCTest
@testable import BeipUI

final class RuntimeStateContextTests: XCTestCase {
    func testReleaseAndDebugUseSeparateConfigurationRoots() {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        let release = RuntimeStateContext.resolve(
            bundleIdentifier: RuntimeStateContext.releaseBundleIdentifier,
            applicationSupportDirectory: support
        )
        let debug = RuntimeStateContext.resolve(
            bundleIdentifier: RuntimeStateContext.debugBundleIdentifier,
            applicationSupportDirectory: support
        )

        XCTAssertEqual(release.configuration, .release)
        XCTAssertEqual(debug.configuration, .debug)
        XCTAssertEqual(release.configurationDirectory.lastPathComponent, "BeipMU")
        XCTAssertEqual(debug.configurationDirectory.lastPathComponent, "BeipMU-Debug")
        XCTAssertNotEqual(release.configurationDirectory, debug.configurationDirectory)
        XCTAssertNil(release.defaultsSuiteName)
        XCTAssertNil(debug.defaultsSuiteName)
    }

    func testUIOverridesAreAcceptedOnlyInUITestingMode() {
        let support = temporaryDirectory()
        let stateDirectory = support.appendingPathComponent("run-state", isDirectory: true)
        let suiteName = "RuntimeStateContextTests.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: support)
        }

        let overrides = [
            "BEIPMU_UI_TEST_STATE_DIRECTORY": stateDirectory.path,
            "BEIPMU_UI_TEST_DEFAULTS_SUITE": suiteName,
        ]
        let release = RuntimeStateContext.resolve(
            environment: overrides,
            bundleIdentifier: RuntimeStateContext.releaseBundleIdentifier,
            applicationSupportDirectory: support
        )
        XCTAssertFalse(release.isUITesting)
        XCTAssertEqual(release.configuration, .release)
        XCTAssertEqual(release.configurationDirectory.lastPathComponent, "BeipMU")
        XCTAssertNil(release.defaultsSuiteName)

        var uiEnvironment = overrides
        uiEnvironment["BEIPMU_UI_TESTING"] = "1"
        let ui = RuntimeStateContext.resolve(
            environment: uiEnvironment,
            bundleIdentifier: RuntimeStateContext.releaseBundleIdentifier,
            applicationSupportDirectory: support
        )
        XCTAssertTrue(ui.isUITesting)
        XCTAssertEqual(ui.configuration, .uiTest)
        XCTAssertEqual(ui.configurationDirectory, stateDirectory.standardizedFileURL)
        XCTAssertEqual(ui.defaultsSuiteName, suiteName)
        XCTAssertNotEqual(ui.configurationDirectory, release.releaseConfigurationDirectory)
    }

    func testUIOverrideCannotSelectReleaseDirectory() {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let releaseDirectory = support.appendingPathComponent("BeipMU", isDirectory: true)
        let context = RuntimeStateContext.resolve(
            environment: [
                "BEIPMU_UI_TESTING": "1",
                "BEIPMU_UI_TEST_STATE_DIRECTORY": releaseDirectory.path,
            ],
            bundleIdentifier: RuntimeStateContext.releaseBundleIdentifier,
            applicationSupportDirectory: support
        )

        XCTAssertTrue(context.isUITesting)
        XCTAssertNotEqual(context.configurationDirectory, releaseDirectory.standardizedFileURL)
        XCTAssertNotEqual(context.configurationDirectory, context.releaseConfigurationDirectory)
    }

    @MainActor
    func testPersistenceWritesStayInsideDebugAndUITestRoots() throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        let debug = RuntimeStateContext.resolve(
            bundleIdentifier: RuntimeStateContext.debugBundleIdentifier,
            applicationSupportDirectory: support
        )
        let debugLibrary = try ProfileLibrary(storageDirectory: debug.configurationDirectory)
        try debugLibrary.mutate { _ in }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: debug.configurationDirectory.appendingPathComponent("Config.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: debug.releaseConfigurationDirectory.appendingPathComponent("Config.txt").path
        ))

        let uiDirectory = support.appendingPathComponent("ui-state", isDirectory: true)
        let ui = RuntimeStateContext.resolve(
            environment: [
                "BEIPMU_UI_TESTING": "1",
                "BEIPMU_UI_TEST_STATE_DIRECTORY": uiDirectory.path,
                "BEIPMU_UI_TEST_DEFAULTS_SUITE": "RuntimeStateContextTests.\(UUID().uuidString)",
            ],
            bundleIdentifier: RuntimeStateContext.debugBundleIdentifier,
            applicationSupportDirectory: support
        )
        let uiLibrary = try ProfileLibrary(storageDirectory: ui.configurationDirectory)
        try uiLibrary.mutate { _ in }

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ui.configurationDirectory.appendingPathComponent("Config.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ui.releaseConfigurationDirectory.appendingPathComponent("Config.txt").path
        ))
    }

    func testResetClearsAllImplicitUITestState() throws {
        let support = temporaryDirectory()
        let suiteName = "RuntimeStateContextTests.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: support)
        }
        let context = RuntimeStateContext.resolve(
            environment: [
                "BEIPMU_UI_TESTING": "1",
                "BEIPMU_UI_TEST_STATE_DIRECTORY": support.appendingPathComponent("state").path,
                "BEIPMU_UI_TEST_DEFAULTS_SUITE": suiteName,
            ],
            bundleIdentifier: RuntimeStateContext.releaseBundleIdentifier,
            applicationSupportDirectory: support
        )
        try FileManager.default.createDirectory(
            at: context.configurationDirectory,
            withIntermediateDirectories: true
        )
        for name in ["Config.txt", "Config.backup.txt", "Config.mac.json", "Restore.dat"] {
            try Data("state".utf8).write(
                to: context.configurationDirectory.appendingPathComponent(name)
            )
        }
        context.defaults.set("saved", forKey: "RuntimeStateContextTests.key")

        try context.resetUITestState()

        XCTAssertTrue(FileManager.default.fileExists(atPath: context.configurationDirectory.path))
        for name in ["Config.txt", "Config.backup.txt", "Config.mac.json", "Restore.dat"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: context.configurationDirectory.appendingPathComponent(name).path
            ))
        }
        XCTAssertNil(context.defaults.object(forKey: "RuntimeStateContextTests.key"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.RuntimeStateContextTests.\(UUID().uuidString)", isDirectory: true)
    }
}
