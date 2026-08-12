import AppKit
import BeipPersistence
import XCTest
@testable import BeipUI

final class MenuReworkTests: XCTestCase {
    @MainActor
    func testMenuStripDefaultsTopAndCanSwitchBottomFromContextMenu() throws {
        let savedPreferences = WorkspacePreferencesStore.load()
        let controller = ClientWindowController(
            profileLibrary: ProfileLibrary(workspace: try .empty(isDirty: false)),
            initialPreferences: WorkspacePreferences(menuStripPosition: .top)
        )
        defer {
            controller.close()
            WorkspacePreferencesStore.save(savedPreferences)
        }
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let originalWindow = window
        let menu = controller.menuStripContextMenuForTesting
        let top = try XCTUnwrap(menu.item(withTitle: "Menu Strip at Top"))
        let bottom = try XCTUnwrap(menu.item(withTitle: "Menu Strip at Bottom"))
        XCTAssertEqual(top.state, .on)
        XCTAssertEqual(bottom.state, .off)
        _ = bottom.target?.perform(bottom.action, with: bottom)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.window === originalWindow)
        XCTAssertEqual(controller.menuStripPositionForTesting, .bottom)
        XCTAssertEqual(controller.sessionBarFrameForTesting.width, controller.workspaceHostFrameForTesting.width, accuracy: 0.5)
        XCTAssertEqual(controller.sessionBarFrameForTesting.maxY, controller.workspaceHostFrameForTesting.minY, accuracy: 0.5)
        let switched = controller.menuStripContextMenuForTesting
        XCTAssertEqual(switched.item(withTitle: "Menu Strip at Top")?.state, .off)
        XCTAssertEqual(switched.item(withTitle: "Menu Strip at Bottom")?.state, .on)
        XCTAssertNotNil(controller.sessionTabContextMenuForTesting.item(withTitle: "Disconnect"))
        XCTAssertNotNil(controller.sessionTabContextMenuForTesting.item(withTitle: "Reconnect"))
        XCTAssertNotNil(controller.sessionTabContextMenuForTesting.item(withTitle: "Close Tab"))
    }

    @MainActor
    func testSessionBarSpansAboveTheEntireWorkspaceHost() throws {
        let preferences = WorkspacePreferences(workspaceLayout: .tabbedRight)
        let controller = ClientWindowController(
            profileLibrary: ProfileLibrary(workspace: try .empty(isDirty: false)),
            initialPreferences: preferences
        )
        defer { controller.close() }
        controller.showWindow(nil)

        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let bar = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: content)
                .first { $0.accessibilityIdentifier() == "sessionBar" }
        )
        let host = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: content)
                .first { $0.accessibilityIdentifier() == "workspaceDockHost" }
        )
        let root = try XCTUnwrap(bar.superview)

        XCTAssertTrue(host.superview === root)
        XCTAssertEqual(bar.frame.width, host.frame.width, accuracy: 0.5)
        XCTAssertEqual(bar.frame.minY, host.frame.maxY, accuracy: 0.5)

        let inputSplit = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: host)
                .first { $0.accessibilityIdentifier() == "commandInputSplit" }
        )
        let inputSplitFrame = root.convert(inputSplit.frame, from: inputSplit.superview)
        XCTAssertGreaterThanOrEqual(inputSplitFrame.minY, host.frame.minY - 0.5)
        XCTAssertLessThanOrEqual(inputSplitFrame.maxY, bar.frame.minY + 0.5)
    }

    @MainActor
    func testLongSessionTabsCompressBeforeTheyOverflowAndExposeFullTitles() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        for index in 1...4 {
            _ = workspace.addServer(named: "World \(index) with an intentionally long session title")
        }
        let servers = workspace.servers.map(\.profile)
        let library = ProfileLibrary(workspace: workspace)
        let controllers = servers.map { server in
            let controller = ClientWindowController(profileLibrary: library)
            controller.restoreOpenTab(server: server, character: nil)
            return controller
        }
        defer { controllers.forEach { $0.close() } }

        let group = ClientTabGroup(controllers[0])
        controllers.dropFirst().forEach { group.add($0) }
        group.select(controllers[3], sender: nil)
        let selected = controllers[3]
        selected.showWindow(nil)
        selected.window?.setFrame(
            NSRect(
                origin: selected.window?.frame.origin ?? .zero,
                size: NSSize(width: 430, height: selected.window?.frame.height ?? 700)
            ),
            display: false
        )
        selected.window?.contentView?.layoutSubtreeIfNeeded()

        let viewport = selected.sessionTabViewportForTesting
        let content = try XCTUnwrap(selected.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let widths = selected.sessionTabWidthsForTesting
        XCTAssertEqual(widths.count, controllers.count)
        XCTAssertTrue(widths.allSatisfy { $0 >= 112 - 0.5 })
        XCTAssertGreaterThan(selected.sessionTabContentWidthForTesting, viewport.contentView.bounds.width)
        XCTAssertTrue(viewport.hasHorizontalScroller)

        let bar = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: content)
                .first { $0.accessibilityIdentifier() == "sessionBar" }
        )
        let root = try XCTUnwrap(bar.superview)
        let statistics = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: bar)
                .first { $0.accessibilityIdentifier() == "activeTabStatistics" }
        )
        let statisticsFrame = root.convert(statistics.frame, from: statistics.superview)
        XCTAssertEqual(statisticsFrame.maxX, bar.frame.maxX - 8, accuracy: 0.5)
        for label in ["Typed", "Online", "Idle"] {
            let metric = try XCTUnwrap(
                WorkspaceUITestSupport.recursiveSubviews(of: statistics)
                    .compactMap { $0 as? NSTextField }
                    .first { $0.stringValue == label }
            )
            XCTAssertGreaterThan(metric.frame.width, 0)
            XCTAssertFalse(metric.isHidden)
        }

        XCTAssertEqual(
            selected.sessionTabTooltipsForTesting,
            servers.map { "\($0.name)" }
        )
        let activeTab = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: content)
                .first { $0.accessibilityIdentifier() == "activeSessionTab" }
        )
        let closeButton = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: activeTab)
                .compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "sessionTabClose" }
        )
        XCTAssertFalse(closeButton.isHidden)
        let initialStrip = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: viewport)
                .first { $0.accessibilityIdentifier() == "sessionTabStrip" }
        )
        let initialActiveFrame = activeTab.convert(activeTab.bounds, to: initialStrip)
        XCTAssertTrue(initialActiveFrame.intersects(viewport.contentView.bounds))

        group.select(controllers[0], sender: nil)
        content.layoutSubtreeIfNeeded()
        let selectedTab = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: content)
                .first { $0.accessibilityIdentifier() == "activeSessionTab" }
        )
        let strip = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: viewport)
                .first { $0.accessibilityIdentifier() == "sessionTabStrip" }
        )
        let selectedTabFrame = selectedTab.convert(selectedTab.bounds, to: strip)
        XCTAssertTrue(selectedTabFrame.intersects(viewport.contentView.bounds))
    }
}
