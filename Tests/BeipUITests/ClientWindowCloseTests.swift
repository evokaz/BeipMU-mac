import AppKit
import BeipPersistence
import XCTest
@testable import BeipUI

final class ClientWindowCloseTests: XCTestCase {
    @MainActor
    func testConnectedTabCancelLeavesTabAndConnectionUnchanged() throws {
        let controller = try makeConnectedController()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        var prompt: (message: String, detail: String)?
        controller.closeConnectedTabConfirmationHandlerForTesting = { message, detail in
            prompt = (message, detail)
            return false
        }

        XCTAssertFalse(controller.windowShouldClose(window))
        XCTAssertTrue(controller.isSessionConnectedForTesting)
        XCTAssertEqual(prompt?.message, "Close connected tab?")
        XCTAssertEqual(prompt?.detail, "Closing this tab will disconnect from World.")
    }

    @MainActor
    func testConnectedTabConfirmationAllowsExistingCloseFlow() throws {
        let controller = try makeConnectedController()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        var promptCount = 0
        controller.closeConnectedTabConfirmationHandlerForTesting = { _, _ in
            promptCount += 1
            return true
        }

        XCTAssertTrue(controller.windowShouldClose(window))
        XCTAssertEqual(promptCount, 1)
    }

    @MainActor
    func testDisconnectedTabClosesWithoutConfirmation() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        var promptCount = 0
        controller.closeConnectedTabConfirmationHandlerForTesting = { _, _ in
            promptCount += 1
            return false
        }

        XCTAssertTrue(controller.windowShouldClose(window))
        XCTAssertEqual(promptCount, 0)
    }

    @MainActor
    func testBackgroundConnectedTabContextMenuTargetsThatTab() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let first = ClientWindowController(profileLibrary: library)
        let second = ClientWindowController(profileLibrary: library)
        defer {
            first.close()
            second.close()
        }
        first.restoreOpenTab(server: .init(name: "Background World", host: "example.invalid", port: 8888), character: nil)
        first.isSessionConnectedForTesting = true
        let group = ClientTabGroup(first)
        group.add(second)
        group.select(second, sender: nil)

        var detail = ""
        first.closeConnectedTabConfirmationHandlerForTesting = { _, promptDetail in
            detail = promptDetail
            return false
        }
        let closeItem = try XCTUnwrap(first.sessionTabContextMenuForTesting.item(withTitle: "Close Tab"))
        let action = try XCTUnwrap(closeItem.action)

        XCTAssertTrue(NSApplication.shared.sendAction(action, to: closeItem.target, from: closeItem))
        XCTAssertEqual(detail, "Closing this tab will disconnect from Background World.")
        XCTAssertEqual(group.controllers.count, 2)
        XCTAssertTrue(group.controllers.first === first)
        XCTAssertTrue(first.isSessionConnectedForTesting)
    }

    @MainActor
    func testLastTabReplacementPromptsOnceAndInternalCloseDoesNotPromptAgain() throws {
        let controller = try makeConnectedController()
        let window = try XCTUnwrap(controller.window)
        defer { controller.closeForTabReplacement() }
        var promptCount = 0
        controller.closeConnectedTabConfirmationHandlerForTesting = { _, _ in
            promptCount += 1
            return true
        }
        var replacementRequested = false
        controller.onRequestCloseLastTab = { _ in
            replacementRequested = true
            return true
        }

        XCTAssertFalse(controller.windowShouldClose(window))
        XCTAssertTrue(replacementRequested)
        XCTAssertEqual(promptCount, 1)

        controller.closeForTabReplacement()
        XCTAssertEqual(promptCount, 1)
    }

    @MainActor
    func testApplicationTerminationSkipsConnectedTabConfirmation() throws {
        let controller = try makeConnectedController()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        var promptCount = 0
        controller.closeConnectedTabConfirmationHandlerForTesting = { _, _ in
            promptCount += 1
            return false
        }

        controller.prepareForApplicationTermination()

        XCTAssertTrue(controller.windowShouldClose(window))
        XCTAssertEqual(promptCount, 0)
    }

    @MainActor
    private func makeConnectedController() throws -> ClientWindowController {
        let controller = ClientWindowController(
            profileLibrary: ProfileLibrary(workspace: try .empty(isDirty: false))
        )
        controller.restoreOpenTab(
            server: .init(name: "World", host: "example.invalid", port: 8888),
            character: nil
        )
        controller.isSessionConnectedForTesting = true
        return controller
    }
}
