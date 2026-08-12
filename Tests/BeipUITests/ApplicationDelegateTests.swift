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
}
