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
        onUndock: (() -> Void)? = nil
    ) {
        precondition(!WorkspacePaneKind.allCases.contains(pane), "Built-in workspace panes cannot be dynamically replaced.")
        paneViews[pane] = Self.wrapped(view, title: title, onUndock: onUndock)
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
        onUndock: (() -> Void)? = nil
    ) -> Bool {
        guard currentLayout.panes.contains(pane) else { return false }
        paneViews[pane] = Self.wrapped(view, title: title, onUndock: onUndock)
        rebuild(currentLayout)
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

    func applyTheme(_ palette: WorkspaceThemePalette) {
        notesTextView.textColor = palette.foreground
        notesTextView.backgroundColor = palette.background
        notesTextView.insertionPointColor = palette.accent
        diagnosticsTextView.textColor = palette.foreground
        diagnosticsTextView.backgroundColor = palette.background
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
            split.dividerStyle = .thin
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
            title: pane.title
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
        panel.setFrameAutosaveName("BeipMUWorkspacePanel")
        ownerWindow?.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        floatingPanel = panel
    }

    private static func wrapped(_ content: NSView, title: String, onUndock: (() -> Void)? = nil) -> NSView {
        let root = NSView()
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(label)
        root.addSubview(content)
        var constraints = [
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 7),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 5),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ]
        if let onUndock {
            let button = DockPanePopOutButton(action: onUndock)
            button.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(button)
            constraints += [
                label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
                button.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
                button.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            ]
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
