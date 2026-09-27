import AppKit
import XCTest
@testable import BeipUI

final class ApplicationDelegateTests: XCTestCase {
    @MainActor
    func testConfigurationImportedAlertDescribesSelectedFile() throws {
        let url = URL(fileURLWithPath: "/tmp/Config-import.txt")

        let alert = ApplicationDelegate.configurationImportedAlert(for: url)

        XCTAssertEqual(alert.messageText, "Configuration Imported")
        XCTAssertEqual(alert.alertStyle, .informational)
        XCTAssertEqual(alert.informativeText, "BeipMU is now using settings from the selected file “Config-import.txt”.")
        XCTAssertEqual(alert.buttons.map(\.title), ["OK"])
    }

    @MainActor
    func testUpdateAvailableAlertShowsVersionAndReleaseAction() {
        let release = AvailableGitHubRelease(
            version: "0.5",
            url: URL(string: "https://github.com/evokaz/BeipMU-mac/releases/tag/v0.5")!
        )

        let alert = ApplicationDelegate.updateAvailableAlert(for: release, currentVersion: "0.4")

        XCTAssertEqual(alert.messageText, "A BeipMU update is available")
        XCTAssertEqual(alert.informativeText, "Version 0.5 is available. You are running version 0.4.")
        XCTAssertEqual(alert.buttons.map(\.title), ["Open Release Page", "Later"])
    }

    @MainActor
    func testManualUpdateCheckAlertsReportCurrentOrFailure() throws {
        let currentAlert = try XCTUnwrap(
            ApplicationDelegate.manualUpdateCheckAlert(for: .upToDate, currentVersion: "0.4")
        )
        XCTAssertEqual(currentAlert.alertStyle, .informational)
        XCTAssertEqual(currentAlert.messageText, "BeipMU Is Up to Date")
        XCTAssertEqual(currentAlert.informativeText, "You are running the latest version of BeipMU (0.4).")
        XCTAssertEqual(currentAlert.buttons.map(\.title), ["OK"])

        let failedAlert = try XCTUnwrap(
            ApplicationDelegate.manualUpdateCheckAlert(for: .failed, currentVersion: "0.4")
        )
        XCTAssertEqual(failedAlert.alertStyle, .warning)
        XCTAssertEqual(failedAlert.messageText, "Unable to Check for Updates")
        XCTAssertEqual(failedAlert.buttons.map(\.title), ["OK"])
    }
}
