import BeipPersistence
import AppKit
import BeipCore
@testable import BeipUI
import Foundation
import XCTest

final class WorkspaceDockingTests: XCTestCase {
    func testWorkspaceLayoutPresetsAreValidAndContainEveryPaneOnce() {
        for layout in [
            WorkspaceLayoutNode.tabbedRight,
            .splitSidebars,
            .stackedRight,
            .stackedBottom,
        ] {
            XCTAssertTrue(layout.isValid)
            XCTAssertEqual(Set(layout.panes), Set(WorkspacePaneKind.allCases))
            XCTAssertEqual(layout.panes.count, WorkspacePaneKind.allCases.count)
        }
        XCTAssertTrue(WorkspaceLayoutNode.mainOnly.isValid)
    }

    func testDynamicPaneKindsRoundTripAndRecursiveInsertionRemovesCleanly() throws {
        let web = WorkspacePaneKind.webView("status:α")
        let spawn = WorkspacePaneKind.spawnTabs("Chat / Public")
        let atlas = WorkspacePaneKind.atlas
        var layout = WorkspaceLayoutNode.tabbedRight.inserting(atlas, side: .top)
        layout = layout.inserting(web, side: .left)
        layout = layout.inserting(spawn, side: .bottom)

        XCTAssertTrue(layout.isValid)
        XCTAssertEqual(layout.panes.filter { $0 == .main }.count, 1)
        XCTAssertTrue(layout.panes.contains(web))
        XCTAssertTrue(layout.panes.contains(spawn))
        XCTAssertEqual(layout.dockSide(of: atlas), .top)

        let decoded = try JSONDecoder().decode(
            WorkspaceLayoutNode.self,
            from: JSONEncoder().encode(layout)
        )
        XCTAssertEqual(decoded, layout)
        XCTAssertEqual(decoded.removing(atlas)?.removing(web)?.removing(spawn), .tabbedRight)
    }

    @MainActor
    func testAtlasSurfaceCanDockOnEveryWorkspaceEdge() {
        for side in WebViewDockSide.allCases {
            let owner = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
            owner.contentView = dock.hostView
            let atlas = AtlasWindowController(atlas: Atlas(maps: []))
            let pane = WorkspacePaneKind.atlas

            dock.dockPane(
                pane,
                view: atlas.contentViewForDocking(),
                title: "Atlas",
                side: side
            )

            XCTAssertTrue(atlas.isDocked)
            XCTAssertEqual(dock.currentLayout.dockSide(of: pane), side)
            XCTAssertTrue(dock.currentLayout.panes.contains(pane))
            dock.hostView.layoutSubtreeIfNeeded()
            guard let split = WorkspaceUITestSupport.recursiveSubviews(of: dock.hostView)
                .compactMap({ $0 as? NSSplitView }).first else {
                XCTFail("Expected a split view for the docked Atlas")
                continue
            }
            let originalPosition = split.isVertical
                ? split.subviews[0].frame.width
                : split.subviews[0].frame.height
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            let offset: CGFloat = originalPosition < total / 2 ? -40 : 40
            let targetPosition = min(total - 1, max(1, originalPosition + offset))
            split.setPosition(targetPosition, ofDividerAt: 0)
            dock.hostView.layoutSubtreeIfNeeded()
            let resizedPosition = split.isVertical
                ? split.subviews[0].frame.width
                : split.subviews[0].frame.height
            XCTAssertNotEqual(resizedPosition, originalPosition, accuracy: 1)

            dock.undockPane(pane)
            atlas.showFloating(nil)
            XCTAssertFalse(atlas.isDocked)
            atlas.closeSurface()
        }
    }

    @MainActor
    func testDockedAtlasCanShrinkBelowToolbarWidth() throws {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = dock.hostView
        let atlas = AtlasWindowController(atlas: Atlas(maps: []))
        let atlasContent = atlas.contentViewForDocking()
        dock.dockPane(.atlas, view: atlasContent, title: "Atlas", side: .right)
        dock.hostView.layoutSubtreeIfNeeded()

        let split = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: dock.hostView).compactMap { $0 as? NSSplitView }.first
        )
        XCTAssertTrue(split.isVertical)
        split.setPosition(split.bounds.width - split.dividerThickness - 240, ofDividerAt: 0)
        dock.hostView.layoutSubtreeIfNeeded()

        XCTAssertEqual(atlasContent.frame.width, 240, accuracy: 2)
        XCTAssertLessThan(atlasContent.frame.width, 680)
        XCTAssertNotNil(
            WorkspaceUITestSupport.recursiveSubviews(of: atlasContent).compactMap { $0 as? NSButton }.first { $0.title == "Open" }
        )
        let overflow = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: atlasContent).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "More Atlas tools"
            }
        )
        XCTAssertFalse(overflow.isHidden)
        XCTAssertEqual(overflow.superview?.frame.width ?? 0, atlasContent.frame.width, accuracy: 1)
        let overflowMenu = atlas.toolbarOverflowMenuForTesting
        XCTAssertEqual(overflowMenu.items.map(\.title), ["Navigation", "Create", "Select", "View"])
        XCTAssertEqual(
            overflowMenu.item(withTitle: "View")?.submenu?.items.map(\.title),
            ["Zoom out", "Actual size", "Zoom in", "Fit map", "Palette", "Export"]
        )
        let findRooms = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: atlasContent).compactMap { $0 as? NSSearchField }.first
        )
        XCTAssertFalse(findRooms.isHidden)
        XCTAssertGreaterThanOrEqual(findRooms.frame.width, 120)
        XCTAssertEqual(findRooms.placeholderString, "Find Rooms")
        let filterOverflow = try XCTUnwrap(
            WorkspaceUITestSupport.recursiveSubviews(of: atlasContent).compactMap { $0 as? NSButton }.first {
                $0.accessibilityLabel() == "More selection filters"
            }
        )
        XCTAssertFalse(filterOverflow.isHidden)
        let filterMenu = atlas.filterOverflowMenuForTesting
        XCTAssertEqual(
            filterMenu.items.map(\.title),
            ["Rooms", "Exits", "Rectangles", "Images", "Labels", "Live track"]
        )
        XCTAssertTrue(filterMenu.items.prefix(5).allSatisfy { $0.state == .on })

        split.setPosition(split.bounds.width - 500, ofDividerAt: 0)
        dock.hostView.layoutSubtreeIfNeeded()
        XCTAssertEqual(overflow.superview?.frame.width ?? 0, atlasContent.frame.width, accuracy: 1)
        XCTAssertLessThan(atlas.toolbarOverflowMenuForTesting.items.count, overflowMenu.items.count)

        split.setPosition(50, ofDividerAt: 0)
        dock.hostView.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(atlasContent.frame.width, 800)
        XCTAssertTrue(overflow.isHidden)
        XCTAssertTrue(filterOverflow.isHidden)
        XCTAssertTrue(
            WorkspaceUITestSupport.recursiveSubviews(of: atlasContent).compactMap { $0 as? NSButton }.filter {
                ["Open", "Save", "Save As", "Locate", "Create room", "Select", "Zoom in", "Export"].contains($0.title)
            }.allSatisfy { !$0.isHidden }
        )
        XCTAssertTrue(
            WorkspaceUITestSupport.recursiveSubviews(of: atlasContent).compactMap { $0 as? NSButton }.filter {
                ["Rooms", "Exits", "Rectangles", "Images", "Labels", "Live track"].contains($0.title)
            }.allSatisfy { !$0.isHidden }
        )
        atlas.closeSurface()
    }

    func testSavedWebViewPaneKeepsSafeURLFieldsOnly() throws {
        let request = WebViewOpenRequest(
            id: "status",
            url: try XCTUnwrap(URL(string: "https://example.invalid/status")),
            headers: ["Authorization": "secret"],
            dock: .bottom,
            width: 640,
            height: 360
        )
        let saved = try XCTUnwrap(SavedWebViewPane(request))
        XCTAssertEqual(saved.request.id, "status")
        XCTAssertEqual(saved.request.dock, .bottom)
        XCTAssertTrue(saved.request.headers.isEmpty)
        XCTAssertNil(SavedWebViewPane(.init(id: "inline", source: "<p>private</p>", dock: .right)))
        XCTAssertNil(SavedWebViewPane(.init(id: "floating", url: request.url)))
    }

    @MainActor
    func testDockControllerHostsAndUnhostsDynamicPane() {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let main = NSView()
        let dynamic = NSTextField(labelWithString: "Server status")
        let controller = WorkspaceDockController(mainView: main, ownerWindow: owner)
        owner.contentView = controller.hostView
        controller.hostView.frame = owner.contentView?.bounds ?? .zero

        let pane = WorkspacePaneKind.webView("status")
        controller.dockPane(pane, view: dynamic, title: "Status", side: .right)
        XCTAssertTrue(controller.containsPane(pane))
        XCTAssertNotNil(dynamic.window)

        controller.undockPane(pane)
        XCTAssertFalse(controller.containsPane(pane))
        XCTAssertEqual(controller.currentLayout, .mainOnly)
    }

    @MainActor
    func testDockControllerCanHostDynamicPaneWithoutTitleChrome() {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let controller = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = controller.hostView
        let pane = WorkspacePaneKind.spawnTabs("Channels")
        let content = NSTextField(labelWithString: "Embedded tabs")

        controller.dockPane(
            pane,
            view: content,
            title: "Channels",
            side: .right,
            showsTitle: false,
            onUndock: {}
        )

        let descendants = WorkspaceUITestSupport.recursiveSubviews(of: controller.hostView)
        XCTAssertFalse(descendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Channels" })
        XCTAssertTrue(descendants.compactMap { $0 as? NSButton }.contains { $0.title == "Pop Out" })
        XCTAssertNotNil(content.window)
    }

    @MainActor
    func testSpawnSurfaceMovesBetweenWindowAndRecursiveDock() {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = dock.hostView
        let spawn = TriggerSpawnWindowController(title: "WHO")
        spawn.append(.init(text: "Player One"))
        let pane = WorkspacePaneKind.spawn("WHO")

        dock.dockPane(pane, view: spawn.contentViewForDocking(), title: "WHO", side: .bottom)
        XCTAssertTrue(spawn.isDocked)
        XCTAssertTrue(dock.containsPane(pane))
        XCTAssertEqual(spawn.retainedLines.map(\.text), ["Player One"])

        dock.undockPane(pane)
        spawn.showFloating(nil)
        XCTAssertFalse(spawn.isDocked)
        XCTAssertNotNil(spawn.window?.contentView)
        spawn.closeSurface()
    }

    func testWorkspaceLayoutUpdatesNestedDividerWithoutChangingOtherBranches() {
        let updated = WorkspaceLayoutNode.splitSidebars.replacingSplitFraction(
            at: [.second],
            with: 0.61
        )
        guard case let .split(_, outerFraction, first, second) = updated,
              case let .split(_, innerFraction, _, _) = second else {
            return XCTFail("Expected nested split layout")
        }
        XCTAssertEqual(outerFraction, 0.22)
        XCTAssertEqual(first, .pane(.notes))
        XCTAssertEqual(innerFraction, 0.61)
        XCTAssertTrue(updated.hasSameTopology(as: .splitSidebars))
        XCTAssertFalse(updated.hasSameTopology(as: .stackedRight))
    }

    func testInvalidWorkspaceLayoutFallsBackToSafeTabbedLayout() {
        let invalid = WorkspaceLayoutNode.split(
            axis: .rows,
            fraction: .nan,
            first: .pane(.main),
            second: .tabs(panes: [.notes, .notes], selected: .notes)
        )
        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(invalid.normalized, .tabbedRight)
    }

    @MainActor
    func testDockControllerBuildsIndependentMultiPaneTree() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let main = NSView()
        main.setAccessibilityIdentifier("mainSession")
        let controller = WorkspaceDockController(mainView: main, ownerWindow: window)
        window.contentView = controller.hostView
        controller.apply(layout: .splitSidebars)
        controller.hostView.layoutSubtreeIfNeeded()

        let descendants = WorkspaceUITestSupport.recursiveSubviews(of: controller.hostView)
        XCTAssertEqual(descendants.compactMap { $0 as? NSSplitView }.count, 2)
        XCTAssertTrue(descendants.contains { $0.accessibilityIdentifier() == "mainSession" })
        XCTAssertTrue(descendants.contains { $0.accessibilityLabel() == "Character notes" })
        XCTAssertTrue(descendants.contains { $0.accessibilityLabel() == "Session diagnostics" })
        XCTAssertEqual(controller.currentLayout, .splitSidebars)
    }

    @MainActor
    func testWebViewMovesIntoDockAndReleasesToSavedPlaceholder() {
        let owner = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let dock = WorkspaceDockController(mainView: NSView(), ownerWindow: owner)
        owner.contentView = dock.hostView
        let web = WebViewWindowController(id: "status")
        let pane = WorkspacePaneKind.webView("status")

        dock.dockPane(pane, view: web.contentViewForDocking(), title: "Status", side: .left)
        XCTAssertTrue(web.isDocked)
        XCTAssertTrue(dock.containsPane(pane))
        XCTAssertTrue(web.webView.window === owner)

        dock.releasePane(pane)
        XCTAssertTrue(dock.containsPane(pane))
        web.closeSurface()
    }

    @MainActor
    func testWebViewInjectedCompatibilityObjectCallsNativeBridge() async throws {
        let controller = WebViewWindowController(id: "Bridge conformance")
        defer { controller.close() }
        controller.onCommand = { command in
            if command == .isConnected { return true }
            if case let .property(name) = command { return name == "ID" ? "Bridge conformance" : nil }
            return nil
        }
        let loaded = expectation(description: "web content loaded")
        controller.onNavigationFinished = { loaded.fulfill() }
        controller.apply(.init(source: "<title>Bridge Test</title><main>Ready</main><iframe srcdoc='<p>isolated</p>'></iframe>"))
        await fulfillment(of: [loaded], timeout: 10)

        let shape = try await controller.webView.callAsyncJavaScript(
            "return [typeof window.beipClient, typeof window.chrome.webview.hostObjects.client.SendGMCP, typeof window.beipClient.setOnDisplay]",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? [String]
        XCTAssertEqual(shape, ["object", "function", "function"])
        let connected = try await controller.webView.callAsyncJavaScript(
            "return await window.beipClient.isConnected()",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? Bool
        XCTAssertEqual(connected, true)
        let identifier = try await controller.webView.callAsyncJavaScript(
            "return await window.chrome.webview.hostObjects.client.GetPropertyString('ID')",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        XCTAssertEqual(identifier, "Bridge conformance")
        let subframeBridge = try await controller.webView.callAsyncJavaScript(
            "return typeof document.querySelector('iframe').contentWindow.beipClient",
            arguments: [:], in: nil, contentWorld: .page
        ) as? String
        XCTAssertEqual(subframeBridge, "undefined")
    }
}
