import BeipPersistence
import XCTest
@testable import BeipUI

final class SessionTitlebarStatisticsTests: XCTestCase {
    func testCompactDurationFormatting() {
        XCTAssertEqual(SessionTitlebarStatisticsFormatter.duration(0), "0s")
        XCTAssertEqual(SessionTitlebarStatisticsFormatter.duration(71), "1m 11s")
        XCTAssertEqual(SessionTitlebarStatisticsFormatter.duration(14_411), "4h 0m")
        XCTAssertEqual(SessionTitlebarStatisticsFormatter.duration(104_400), "1d 5h")
    }

    func testDurationFormattingClampsNegativeValues() {
        XCTAssertEqual(SessionTitlebarStatisticsFormatter.duration(-1), "0s")
    }

    @MainActor
    func testCustomSessionStripSuppressesNativeTabBar() async throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let first = ClientWindowController(profileLibrary: library)
        let second = ClientWindowController(profileLibrary: library)
        defer {
            first.close()
            second.close()
        }
        let firstWindow = try XCTUnwrap(first.window)
        let secondWindow = try XCTUnwrap(second.window)
        first.showWindow(nil)
        let group = ClientTabGroup(first)
        group.add(second)
        group.select(second, sender: nil)
        await Task.yield()

        XCTAssertEqual(group.controllers.count, 2)
        XCTAssertTrue(group.selectedController === second)
        XCTAssertTrue(second.isCommandInputFocusedForTesting)
        XCTAssertNil(firstWindow.tabbedWindows)
        XCTAssertNil(secondWindow.tabbedWindows)

        group.prepareToClose(second)
        XCTAssertTrue(group.selectedController === first)
        XCTAssertTrue(first.isCommandInputFocusedForTesting)
    }
}
