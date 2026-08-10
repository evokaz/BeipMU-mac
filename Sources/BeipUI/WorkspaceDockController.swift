import AppKit
import BeipCore

@MainActor
final class WorkspaceDockController: NSObject, NSWindowDelegate, NSSplitViewDelegate, NSTextViewDelegate {
    let hostView = NSView()
    var onPlacementChange: ((WorkspaceDockPlacement, Double) -> Void)?
    var onLayoutChange: ((WorkspaceLayoutNode) -> Void)?
    var onNotesChange: ((String) -> Void)?

    private weak var ownerWindow: NSWindow?
    private let mainView: NSView
    private let notesTextView: NSTextView
    private let diagnosticsTextView: NSTextView
    private var paneViews: [WorkspacePaneKind: NSView] = [:]
    private var splitPaths: [ObjectIdentifier: [WorkspaceLayoutBranch]] = [:]
    private var tabLocations: [WorkspacePaneKind: (controller: NSTabViewController, index: Int)] = [:]
    private var activeViewControllers: [NSViewController] = []
    private var floatingPanel: NSPanel?
    private var isRehosting = false
    private(set) var placement: WorkspaceDockPlacement = .hidden
    private(set) var thickness: Double = 280
    private(set) var currentLayout: WorkspaceLayoutNode = .mainOnly
    var legacyPlacement: WorkspaceDockPlacement? {
        if placement == .floating { return .floating }
        if currentLayout == .mainOnly { return .hidden }
        guard case let .split(axis, _, first, second) = currentLayout else { return nil }
        if first == .pane(.main), isAuxiliaryTabs(second) {
            return axis == .columns ? .right : .bottom
        }
        if isAuxiliaryTabs(first), second == .pane(.main) {
            return axis == .columns ? .left : .top
        }
        return nil
    }

    init(mainView: NSView, ownerWindow: NSWindow) {
        self.mainView = mainView
        self.ownerWindow = ownerWindow

        let notesScroll = NSTextView.scrollableTextView()
        notesTextView = notesScroll.documentView as! NSTextView
        let diagnosticsScroll = NSTextView.scrollableTextView()
        diagnosticsTextView = diagnosticsScroll.documentView as! NSTextView
        super.init()

        hostView.autoresizingMask = [.width, .height]
        notesTextView.font = .systemFont(ofSize: 13)
        notesTextView.textColor = .labelColor
        notesTextView.backgroundColor = .textBackgroundColor
        notesTextView.isRichText = false
        notesTextView.allowsUndo = true
        notesTextView.isAutomaticQuoteSubstitutionEnabled = false
        notesTextView.setAccessibilityLabel("Character notes")
        notesTextView.delegate = self

        diagnosticsTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        diagnosticsTextView.isEditable = false
        diagnosticsTextView.isSelectable = true
        diagnosticsTextView.backgroundColor = .textBackgroundColor
        diagnosticsTextView.textColor = .labelColor
        diagnosticsTextView.setAccessibilityLabel("Session diagnostics")

        paneViews[.notes] = Self.wrapped(notesScroll, title: "Character Notes")
        paneViews[.diagnostics] = Self.wrapped(diagnosticsScroll, title: "Session Diagnostics")
    }

    func apply(placement: WorkspaceDockPlacement, thickness: Double) {
        self.thickness = max(160, min(600, thickness))
        setPlacement(placement, notify: false)
    }

    func apply(layout: WorkspaceLayoutNode) {
        setLayout(layout, notify: false)
    }

    func setPlacement(_ placement: WorkspaceDockPlacement) {
        setPlacement(placement, notify: true)
    }

    func setLayout(_ layout: WorkspaceLayoutNode) {
        setLayout(layout, notify: true)
    }

    func selectNotes() {
        if !currentLayout.panes.contains(.notes), placement != .floating { setLayout(.tabbedRight) }
        select(.notes)
        if placement == .floating { floatingPanel?.makeKeyAndOrderFront(nil) }
        notesTextView.window?.makeFirstResponder(notesTextView)
    }

    func selectDiagnostics() {
        if !currentLayout.panes.contains(.diagnostics), placement != .floating { setLayout(.tabbedRight) }
        select(.diagnostics)
        if placement == .floating { floatingPanel?.makeKeyAndOrderFront(nil) }
    }

    func setNotes(_ value: String) {
        guard notesTextView.string != value else { return }
        notesTextView.string = value
    }

    func setDiagnostics(_ value: String) {
        diagnosticsTextView.string = value
    }

    func dockPane(
        _ pane: WorkspacePaneKind,
        view: NSView,
        title: String,
        side: WebViewDockSide,
        fraction: Double = 0.72,
        showsTitle: Bool = true,
        onUndock: (() -> Void)? = nil,
        onDrag: ((NSPoint) -> Bool)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        precondition(!WorkspacePaneKind.allCases.contains(pane), "Built-in workspace panes cannot be dynamically replaced.")
        paneViews[pane] = Self.wrapped(
            view,
            title: title,
            showsTitle: showsTitle,
            onUndock: onUndock,
            onDrag: onDrag,
            onClose: onClose
        )
        placement = .right
        rebuild(currentLayout.inserting(pane, side: side, fraction: fraction))
        onLayoutChange?(currentLayout)
        onPlacementChange?(placement, thickness)
    }

    @discardableResult
    func restorePane(
        _ pane: WorkspacePaneKind,
        view: NSView,
        title: String,
        showsTitle: Bool = true,
        onUndock: (() -> Void)? = nil,
        onDrag: ((NSPoint) -> Bool)? = nil,
        onClose: (() -> Void)? = nil
    ) -> Bool {
        guard currentLayout.panes.contains(pane) else { return false }
        paneViews[pane] = Self.wrapped(
            view,
            title: title,
            showsTitle: showsTitle,
            onUndock: onUndock,
            onDrag: onDrag,
            onClose: onClose
        )
        rebuild(currentLayout)
        return true
    }

    func movePane(_ pane: WorkspacePaneKind, side: WebViewDockSide, fraction: Double = 0.72) {
        guard paneViews[pane] != nil, currentLayout.panes.contains(pane) else { return }
        placement = .right
        rebuild(currentLayout.inserting(pane, side: side, fraction: fraction))
        onLayoutChange?(currentLayout)
        onPlacementChange?(placement, thickness)
    }

    func dockPaneInVerticalStack(
        _ pane: WorkspacePaneKind,
        view: NSView,
        title: String,
        side: WebViewDockSide,
        fraction: Double = 0.72,
        matching isStackPane: (WorkspacePaneKind) -> Bool,
        onUndock: (() -> Void)? = nil,
        onDrag: ((NSPoint) -> Bool)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        precondition(!WorkspacePaneKind.allCases.contains(pane), "Built-in workspace panes cannot be dynamically replaced.")
        paneViews[pane] = Self.wrapped(
            view,
            title: title,
            onUndock: onUndock,
            onDrag: onDrag,
            onClose: onClose
        )
        placement = .right
        rebuild(currentLayout.insertingVerticalStack(pane, side: side, fraction: fraction, matching: isStackPane))
        onLayoutChange?(currentLayout)
        onPlacementChange?(placement, thickness)
    }

    func movePaneInVerticalStack(
        _ pane: WorkspacePaneKind,
        side: WebViewDockSide,
        fraction: Double = 0.72,
        matching isStackPane: (WorkspacePaneKind) -> Bool
    ) {
        guard paneViews[pane] != nil, currentLayout.panes.contains(pane) else { return }
        placement = .right
        rebuild(currentLayout.insertingVerticalStack(pane, side: side, fraction: fraction, matching: isStackPane))
        onLayoutChange?(currentLayout)
        onPlacementChange?(placement, thickness)
    }

    @discardableResult
    func reorderPaneInVerticalStack(
        _ pane: WorkspacePaneKind,
        atScreenPoint point: NSPoint,
        matching isStackPane: (WorkspacePaneKind) -> Bool
    ) -> Bool {
        guard currentLayout.panes.contains(pane),
              let target = self.pane(atScreenPoint: point, matching: { $0 != pane && isStackPane($0) }),
              let side = dockSide(of: target),
              let targetFrame = frame(of: target) else { return false }
        let before = point.y > targetFrame.midY
        rebuild(currentLayout.insertingVerticalStack(
            pane,
            side: side,
            matching: isStackPane,
            relativeTo: target,
            before: before
        ))
        onLayoutChange?(currentLayout)
        onPlacementChange?(placement, thickness)
        return true
    }

    func undockPane(_ pane: WorkspacePaneKind) {
        guard paneViews.removeValue(forKey: pane) != nil || currentLayout.panes.contains(pane) else { return }
        let next = currentLayout.removing(pane) ?? .mainOnly
        placement = next == .mainOnly ? .hidden : .right
        rebuild(next)
        onLayoutChange?(currentLayout)
        onPlacementChange?(placement, thickness)
    }

    /// Releases a dynamic pane's live view while retaining its saved position.
    /// A placeholder occupies the node until the corresponding session surface
    /// is restored and calls `dockPane` again.
    func releasePane(_ pane: WorkspacePaneKind) {
        guard paneViews.removeValue(forKey: pane) != nil, currentLayout.panes.contains(pane) else { return }
        rebuild(currentLayout)
    }

    func containsPane(_ pane: WorkspacePaneKind) -> Bool { currentLayout.panes.contains(pane) }

    func dockSide(
        forFloatingFrame frame: NSRect,
        threshold: CGFloat = 44,
        allowedSides: Set<WebViewDockSide> = Set(WebViewDockSide.allCases)
    ) -> WebViewDockSide? {
        guard let hostFrame = ownerWindow?.frame else { return nil }
        return Self.dockSide(forFloatingFrame: frame, near: hostFrame, threshold: threshold, allowedSides: allowedSides)
    }

    func dockSide(
        forScreenPoint point: NSPoint,
        threshold: CGFloat = 36,
        allowedSides: Set<WebViewDockSide> = Set(WebViewDockSide.allCases)
    ) -> WebViewDockSide? {
        guard let hostFrame = ownerWindow?.frame else { return nil }
        return Self.dockSide(forScreenPoint: point, in: hostFrame, threshold: threshold, allowedSides: allowedSides)
    }

    func isOutsideHostWindow(_ point: NSPoint, tolerance: CGFloat = 48) -> Bool {
        guard let hostFrame = ownerWindow?.frame else { return false }
        return !hostFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    func dockSide(of pane: WorkspacePaneKind) -> WebViewDockSide? {
        guard let frame = frame(of: pane),
              let window = ownerWindow ?? paneViews[pane]?.window else { return nil }
        let hostInWindow = hostView.convert(hostView.bounds, to: nil)
        let hostFrame = window.convertToScreen(hostInWindow)
        return Self.nearestEdge(for: NSPoint(x: frame.midX, y: frame.midY), in: hostFrame)
    }

    func pane(atScreenPoint point: NSPoint, matching predicate: (WorkspacePaneKind) -> Bool) -> WorkspacePaneKind? {
        for pane in currentLayout.panes.reversed() where predicate(pane) {
            guard let view = paneViews[pane], let window = view.window else { continue }
            let local = view.convert(window.convertPoint(fromScreen: point), from: nil)
            if view.bounds.contains(local) { return pane }
        }
        return nil
    }

    static func dockSide(
        forFloatingFrame floatingFrame: NSRect,
        near hostFrame: NSRect,
        threshold: CGFloat = 44,
        allowedSides: Set<WebViewDockSide> = Set(WebViewDockSide.allCases)
    ) -> WebViewDockSide? {
        guard hostFrame.insetBy(dx: -threshold, dy: -threshold).intersects(floatingFrame) else { return nil }
        let overlapX = max(0, min(floatingFrame.maxX, hostFrame.maxX) - max(floatingFrame.minX, hostFrame.minX))
        let overlapY = max(0, min(floatingFrame.maxY, hostFrame.maxY) - max(floatingFrame.minY, hostFrame.minY))
        let distanceToLeft = min(abs(floatingFrame.minX - hostFrame.minX), abs(floatingFrame.maxX - hostFrame.minX))
        let distanceToRight = min(abs(floatingFrame.maxX - hostFrame.maxX), abs(floatingFrame.minX - hostFrame.maxX))
        let candidates: [(WebViewDockSide, CGFloat, Bool)] = [
            (.left, distanceToLeft, overlapY > 24),
            (.right, distanceToRight, overlapY > 24),
            (.top, abs(floatingFrame.maxY - hostFrame.maxY), overlapX > 24),
            (.bottom, abs(floatingFrame.minY - hostFrame.minY), overlapX > 24),
        ]
        return candidates
            .filter { allowedSides.contains($0.0) && $0.2 && $0.1 <= threshold }
            .min { $0.1 < $1.1 }?
            .0
    }

    static func dockSide(
        forScreenPoint point: NSPoint,
        in hostFrame: NSRect,
        threshold: CGFloat = 36,
        allowedSides: Set<WebViewDockSide> = Set(WebViewDockSide.allCases)
    ) -> WebViewDockSide? {
        guard hostFrame.insetBy(dx: -threshold, dy: -threshold).contains(point) else { return nil }
        let distances: [(WebViewDockSide, CGFloat)] = [
            (.left, abs(point.x - hostFrame.minX)),
            (.right, abs(point.x - hostFrame.maxX)),
            (.top, abs(point.y - hostFrame.maxY)),
            (.bottom, abs(point.y - hostFrame.minY)),
        ]
        return distances
            .filter { allowedSides.contains($0.0) && $0.1 <= threshold }
            .min { $0.1 < $1.1 }?
            .0
    }

    func frame(of pane: WorkspacePaneKind) -> NSRect? {
        guard let view = paneViews[pane], let window = view.window else { return nil }
        let frameInWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        floatingPanel?.appearance = palette.appearance
        floatingPanel?.backgroundColor = palette.chrome
        floatingPanel?.contentView?.appearance = palette.appearance
        floatingPanel?.contentView?.needsDisplay = true
        notesTextView.textColor = palette.foreground
        notesTextView.backgroundColor = palette.background
        notesTextView.insertionPointColor = palette.accent
        diagnosticsTextView.textColor = palette.foreground
        diagnosticsTextView.backgroundColor = palette.background
        diagnosticsTextView.insertionPointColor = palette.accent
        notesTextView.needsDisplay = true
        diagnosticsTextView.needsDisplay = true
    }

    func prepareForOwnerClose() {
        floatingPanel?.delegate = nil
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === notesTextView else { return }
        onNotesChange?(notesTextView.string)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === floatingPanel, !isRehosting else { return }
        setPlacement(.hidden)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !isRehosting, let splitView = notification.object as? NSSplitView,
              let path = splitPaths[ObjectIdentifier(splitView)], splitView.subviews.count == 2 else { return }
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard total > 0 else { return }
        let firstSize = splitView.isVertical ? splitView.subviews[0].frame.width : splitView.subviews[0].frame.height
        currentLayout = currentLayout.replacingSplitFraction(at: path, with: Double(firstSize / total))
        thickness = inferredAuxiliaryThickness(in: splitView)
        onLayoutChange?(currentLayout)
        onPlacementChange?(placement, thickness)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0,
              let path = splitPaths[ObjectIdentifier(splitView)],
              let node = node(at: path),
              case let .split(_, _, first, _) = node,
              first.panes.contains(.atlas) else { return proposedMinimumPosition }
        return min(proposedMinimumPosition, 240)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0,
              let path = splitPaths[ObjectIdentifier(splitView)],
              let node = node(at: path),
              case let .split(_, _, _, second) = node,
              second.panes.contains(.atlas) else { return proposedMaximumPosition }
        let total = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return max(proposedMaximumPosition, total - splitView.dividerThickness - 240)
    }

    private func setPlacement(_ placement: WorkspaceDockPlacement, notify: Bool) {
        self.placement = placement
        switch placement {
        case .hidden:
            rebuild(.mainOnly)
        case .floating:
            rebuild(.mainOnly)
            showFloatingPanel()
        case .left, .right, .top, .bottom:
            let total = (placement == .left || placement == .right) ? hostView.bounds.width : hostView.bounds.height
            let mainFraction = total > 0 ? 1 - CGFloat(thickness) / total : 0.72
            rebuild(.legacyDocked(placement, fraction: Double(mainFraction)))
        }
        if notify {
            onLayoutChange?(currentLayout)
            onPlacementChange?(placement, thickness)
        }
    }

    private func setLayout(_ layout: WorkspaceLayoutNode, notify: Bool) {
        placement = layout == .mainOnly ? .hidden : .right
        rebuild(layout)
        if notify {
            onLayoutChange?(currentLayout)
            onPlacementChange?(placement, thickness)
        }
    }

    private func rebuild(_ layout: WorkspaceLayoutNode) {
        isRehosting = true
        defer { isRehosting = false }
        tearDownHostedViews()
        currentLayout = layout.normalized
        Self.pin(build(currentLayout, path: []), in: hostView)
        hostView.layoutSubtreeIfNeeded()
        applyDividerPositions(in: hostView)
    }

    private func tearDownHostedViews() {
        if let floatingPanel { ownerWindow?.removeChildWindow(floatingPanel) }
        floatingPanel?.delegate = nil
        floatingPanel?.orderOut(nil)
        floatingPanel?.contentView = nil
        floatingPanel = nil
        splitPaths.removeAll(keepingCapacity: true)
        tabLocations.removeAll(keepingCapacity: true)
        activeViewControllers.removeAll(keepingCapacity: true)
        mainView.removeFromSuperview()
        paneViews.values.forEach { $0.removeFromSuperview() }
        hostView.subviews.forEach { $0.removeFromSuperview() }
    }

    private func build(_ node: WorkspaceLayoutNode, path: [WorkspaceLayoutBranch]) -> NSView {
        switch node {
        case let .pane(kind):
            return kind == .main ? mainView : view(for: kind)
        case let .tabs(panes, selected):
            let controller = NSTabViewController()
            controller.tabStyle = .segmentedControlOnTop
            for (index, pane) in panes.enumerated() {
                let child = NSViewController()
                child.title = pane.title
                child.view = view(for: pane)
                controller.addChild(child)
                tabLocations[pane] = (controller, index)
            }
            controller.selectedTabViewItemIndex = panes.firstIndex(of: selected) ?? 0
            activeViewControllers.append(controller)
            return controller.view
        case let .split(axis, _, first, second):
            let split = NSSplitView()
            split.isVertical = axis == .columns
            split.dividerStyle = .thick
            split.delegate = self
            split.setAccessibilityIdentifier("workspaceSplit.\(path.map(\.rawValue).joined(separator: "."))")
            split.addArrangedSubview(build(first, path: path + [.first]))
            split.addArrangedSubview(build(second, path: path + [.second]))
            splitPaths[ObjectIdentifier(split)] = path
            return split
        }
    }

    private func view(for pane: WorkspacePaneKind) -> NSView {
        if let existing = paneViews[pane] { return existing }
        let placeholder = Self.wrapped(
            NSTextField(wrappingLabelWithString: "This saved pane is waiting for its session content."),
            title: pane.title,
            onClose: { [weak self] in
                self?.undockPane(pane)
            }
        )
        placeholder.setAccessibilityLabel("Unavailable saved pane: \(pane.title)")
        paneViews[pane] = placeholder
        return placeholder
    }

    private func applyDividerPositions(in view: NSView) {
        if let split = view as? NSSplitView,
           let path = splitPaths[ObjectIdentifier(split)],
           let node = node(at: path), case let .split(_, fraction, _, _) = node {
            split.layoutSubtreeIfNeeded()
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            if total > 0 { split.setPosition(total * CGFloat(fraction), ofDividerAt: 0) }
        }
        view.subviews.forEach { applyDividerPositions(in: $0) }
    }

    private func node(at path: [WorkspaceLayoutBranch]) -> WorkspaceLayoutNode? {
        var node = currentLayout
        for branch in path {
            guard case let .split(_, _, first, second) = node else { return nil }
            node = branch == .first ? first : second
        }
        return node
    }

    private func select(_ pane: WorkspacePaneKind) {
        guard let location = tabLocations[pane] else { return }
        location.controller.selectedTabViewItemIndex = location.index
    }

    private func inferredAuxiliaryThickness(in split: NSSplitView) -> Double {
        guard splitPaths[ObjectIdentifier(split)] == [], split.subviews.count == 2 else { return thickness }
        let firstContainsMain: Bool
        if case let .split(_, _, first, _) = currentLayout { firstContainsMain = first.panes.contains(.main) }
        else { return thickness }
        let auxiliary = firstContainsMain ? split.subviews[1] : split.subviews[0]
        return Double(split.isVertical ? auxiliary.frame.width : auxiliary.frame.height)
    }

    private func isAuxiliaryTabs(_ node: WorkspaceLayoutNode) -> Bool {
        guard case let .tabs(panes, _) = node else { return false }
        return panes == [.notes, .diagnostics]
    }

    private func showFloatingPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "BeipMU Workspace"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = build(.tabs(panes: [.notes, .diagnostics], selected: .notes), path: [])
        RuntimeStateContext.setFrameAutosaveName("BeipMUWorkspacePanel", for: panel)
        ownerWindow?.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        floatingPanel = panel
    }

    private static func wrapped(
        _ content: NSView,
        title: String,
        showsTitle: Bool = true,
        onUndock: (() -> Void)? = nil,
        onDrag: ((NSPoint) -> Bool)? = nil,
        onClose: (() -> Void)? = nil
    ) -> NSView {
        let root = DockPaneRootView()
        root.onClose = onClose
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        guard showsTitle else {
            var constraints = [
                content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                content.topAnchor.constraint(equalTo: root.topAnchor),
                content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ]
            var popOutButton: DockPanePopOutButton?
            if let onUndock {
                let button = DockPanePopOutButton(action: onUndock)
                button.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(button)
                popOutButton = button
                constraints += [
                    button.topAnchor.constraint(equalTo: root.topAnchor, constant: 5),
                ]
            }
            if let onClose {
                let button = DockPaneCloseButton(action: onClose)
                button.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(button)
                constraints += [
                    button.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
                    button.topAnchor.constraint(equalTo: root.topAnchor, constant: 5),
                ]
                if let popOutButton {
                    constraints.append(popOutButton.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -8))
                }
            } else if let popOutButton {
                constraints.append(popOutButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8))
            }
            NSLayoutConstraint.activate(constraints)
            return root
        }

        let label = DockPaneTitleLabel(labelWithString: title)
        label.onDrag = onDrag
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.onClose = onClose
        label.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(label)
        var constraints = [
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 7),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 5),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ]
        var popOutButton: DockPanePopOutButton?
        if let onUndock {
            let button = DockPanePopOutButton(action: onUndock)
            button.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(button)
            popOutButton = button
            constraints += [
                label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
                button.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            ]
        }
        if let onClose {
            let button = DockPaneCloseButton(action: onClose)
            button.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(button)
            constraints += [
                label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
                button.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
                button.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            ]
            if let popOutButton {
                constraints.append(popOutButton.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -8))
            }
        } else if let popOutButton {
            constraints.append(popOutButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8))
        } else {
            constraints.append(label.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8))
        }
        NSLayoutConstraint.activate(constraints)
        return root
    }

    private static func pin(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private static func nearestEdge(for point: NSPoint, in container: NSRect) -> WebViewDockSide {
        let distances: [(WebViewDockSide, CGFloat)] = [
            (.left, abs(point.x - container.minX)),
            (.right, abs(point.x - container.maxX)),
            (.top, abs(point.y - container.maxY)),
            (.bottom, abs(point.y - container.minY)),
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .right
    }
}

@MainActor
private final class DockPaneRootView: NSView {
    var onClose: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onClose != nil else { return super.menu(for: event) }
        let item = NSMenuItem(title: "Close", action: #selector(closePane(_:)), keyEquivalent: "")
        item.target = self
        let menu = NSMenu(title: "Pane")
        menu.addItem(item)
        return menu
    }

    @objc private func closePane(_ sender: Any?) { onClose?() }
}

@MainActor
private final class DockPaneTitleLabel: NSTextField {
    var onDrag: ((NSPoint) -> Bool)?
    var onClose: (() -> Void)?

    convenience init(labelWithString string: String) {
        self.init(frame: .zero)
        self.stringValue = string
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        if onDrag?(point) != true { super.mouseDragged(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onClose != nil else { return super.menu(for: event) }
        let item = NSMenuItem(title: "Close", action: #selector(closePane(_:)), keyEquivalent: "")
        item.target = self
        let menu = NSMenu(title: "Pane")
        menu.addItem(item)
        return menu
    }

    @objc private func closePane(_ sender: Any?) { onClose?() }
}

@MainActor
private final class DockPanePopOutButton: NSButton {
    private let handler: () -> Void

    init(action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        title = "Pop Out"
        bezelStyle = .inline
        controlSize = .small
        target = self
        self.action = #selector(performAction)
        setAccessibilityLabel("Move pane to a separate window")
    }

    required init?(coder: NSCoder) { nil }
    @objc private func performAction() { handler() }
}

@MainActor
private final class DockPaneCloseButton: NSButton {
    private let handler: () -> Void

    init(action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close pane")
        imageScaling = .scaleProportionallyDown
        isBordered = false
        focusRingType = .none
        contentTintColor = .secondaryLabelColor
        toolTip = "Close pane"
        setAccessibilityLabel("Close pane")
        setAccessibilityIdentifier("workspacePaneClose")
        target = self
        self.action = #selector(performAction)
    }

    required init?(coder: NSCoder) { nil }
    @objc private func performAction() { handler() }
}

@MainActor
final class DockSurfaceAccessoryViewController: NSTitlebarAccessoryViewController {
    var onDockRequest: ((WebViewDockSide) -> Void)?

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 92, height: 24), pullsDown: true)
        popup.addItem(withTitle: "Dock…")
        for side in WebViewDockSide.allCases {
            let item = NSMenuItem(title: side.rawValue.capitalized, action: #selector(dock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = side.rawValue
            popup.menu?.addItem(item)
        }
        popup.setAccessibilityLabel("Dock window")
        view = popup
        layoutAttribute = .right
    }

    convenience init() { self.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }

    @objc private func dock(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let side = WebViewDockSide(rawValue: value) else { return }
        onDockRequest?(side)
    }
}
