import AppKit
import XCTest
@testable import BeipUI

@MainActor
final class AboutWindowControllerTests: XCTestCase {
    func testAboutWindowShowsProductVersionAndAttribution() throws {
        let controller = AboutWindowController()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let views = recursiveSubviews(of: content)

        XCTAssertEqual(window.title, "About BeipMU for Mac")
        XCTAssertEqual(window.accessibilityIdentifier(), "aboutWindow")
        XCTAssertEqual(textField("aboutAppName", in: views)?.stringValue, "BeipMU for Mac")
        XCTAssertFalse(textField("aboutVersion", in: views)?.stringValue.isEmpty ?? true)

        let project = button("aboutProjectGitHub", in: views)
        XCTAssertEqual(project?.title, "https://github.com/evokaz/BeipMU-mac")
        XCTAssertEqual(project?.isEnabled, true)

        let originalProjectLabel = textField("aboutOriginalProjectLabel", in: views)
        XCTAssertEqual(originalProjectLabel?.stringValue, "Original Project:")

        let originalDeveloper = button("aboutOriginalDeveloperLink", in: views)
        XCTAssertEqual(originalDeveloper?.title, "https://beipdev.github.io/BeipMU/")
        XCTAssertEqual(originalDeveloper?.isEnabled, true)
        XCTAssertTrue(views.compactMap { ($0 as? NSTextField)?.stringValue }.contains {
            $0.contains("Special thanks to BeipDev")
        })
    }

    private func textField(_ identifier: String, in views: [NSView]) -> NSTextField? {
        views.first { $0.accessibilityIdentifier() == identifier } as? NSTextField
    }

    private func button(_ identifier: String, in views: [NSView]) -> NSButton? {
        views.first { $0.accessibilityIdentifier() == identifier } as? NSButton
    }

    private func recursiveSubviews(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(recursiveSubviews(of:))
    }
}
