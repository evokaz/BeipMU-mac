import BeipPersistence
import AppKit
import BeipCore
@testable import BeipUI
import Foundation
import XCTest

final class TriggerSpawnWorkspaceTests: XCTestCase {
    @MainActor
    func testFreshWorldDoesNotInheritGlobalSpawnPane() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer(named: "Fresh World")
        let server = try XCTUnwrap(workspace.servers.first { $0.profile.id == serverID }?.profile)
        let layout = WorkspaceLayoutNode.mainOnly.inserting(.spawn("Pages"), side: .right)
        let controller = ClientWindowController(
            profileLibrary: ProfileLibrary(workspace: workspace),
            runsScriptServices: false,
            initialPreferences: .init(workspaceLayout: layout)
        )
        defer { controller.close() }

        controller.restoreOpenTab(server: server, character: nil)

        XCTAssertTrue(controller.usesWorkspaceLayout(.mainOnly))
        XCTAssertEqual(controller.testingSpawnSurfaceState().standalone, [:])
    }

    @MainActor
    func testSavedWorldSpawnPaneStillRestoresWithItsSurfaceState() throws {
        var workspace = try LegacyConfigurationWorkspace.empty(isDirty: false)
        let serverID = workspace.addServer(named: "Saved World")
        let server = try XCTUnwrap(workspace.servers.first { $0.profile.id == serverID }?.profile)
        let key = try XCTUnwrap(TextWindowSettingsIdentity(world: server.name, character: nil, tab: nil).worldKey)
        let layout = WorkspaceLayoutNode.mainOnly.inserting(.spawn("Pages"), side: .right)
        let preferences = WorkspacePreferences(
            workspaceLayout: .mainOnly,
            workspaceLayouts: [key: layout],
            spawnSurfaces: [key: .init(standaloneWindows: ["Pages"])]
        )
        let controller = ClientWindowController(
            profileLibrary: ProfileLibrary(workspace: workspace),
            runsScriptServices: false,
            initialPreferences: preferences
        )
        defer { controller.close() }

        controller.restoreOpenTab(server: server, character: nil)

        XCTAssertTrue(controller.usesWorkspaceLayout(layout))
        XCTAssertEqual(controller.testingSpawnSurfaceState().standalone, ["Pages": true])
    }

    @MainActor
    func testClosingOneDockedTriggerPaneLeavesOtherPanesOpen() throws {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = dock.hostView

        let first = TriggerSpawnWindowController(title: "WHO")
        let second = TriggerSpawnWindowController(title: "Pages")
        let firstPane = WorkspacePaneKind.spawn("WHO")
        let secondPane = WorkspacePaneKind.spawn("Pages")
        first.onClose = { dock.undockPane(firstPane) }
        second.onClose = { dock.undockPane(secondPane) }

        dock.dockPaneInVerticalStack(
            firstPane,
            view: first.contentViewForDocking(),
            title: "WHO",
            side: .right,
            matching: WorkspaceUITestSupport.isStandaloneSpawnPane,
            onClose: { first.requestClose() }
        )
        dock.dockPaneInVerticalStack(
            secondPane,
            view: second.contentViewForDocking(),
            title: "Pages",
            side: .right,
            matching: WorkspaceUITestSupport.isStandaloneSpawnPane,
            onClose: { second.requestClose() }
        )

        let closeButtons = WorkspaceUITestSupport.recursiveSubviews(of: dock.hostView).compactMap { view in
            view as? NSButton
        }.filter { $0.accessibilityIdentifier() == "workspacePaneClose" }
        XCTAssertEqual(closeButtons.count, 2)
        closeButtons[0].performClick(nil)

        XCTAssertFalse(dock.containsPane(firstPane))
        XCTAssertTrue(dock.containsPane(secondPane))
        XCTAssertFalse(first.isDocked)
        XCTAssertTrue(second.isDocked)
        second.closeSurface()
    }

    @MainActor
    func testSavedPanePlaceholderCanBeClosed() {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = dock.hostView
        let pane = WorkspacePaneKind.spawnTabs("Pages")

        dock.apply(layout: .mainOnly.inserting(pane, side: .right))
        XCTAssertTrue(dock.containsPane(pane))

        let closeButton = WorkspaceUITestSupport.recursiveSubviews(of: dock.hostView)
            .compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "workspacePaneClose" }
        XCTAssertNotNil(closeButton)
        closeButton?.performClick(nil)

        XCTAssertFalse(dock.containsPane(pane))
        XCTAssertEqual(dock.currentLayout, .mainOnly)
    }

    @MainActor
    func testTriggerSpawnContextMenuIncludesClearAndClose() {
        let standalone = TriggerSpawnWindowController(title: "WHO")
        let group = TriggerSpawnTabGroupWindowController(title: "Channels")

        XCTAssertEqual(standalone.contextMenuForTesting.items.map(\.title), ["Copy", "Select All", "", "Clear", "", "Close"])
        XCTAssertEqual(group.contextMenuForTesting.items.map(\.title), ["Copy", "Select All", "", "Clear", "", "Close"])
        standalone.closeSurface()
        group.closeSurface()
    }

    @MainActor
    func testTriggerSpawnClearContextMenuOnlyClearsTargetPane() throws {
        let standalone = TriggerSpawnWindowController(title: "WHO")
        standalone.append(.init(text: "standalone"))
        let standaloneClear = try XCTUnwrap(standalone.contextMenuForTesting.item(withTitle: "Clear"))
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(standaloneClear.action),
            to: standaloneClear.target,
            from: standaloneClear
        ))
        XCTAssertTrue(standalone.retainedLines.isEmpty)

        let group = TriggerSpawnTabGroupWindowController(title: "Channels")
        group.ensureTab(named: "WHO", selected: true)
        group.ensureTab(named: "Pages")
        group.deliver(.init(text: "who line"), to: "WHO", clear: false, showTab: false)
        group.deliver(.init(text: "page line"), to: "Pages", clear: false, showTab: false)
        XCTAssertTrue(group.selectTab(named: "WHO"))

        let groupClear = try XCTUnwrap(group.contextMenuForTesting.item(withTitle: "Clear"))
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(groupClear.action),
            to: groupClear.target,
            from: groupClear
        ))
        XCTAssertTrue(group.retainedLines(in: "WHO").isEmpty)
        XCTAssertEqual(group.retainedLines(in: "Pages").map(\.text), ["page line"])

        standalone.closeSurface()
        group.closeSurface()
    }

    @MainActor
    func testStandaloneTriggerSpawnDockingBuildsVerticalStack() {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = dock.hostView

        let whoPane = WorkspacePaneKind.spawn("WHO")
        let pagesPane = WorkspacePaneKind.spawn("Pages")
        dock.dockPaneInVerticalStack(
            whoPane,
            view: NSTextField(labelWithString: "WHO"),
            title: "WHO",
            side: .right,
            matching: WorkspaceUITestSupport.isStandaloneSpawnPane
        )
        dock.dockPaneInVerticalStack(
            pagesPane,
            view: NSTextField(labelWithString: "Pages"),
            title: "Pages",
            side: .right,
            matching: WorkspaceUITestSupport.isStandaloneSpawnPane
        )

        guard case let .split(.columns, _, .pane(.main), stack) = dock.currentLayout,
              case let .split(.rows, _, .pane(first), .pane(second)) = stack else {
            return XCTFail("Expected standalone spawns to dock as a vertical stack beside the main session")
        }
        XCTAssertEqual(first, whoPane)
        XCTAssertEqual(second, pagesPane)
    }

    func testStandaloneTriggerSpawnStackOrderCanBeRewritten() {
        let whoPane = WorkspacePaneKind.spawn("WHO")
        let pagesPane = WorkspacePaneKind.spawn("Pages")
        let layout = WorkspaceLayoutNode.mainOnly
            .insertingVerticalStack(whoPane, side: .right, matching: WorkspaceUITestSupport.isStandaloneSpawnPane)
            .insertingVerticalStack(pagesPane, side: .right, matching: WorkspaceUITestSupport.isStandaloneSpawnPane)

        let reordered = layout.insertingVerticalStack(
            pagesPane,
            side: .right,
            matching: WorkspaceUITestSupport.isStandaloneSpawnPane,
            relativeTo: whoPane,
            before: true
        )

        XCTAssertEqual(reordered.panes, [.main, pagesPane, whoPane])
    }

    func testStandaloneTriggerSpawnStacksAreIndependentPerSide() {
        let pagesPane = WorkspacePaneKind.spawn("Pages")
        let whoPane = WorkspacePaneKind.spawn("WHO")
        let mapPane = WorkspacePaneKind.spawn("Map")
        let layout = WorkspaceLayoutNode.mainOnly
            .insertingVerticalStack(pagesPane, side: .right, matching: WorkspaceUITestSupport.isStandaloneSpawnPane)
            .insertingVerticalStack(whoPane, side: .left, matching: WorkspaceUITestSupport.isStandaloneSpawnPane)
            .insertingVerticalStack(mapPane, side: .right, matching: WorkspaceUITestSupport.isStandaloneSpawnPane)

        XCTAssertEqual(layout.dockSide(of: pagesPane), .right)
        XCTAssertEqual(layout.dockSide(of: mapPane), .right)
        XCTAssertEqual(layout.dockSide(of: whoPane), .left)
        XCTAssertEqual(layout.panes, [whoPane, .main, pagesPane, mapPane])

        let moved = layout.insertingVerticalStack(
            pagesPane,
            side: .left,
            matching: WorkspaceUITestSupport.isStandaloneSpawnPane,
            relativeTo: whoPane,
            before: false
        )

        XCTAssertEqual(moved.dockSide(of: pagesPane), .left)
        XCTAssertEqual(moved.dockSide(of: whoPane), .left)
        XCTAssertEqual(moved.dockSide(of: mapPane), .right)
        XCTAssertEqual(moved.panes, [whoPane, pagesPane, .main, mapPane])
    }

    @MainActor
    func testDockSideResolverSnapsFloatingSpawnNearHostEdges() {
        let host = NSRect(x: 100, y: 100, width: 900, height: 600)

        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 108, y: 260, width: 260, height: 180),
                near: host
            ),
            .left
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: -160, y: 260, width: 260, height: 180),
                near: host
            ),
            .left
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: -240, y: 260, width: 260, height: 180),
                near: host,
                threshold: 120,
                allowedSides: [.left, .right]
            ),
            .left
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 732, y: 260, width: 260, height: 180),
                near: host
            ),
            .right
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 1_000, y: 260, width: 260, height: 180),
                near: host
            ),
            .right
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 1_080, y: 260, width: 260, height: 180),
                near: host,
                threshold: 120,
                allowedSides: [.left, .right]
            ),
            .right
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 430, y: 522, width: 260, height: 180),
                near: host
            ),
            .top
        )
        XCTAssertNil(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 430, y: 522, width: 260, height: 180),
                near: host,
                allowedSides: [.left, .right]
            )
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forScreenPoint: NSPoint(x: 35, y: 320),
                in: host,
                threshold: 96,
                allowedSides: [.left, .right]
            ),
            .left
        )
        XCTAssertEqual(
            WorkspaceDockController.dockSide(
                forScreenPoint: NSPoint(x: 1_065, y: 320),
                in: host,
                threshold: 96,
                allowedSides: [.left, .right]
            ),
            .right
        )
        XCTAssertNil(
            WorkspaceDockController.dockSide(
                forScreenPoint: NSPoint(x: 430, y: 755),
                in: host,
                threshold: 96,
                allowedSides: [.left, .right]
            )
        )
        XCTAssertNil(
            WorkspaceDockController.dockSide(
                forFloatingFrame: NSRect(x: 420, y: 280, width: 260, height: 180),
                near: host
            )
        )
    }

    @MainActor
    func testRestoredOpenTabRecreatesFloatingAndDockedTriggerSpawns() throws {
        let server = ServerProfile(name: "Spawn World", host: "example.invalid", port: 8888)
        let key = "Spawn World".folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let dockedSpawn = WorkspacePaneKind.spawn("Docked")
        let dockedTabGroup = WorkspacePaneKind.spawnTabs("Channels")
        let layout = WorkspaceLayoutNode.mainOnly
            .inserting(dockedSpawn, side: .right)
            .inserting(dockedTabGroup, side: .bottom)
        let preferences = WorkspacePreferences(
            workspaceLayouts: [key: layout],
            spawnSurfaces: [
                key: .init(
                    standaloneWindows: ["Docked", "Floating"],
                    tabGroups: [.init(title: "Channels", tabs: ["Public"], selectedTab: "Public")]
                ),
            ]
        )
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        let controller = ClientWindowController(
            profileLibrary: library,
            runsScriptServices: false,
            initialPreferences: preferences
        )
        defer { controller.close() }

        controller.restoreOpenTab(server: server, character: nil)

        let state = controller.testingSpawnSurfaceState()
        XCTAssertEqual(state.standalone["Docked"], true)
        XCTAssertEqual(state.standalone["Floating"], false)
        XCTAssertEqual(state.tabGroups["Channels"], true)
        let views = WorkspaceUITestSupport.recursiveSubviews(of: try XCTUnwrap(controller.window?.contentView))
        XCTAssertTrue(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Channels" })
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Spawn tabs" })
    }

    @MainActor
    func testSpawnTabGroupRetainsRoutesHighlightsReordersAndClosesTabs() throws {
        let group = TriggerSpawnTabGroupWindowController(title: "Channels")
        let publicLine = RenderedLine(
            text: "[Public] hello",
            runs: [.init(range: 0..<8, style: .init(foreground: .init(red: 0, green: 255, blue: 0)))]
        )
        group.deliver(publicLine, to: "Public", clear: false, showTab: false)
        group.deliver(.init(text: "[Private] secret"), to: "Private", clear: false, showTab: false)

        XCTAssertEqual(group.tabTitles, ["Public", "Private"])
        XCTAssertEqual(group.selectedTitle, "Public")
        XCTAssertEqual(group.highlightedTitles, ["Private"])
        XCTAssertEqual(group.retainedLines(in: "Public"), [publicLine])

        XCTAssertTrue(group.selectTab(named: "Private"))
        XCTAssertEqual(group.selectedTitle, "Private")
        XCTAssertTrue(group.highlightedTitles.isEmpty)
        group.deliver(.init(text: "replacement"), to: "Private", clear: true, showTab: false)
        XCTAssertEqual(group.retainedLines(in: "Private").map(\.text), ["replacement"])

        group.moveTab(from: 1, to: 0)
        XCTAssertEqual(group.tabTitles, ["Private", "Public"])
        XCTAssertTrue(group.closeTab(named: "Private"))
        XCTAssertEqual(group.tabTitles, ["Public"])
        XCTAssertEqual(group.selectedTitle, "Public")

        let content = try XCTUnwrap(group.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let views = WorkspaceUITestSupport.recursiveSubviews(of: content)
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Spawn tabs" })
        XCTAssertTrue(views.contains { $0.accessibilityLabel() == "Close Public" })
        let scrollView = try XCTUnwrap(views.compactMap { $0 as? NSScrollView }.first)
        XCTAssertEqual(scrollView.frame.height, content.bounds.height - 32, accuracy: 1)
    }
}
