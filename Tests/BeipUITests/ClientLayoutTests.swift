import BeipPersistence
import BeipTestSupport
import AppKit
import BeipCore
@testable import BeipUI
import Foundation
import XCTest

final class ClientLayoutTests: XCTestCase {
    @MainActor
    func testMainWindowDisablesAnimation() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }

        XCTAssertEqual(try XCTUnwrap(controller.window).animationBehavior, .none)
    }

    @MainActor
    func testMainWindowSupportsVerticalResize() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        controller.showWindow(nil)
        guard let visibleFrame = window.screen?.visibleFrame else {
            throw XCTSkip("A WindowServer screen is required for window geometry testing")
        }
        let inputSplit = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: try XCTUnwrap(window.contentView))
                .compactMap { $0 as? NSSplitView }
                .first { $0.accessibilityIdentifier() == "commandInputSplit" }
        )
        XCTAssertFalse(inputSplit.isVertical)
        XCTAssertEqual(inputSplit.subviews.count, 2)
        XCTAssertTrue(
            WorkspaceUITestSupport.recursiveSubviews(of: inputSplit.subviews[1])
                .contains { $0.accessibilityLabel() == "Command input" }
        )
        XCTAssertEqual(
            controller.splitView(inputSplit, constrainMinCoordinate: 0, ofSubviewAt: 0),
            80
        )
        // AppKit retains only the title bar's own system minimum after showing.
        XCTAssertLessThanOrEqual(window.minSize.height, 32)
        XCTAssertEqual(window.contentMinSize, .zero)
        let initialHeight = window.frame.height
        let smallerHeight = max(
            window.minSize.height + 1,
            min(initialHeight * 0.5, visibleFrame.height * 0.5)
        )
        window.setFrame(
            NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.maxY - smallerHeight,
                width: window.frame.width,
                height: smallerHeight
            ),
            display: false
        )
        XCTAssertLessThan(window.frame.height, initialHeight)
        let reducedHeight = window.frame.height
        let largerHeight = min(
            visibleFrame.height,
            max(reducedHeight + 1, visibleFrame.height * 0.9)
        )
        window.setFrame(
            NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.maxY - largerHeight,
                width: window.frame.width,
                height: largerHeight
            ),
            display: false
        )
        XCTAssertGreaterThan(window.frame.height, reducedHeight)
        XCTAssertGreaterThan(window.maxSize.height, 1_200)
        XCTAssertGreaterThan(window.contentMaxSize.height, 1_200)
        XCTAssertEqual(window.resizeIncrements.height, 1)
        XCTAssertEqual(window.contentResizeIncrements.height, 1)
        XCTAssertEqual(window.contentAspectRatio, .zero)
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertGreaterThan(window.maxFullScreenContentSize.height, 1_200)
    }

    @MainActor
    func testHiddenWindowLayoutDoesNotOverwriteSavedInputHeight() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let inputSplit = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: try XCTUnwrap(window.contentView))
                .compactMap { $0 as? NSSplitView }
                .first { $0.accessibilityIdentifier() == "commandInputSplit" }
        )
        let savedHeight = controller.inputHeightPreferenceForTesting

        inputSplit.setPosition(80, ofDividerAt: 0)
        controller.splitViewDidResizeSubviews(
            Notification(name: NSSplitView.didResizeSubviewsNotification, object: inputSplit)
        )

        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(controller.inputHeightPreferenceForTesting, savedHeight)
    }

    @MainActor
    func testInputHeightCanBeSynchronizedToHiddenTabs() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(profileLibrary: library)
        defer { controller.close() }
        let inputSplit = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: try XCTUnwrap(controller.window?.contentView))
                .compactMap { $0 as? NSSplitView }
                .first { $0.accessibilityIdentifier() == "commandInputSplit" }
        )

        controller.synchronizeInputHeight(137)

        XCTAssertEqual(controller.inputHeightPreferenceForTesting, 137)
        XCTAssertEqual(inputSplit.subviews[1].frame.height, 137, accuracy: 1)
    }

    @MainActor
    func testFirstShownTabRestoresInputHeightAfterHiddenLayout() async throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        _ = workspace.addServer(named: "World")
        let server = try XCTUnwrap(workspace.servers.first).profile
        let library = ProfileLibrary(workspace: workspace)
        let preferences = WorkspacePreferences(inputHeight: 137)
        let first = ClientWindowController(
            profileLibrary: library,
            initialPreferences: preferences
        )
        let second = ClientWindowController(
            profileLibrary: library,
            initialPreferences: preferences
        )
        defer {
            first.close()
            second.close()
        }

        first.restoreOpenTab(server: server, character: nil)
        let firstSplit = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: try XCTUnwrap(first.window?.contentView))
                .compactMap { $0 as? NSSplitView }
                .first { $0.accessibilityIdentifier() == "commandInputSplit" }
        )
        first.showWindow(nil)
        firstSplit.layoutSubtreeIfNeeded()
        try await eventuallyOnMainActor("first tab layout restoration") {
            first.inputLayoutRestorationGenerationForTesting > 0
        }
        XCTAssertGreaterThan(firstSplit.bounds.height, 0)

        let group = ClientTabGroup(first)
        group.add(second)
        group.select(second, sender: nil)
        firstSplit.setPosition(100, ofDividerAt: 0)
        XCTAssertNotEqual(firstSplit.subviews[1].frame.height, 137, accuracy: 1)

        let restorationGeneration = first.inputLayoutRestorationGenerationForTesting
        group.select(first, sender: nil)
        try await eventuallyOnMainActor("first tab input divider restoration") {
            first.inputLayoutRestorationGenerationForTesting > restorationGeneration
        }

        XCTAssertEqual(firstSplit.subviews[1].frame.height, 137, accuracy: 1)
    }

    @MainActor
    func testAIWindowUsesNativeAccessibleSurfaceAndProfileState() throws {
        let controller = AIWindowController(profileKey: "ai-profile")
        controller.updateEndpoint(URL(string: "https://example.invalid/ai")!)
        controller.showResponse("answer", for: "question")
        controller.showWindow(nil)

        XCTAssertEqual(controller.window?.title, "AI")
        XCTAssertNotNil(controller.window?.contentView)
        let dockedView = controller.contentViewForDocking()
        let descendants = WorkspaceUITestSupport.recursiveSubviews(of: dockedView)
        XCTAssertTrue(controller.isDocked)
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "aiPrompt" })
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "aiResponse" })
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "aiEndpoint" })
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "aiStatus" })
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "aiSend" })
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "aiClear" })
        controller.showFloating(nil)
        XCTAssertFalse(controller.isDocked)

        controller.close()
    }

    @MainActor
    func testPuppetWindowAttachesWithoutCreatingASecondNetworkSession() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let master = ClientWindowController(profileLibrary: library)
        let puppetWindow = ClientWindowController(profileLibrary: library)
        let server = ServerProfile(name: "World", host: "example.invalid", port: 8888)
        let puppet = PuppetProfile(name: "Helper", receivePrefix: "Helper> ", sendPrefix: "tell Helper ")
        let character = CharacterProfile(name: "Player", puppets: [puppet])

        puppetWindow.startPuppetSession(
            master: master,
            server: server,
            character: character,
            puppet: puppet
        )

        XCTAssertTrue(puppetWindow.isPuppetAttachment)
        XCTAssertFalse(puppetWindow.ownsNetworkSession)
        XCTAssertTrue(master.puppetController(for: puppet.id) === puppetWindow)

        puppetWindow.disconnect()
        XCTAssertNil(master.puppetController(for: puppet.id))
        master.close()
        puppetWindow.close()
    }
}
