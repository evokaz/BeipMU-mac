import AppKit
import BeipCore

@MainActor
private final class TriggerSpawnFloatingWindow: NSWindow {
    var onLeftMouseUp: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseUp { onLeftMouseUp?() }
    }
}

@MainActor
final class TriggerSpawnWindowController: NSWindowController, NSWindowDelegate {
    private let output: OutputTextView
    private let unreadBoundaryCoordinator: SharedUnreadBoundaryCoordinator
    private let dockingAccessory = DockSurfaceAccessoryViewController()
    private var themePalette = WorkspaceThemeSettings().palette
    private(set) var isDocked = false
    var onClose: (() -> Void)?
    var onCloseRequest: (() -> Void)?
    var onWindowDragEnded: ((NSPoint) -> Bool)?
    var onDockRequest: ((WebViewDockSide) -> Void)? {
        didSet { dockingAccessory.onDockRequest = onDockRequest }
    }
    var onAction: ((LinkAction) -> Void)? {
        didSet { output.onAction = onAction }
    }
    var showsInlineImagePreviews = false {
        didSet { output.showsInlineImagePreviews = showsInlineImagePreviews }
    }
    private var dragFeedbackGeneration = 0
    private var floatingDragTask: Task<Void, Never>?
    private var latestDragReleasePoint: NSPoint?

    init(
        title: String,
        unreadBoundaryCoordinator: SharedUnreadBoundaryCoordinator = SharedUnreadBoundaryCoordinator()
    ) {
        output = OutputTextView()
        self.unreadBoundaryCoordinator = unreadBoundaryCoordinator
        let panel = TriggerSpawnFloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.setAccessibilityIdentifier("triggerSpawnWindow")
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = output.containerView
        super.init(window: panel)
        output.setUnreadBoundaryCoordinator(unreadBoundaryCoordinator)
        output.setWindowFocused(panel.isKeyWindow)
        panel.delegate = self
        panel.addTitlebarAccessoryViewController(dockingAccessory)
        panel.onLeftMouseUp = { [weak self] in self?.finishFloatingDrag() }
        output.onContextMenu = { [weak self] _ in self?.outputContextMenu() }
    }

    required init?(coder: NSCoder) { nil }

    func clear() { output.clear() }
    func append(_ line: RenderedLine) { output.append(line) }
    var outputForTesting: OutputTextView { output }
    var retainedLines: [RenderedLine] { output.retainedLines }
    func applyTheme(_ palette: WorkspaceThemePalette) {
        themePalette = palette
        window?.appearance = palette.appearance
        window?.backgroundColor = palette.chrome
        output.applyTheme(palette)
        window?.contentView?.needsDisplay = true
    }
    func contentViewForDocking() -> NSView {
        cancelFloatingDrag()
        window?.orderOut(nil)
        if window?.contentView === output.containerView { window?.contentView = nil }
        output.containerView.removeFromSuperview()
        isDocked = true
        return output.containerView
    }
    func showFloating(_ sender: Any?) {
        showFloating(sender, near: nil)
    }

    func showFloating(_ sender: Any?, near point: NSPoint?) {
        if isDocked {
            output.containerView.removeFromSuperview()
            window?.contentView = output.containerView
            isDocked = false
        }
        if let point, let window {
            Self.position(window, near: point)
        }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
    func closeSurface() {
        cancelFloatingDrag()
        if isDocked {
            output.containerView.removeFromSuperview()
            window?.contentView = output.containerView
            isDocked = false
        }
        close()
    }
    func requestClose() { onCloseRequest?() ?? closeSurface() }
    var contextMenuForTesting: NSMenu { outputContextMenu() }
    func windowDidMove(_ notification: Notification) {
        guard !isDocked, let frame = window?.frame else { return }
        observeFloatingDrag(frame: frame)
        pulseDragFeedback()
    }
    func windowWillClose(_ notification: Notification) {
        cancelFloatingDrag()
        output.unregisterFromUnreadBoundaryCoordinator()
        onClose?()
    }

    private func pulseDragFeedback() {
        guard let view = window?.contentView else { return }
        view.wantsLayer = true
        view.layer?.borderWidth = 3
        view.layer?.borderColor = themePalette.accent.cgColor
        dragFeedbackGeneration += 1
        let generation = dragFeedbackGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, dragFeedbackGeneration == generation else { return }
            view.layer?.borderWidth = 0
            view.layer?.borderColor = nil
        }
    }

    private func observeFloatingDrag(frame: NSRect) {
        latestDragReleasePoint = NSEvent.mouseLocation
        guard floatingDragTask == nil, Self.leftMouseButtonIsPressed else { return }
        floatingDragTask = Task { @MainActor [weak self] in
            while Self.leftMouseButtonIsPressed {
                try? await Task.sleep(for: .milliseconds(25))
            }
            self?.finishFloatingDrag()
        }
    }

    private func finishFloatingDrag() {
        latestDragReleasePoint = NSEvent.mouseLocation
        guard let point = latestDragReleasePoint else {
            cancelFloatingDrag()
            return
        }
        cancelFloatingDrag()
        guard !isDocked else { return }
        if onWindowDragEnded?(point) == true { pulseDragFeedback() }
    }

    private func cancelFloatingDrag() {
        latestDragReleasePoint = nil
        floatingDragTask?.cancel()
        floatingDragTask = nil
    }

    private func closeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Trigger Pane")
        menu.addItem(clearMenuItem())
        menu.addItem(.separator())
        menu.addItem(closeMenuItem())
        return menu
    }

    private func outputContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Trigger Pane")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(clearMenuItem())
        menu.addItem(.separator())
        menu.addItem(closeMenuItem())
        return menu
    }

    private func clearMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Clear", action: #selector(clearOutput(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = output.visibleLineCount > 0
        return item
    }

    @objc private func clearOutput(_ sender: Any?) { clear() }

    private func closeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Close", action: #selector(requestClose(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func requestClose(_ sender: Any?) { requestClose() }

    fileprivate static var leftMouseButtonIsPressed: Bool {
        NSEvent.pressedMouseButtons & 1 == 1
    }

    fileprivate static func position(_ window: NSWindow, near point: NSPoint) {
        var frame = window.frame
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? window.screen
        let visible = screen?.visibleFrame
        frame.origin = NSPoint(x: point.x - frame.width / 2, y: point.y - min(frame.height / 2, 120))
        if let visible {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true)
    }
}

/// A native equivalent of the Windows SpawnTabsWindow. Each tab retains an
/// independent virtualized output history. Inactive tabs receive an activity
/// marker, tabs can be selected/closed with the keyboard or pointer, and the
/// tab strip accepts local drags for deterministic reordering.
@MainActor
final class TriggerSpawnTabGroupWindowController: NSWindowController, NSWindowDelegate {
    private struct Tab {
        let id: UUID
        var title: String
        let output: OutputTextView
        var highlighted: Bool
    }

    private let tabStrip = SpawnTabStripView()
    private let contentHost = NSView()
    private let root = NSView()
    private let dockingAccessory = DockSurfaceAccessoryViewController()
    private let unreadBoundaryCoordinator: SharedUnreadBoundaryCoordinator
    private var tabs: [Tab] = []
    private var themePalette = WorkspaceThemeSettings().palette
    private var selectedID: UUID?
    private(set) var isDocked = false
    var onClose: (() -> Void)?
    var onCloseRequest: (() -> Void)?
    var onWindowDragEnded: ((NSPoint) -> Bool)?
    var onDockRequest: ((WebViewDockSide) -> Void)? {
        didSet { dockingAccessory.onDockRequest = onDockRequest }
    }
    var onAction: ((LinkAction) -> Void)?
    var showsInlineImagePreviews = false {
        didSet { tabs.forEach { $0.output.showsInlineImagePreviews = showsInlineImagePreviews } }
    }
    var onStructureChange: (() -> Void)?
    var onTabActivate: ((String) -> Void)?
    var onDockedSurfaceDrag: ((NSPoint) -> Bool)?
    private var dragFeedbackGeneration = 0
    private var floatingDragTask: Task<Void, Never>?
    private var latestDragReleasePoint: NSPoint?

    init(
        title: String,
        unreadBoundaryCoordinator: SharedUnreadBoundaryCoordinator = SharedUnreadBoundaryCoordinator()
    ) {
        self.unreadBoundaryCoordinator = unreadBoundaryCoordinator
        let panel = TriggerSpawnFloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.setAccessibilityIdentifier("triggerSpawnTabGroupWindow")
        panel.tabbingMode = .disallowed
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabStrip)
        root.addSubview(contentHost)
        root.wantsLayer = true
        panel.contentView = root
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: root.topAnchor),
            tabStrip.heightAnchor.constraint(equalToConstant: 32),
            contentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        super.init(window: panel)
        panel.delegate = self
        panel.addTitlebarAccessoryViewController(dockingAccessory)
        panel.onLeftMouseUp = { [weak self] in self?.finishFloatingDrag() }
        tabStrip.owner = self
    }

    required init?(coder: NSCoder) { nil }

    var tabTitles: [String] { tabs.map(\.title) }
    var selectedTitle: String? { tabs.first(where: { $0.id == selectedID })?.title }
    var highlightedTitles: [String] { tabs.filter(\.highlighted).map(\.title) }
    func outputForTesting(named title: String) -> OutputTextView? {
        tabs.first(where: { $0.title == title })?.output
    }

    func contentViewForDocking() -> NSView {
        cancelFloatingDrag()
        window?.orderOut(nil)
        if window?.contentView === root { window?.contentView = nil }
        root.removeFromSuperview()
        isDocked = true
        return root
    }

    func showFloating(_ sender: Any?) {
        showFloating(sender, near: nil)
    }

    func showFloating(_ sender: Any?, near point: NSPoint?) {
        if isDocked {
            root.removeFromSuperview()
            window?.contentView = root
            isDocked = false
        }
        if let point, let window {
            TriggerSpawnWindowController.position(window, near: point)
        }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func closeSurface() {
        cancelFloatingDrag()
        if isDocked {
            root.removeFromSuperview()
            window?.contentView = root
            isDocked = false
        }
        close()
    }
    func requestClose() { onCloseRequest?() ?? closeSurface() }
    var contextMenuForTesting: NSMenu { outputContextMenu() }

    func ensureTab(named title: String, selected: Bool = false) {
        if let index = index(ofTitle: title) {
            if selected { select(id: tabs[index].id) }
            return
        }
        let output = makeOutput()
        let id = UUID()
        tabs.append(.init(id: id, title: title, output: output, highlighted: false))
        output.setWindowFocused(surfaceIsFocused && (selectedID == nil || selected))
        rebuildTabStrip()
        if selectedID == nil || selected { select(id: id) }
        else {
            updateOutputFocus()
            onStructureChange?()
        }
    }

    func deliver(
        _ line: RenderedLine,
        to title: String,
        clear: Bool,
        showTab: Bool,
        highlight: Bool = true
    ) {
        let id: UUID
        if let index = index(ofTitle: title) {
            id = tabs[index].id
            if clear { tabs[index].output.clear() }
            tabs[index].output.append(line)
            if selectedID != id, highlight { tabs[index].highlighted = true }
        } else {
            let output = makeOutput()
            output.setWindowFocused(surfaceIsFocused && (selectedID == nil || showTab))
            output.append(line)
            id = UUID()
            tabs.append(.init(
                id: id,
                title: title,
                output: output,
                highlighted: selectedID != nil && highlight
            ))
            rebuildTabStrip()
        }
        if selectedID == nil || showTab { select(id: id) }
        else {
            updateTabStripState()
            updateOutputFocus()
            onStructureChange?()
        }
    }

    @discardableResult
    func selectTab(named title: String) -> Bool {
        guard let index = index(ofTitle: title) else { return false }
        select(id: tabs[index].id)
        if isDocked { NSAccessibility.post(element: contentHost, notification: .layoutChanged) }
        else { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    @discardableResult
    func closeTab(named title: String) -> Bool {
        guard let index = index(ofTitle: title) else { return false }
        closeTab(id: tabs[index].id)
        return true
    }

    func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), destination >= 0, destination <= tabs.count else { return }
        let tab = tabs.remove(at: source)
        let adjusted = destination > source ? destination - 1 : destination
        tabs.insert(tab, at: min(adjusted, tabs.count))
        rebuildTabStrip()
        onStructureChange?()
    }

    func retainedLines(in title: String) -> [RenderedLine] {
        index(ofTitle: title).map { tabs[$0].output.retainedLines } ?? []
    }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        themePalette = palette
        window?.appearance = palette.appearance
        window?.backgroundColor = palette.chrome
        tabs.forEach { $0.output.applyTheme(palette) }
        root.layer?.backgroundColor = palette.chrome.cgColor
        window?.contentView?.needsDisplay = true
    }

    func windowDidMove(_ notification: Notification) {
        guard !isDocked, let frame = window?.frame else { return }
        observeFloatingDrag(frame: frame)
        pulseDragFeedback()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateOutputFocus()
    }

    func windowDidResignKey(_ notification: Notification) {
        updateOutputFocus()
    }

    func windowWillClose(_ notification: Notification) {
        cancelFloatingDrag()
        tabs.forEach { $0.output.unregisterFromUnreadBoundaryCoordinator() }
        onClose?()
    }

    fileprivate func selectDraggedTab(_ id: UUID) { select(id: id) }

    fileprivate func closeDraggedTab(_ id: UUID) { closeTab(id: id) }

    fileprivate func moveDraggedTab(_ id: UUID, to insertionIndex: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        moveTab(from: source, to: insertionIndex)
    }

    fileprivate func setDraggedTab(_ id: UUID, active: Bool) {
        tabStrip.setDragging(id: id, active: active)
    }

    fileprivate func dragDockedSurface(to point: NSPoint) -> Bool {
        guard isDocked else { return false }
        return onDockedSurfaceDrag?(point) ?? false
    }

    private func index(ofTitle title: String) -> Int? {
        tabs.firstIndex { $0.title == title }
    }

    private func select(id: UUID) {
        guard let tabIndex = tabs.firstIndex(where: { $0.id == id }) else { return }
        selectedID = id
        tabs[tabIndex].highlighted = false
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let view = tabs[tabIndex].output.containerView
        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        updateTabStripState()
        updateOutputFocus()
        NSAccessibility.post(element: contentHost, notification: .layoutChanged)
        onTabActivate?(tabs[tabIndex].title)
        onStructureChange?()
    }

    private func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let id = tabs[index].id
        let wasSelected = selectedID == id
        let removed = tabs.remove(at: index)
        removed.output.unregisterFromUnreadBoundaryCoordinator()
        removed.output.containerView.removeFromSuperview()
        if tabs.isEmpty {
            selectedID = nil
            contentHost.subviews.forEach { $0.removeFromSuperview() }
            rebuildTabStrip()
            onStructureChange?()
            closeSurface()
            return
        }
        rebuildTabStrip()
        if wasSelected {
            select(id: tabs[min(index, tabs.count - 1)].id)
        } else {
            updateTabStripState()
            updateOutputFocus()
            onStructureChange?()
        }
    }

    private func rebuildTabStrip() {
        tabStrip.setTabs(tabs.map { .init(id: $0.id, title: $0.title) })
        updateTabStripState()
    }

    private func updateTabStripState() {
        tabStrip.update(selectedID: selectedID, highlightedIDs: Set(tabs.filter(\.highlighted).map(\.id)))
    }

    private func updateOutputFocus() {
        let isFocused = surfaceIsFocused
        for tab in tabs {
            tab.output.setWindowFocused(isFocused && tab.id == selectedID)
        }
    }

    private var surfaceIsFocused: Bool {
        window?.isKeyWindow == true || root.window?.isKeyWindow == true
    }

    private func pulseDragFeedback() {
        root.layer?.borderWidth = 3
        root.layer?.borderColor = themePalette.accent.cgColor
        dragFeedbackGeneration += 1
        let generation = dragFeedbackGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, dragFeedbackGeneration == generation else { return }
            root.layer?.borderWidth = 0
            root.layer?.borderColor = nil
        }
    }

    private func observeFloatingDrag(frame: NSRect) {
        latestDragReleasePoint = NSEvent.mouseLocation
        guard floatingDragTask == nil, TriggerSpawnWindowController.leftMouseButtonIsPressed else { return }
        floatingDragTask = Task { @MainActor [weak self] in
            while TriggerSpawnWindowController.leftMouseButtonIsPressed {
                try? await Task.sleep(for: .milliseconds(25))
            }
            self?.finishFloatingDrag()
        }
    }

    private func finishFloatingDrag() {
        latestDragReleasePoint = NSEvent.mouseLocation
        guard let point = latestDragReleasePoint else {
            cancelFloatingDrag()
            return
        }
        cancelFloatingDrag()
        guard !isDocked else { return }
        if onWindowDragEnded?(point) == true { pulseDragFeedback() }
    }

    private func cancelFloatingDrag() {
        latestDragReleasePoint = nil
        floatingDragTask?.cancel()
        floatingDragTask = nil
    }

    private func makeOutput() -> OutputTextView {
        let output = OutputTextView()
        output.setUnreadBoundaryCoordinator(unreadBoundaryCoordinator)
        output.applyTheme(themePalette)
        output.showsInlineImagePreviews = showsInlineImagePreviews
        output.setWindowFocused(false)
        output.onAction = { [weak self] action in self?.onAction?(action) }
        output.onContextMenu = { [weak self] _ in self?.outputContextMenu() }
        return output
    }

    fileprivate func closeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Trigger Pane")
        menu.addItem(clearMenuItem())
        menu.addItem(.separator())
        menu.addItem(closeMenuItem())
        return menu
    }

    private func outputContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Trigger Pane")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(clearMenuItem())
        menu.addItem(.separator())
        menu.addItem(closeMenuItem())
        return menu
    }

    private func clearMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Clear", action: #selector(clearSelectedTab(_:)), keyEquivalent: "")
        item.target = self
        let lineCount = selectedID.flatMap { id in
            tabs.first(where: { $0.id == id })?.output.visibleLineCount
        } ?? 0
        item.isEnabled = lineCount > 0
        return item
    }

    private func closeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Close", action: #selector(requestClose(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func clearSelectedTab(_ sender: Any?) {
        guard let selectedID,
              let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        tabs[index].output.clear()
        onStructureChange?()
    }

    @objc private func requestClose(_ sender: Any?) { requestClose() }
}

@MainActor
private final class SpawnTabStripView: NSStackView {
    struct Item { let id: UUID; let title: String }
    static let pasteboardType = NSPasteboard.PasteboardType("org.beipmu.spawn-tab")
    weak var owner: TriggerSpawnTabGroupWindowController?
    private var items: [Item] = []
    private var cells: [UUID: SpawnTabCellView] = [:]
    private var draggedID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal
        alignment = .centerY
        spacing = 2
        edgeInsets = .init(top: 3, left: 5, bottom: 3, right: 5)
        registerForDraggedTypes([Self.pasteboardType])
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Spawn tabs")
    }

    required init?(coder: NSCoder) { nil }

    func setTabs(_ values: [Item]) {
        items = values
        arrangedSubviews.forEach { view in
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cells.removeAll(keepingCapacity: true)
        for item in values {
            let cell = SpawnTabCellView(item: item, owner: owner)
            cells[item.id] = cell
            addArrangedSubview(cell)
        }
        addArrangedSubview(NSView())
    }

    func update(selectedID: UUID?, highlightedIDs: Set<UUID>) {
        for (id, cell) in cells {
            cell.update(
                selected: id == selectedID,
                highlighted: highlightedIDs.contains(id),
                dragging: id == draggedID
            )
        }
    }

    func setDragging(id: UUID, active: Bool) {
        draggedID = active ? id : nil
        for (cellID, cell) in cells {
            cell.setDragging(cellID == draggedID)
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        localDraggedID(from: sender) == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        localDraggedID(from: sender) == nil ? [] : .move
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let id = localDraggedID(from: sender) else { return false }
        let x = convert(sender.draggingLocation, from: nil).x
        let insertion = items.firstIndex { item in
            guard let cell = cells[item.id] else { return false }
            return x < cell.frame.midX
        } ?? items.count
        owner?.moveDraggedTab(id, to: insertion)
        return true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else {
            super.mouseDragged(with: event)
            return
        }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        if owner?.dragDockedSurface(to: point) != true { super.mouseDragged(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { owner?.closeContextMenu() }

    private func localDraggedID(from sender: any NSDraggingInfo) -> UUID? {
        guard let raw = sender.draggingPasteboard.string(forType: Self.pasteboardType),
              let id = UUID(uuidString: raw),
              items.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}

@MainActor
private final class SpawnTabCellView: NSView, NSDraggingSource {
    private final class ClickThroughLabel: NSTextField {
        override var alignmentRectInsets: NSEdgeInsets {
            NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private let id: UUID
    private weak var owner: TriggerSpawnTabGroupWindowController?
    private let baseTitle: String
    private let titleLabel = ClickThroughLabel(labelWithString: "")
    private let closeButton: NSButton
    private var tracking: NSTrackingArea?
    private var selected = false
    private var highlighted = false
    private var dragging = false
    private var hovered = false

    init(item: SpawnTabStripView.Item, owner: TriggerSpawnTabGroupWindowController?) {
        id = item.id
        self.owner = owner
        baseTitle = item.title
        closeButton = NSButton()
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 7

        titleLabel.stringValue = item.title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.allowsExpansionToolTips = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.focusRingType = .none
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close \(item.title)"
        closeButton.setAccessibilityLabel("Close \(item.title)")
        closeButton.target = self
        closeButton.action = #selector(closeTab(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(item.title) spawn tab")
        setAccessibilityIdentifier("spawnTab")

        let minimumWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
        minimumWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            minimumWidth,
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -7),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil((baseTitle as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular),
        ]).width)
        return NSSize(width: min(max(titleWidth + 50, 96), 220), height: 28)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        owner?.selectDraggedTab(id)
    }

    override func menu(for event: NSEvent) -> NSMenu? { owner?.closeContextMenu() }

    override func mouseDragged(with event: NSEvent) {
        owner?.setDraggedTab(id, active: true)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(id.uuidString, forType: SpawnTabStripView.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(bounds, contents: dragImage())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func update(selected: Bool, highlighted: Bool, dragging: Bool) {
        self.selected = selected
        self.highlighted = highlighted
        invalidateIntrinsicContentSize()
        setDragging(dragging)
        setAccessibilitySelected(selected)
        setAccessibilityHelp(highlighted ? "Unread spawn activity" : nil)
    }

    func setDragging(_ dragging: Bool) {
        self.dragging = dragging
        updateAppearance()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        owner?.setDraggedTab(id, active: false)
    }

    private func updateAppearance() {
        alphaValue = dragging ? 0.62 : 1
        titleLabel.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        titleLabel.stringValue = (highlighted ? "● " : "") + baseTitle
        titleLabel.textColor = highlighted ? .systemOrange : .labelColor
        closeButton.isHidden = !(selected || hovered)
        layer?.backgroundColor = if selected {
            NSColor.controlColor.cgColor
        } else if hovered || dragging {
            NSColor.quaternaryLabelColor.cgColor
        } else {
            NSColor.clear.cgColor
        }
        layer?.borderWidth = dragging ? 2 : 0
        layer?.borderColor = dragging ? NSColor.controlAccentColor.cgColor : nil
    }

    private func dragImage() -> NSImage {
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSImage(size: bounds.size)
        }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }

    @objc private func closeTab(_ sender: Any?) {
        owner?.closeDraggedTab(id)
    }
}
