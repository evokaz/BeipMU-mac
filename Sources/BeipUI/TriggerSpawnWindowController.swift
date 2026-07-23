import AppKit
import BeipCore

@MainActor
final class TriggerSpawnWindowController: NSWindowController, NSWindowDelegate {
    private let output = OutputTextView()
    private let dockingAccessory = DockSurfaceAccessoryViewController()
    private(set) var isDocked = false
    var onClose: (() -> Void)?
    var onDockRequest: ((WebViewDockSide) -> Void)? {
        didSet { dockingAccessory.onDockRequest = onDockRequest }
    }
    var onAction: ((LinkAction) -> Void)? {
        didSet { output.onAction = onAction }
    }

    init(title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.setAccessibilityIdentifier("triggerSpawnWindow")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = output.containerView
        super.init(window: panel)
        panel.delegate = self
        panel.addTitlebarAccessoryViewController(dockingAccessory)
    }

    required init?(coder: NSCoder) { nil }

    func clear() { output.clear() }
    func append(_ line: RenderedLine) { output.append(line) }
    var retainedLines: [RenderedLine] { output.retainedLines }
    func contentViewForDocking() -> NSView {
        window?.orderOut(nil)
        if window?.contentView === output.containerView { window?.contentView = nil }
        output.containerView.removeFromSuperview()
        isDocked = true
        return output.containerView
    }
    func showFloating(_ sender: Any?) {
        if isDocked {
            output.containerView.removeFromSuperview()
            window?.contentView = output.containerView
            isDocked = false
        }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
    func closeSurface() {
        if isDocked {
            output.containerView.removeFromSuperview()
            window?.contentView = output.containerView
            isDocked = false
        }
        close()
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
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
    private let root = NSStackView()
    private let dockingAccessory = DockSurfaceAccessoryViewController()
    private var tabs: [Tab] = []
    private var selectedID: UUID?
    private(set) var isDocked = false
    var onClose: (() -> Void)?
    var onDockRequest: ((WebViewDockSide) -> Void)? {
        didSet { dockingAccessory.onDockRequest = onDockRequest }
    }
    var onAction: ((LinkAction) -> Void)?
    var onStructureChange: (() -> Void)?
    var onTabActivate: ((String) -> Void)?

    init(title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.setAccessibilityIdentifier("triggerSpawnTabGroupWindow")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        root.setViews([tabStrip, contentHost], in: .leading)
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        panel.contentView = root
        NSLayoutConstraint.activate([
            tabStrip.heightAnchor.constraint(equalToConstant: 32),
            tabStrip.widthAnchor.constraint(equalTo: root.widthAnchor),
            contentHost.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])

        super.init(window: panel)
        panel.delegate = self
        panel.addTitlebarAccessoryViewController(dockingAccessory)
        tabStrip.owner = self
    }

    required init?(coder: NSCoder) { nil }

    var tabTitles: [String] { tabs.map(\.title) }
    var selectedTitle: String? { tabs.first(where: { $0.id == selectedID })?.title }
    var highlightedTitles: [String] { tabs.filter(\.highlighted).map(\.title) }

    func contentViewForDocking() -> NSView {
        window?.orderOut(nil)
        if window?.contentView === root { window?.contentView = nil }
        root.removeFromSuperview()
        isDocked = true
        return root
    }

    func showFloating(_ sender: Any?) {
        if isDocked {
            root.removeFromSuperview()
            window?.contentView = root
            isDocked = false
        }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func closeSurface() {
        if isDocked {
            root.removeFromSuperview()
            window?.contentView = root
            isDocked = false
        }
        close()
    }

    func ensureTab(named title: String, selected: Bool = false) {
        if let index = index(ofTitle: title) {
            if selected { select(id: tabs[index].id) }
            return
        }
        let output = OutputTextView()
        output.onAction = { [weak self] action in self?.onAction?(action) }
        let id = UUID()
        tabs.append(.init(id: id, title: title, output: output, highlighted: false))
        rebuildTabStrip()
        if selectedID == nil || selected { select(id: id) }
        else { onStructureChange?() }
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
            let output = OutputTextView()
            output.onAction = { [weak self] action in self?.onAction?(action) }
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

    func windowWillClose(_ notification: Notification) { onClose?() }

    fileprivate func selectDraggedTab(_ id: UUID) { select(id: id) }

    fileprivate func closeDraggedTab(_ id: UUID) { closeTab(id: id) }

    fileprivate func moveDraggedTab(_ id: UUID, to insertionIndex: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        moveTab(from: source, to: insertionIndex)
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
        NSAccessibility.post(element: contentHost, notification: .layoutChanged)
        onTabActivate?(tabs[tabIndex].title)
        onStructureChange?()
    }

    private func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedID == id
        tabs.remove(at: index)
        if tabs.isEmpty {
            selectedID = nil
            contentHost.subviews.forEach { $0.removeFromSuperview() }
            onStructureChange?()
            closeSurface()
            return
        }
        rebuildTabStrip()
        if wasSelected {
            select(id: tabs[min(index, tabs.count - 1)].id)
        } else {
            updateTabStripState()
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
}

@MainActor
private final class SpawnTabStripView: NSStackView {
    struct Item { let id: UUID; let title: String }
    static let pasteboardType = NSPasteboard.PasteboardType("org.beipmu.spawn-tab")
    weak var owner: TriggerSpawnTabGroupWindowController?
    private var items: [Item] = []
    private var cells: [UUID: SpawnTabCellView] = [:]

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
            cell.update(selected: id == selectedID, highlighted: highlightedIDs.contains(id))
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [Self.pasteboardType]) == nil ? [] : .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { .move }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let raw = sender.draggingPasteboard.string(forType: Self.pasteboardType),
              let id = UUID(uuidString: raw) else { return false }
        let x = convert(sender.draggingLocation, from: nil).x
        let insertion = items.firstIndex { item in
            guard let cell = cells[item.id] else { return false }
            return x < cell.frame.midX
        } ?? items.count
        owner?.moveDraggedTab(id, to: insertion)
        return true
    }
}

@MainActor
private final class SpawnTabCellView: NSStackView {
    private let id: UUID
    private let titleButton: SpawnTabButton
    private let closeButton: NSButton

    init(item: SpawnTabStripView.Item, owner: TriggerSpawnTabGroupWindowController?) {
        id = item.id
        titleButton = SpawnTabButton(title: item.title, id: item.id, owner: owner)
        closeButton = NSButton(title: "×", target: nil, action: nil)
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 1
        titleButton.bezelStyle = .recessed
        titleButton.setButtonType(.toggle)
        titleButton.target = owner
        titleButton.action = #selector(TriggerSpawnTabGroupWindowController.selectTabButton(_:))
        titleButton.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        closeButton.isBordered = false
        closeButton.toolTip = "Close \(item.title)"
        closeButton.setAccessibilityLabel("Close \(item.title)")
        closeButton.target = owner
        closeButton.action = #selector(TriggerSpawnTabGroupWindowController.closeTabButton(_:))
        closeButton.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        addArrangedSubview(titleButton)
        addArrangedSubview(closeButton)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(selected: Bool, highlighted: Bool) {
        titleButton.state = selected ? .on : .off
        titleButton.contentTintColor = highlighted ? .systemOrange : .controlTextColor
        titleButton.title = (highlighted ? "● " : "") + titleButton.baseTitle
        titleButton.setAccessibilitySelected(selected)
        titleButton.setAccessibilityHelp(highlighted ? "Unread spawn activity" : nil)
    }
}

@MainActor
private final class SpawnTabButton: NSButton, NSDraggingSource {
    let baseTitle: String
    private let tabID: UUID
    private weak var owner: TriggerSpawnTabGroupWindowController?

    init(title: String, id: UUID, owner: TriggerSpawnTabGroupWindowController?) {
        baseTitle = title
        tabID = id
        self.owner = owner
        super.init(frame: .zero)
        self.title = title
        setAccessibilityRole(.radioButton)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDragged(with event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(tabID.uuidString, forType: SpawnTabStripView.pasteboardType)
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        draw(bounds)
        image.unlockFocus()
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }
}

private extension TriggerSpawnTabGroupWindowController {
    @objc func selectTabButton(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        selectDraggedTab(id)
    }

    @objc func closeTabButton(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) else { return }
        closeDraggedTab(id)
    }
}
