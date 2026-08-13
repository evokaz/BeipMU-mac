import AppKit
import AVFoundation
import BeipAutomation
import BeipCore
import BeipPersistence
import BeipProtocols
import BeipScriptRuntime
import Darwin
import UserNotifications

enum WorldTabDragInsertion {
    static func index(midpoints: [CGFloat], x: CGFloat) -> Int {
        midpoints.firstIndex(where: { x < $0 }) ?? midpoints.count
    }
}

enum SessionTabScrollOffset {
    static func clamped(
        current: CGFloat,
        horizontalDelta: CGFloat,
        verticalDelta: CGFloat,
        contentWidth: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        let maximum = max(0, contentWidth - viewportWidth)
        let proposed = current - horizontalDelta - verticalDelta
        return min(max(proposed, 0), maximum)
    }
}

@MainActor
private final class SessionTabStripView: NSStackView {
    static let pasteboardType = NSPasteboard.PasteboardType("org.beipmu.world-tab")
    static let minimumTabWidth: CGFloat = 112

    weak var owner: ClientWindowController?
    weak var viewport: SessionTabScrollView?
    private var tabControllers: [ClientWindowController] = []
    private var cells: [UUID: SessionWindowTabItemView] = [:]
    private var draggedTabID: UUID?
    private var dropInsertionIndex: Int?
    private var widthConstraints: [NSLayoutConstraint] = []
    private var accentColor = NSColor.controlAccentColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal
        alignment = .centerY
        distribution = .fill
        spacing = 4
        registerForDraggedTypes([Self.pasteboardType])
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("World tabs")
    }

    required init?(coder: NSCoder) { nil }

    func setTabs(_ controllers: [ClientWindowController], selectedController: ClientWindowController) {
        tabControllers = controllers
        widthConstraints.forEach { $0.isActive = false }
        widthConstraints.removeAll(keepingCapacity: true)
        arrangedSubviews.forEach {
            removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        cells.removeAll(keepingCapacity: true)
        for controller in controllers {
            let tab = SessionWindowTabItemView(
                tabID: controller.tabDragIdentifier,
                title: controller.sessionTabTextForTabStrip,
                trailingIndicators: controller.sessionTabTrailingIndicatorsForTabStrip,
                isTerminallyDisconnected: controller.isTerminallyDisconnectedForTabStrip,
                selected: controller === selectedController,
                color: controller.sessionTabColorForTabStrip,
                targetController: controller,
                strip: self
            )
            tab.applyTheme(accent: accentColor)
            cells[controller.tabDragIdentifier] = tab
            addArrangedSubview(tab)
        }
        viewport?.setNeedsLayoutAndRevealSelection()
        needsDisplay = true
    }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        accentColor = palette.accent
        cells.values.forEach { $0.applyTheme(accent: palette.accent) }
        needsDisplay = true
    }

    var tabWidths: [CGFloat] {
        tabControllers.compactMap { cells[$0.tabDragIdentifier]?.frame.width }
    }

    var tabTooltips: [String?] {
        tabControllers.map { cells[$0.tabDragIdentifier]?.toolTip }
    }

    var tabIndicators: [String] {
        tabControllers.compactMap { cells[$0.tabDragIdentifier]?.trailingIndicators }
    }

    var tabAccessibilityLabels: [String?] {
        tabControllers.map { cells[$0.tabDragIdentifier]?.accessibilityLabel() }
    }

    var selectedTab: SessionWindowTabItemView? {
        tabControllers
            .compactMap { cells[$0.tabDragIdentifier] }
            .first { $0.isSelectedForLayout }
    }

    @discardableResult
    func layoutForViewport(width viewportWidth: CGFloat) -> CGFloat {
        let naturalWidths = tabControllers.compactMap { cells[$0.tabDragIdentifier]?.naturalWidth }
        guard naturalWidths.count == tabControllers.count else {
            setFrameSize(NSSize(width: max(1, viewportWidth), height: 28))
            return max(1, viewportWidth)
        }

        let minimumWidths = naturalWidths.map { _ in Self.minimumTabWidth }
        let naturalTotal = naturalWidths.reduce(0, +) + CGFloat(max(0, naturalWidths.count - 1)) * spacing
        let minimumTotal = minimumWidths.reduce(0, +) + CGFloat(max(0, minimumWidths.count - 1)) * spacing
        let availableWidth = max(1, viewportWidth)
        let targetWidth = naturalTotal <= availableWidth
            ? naturalTotal
            : max(minimumTotal, availableWidth)
        let widths: [CGFloat]
        if targetWidth >= naturalTotal || naturalWidths.isEmpty {
            widths = naturalWidths
        } else if targetWidth <= minimumTotal {
            widths = minimumWidths
        } else {
            let compressible = naturalTotal - minimumTotal
            let scale = compressible > 0
                ? (naturalTotal - targetWidth) / compressible
                : 1
            widths = zip(naturalWidths, minimumWidths).map { natural, minimum in
                natural - (natural - minimum) * scale
            }
        }

        widthConstraints = zip(tabControllers, widths).compactMap { controller, width in
            guard let cell = cells[controller.tabDragIdentifier] else { return nil }
            return cell.widthAnchor.constraint(equalToConstant: max(Self.minimumTabWidth, width))
        }
        NSLayoutConstraint.activate(widthConstraints)
        setFrameSize(NSSize(width: max(1, targetWidth), height: 28))
        layoutSubtreeIfNeeded()
        return targetWidth
    }

    func setDragging(_ id: UUID?, active: Bool) {
        draggedTabID = active ? id : nil
        cells.forEach { tabID, cell in cell.setDragging(active && tabID == id) }
        needsDisplay = true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard localDraggedTabID(from: sender) != nil else {
            clearDropIndicator()
            return []
        }
        updateDropIndicator(for: sender)
        return .move
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard localDraggedTabID(from: sender) != nil else {
            clearDropIndicator()
            return []
        }
        updateDropIndicator(for: sender)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearDropIndicator()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let id = localDraggedTabID(from: sender) else {
            clearDropIndicator()
            return false
        }
        let index = insertionIndex(at: sender.draggingLocation)
        clearDropIndicator()
        return (NSApp.delegate as? ApplicationDelegate)?.completeTabDrop(
            tabID: id,
            target: owner,
            insertionIndex: index
        ) ?? false
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        clearDropIndicator()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard dropInsertionIndex != nil else { return }
        let highlight = bounds.insetBy(dx: 1, dy: 1)
        accentColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: highlight, xRadius: 6, yRadius: 6).fill()

        let index = dropInsertionIndex ?? 0
        let markerX: CGFloat
        if index < tabControllers.count, let cell = cells[tabControllers[index].tabDragIdentifier] {
            markerX = cell.frame.minX - 2
        } else if let last = tabControllers.last,
                  let cell = cells[last.tabDragIdentifier] {
            markerX = cell.frame.maxX + 2
        } else {
            markerX = 2
        }
        accentColor.setFill()
        NSBezierPath(rect: NSRect(x: markerX, y: 3, width: 2, height: max(0, bounds.height - 6))).fill()
    }

    static func insertionIndex(midpoints: [CGFloat], x: CGFloat) -> Int {
        WorldTabDragInsertion.index(midpoints: midpoints, x: x)
    }

    func insertionIndex(at point: NSPoint) -> Int {
        layoutSubtreeIfNeeded()
        let midpoints = tabControllers.compactMap { cells[$0.tabDragIdentifier]?.frame.midX }
        return Self.insertionIndex(midpoints: midpoints, x: convert(point, from: nil).x)
    }

    private func updateDropIndicator(for sender: any NSDraggingInfo) {
        dropInsertionIndex = insertionIndex(at: sender.draggingLocation)
        needsDisplay = true
    }

    private func clearDropIndicator() {
        guard dropInsertionIndex != nil else { return }
        dropInsertionIndex = nil
        needsDisplay = true
    }

    private func localDraggedTabID(from sender: any NSDraggingInfo) -> UUID? {
        guard let raw = sender.draggingPasteboard.string(forType: Self.pasteboardType),
              let id = UUID(uuidString: raw),
              sender.draggingSource is SessionWindowTabItemView,
              let delegate = NSApp.delegate as? ApplicationDelegate,
              delegate.tabController(for: id) != nil else { return nil }
        return id
    }
}

@MainActor
private final class MenuStripView: NSStackView {
    weak var owner: ClientWindowController?

    override func menu(for event: NSEvent) -> NSMenu? {
        owner?.menuStripContextMenu()
    }
}

@MainActor
private final class SessionTabScrollView: NSScrollView {
    private weak var strip: SessionTabStripView?
    private var shouldRevealSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        backgroundColor = .clear
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = true
        autohidesScrollers = true
        horizontalScrollElasticity = .none
        verticalScrollElasticity = .none
        scrollerStyle = .overlay
        setAccessibilityRole(.group)
        setAccessibilityLabel("Session tabs")
        setAccessibilityIdentifier("sessionTabViewport")
    }

    required init?(coder: NSCoder) { nil }

    func attach(_ strip: SessionTabStripView) {
        self.strip = strip
        strip.viewport = self
        documentView = strip
    }

    func setNeedsLayoutAndRevealSelection() {
        shouldRevealSelection = true
        needsLayout = true
    }

    func revealSelectedTab() {
        guard let strip, let selected = strip.selectedTab else { return }
        layoutSubtreeIfNeeded()
        contentView.scrollToVisible(selected.frame.insetBy(dx: -3, dy: 0))
        shouldRevealSelection = false
    }

    override func scrollWheel(with event: NSEvent) {
        guard let documentView else { return }
        let currentOrigin = contentView.bounds.origin
        let nextX = SessionTabScrollOffset.clamped(
            current: currentOrigin.x,
            horizontalDelta: event.scrollingDeltaX,
            verticalDelta: event.scrollingDeltaY,
            contentWidth: documentView.bounds.width,
            viewportWidth: contentView.bounds.width
        )
        guard nextX != currentOrigin.x else { return }
        contentView.scroll(to: NSPoint(x: nextX, y: currentOrigin.y))
        reflectScrolledClipView(contentView)
    }

    override func layout() {
        super.layout()
        guard let strip else { return }
        strip.layoutForViewport(width: contentView.bounds.width)
        if shouldRevealSelection {
            revealSelectedTab()
        }
    }
}

@MainActor
private final class SessionWindowTabItemView: NSView, NSDraggingSource {
    private let tabID: UUID
    weak var targetController: ClientWindowController?
    private weak var strip: SessionTabStripView?
    private final class ClickThroughLabel: NSTextField {
        override var alignmentRectInsets: NSEdgeInsets {
            NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private let titleLabel = ClickThroughLabel(labelWithString: "")
    private let trailingIndicatorLabel = ClickThroughLabel(labelWithString: "")
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?
    private var selected = false
    private let tabColor: NSColor?
    private var hovered = false
    private var dragging = false
    private var dragStarted = false
    private var accentColor = NSColor.controlAccentColor

    var isSelectedForLayout: Bool { selected }
    var trailingIndicators: String { trailingIndicatorLabel.stringValue }
    var naturalWidth: CGFloat {
        let titleWidth = titleLabel.intrinsicContentSize.width
        let indicatorWidth = trailingIndicatorLabel.intrinsicContentSize.width
        let indicatorSpacing: CGFloat = trailingIndicatorLabel.stringValue.isEmpty ? 0 : 5
        let fixedWidth: CGFloat = 7 + 16 + 5 + indicatorSpacing + 10
        return max(SessionTabStripView.minimumTabWidth, fixedWidth + titleWidth + indicatorWidth)
    }

    init(
        tabID: UUID,
        title: String,
        trailingIndicators: String,
        isTerminallyDisconnected: Bool,
        selected: Bool,
        color: NSColor?,
        targetController: ClientWindowController,
        strip: SessionTabStripView
    ) {
        self.tabID = tabID
        self.targetController = targetController
        self.strip = strip
        self.selected = selected
        tabColor = color
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 7

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        titleLabel.lineBreakMode = .byClipping
        titleLabel.maximumNumberOfLines = 1
        titleLabel.allowsExpansionToolTips = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityIdentifier("sessionTabTitle")
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        trailingIndicatorLabel.stringValue = trailingIndicators
        trailingIndicatorLabel.font = .systemFont(ofSize: 13)
        trailingIndicatorLabel.lineBreakMode = .byClipping
        trailingIndicatorLabel.maximumNumberOfLines = 1
        trailingIndicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        trailingIndicatorLabel.setAccessibilityIdentifier("sessionTabIndicators")
        trailingIndicatorLabel.setContentHuggingPriority(.required, for: .horizontal)
        trailingIndicatorLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(trailingIndicatorLabel)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.focusRingType = .none
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTab(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = !selected
        closeButton.toolTip = "Close tab"
        closeButton.setAccessibilityLabel("Close tab")
        closeButton.setAccessibilityIdentifier("sessionTabClose")
        addSubview(closeButton)

        toolTip = title

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            isTerminallyDisconnected ? "\(title) tab, disconnected" : "\(title) tab"
        )
        setAccessibilityIdentifier(selected ? "activeSessionTab" : "sessionTab")

        let minimumWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: SessionTabStripView.minimumTabWidth)
        let titleToIndicators = titleLabel.trailingAnchor.constraint(
            equalTo: trailingIndicatorLabel.leadingAnchor,
            constant: trailingIndicators.isEmpty ? 0 : -5
        )
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            minimumWidth,
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 5),
            titleToIndicators,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingIndicatorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailingIndicatorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateBackground()
    }

    required init?(coder: NSCoder) { nil }

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
        closeButton.isHidden = false
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        closeButton.isHidden = !selected
        updateBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted,
              let delegate = NSApp.delegate as? ApplicationDelegate,
              delegate.beginTabDrag(tabID: tabID) else { return }
        dragStarted = true
        strip?.setDragging(tabID, active: true)

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(tabID.uuidString, forType: SessionTabStripView.pasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: dragImage())
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStarted = false }
        guard !dragStarted else { return }
        selectTab(self)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        targetController?.window?.performClose(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = targetController?.sessionTabContextMenu() else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        targetController?.sessionTabContextMenu()
    }

    func setDragging(_ dragging: Bool) {
        self.dragging = dragging
        updateBackground()
    }

    func applyTheme(accent: NSColor) {
        accentColor = accent
        updateBackground()
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        strip?.setDragging(tabID, active: false)
        (NSApp.delegate as? ApplicationDelegate)?.finishTabDrag(
            tabID: tabID,
            screenPoint: screenPoint,
            operation: operation
        )
    }

    private func updateBackground() {
        alphaValue = dragging ? 0.62 : 1
        layer?.backgroundColor = if selected {
            (tabColor ?? NSColor.controlColor).cgColor
        } else if hovered || dragging {
            NSColor.quaternaryLabelColor.cgColor
        } else {
            NSColor.clear.cgColor
        }
        layer?.borderWidth = dragging ? 2 : 0
        layer?.borderColor = dragging ? accentColor.cgColor : nil
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

    @objc private func selectTab(_ sender: Any?) {
        targetController?.sessionTabGroup?.select(targetController, sender: sender)
    }

    @objc private func closeTab(_ sender: Any?) {
        targetController?.window?.performClose(sender)
    }
}

@MainActor
final class ClientTabGroup {
    private final class WeakController {
        weak var value: ClientWindowController?
        init(_ value: ClientWindowController) { self.value = value }
    }

    private var entries: [WeakController]
    private(set) weak var selectedController: ClientWindowController?

    init(_ initialController: ClientWindowController) {
        entries = [WeakController(initialController)]
        selectedController = initialController
        initialController.sessionTabGroup = self
    }

    var controllers: [ClientWindowController] {
        entries.compactMap(\.value)
    }

    func add(_ controller: ClientWindowController) {
        insert(controller, at: controllers.count, selecting: false)
    }

    func insert(
        _ controller: ClientWindowController,
        at index: Int,
        selecting: Bool = true
    ) {
        guard !controllers.contains(where: { $0 === controller }) else { return }
        let insertionIndex = min(max(index, 0), entries.count)
        entries.insert(WeakController(controller), at: insertionIndex)
        controller.sessionTabGroup = self
        refreshTabs()
        if selecting { select(controller, sender: nil) }
    }

    func reorder(_ controller: ClientWindowController, to index: Int) {
        let currentControllers = controllers
        guard let currentIndex = currentControllers.firstIndex(where: { $0 === controller }) else { return }
        let entry = entries.remove(at: currentIndex)
        let adjustedIndex = index > currentIndex ? index - 1 : index
        let insertionIndex = min(max(adjustedIndex, 0), entries.count)
        entries.insert(entry, at: insertionIndex)
        refreshTabs()
    }

    @discardableResult
    func detach(_ controller: ClientWindowController) -> Bool {
        let currentControllers = controllers
        guard currentControllers.count > 1,
              let index = currentControllers.firstIndex(where: { $0 === controller }) else {
            return false
        }

        let wasSelected = selectedController === controller
        let sourceFrame = controller.window?.frame
        entries.remove(at: index)
        controller.sessionTabGroup = nil

        let remaining = controllers
        guard !remaining.isEmpty else {
            selectedController = nil
            return true
        }

        if remaining.count == 1 {
            let survivor = remaining[0]
            survivor.sessionTabGroup = nil
            selectedController = nil
            if wasSelected {
                if let sourceFrame { survivor.window?.setFrame(sourceFrame, display: false) }
                controller.window?.orderOut(nil)
                survivor.showWindow(nil)
                survivor.window?.makeKeyAndOrderFront(nil)
                survivor.focusCommandInput()
            }
            survivor.rebuildSessionTabs()
            return true
        }

        if wasSelected {
            let replacement = remaining[min(index, remaining.count - 1)]
            selectedController = replacement
            if let sourceFrame { replacement.window?.setFrame(sourceFrame, display: false) }
            controller.window?.orderOut(nil)
            replacement.showWindow(nil)
            replacement.window?.makeKeyAndOrderFront(nil)
            replacement.focusCommandInput()
        }
        refreshTabs()
        return true
    }

    func select(_ controller: ClientWindowController?, sender: Any?) {
        guard let controller, controllers.contains(where: { $0 === controller }) else { return }
        let previous = selectedController
        if let frame = previous?.window?.frame {
            controller.window?.setFrame(frame, display: false)
        }
        selectedController = controller
        if previous !== controller { previous?.window?.orderOut(sender) }
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
        controller.focusCommandInput()
        refreshTabs()
        controller.tabStateDidChange()
    }

    func prepareToClose(_ controller: ClientWindowController) {
        guard selectedController === controller else { return }
        let current = controllers
        guard current.count > 1,
              let index = current.firstIndex(where: { $0 === controller }) else { return }
        let remaining = current.filter { $0 !== controller }
        let replacement = remaining[min(index, remaining.count - 1)]
        if let frame = controller.window?.frame {
            replacement.window?.setFrame(frame, display: false)
        }
        selectedController = replacement
        replacement.showWindow(nil)
        replacement.window?.makeKeyAndOrderFront(nil)
        replacement.focusCommandInput()
        refreshTabs()
    }

    func markSelected(_ controller: ClientWindowController) {
        guard controllers.contains(where: { $0 === controller }) else { return }
        selectedController = controller
        refreshTabs()
        controller.tabStateDidChange()
    }

    func controllerWillClose(_ controller: ClientWindowController) {
        let before = controllers
        guard let index = before.firstIndex(where: { $0 === controller }) else { return }
        let wasSelected = selectedController === controller
        entries.removeAll { $0.value == nil || $0.value === controller }
        controller.sessionTabGroup = nil

        let remaining = controllers
        if remaining.count == 1 {
            let survivor = remaining[0]
            survivor.sessionTabGroup = nil
            selectedController = nil
            if wasSelected {
                DispatchQueue.main.async {
                    survivor.showWindow(nil)
                    survivor.window?.makeKeyAndOrderFront(nil)
                    survivor.rebuildSessionTabs()
                }
            } else {
                survivor.rebuildSessionTabs()
            }
            return
        }

        if wasSelected, !remaining.isEmpty {
            selectedController = nil
            let replacement = remaining[min(index, remaining.count - 1)]
            DispatchQueue.main.async { [weak self, weak replacement] in
                self?.select(replacement, sender: nil)
            }
        } else {
            refreshTabs()
        }
        controller.tabStateDidChange()
    }

    func refreshTabs() {
        controllers.forEach { $0.rebuildSessionTabs() }
    }
}

@MainActor
final class ClientWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    private struct SpawnCapture {
        var title: String
        var action: TriggerSpawnAction
        var children: [Trigger]
    }

    private struct WindowSettingsClipboard: Codable {
        var globalTextWindowSettings: TextWindowSettings
        var worldTextWindowSettings: [String: TextWindowSettingsOverride]
        var characterTextWindowSettings: [String: TextWindowSettingsOverride]
        var tabTextWindowSettings: [String: TextWindowSettingsOverride]
        var globalInputWindowSettings: InputWindowSettings
        var worldInputWindowSettings: [String: InputWindowSettingsOverride]
        var characterInputWindowSettings: [String: InputWindowSettingsOverride]
        var tabInputWindowSettings: [String: InputWindowSettingsOverride]
    }

    private struct ActiveCharacterProfile: Equatable {
        let serverID: UUID
        let characterID: UUID
    }

    private final class SimpleEditUploadState {
        let reference: String
        let type: String
        let original: String
        var lastUploaded: String?

        init(reference: String, type: String, original: String) {
            self.reference = reference
            self.type = type
            self.original = original
        }
    }

    private let profileLibrary: ProfileLibrary
    private var loggingCoordinator: SessionLoggingCoordinator!
    private var recoveryCoordinator: SessionRecoveryCoordinator!
    private let output = OutputTextView()
    private let input = CommandInputView()
    private let inputSplitView = NSSplitView()
    private let inputHistoryPane = InputHistoryPaneView()
    private let inputContainer = NSView()
    private let stateLabel = NSTextField(labelWithString: "Disconnected")
    private let activityLabel = NSTextField(labelWithString: "")
    private let applicationMenuButton = NSButton()
    private let quickConnectButton = NSButton()
    private let profilesButton = NSButton()
    private let sessionTabs = SessionTabStripView(frame: .zero)
    private let sessionTabViewport = SessionTabScrollView(frame: .zero)
    private let titlebarStatistics = SessionTitlebarStatisticsController()
    private let commandRegistry = CommandRegistry()
    private let delayScheduler = DelayScheduler()
    private let scriptService = ScriptServiceClient()
    private let runsScriptServices: Bool
    private let aiClient = AIClient()
    private let triggerEngine = TriggerEngine()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var scriptSounds: [NSSound] = []
    private var scriptWindows: [String: ScriptWindowController] = [:]
    private var suppressNextSessionActivity = false
    private var suppressSessionData = false
    private var frameBeforeMaximize: NSRect?
    private var dockController: WorkspaceDockController!
    private var variables: [String: String] = [:]
    private var aliasGroups: [AliasGroup] = []
    private var triggerGroups: [TriggerGroup] = []
    private var keyboardMacroGroups: [KeyboardMacroGroup] = []
    private var session: SessionActor?
    private var sessionTask: Task<Void, Never>?
    private var activeCharacterProfile: ActiveCharacterProfile?
    private var persistedSessionStatistics = ConnectionStatistics()
    private var currentServer: ServerProfile?
    private var currentCharacter: CharacterProfile?
    private var currentPuppet: PuppetProfile?
    private weak var puppetMaster: ClientWindowController?
    private var puppetChildren: [UUID: ClientWindowController] = [:]
    private var aiWindow: AIWindowController?
    private var aiRequestTask: Task<Void, Never>?
    private var preservingAIPlacement = false
    private var grabPrefix: String?
    private var secondaryInputWindows: [SecondaryInputWindowController] = []
    private var isInputHistoryPaneVisible = false
    private var editWindows: [EditWindowController] = []
    private var statisticsWindow: SessionStatisticsWindowController?
    private var loggingWindow: LoggingWindowController?
    private var triggerStatisticsWindows: [String: TriggerStatisticsWindowController] = [:]
    private var triggerStatistics: [String: TriggerStatisticStore] = [:]
    private var triggerSpawnWindows: [String: TriggerSpawnWindowController] = [:]
    private var triggerSpawnTabGroups: [String: TriggerSpawnTabGroupWindowController] = [:]
    private var suppressSpawnPersistence = false
    private var gmcpState = AdvancedGMCPState()
    private var mediaState = ClientMediaState()
    private let mediaController = ClientMediaController()
    private var mcpStatusWindow: MCPStatusWindowController?
    private var webViewState = WebViewProtocolState()
    private var webViewWindows: [String: WebViewWindowController] = [:]
    private var nextUnnamedWebViewID = 1
    private var gmcpStatisticsWindows: [String: GMCPStatisticsWindowController] = [:]
    private var tileMapWindows: [String: TileMapWindowController] = [:]
    private var atlasWindow: AtlasWindowController?
    private var suppressAtlasPersistence = false
    private var preservingAtlasPlacement = false
    private var automationEditors: [AutomationEditorWindowController] = []
    private var automationDebugWindows: [CommandOutcome.DebugAutomationKind: AutomationDebugWindowController] = [:]
    private var networkDebugWindow: NetworkDebugWindowController?
    private var scriptDebugWindow: ScriptDebugWindowController?
    private var scriptDebugEntries: [ScriptDebugWindowController.Entry] = []
    private var helpWindow: EmbeddedHelpWindowController?
    private var spawnCapture: SpawnCapture?
    private var statisticsTask: Task<Void, Never>?
    private var titlebarStatisticsTask: Task<Void, Never>?
    private var lastTypedAt = Date()
    private var isSessionConnected = false
    private var localEcho = true
    private var terminalType = "Beip"
    private var gmcpDumpEnabled = false
    private var tileMapsEnabled = true
    private var hasPendingPrompt = false
    private var unreadCount = 0
    private var lastFindQuery = ""
    private var sessionTabColor: NSColor?
    let tabDragIdentifier = UUID()
    private var profileLibraryObserverID: UUID?
    var sessionTabGroup: ClientTabGroup?
    private var preferences: WorkspacePreferences
    private var baseWindowTitle = "Untitled"
    private var scriptTitlePrefix = ""
    private var isMuted = false
    private var bypassLastTabReplacement = false
    private var suppressPersistence = false
    private var connectionStateText = "Disconnected"
    private var isTerminallyDisconnected = true
    private weak var taskbarView: NSStackView?
    private weak var rootStackView: NSStackView?
    private weak var workspaceHostView: NSView?
    private var tracksInputHeight = false
    private var inputHistoryHeight: CGFloat = 84
    private var isRestoringInputSplitLayout = false
    private var applicationTerminationPrepared = false
    private static var didRunStartupScript = false
    private static let minimumOutputHeight: CGFloat = 80
    private static let minimumInputHistoryHeight: CGFloat = 22
    private static let minimumInputHeight: CGFloat = 30
    var onClose: (() -> Void)?
    var onRequestCloseLastTab: ((ClientWindowController) -> Bool)?
    var onTabStateChange: (() -> Void)?
    var onQuickConnectProfile: ((ClientWindowController, ServerProfile, CharacterProfile?) -> Void)?
    var onThemeChange: ((WorkspaceThemeSettings) -> Void)?
    var onTextWindowSettingsChange: (() -> Void)?
    var onWorkspacePreferencesChange: (() -> Void)?
    var onSettingsRequest: ((ClientWindowController, SettingsSection, TextWindowSettingsEditorView.Scope?) -> Void)?
    var onFactoryResetRequest: (() -> Void)?
    var onInputHeightChange: ((Double) -> Void)?
    var timestampsEnabled: Bool {
        let settings = activeTextWindowSettings
        return settings.showsTime || settings.showsDate
    }
    var fanFoldEnabled: Bool { activeTextWindowSettings.usesFanFoldBackgrounds }
    var stickyInputEnabled: Bool { activeInputWindowSettings.keepsTextOnSubmit }
    var spellCheckingEnabled: Bool { preferences.checksSpelling }
    var outputSplitEnabled: Bool { output.isSplit }
    var muted: Bool { isMuted }
    var dockPlacement: WorkspaceDockPlacement { dockController?.placement ?? preferences.dockPlacement }
    var legacyDockPlacement: WorkspaceDockPlacement? { dockController?.legacyPlacement }
    var activeLogCount: Int { loggingCoordinator?.activeLogCount ?? 0 }

    var settingsIdentityForTesting: TextWindowSettingsIdentity { textWindowIdentity }

    var sessionTabTextForTabStrip: String { sessionTabText }
    var sessionTabTrailingIndicatorsForTabStrip: String { sessionTabTrailingIndicators }
    var sessionTabColorForTabStrip: NSColor? { sessionTabColor }
    var isTerminallyDisconnectedForTabStrip: Bool { isTerminallyDisconnected }

    func startDeviceMediaAuditIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BEIPMU_DEVICE_MEDIA_AUDIT"] == "1" else { return }

        if let source = environment["BEIPMU_DEVICE_MEDIA_URL"].flatMap(URL.init(string:)) {
            let item = ClientMediaItem(
                name: "device-audit",
                source: source,
                volume: 1,
                loops: 1,
                continues: false
            )
            appendClient("Device audit: downloading Client.Media from \(source.absoluteString)")
            mediaController.apply(.play(item))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                appendClient("Device audit: \(mediaController.information)")
            }
        }

        let phrase = environment["BEIPMU_DEVICE_SPEECH_TEXT"]
            ?? "BeipMU selected speech voice device audit."
        let utterance = AVSpeechUtterance(string: phrase)
        if let identifier = preferences.speechVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
            appendClient("Device audit: speaking with \(voice.name), \(voice.language).")
        } else {
            appendClient("Device audit: speaking with the system default voice.")
        }
        speechSynthesizer.speak(utterance)
    }

    func usesWorkspaceLayout(_ layout: WorkspaceLayoutNode) -> Bool {
        dockController?.currentLayout.hasSameTopology(as: layout) == true
    }

    func toggleMaximize() {
        guard let window, let screen = window.screen else { return }
        if let restoreFrame = frameBeforeMaximize {
            frameBeforeMaximize = nil
            window.setFrame(restoreFrame, display: true)
            Self.postFrameChange(for: window)
        } else {
            frameBeforeMaximize = window.frame
            Self.configureUnrestrictedSizing(for: window)
            window.setFrame(screen.visibleFrame, display: true)
            Self.postFrameChange(for: window)
            Self.publishTestFrame(for: window)
        }
    }

    func toggleFullScreen() {
        guard let window else { return }
        Self.configureUnrestrictedSizing(for: window)
        window.toggleFullScreen(nil)
    }

    init(
        profileLibrary: ProfileLibrary,
        recoveryStore: SessionRecoveryStore? = nil,
        runsScriptServices: Bool = true,
        initialPreferences: WorkspacePreferences = WorkspacePreferencesStore.load()
    ) {
        self.profileLibrary = profileLibrary
        self.runsScriptServices = runsScriptServices
        self.preferences = initialPreferences
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.title = "BeipMU"
        window.setAccessibilityIdentifier("mainWindow")
        super.init(window: window)
        recoveryCoordinator = SessionRecoveryCoordinator(store: recoveryStore)
        loggingCoordinator = SessionLoggingCoordinator(
            context: .init(
                options: { [weak self] in self?.preferences.logging ?? .init() },
                baseWindowTitle: { [weak self] in self?.baseWindowTitle ?? "Untitled" },
                serverName: { [weak self] in self?.currentServer?.name ?? "Server" },
                characterName: { [weak self] in self?.currentCharacter?.name ?? "Character" },
                loggingPath: { [weak self] in self?.profileLibrary.workspace.projection.loggingPath ?? "" },
                workspaceSourceURL: { [weak self] in self?.profileLibrary.workspace.sourceURL },
                themePalette: { [weak self] in
                    let palette = self?.preferences.theme.palette
                    return (
                        foreground: palette?.foreground.hexString ?? "#FFFFFF",
                        background: palette?.background.hexString ?? "#000000"
                    )
                },
                automaticConfiguration: { [weak self] in
                    guard let self else { return .init() }
                    if let puppet = currentPuppet, !puppet.logFilename.isEmpty {
                        return .init(
                            filename: puppet.logFilename,
                            appendsDate: puppet.logAppendsDate,
                            enabled: true
                        )
                    }
                    if let server = currentServer,
                       let legacy = profileLibrary.workspace.projection.automaticLog(
                           for: server,
                           character: currentCharacter
                       ) {
                        return .init(
                            filename: legacy.filename,
                            appendsDate: legacy.appendsDate,
                            enabled: true
                        )
                    }
                    return .init(filename: nil, appendsDate: false, enabled: preferences.logging.autoLogEnabled)
                }
            ),
            callbacks: .init(
                informationalNotice: { [weak self] text in self?.appendInformationalNotice(text) },
                clientNotice: { [weak self] text in self?.appendClient(text) },
                error: { [weak self] text in self?.appendError(text) },
                stateChanged: { [weak self] in
                    guard let self else { return }
                    updateWindowTitle()
                    refreshDiagnostics()
                    refreshLoggingWindow()
                }
            )
        )
        profileLibraryObserverID = profileLibrary.addChangeObserver { [weak self] in
            self?.profileLibraryDidChange()
        }
        if runsScriptServices {
            Task { [weak self, scriptService] in
                await scriptService.startAsyncOutputDelivery { [weak self] outputs in
                    self?.applyScriptEvaluation(.init(outputs: outputs), showValue: false)
                }
            }
        }
        mediaController.onError = { [weak self] message in self?.appendError(message) }
        if preferences.logging == SessionLogOptions() {
            preferences.logging = profileLibrary.workspace.projection.logging
        }
        window.delegate = self
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localCalendarDidChange(_:)),
            name: .NSCalendarDayChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(localCalendarDidChange(_:)),
            name: .NSSystemTimeZoneDidChange,
            object: nil
        )
        configureUI(in: window)
        startTitlebarStatisticsUpdates()
        Self.configureUnrestrictedSizing(for: window)
        if ProcessInfo.processInfo.environment["BEIPMU_UI_TESTING"] == "1" {
            window.setContentSize(NSSize(width: 980, height: 700))
            window.center()
        } else {
            if !window.setFrameUsingName("BeipMUClientWindow") { window.center() }
            RuntimeStateContext.setFrameAutosaveName("BeipMUClientWindow", for: window)
        }
        restoreInputHeight()
        tracksInputHeight = true
        appendClient("Welcome to BeipMU for Mac. Choose Connection → Connect… to begin.")
        runStartupScriptIfNeeded()
        updateWindowTitle()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Restored tabs can be laid out while hidden. Reapply the saved input
        // height after AppKit has completed the visible layout.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            window.contentView?.layoutSubtreeIfNeeded()
            self.restoreInputHeight()
            self.inputLayoutRestorationGenerationForTesting &+= 1
        }
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: .NSCalendarDayChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .NSSystemTimeZoneDidChange, object: nil)
        profileLibrary.removeChangeObserver(profileLibraryObserverID)
        profileLibraryObserverID = nil
        if applicationTerminationPrepared {
            // Factory reset closes every tab in the group; letting the group
            // select a survivor here would recreate a window while the reset
            // coordinator is tearing the workspace down.
            sessionTabGroup = nil
        } else {
            sessionTabGroup?.controllerWillClose(self)
        }
        if let puppet = currentPuppet {
            puppetMaster?.detachPuppetChild(puppet.id)
            puppetMaster = nil
        } else {
            let children = Array(puppetChildren.values)
            puppetChildren.removeAll()
            children.forEach { $0.masterConnectionClosed() }
        }
        if runsScriptServices {
            Task { [weak self, scriptService] in
                guard let self else { return }
                applyScriptEvaluation(
                    await scriptService.dispatchConnectionEvent("window:close", host: scriptHostSnapshot),
                    showValue: false
                )
            }
        }
        dockController?.prepareForOwnerClose()
        secondaryInputWindows.forEach { $0.close() }
        editWindows.forEach { $0.close() }
        statisticsTask?.cancel()
        titlebarStatisticsTask?.cancel()
        statisticsWindow?.close()
        loggingWindow?.close()
        triggerStatisticsWindows.values.forEach { $0.close() }
        saveSpawnSurfacePreferences()
        closeSpawnSurfaces()
        gmcpStatisticsWindows.values.forEach { $0.close() }
        tileMapWindows.values.forEach { $0.close() }
        mcpStatusWindow?.close()
        closeWebViews()
        mediaController.flush()
        scriptWindows.values.forEach { $0.close() }
        scriptWindows.removeAll()
        if applicationTerminationPrepared {
            automationEditors.forEach { $0.prepareForFactoryReset(); $0.close() }
            automationEditors.removeAll()
            helpWindow?.close()
            helpWindow = nil
        }
        saveAtlasSurfacePreferences()
        closeAtlasSurface()
        automationDebugWindows.values.forEach { $0.close() }
        networkDebugWindow?.close()
        scriptDebugWindow?.close()
        closeAIWindow(preservingDockPlacement: false)
        loggingCoordinator.stopAll(announcing: false)
        if runsScriptServices {
            Task { [scriptService] in await scriptService.stopAsyncOutputDelivery() }
        }
        stopCurrentSessionAndPersistStatistics()
        if !applicationTerminationPrepared {
            recoveryCoordinator.discard()
        } else {
            recoveryCoordinator.flush()
        }
        onClose?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isSessionConnected,
           !bypassLastTabReplacement,
           !applicationTerminationPrepared,
           !confirmClosingConnectedTab() {
            return false
        }
        if !bypassLastTabReplacement,
           (sessionTabGroup?.controllers.count ?? 1) == 1,
           onRequestCloseLastTab?(self) == true {
            return false
        }
        sessionTabGroup?.prepareToClose(self)
        return true
    }

    private func confirmClosingConnectedTab() -> Bool {
        let world = currentServer?.name ?? baseWindowTitle
        let message = "Close connected tab?"
        let detail = "Closing this tab will disconnect from \(world)."
        if let handler = closeConnectedTabConfirmationHandlerForTesting {
            return handler(message, detail)
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func closeForTabReplacement() {
        bypassLastTabReplacement = true
        close()
    }

    func prepareForFactoryReset() {
        applicationTerminationPrepared = true
        bypassLastTabReplacement = true
        suppressPersistence = true
        suppressSessionData = true
        dockController?.prepareForOwnerClose()
        aiRequestTask?.cancel()
        aiRequestTask = nil
    }

    func tabStateDidChange() {
        onTabStateChange?()
    }

    var persistedOpenTab: MacConfigurationSidecar.OpenTab {
        .init(
            serverID: currentServer?.id,
            characterID: currentCharacter?.id,
            serverName: currentServer?.name,
            characterName: currentCharacter?.name
        )
    }

    func representsSavedProfile(_ server: ServerProfile, character: CharacterProfile?) -> Bool {
        currentServer?.id == server.id && currentCharacter?.id == character?.id
    }

    func savedProfileControllerInTabGroup(
        _ server: ServerProfile,
        character: CharacterProfile?
    ) -> ClientWindowController? {
        (sessionTabGroup?.controllers ?? [self]).first {
            $0.representsSavedProfile(server, character: character)
        }
    }

    var isUntitledDisconnectedTabForQuickConnect: Bool {
        currentServer == nil
            && currentCharacter == nil
            && currentPuppet == nil
            && !isSessionConnected
            && connectionStateText == "Disconnected"
    }

    var isDisconnectedSavedProfileForQuickConnect: Bool {
        currentServer != nil && !isSessionConnected
    }

    func activateForQuickConnect(sender: Any?) {
        if let group = sessionTabGroup {
            group.select(self, sender: sender)
        } else {
            showWindow(sender)
            window?.makeKeyAndOrderFront(sender)
            focusCommandInput()
        }
    }

    func connectSavedProfileIfDisconnected(policy: ConnectionPolicy) {
        guard isDisconnectedSavedProfileForQuickConnect, let currentServer else { return }
        startSavedProfileSession(currentServer, character: currentCharacter, policy: policy)
    }

    func restoreOpenTab(server: ServerProfile, character: CharacterProfile?) {
        currentServer = server
        currentCharacter = character
        currentPuppet = nil
        variables = profileLibrary.workspace.projection.variables(
            for: server,
            character: character,
            puppet: nil
        )
        let automation = profileLibrary.workspace.projection.automationGroups(
            for: server,
            character: character,
            puppet: nil
        )
        aliasGroups = automation.aliases
        triggerGroups = automation.triggers
        keyboardMacroGroups = profileLibrary.workspace.projection.macroGroups(
            for: server,
            character: character,
            puppet: nil
        )
        refreshBaseWindowTitle()
        applyTextWindowSettings()
        applyInputWindowSettings()
        dockController.setNotes(preferences.characterNotes[notesKey] ?? "")
        if let layout = restoredWorkspaceLayout {
            dockController.apply(layout: layout)
        }
        restoreSpawnSurfacePreferences()
        updateWindowTitle()
        refreshDiagnostics()
    }

    func windowDidResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            Self.publishTestFrame(for: window)
        }
        guard let session else { return }
        let size = output.terminalSize
        Task { await session.updateWindowSize(columns: size.columns, rows: size.rows) }
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === inputSplitView else { return proposedMinimumPosition }
        return max(minimumCoordinateForInputSplitDivider(at: dividerIndex), proposedMinimumPosition)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === inputSplitView else { return proposedMaximumPosition }
        return max(
            minimumCoordinateForInputSplitDivider(at: dividerIndex),
            min(proposedMaximumPosition, maximumCoordinateForInputSplitDivider(at: dividerIndex))
        )
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard window?.isVisible == true,
              notification.object as? NSSplitView === inputSplitView else { return }
        if !isRestoringInputSplitLayout,
           isInputHistoryPaneVisible,
           inputHistoryPane.frame.height >= Self.minimumInputHistoryHeight {
            inputHistoryHeight = inputHistoryPane.frame.height
        }
        guard tracksInputHeight,
              inputContainer.frame.height >= 30 else { return }
        let height = Double(inputContainer.frame.height)
        guard abs(preferences.inputHeight - height) >= 0.5 else { return }
        preferences.inputHeight = height
        savePreferences()
        onInputHeightChange?(height)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            Self.configureUnrestrictedSizing(for: window)
        }
        unreadCount = 0
        activityLabel.stringValue = ""
        updateWindowTitle()
        sessionTabGroup?.markSelected(self)
        rebuildSessionTabs()
        Self.updateDockBadge()
        Task { [weak self, scriptService] in
            guard let self else { return }
            applyScriptEvaluation(
                await scriptService.dispatchConnectionEvent("window:activate", arguments: ["true"], host: scriptHostSnapshot),
                showValue: false
            )
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        Task { [weak self, scriptService] in
            guard let self else { return }
            applyScriptEvaluation(
                await scriptService.dispatchConnectionEvent("window:activate", arguments: ["false"], host: scriptHostSnapshot),
                showValue: false
            )
        }
    }

    func showConnectDialog() {
        let alert = NSAlert()
        alert.messageText = "Connect to a MU*"
        alert.informativeText = "Choose a saved profile or enter a host and port."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Manage Profiles…")
        alert.addButton(withTitle: "Cancel")

        let choices = profileLibrary.workspace.servers.flatMap { server in
            [(server.profile, Optional<CharacterProfile>.none)]
                + server.characters.map { (server.profile, Optional($0)) }
        }
        let profile = NSPopUpButton()
        profile.addItem(withTitle: "Manual Address")
        profile.addItems(withTitles: choices.map { server, character in
            character.map { "\(server.name) — \($0.name)" } ?? server.name
        })
        profile.setAccessibilityIdentifier("connectionProfile")

        let host = NSTextField(string: currentServer?.host ?? "lambda.moo.mud.org")
        let port = NSTextField(string: currentServer.map { String($0.port) } ?? "8888")
        let tls = NSButton(checkboxWithTitle: "Use TLS", target: nil, action: nil)
        tls.state = currentServer?.usesTLS == true ? .on : .off
        let verify = NSButton(checkboxWithTitle: "Verify TLS certificate", target: nil, action: nil)
        verify.state = currentServer?.verifiesCertificate == true ? .on : .off
        let resizeNAWS = NSButton(checkboxWithTitle: "Send window size updates", target: nil, action: nil)
        resizeNAWS.state = currentServer?.sendNAWSOnResize == true ? .on : .off

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Profile:"), profile],
            [NSTextField(labelWithString: "Host:"), host],
            [NSTextField(labelWithString: "Port:"), port],
            [NSView(), tls],
            [NSView(), verify],
            [NSView(), resizeNAWS],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 260
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 350, height: 170)
        alert.accessoryView = grid

        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                NSApplication.shared.sendAction(#selector(ApplicationDelegate.manageProfiles(_:)), to: nil, from: nil)
                return
            }
            guard response == .alertFirstButtonReturn else { return }
            if profile.indexOfSelectedItem > 0 {
                let choice = choices[profile.indexOfSelectedItem - 1]
                self.startSession(
                    choice.0,
                    character: choice.1,
                    policy: self.profileLibrary.workspace.projection.connectionPolicy
                )
                return
            }
            guard let rawPort = UInt16(port.stringValue), !host.stringValue.isEmpty else { return }
            let profile = ServerProfile(
                name: host.stringValue,
                host: host.stringValue,
                port: rawPort,
                usesTLS: tls.state == .on,
                verifiesCertificate: verify.state == .on,
                sendNAWSOnResize: resizeNAWS.state == .on
            )
            self.startSession(profile)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: complete) }
        else { complete(alert.runModal()) }
    }

    private func configureTabBarButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        tintColor: NSColor,
        action: Selector
    ) {
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.focusRingType = .none
        button.contentTintColor = tintColor
        button.target = self
        button.action = action
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc private func showApplicationMenu(_ sender: NSButton) {
        popUp(tabBarApplicationMenu(), from: sender)
    }

    @objc private func showQuickConnectMenu(_ sender: NSButton) {
        popUp(quickConnectMenu(), from: sender)
    }

    @objc private func showProfiles(_ sender: NSButton) {
        NSApplication.shared.sendAction(
            #selector(ApplicationDelegate.manageProfiles(_:)),
            to: NSApplication.shared.delegate,
            from: sender
        )
    }

    private func popUp(_ menu: NSMenu, from button: NSButton) {
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: button.bounds.minY - 4),
            in: button
        )
    }

    private func tabBarApplicationMenu() -> NSMenu {
        ApplicationMenuBuilder.makeMenu(
            shortcuts: KeyboardShortcutStore.load(from: profileLibrary.keyEquivalents)
        )
    }

    private final class QuickConnectTarget: NSObject {
        let serverID: UUID
        let characterID: UUID?

        init(serverID: UUID, characterID: UUID?) {
            self.serverID = serverID
            self.characterID = characterID
        }
    }

    private func quickConnectMenu() -> NSMenu {
        let menu = NSMenu(title: "Player Quick Connect")
        menu.autoenablesItems = false
        let servers = profileLibrary.workspace.servers
        guard !servers.isEmpty else {
            let empty = NSMenuItem(title: "No Saved Worlds", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for server in servers {
            switch server.characters.count {
            case 0:
                menu.addItem(quickConnectItem(
                    title: server.profile.name,
                    serverID: server.profile.id,
                    characterID: nil
                ))
            case 1:
                let character = server.characters[0]
                menu.addItem(quickConnectItem(
                    title: "\(server.profile.name) — \(character.name)",
                    serverID: server.profile.id,
                    characterID: character.id
                ))
            default:
                let characters = NSMenu(title: server.profile.name)
                characters.autoenablesItems = false
                for character in server.characters {
                    characters.addItem(quickConnectItem(
                        title: character.name,
                        serverID: server.profile.id,
                        characterID: character.id
                    ))
                }
                let world = NSMenuItem(title: server.profile.name, action: nil, keyEquivalent: "")
                world.submenu = characters
                world.isEnabled = true
                menu.addItem(world)
            }
        }
        return menu
    }

    private func quickConnectItem(
        title: String,
        serverID: UUID,
        characterID: UUID?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(quickConnect(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = QuickConnectTarget(serverID: serverID, characterID: characterID)
        item.isEnabled = true
        return item
    }

    @objc private func quickConnect(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? QuickConnectTarget,
              let server = profileLibrary.workspace.servers.first(where: {
                  $0.profile.id == target.serverID
              }) else { return }
        let character = target.characterID.flatMap { characterID in
            server.characters.first { $0.id == characterID }
        }
        if let existing = savedProfileControllerInTabGroup(server.profile, character: character) {
            existing.activateForQuickConnect(sender: sender)
            existing.connectSavedProfileIfDisconnected(
                policy: profileLibrary.workspace.projection.connectionPolicy
            )
            return
        }
        if let onQuickConnectProfile {
            onQuickConnectProfile(self, server.profile, character)
            return
        }
        startSession(
            server.profile,
            character: character,
            policy: profileLibrary.workspace.projection.connectionPolicy
        )
    }

    var tabBarApplicationMenuForTesting: NSMenu { tabBarApplicationMenu() }
    var quickConnectMenuForTesting: NSMenu { quickConnectMenu() }
    var sessionTabContextMenuForTesting: NSMenu { sessionTabContextMenu() }
    var menuStripContextMenuForTesting: NSMenu { menuStripContextMenu() }
    var isSessionConnectedForTesting: Bool {
        get { isSessionConnected }
        set {
            isSessionConnected = newValue
            connectionStateText = newValue ? "Connected" : "Disconnected"
            isTerminallyDisconnected = !newValue
            refreshSessionTabsAcrossGroup()
        }
    }
    var closeConnectedTabConfirmationHandlerForTesting: (@MainActor (String, String) -> Bool)?
    var inputHeightPreferenceForTesting: Double { preferences.inputHeight }
    private(set) var inputLayoutRestorationGenerationForTesting: UInt64 = 0
    var isInputHistoryPaneVisibleForTesting: Bool { isInputHistoryPaneVisible }
    var inputSplitArrangedIdentifiersForTesting: [String] {
        inputSplitView.arrangedSubviews.compactMap { $0.accessibilityIdentifier() }
    }
    func addInputHistoryEntryForTesting(_ entry: String) {
        input.addToHistory(entry)
    }
    var tabBarControlIdentifiersForTesting: [String] {
        [applicationMenuButton, quickConnectButton, profilesButton].compactMap {
            $0.accessibilityIdentifier()
        }
    }
    var tabBarArrangedIdentifiersForTesting: [String] {
        taskbarView?.arrangedSubviews.compactMap { $0.accessibilityIdentifier() } ?? []
    }
    var sessionTabViewportForTesting: NSScrollView { sessionTabViewport }
    var sessionTabWidthsForTesting: [CGFloat] { sessionTabs.tabWidths }
    var sessionTabTooltipsForTesting: [String?] { sessionTabs.tabTooltips }
    var sessionTabIndicatorsForTesting: [String] { sessionTabs.tabIndicators }
    var sessionTabAccessibilityLabelsForTesting: [String?] { sessionTabs.tabAccessibilityLabels }
    var currentCharacterForTesting: CharacterProfile? { currentCharacter }
    var sessionTabContentWidthForTesting: CGFloat { sessionTabs.frame.width }
    var sessionBarFrameForTesting: NSRect { taskbarView?.frame ?? .zero }
    var workspaceHostFrameForTesting: NSRect { dockController?.hostView.frame ?? .zero }
    var menuStripPositionForTesting: MenuStripPosition {
        profileLibrary.workspace.projection.taskbarOnTop ? .top : .bottom
    }

    func disconnect() {
        if let puppet = currentPuppet, let master = puppetMaster {
            master.detachPuppetChild(puppet.id)
            puppetMaster = nil
            masterConnectionStateChanged(connected: false)
            return
        }
        guard let session else { return }
        Task { [weak self] in
            await session.disconnect()
            guard let self else { return }
            await self.persistActiveCharacterStatistics(from: session)
        }
    }

    func reconnect() {
        guard let server = currentServer else {
            appendError("No previous connection to reconnect.")
            return
        }
        let preserveOutput = session != nil
        startSession(
            server,
            character: currentCharacter,
            policy: profileLibrary.workspace.projection.connectionPolicy,
            preserveOutput: preserveOutput
        )
    }

    func sessionTabContextMenu() -> NSMenu {
        let menu = NSMenu(title: sessionTabTitle)
        menu.autoenablesItems = false

        let disconnectItem = NSMenuItem(
            title: "Disconnect",
            action: #selector(contextDisconnectTab(_:)),
            keyEquivalent: ""
        )
        disconnectItem.target = self
        disconnectItem.isEnabled = session != nil || currentPuppet != nil
        menu.addItem(disconnectItem)

        let reconnectItem = NSMenuItem(
            title: "Reconnect",
            action: #selector(contextReconnectTab(_:)),
            keyEquivalent: ""
        )
        reconnectItem.target = self
        reconnectItem.isEnabled = currentServer != nil && currentPuppet == nil
        menu.addItem(reconnectItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(
            title: "Close Tab",
            action: #selector(contextCloseTab(_:)),
            keyEquivalent: ""
        )
        closeItem.target = self
        closeItem.isEnabled = window != nil
        menu.addItem(closeItem)

        menu.addItem(.separator())
        appendMenuStripPositionItems(to: menu)

        return menu
    }

    func menuStripContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Menu Strip")
        menu.autoenablesItems = false
        appendMenuStripPositionItems(to: menu)
        return menu
    }

    private func appendMenuStripPositionItems(to menu: NSMenu) {
        for position in MenuStripPosition.allCases {
            let item = NSMenuItem(
                title: "Menu Strip at \(position.title)",
                action: #selector(changeMenuStripPosition(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = position
            let current = profileLibrary.workspace.projection.taskbarOnTop ? MenuStripPosition.top : .bottom
            item.state = current == position ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func changeMenuStripPosition(_ sender: NSMenuItem) {
        guard let position = sender.representedObject as? MenuStripPosition else { return }
        do {
            try profileLibrary.mutate { workspace in
                workspace.setTaskbarOnTop(position == .top)
            }
            onWorkspacePreferencesChange?()
        } catch {
            appendError("Unable to save menu strip position: \(error.localizedDescription)")
        }
    }

    @objc private func contextDisconnectTab(_ sender: Any?) {
        disconnect()
    }

    @objc private func contextReconnectTab(_ sender: Any?) {
        reconnect()
    }

    @objc private func contextCloseTab(_ sender: Any?) {
        window?.performClose(sender)
    }

    func clearOutput() { output.clear() }

    func toggleOutputPause() { output.togglePaused() }
    func toggleTimestamps() {
        updateActiveTextWindowSettings { $0.showsTime.toggle() }
    }
    func toggleFanFold() {
        updateActiveTextWindowSettings { $0.usesFanFoldBackgrounds.toggle() }
    }
    func copyOutputAsPlainText() { output.copySelectionAsPlainText() }
    func copyOutputAsHTML() { output.copySelectionAsHTML() }
    func toggleOutputMarker() { output.toggleMarkerForSelectedLine() }
    func toggleOutputSplit() {
        output.toggleSplit()
        preferences.outputSplit = output.isSplit
        savePreferences()
        onWorkspacePreferencesChange?()
    }
    func smartPaste(_ sender: Any?) { input.paste(sender) }
    func toggleStickyInput() {
        updateActiveInputWindowSettings { $0.keepsTextOnSubmit.toggle() }
    }
    func toggleSpellChecking() {
        preferences.checksSpelling.toggle()
        input.isContinuousSpellCheckingEnabled = preferences.checksSpelling
        savePreferences()
        onWorkspacePreferencesChange?()
    }

    func toggleMute() {
        isMuted.toggle()
        mediaController.isMuted = isMuted
        if isMuted {
            scriptSounds.forEach { $0.stop() }
            scriptSounds.removeAll()
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        updateWindowTitle()
        appendClient(isMuted ? "This tab is muted." : "This tab is unmuted.")
    }

    func setDockPlacement(_ placement: WorkspaceDockPlacement) {
        if atlasWindow?.isDocked == true { atlasWindow?.showFloating(self) }
        dockController.setPlacement(placement)
    }

    func setWorkspaceLayout(_ layout: WorkspaceLayoutNode) {
        if atlasWindow?.isDocked == true, !layout.panes.contains(.atlas) {
            atlasWindow?.showFloating(self)
        }
        dockController.setLayout(layout)
        if let atlasWindow, layout.panes.contains(.atlas), !atlasWindow.isDocked {
            presentAtlas(atlasWindow)
        }
    }

    func prepareForApplicationTermination() {
        applicationTerminationPrepared = true
        dockController?.prepareForOwnerClose()
        saveSpawnSurfacePreferences()
        saveAtlasSurfacePreferences()
        mediaController.flush()
        loggingCoordinator.stopAll(announcing: false)
        recoveryCoordinator.discard()
        recoveryCoordinator.flush()
    }

    func startPerformanceSoakIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BEIPMU_PERFORMANCE_SOAK"] == "1" else { return }
        let requestedLines = Int(environment["BEIPMU_PERFORMANCE_SOAK_LINES"] ?? "") ?? 100_000
        let requestedHold = Double(environment["BEIPMU_PERFORMANCE_SOAK_HOLD_SECONDS"] ?? "") ?? 15
        let requestedDelay = Double(environment["BEIPMU_PERFORMANCE_SOAK_START_DELAY_SECONDS"] ?? "") ?? 0
        let requestedLimit = Int(environment["BEIPMU_PERFORMANCE_SOAK_HISTORY_LIMIT"] ?? "") ?? 10_000
        let lineCount = max(10_000, requestedLines)
        let holdSeconds = max(1, requestedHold)
        let startDelaySeconds = max(0, requestedDelay)
        let historyLimit = max(1_000, requestedLimit)

        preferences.outputHistoryLimit = historyLimit
        preferences.workspaceLayout = .splitSidebars
        output.historyLimit = historyLimit
        if !output.isSplit { output.toggleSplit() }
        dockController.setLayout(.splitSidebars)

        Task { [weak self] in
            guard let self else { return }
            if startDelaySeconds > 0 {
                try? await Task.sleep(for: .seconds(startDelaySeconds))
            }
            let started = Date()
            var appended = 0
            let batchSize = 250
            while appended < lineCount, !Task.isCancelled {
                let end = min(lineCount, appended + batchSize)
                for index in appended..<end {
                    output.append(Self.performanceSoakLine(index))
                }
                appended = end
                if appended == lineCount / 2 { dockController.setLayout(.stackedRight) }
                await Task.yield()
            }

            let holdTicks = max(1, Int((holdSeconds * 4).rounded(.up)))
            for tick in 0..<holdTicks where !Task.isCancelled {
                if tick == holdTicks / 2 { dockController.setLayout(.stackedBottom) }
                output.append(Self.performanceSoakLine(lineCount + tick))
                appended += 1
                try? await Task.sleep(for: .milliseconds(250))
            }

            dockController.setLayout(.splitSidebars)
            refreshDiagnostics()
            window?.displayIfNeeded()
            let report = [
                "lines=\(appended)",
                "retained=\(output.visibleLineCount)",
                "rendered=\(output.renderedLineCount)",
                "paintCandidates=\(output.visiblePaintCandidateCount)",
                "rssBytes=\(Self.currentResidentSize())",
                "elapsedSeconds=\(String(format: "%.3f", Date().timeIntervalSince(started)))",
            ].joined(separator: " ")
            FileHandle.standardOutput.write(Data("BEIPMU_SOAK_COMPLETE \(report)\n".utf8))
            NSApplication.shared.terminate(nil)
        }
    }

    func startScaleTestIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BEIPMU_SCALE_TEST"] == "1" else { return }
        preferences.outputHistoryLimit = 10_000
        output.historyLimit = 10_000
        preferences.workspaceLayout = .splitSidebars
        dockController.setLayout(.splitSidebars)

        Task { [weak self] in
            guard let self else { return }
            let started = Date()
            for session in 0..<8 {
                output.append(.init(text: "[Scale:\(session)] connected (attempt 3/3)"))
                for line in 0..<250 {
                    let color = RGBColor(
                        red: UInt8(48 + session * 20),
                        green: UInt8(180 - session * 12),
                        blue: UInt8(96 + session * 16)
                    )
                    output.append(.init(
                        text: String(format: "[Scale:%d:%03d] styled payload ✓ %d", session, line, line * 7_919 % 100_003),
                        runs: [.init(range: 0..<11, style: .init(foreground: color, bold: true))]
                    ))
                    if line == 49 || line == 149 {
                        output.append(.init(text: "Client.Media.Play session=\(session) line=\(line)"))
                        output.append(.init(text: "WebView.Open session=\(session) line=\(line)"))
                    }
                    if line.isMultiple(of: 50) { await Task.yield() }
                }
                output.append(.init(text: "[Scale:\(session)] log closed; session cleaned"))
                dockController.setLayout(session.isMultiple(of: 2) ? .stackedRight : .splitSidebars)
            }
            dockController.setLayout(.splitSidebars)
            window?.displayIfNeeded()
            let result: [String: Any] = [
                "schemaVersion": 1,
                "result": "pass",
                "sessionCount": 8,
                "reconnectsPerSession": 2,
                "styledLines": 2_000,
                "mediaEvents": 16,
                "webViewEvents": 16,
                "activeSessionsAfterClose": 0,
                "openLogsAfterClose": 0,
                "retainedRendererRows": output.visibleLineCount,
                "renderedRows": output.renderedLineCount,
                "peakRSSBytes": Self.currentResidentSize(),
                "completionSeconds": Date().timeIntervalSince(started),
            ]
            if let path = environment["BEIPMU_SCALE_TEST_RESULT"],
               let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            output.append(.init(text: "BEIPMU_SCALE_TEST_COMPLETE activeSessions=0 openLogs=0"))
            refreshDiagnostics()
            if environment["BEIPMU_SCALE_TEST_AUTO_TERMINATE"] == "1" {
                try? await Task.sleep(for: .seconds(1))
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func showCharacterNotes() {
        if dockController.placement == .hidden {
            dockController.setPlacement(preferences.lastDockedPlacement)
        }
        dockController.selectNotes()
    }

    func toggleInputHistoryWindow() {
        isInputHistoryPaneVisible.toggle()
        inputHistoryPane.update(input.historyEntriesForDisplay)
        if isInputHistoryPaneVisible {
            inputSplitView.insertArrangedSubview(inputHistoryPane, at: 1)
            inputSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            inputSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
            inputSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 2)
        } else {
            inputSplitView.removeArrangedSubview(inputHistoryPane)
            inputHistoryPane.removeFromSuperview()
            inputSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            inputSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        }
        isRestoringInputSplitLayout = true
        inputSplitView.adjustSubviews()
        isRestoringInputSplitLayout = false
        restoreInputSplitLayout()
        focusCommandInput()
    }

    func toggleMapWindow() {
        if atlasWindow?.isDocked == true || atlasWindow?.window?.isVisible == true {
            closeAtlasSurface()
        } else {
            showAtlas()
        }
    }

    func toggleCharacterNotesWindow() {
        if dockController.placement != .hidden, dockController.containsPane(.notes) {
            dockController.setPlacement(.hidden)
        } else {
            showCharacterNotes()
        }
    }

    func copyAllWindowSettings() {
        let bundle = WindowSettingsClipboard(
            globalTextWindowSettings: preferences.globalTextWindowSettings,
            worldTextWindowSettings: preferences.worldTextWindowSettings,
            characterTextWindowSettings: preferences.characterTextWindowSettings,
            tabTextWindowSettings: preferences.tabTextWindowSettings,
            globalInputWindowSettings: preferences.globalInputWindowSettings,
            worldInputWindowSettings: preferences.worldInputWindowSettings,
            characterInputWindowSettings: preferences.characterInputWindowSettings,
            tabInputWindowSettings: preferences.tabInputWindowSettings
        )
        guard let data = try? JSONEncoder().encode(bundle),
              let value = String(data: data, encoding: .utf8) else {
            appendError("Unable to copy window settings.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        appendClient("Copied all window settings.")
    }

    func pasteAllWindowSettings() {
        guard let value = NSPasteboard.general.string(forType: .string),
              let data = value.data(using: .utf8),
              let bundle = try? JSONDecoder().decode(WindowSettingsClipboard.self, from: data) else {
            appendError("Clipboard does not contain BeipMU window settings.")
            return
        }
        preferences.globalTextWindowSettings = bundle.globalTextWindowSettings.normalized
        preferences.worldTextWindowSettings = bundle.worldTextWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        preferences.characterTextWindowSettings = bundle.characterTextWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        preferences.tabTextWindowSettings = bundle.tabTextWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        preferences.globalInputWindowSettings = bundle.globalInputWindowSettings.normalized
        preferences.worldInputWindowSettings = bundle.worldInputWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        preferences.characterInputWindowSettings = bundle.characterInputWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        preferences.tabInputWindowSettings = bundle.tabInputWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        synchronizeLegacyGlobalTextSettings()
        synchronizeLegacyGlobalInputSettings()
        applyTextWindowSettings()
        applyInputWindowSettings()
        savePreferences()
        onTextWindowSettingsChange?()
        onWorkspacePreferencesChange?()
        appendClient("Pasted all window settings.")
    }

    func showHiddenCaptions() {
        appendClient("Hidden captions are not currently tracked by this Mac-native workspace.")
    }

    func showSessionDiagnostics() {
        refreshDiagnostics()
        if dockController.placement == .hidden {
            dockController.setPlacement(preferences.lastDockedPlacement)
        }
        dockController.selectDiagnostics()
    }

    func showConnectionStatistics() {
        if let statisticsWindow {
            statisticsWindow.showWindow(nil)
            statisticsWindow.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = SessionStatisticsWindowController()
        applyTheme(to: controller)
        controller.onClose = { [weak self] in
            self?.statisticsTask?.cancel()
            self?.statisticsTask = nil
            self?.statisticsWindow = nil
        }
        statisticsWindow = controller
        controller.showWindow(nil)
        if let owner = window, let panel = controller.window {
            owner.addChildWindow(panel, ordered: .above)
            panel.center()
        }

        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshConnectionStatistics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func outputContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Output")
        func add(_ title: String, _ action: Selector, enabled: Bool = true, state: NSControl.StateValue = .off) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.state = state
            menu.addItem(item)
        }
        add("Find…", #selector(contextFind(_:)))
        add(
            output.isPaused ? "Resume" : "Pause",
            #selector(contextPause(_:)),
            state: output.isPaused ? .on : .off
        )
        add("Split", #selector(contextSplit(_:)), state: output.isSplit ? .on : .off)
        add("Copy screen to clipboard", #selector(contextCopyScreen(_:)), enabled: output.visibleLineCount > 0)
        menu.addItem(.separator())
        add("Clear", #selector(contextClear(_:)), enabled: output.visibleLineCount > 0)
        add("Delete Line", #selector(contextDeleteLine(_:)), enabled: output.hasSelectedLine)
        menu.addItem(.separator())
        let tabKey = textWindowIdentity.tabKey
        let usesGlobal = activeTextWindowUsesGlobalSettings
        add(
            "Inherit default settings",
            #selector(contextUseGlobalSettings(_:)),
            enabled: tabKey != nil,
            state: usesGlobal ? .on : .off
        )
        add("Settings…", #selector(contextTextWindowSettings(_:)))
        return menu
    }

    func outputContextMenuForTesting() -> NSMenu {
        outputContextMenu()
    }

    func inputContextMenuForTesting() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        return input.contextMenuForTesting(baseMenu: menu)
    }

    @objc private func contextFind(_ sender: Any?) { showFindDialog() }
    @objc private func contextPause(_ sender: Any?) { toggleOutputPause() }
    @objc private func contextSplit(_ sender: Any?) { toggleOutputSplit() }
    @objc private func contextCopyScreen(_ sender: Any?) { output.copyScreenToClipboard() }
    @objc private func contextClear(_ sender: Any?) { clearOutput() }
    @objc private func contextDeleteLine(_ sender: Any?) { output.removeSelectedLine() }
    @objc private func contextTextWindowSettings(_ sender: Any?) {
        onSettingsRequest?(self, .output, activeTextWindowSettingsScope)
    }

    @objc private func contextUseGlobalSettings(_ sender: Any?) {
        guard let key = textWindowIdentity.tabKey else { return }
        let newValue = !activeTextWindowUsesGlobalSettings
        var entry = preferences.tabTextWindowSettings[key]
            ?? .init(usesGlobalSettings: newValue, settings: activeTextWindowSettings)
        entry.usesGlobalSettings = newValue
        preferences.tabTextWindowSettings[key] = entry
        applyTextWindowSettings()
        savePreferences()
        onTextWindowSettingsChange?()
        onWorkspacePreferencesChange?()
    }

    private func showInputWindowSettings(initialScope: TextWindowSettingsEditorView.Scope) {
        onSettingsRequest?(self, .input, initialScope)
    }

    private func toggleInputUseGlobalSettings() {
        guard let key = textWindowIdentity.tabKey else { return }
        let newValue = !activeInputWindowUsesGlobalSettings
        var entry = preferences.tabInputWindowSettings[key]
            ?? .init(usesGlobalSettings: newValue, settings: activeInputWindowSettings)
        entry.usesGlobalSettings = newValue
        preferences.tabInputWindowSettings[key] = entry
        applyInputWindowSettings()
        savePreferences()
        onTextWindowSettingsChange?()
        onWorkspacePreferencesChange?()
    }

    func showWorkspaceSettings() {
        onSettingsRequest?(self, .appearance, nil)
    }

    func showEmbeddedHelp(topic: String? = nil) {
        let controller = helpWindow ?? EmbeddedHelpWindowController()
        helpWindow = controller
        applyTheme(to: controller)
        controller.show(topic: topic)
        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)
    }

    func showAutomationEditor(_ kind: AutomationEditorWindowController.Kind, scope: LegacyConfigurationWorkspace.AutomationScope? = nil) {
        let selectedScope = scope ?? currentAutomationScope
        let title = "\(kind.title) — \(selectedScope.displayName)"
        if let existing = automationEditors.first(where: { $0.window?.title == title }) {
            existing.showWindow(nil)
            return
        }
        let editor = AutomationEditorWindowController(library: profileLibrary, kind: kind, scope: selectedScope)
        applyTheme(to: editor)
        editor.onClose = { [weak self, weak editor] in
            guard let editor else { return }
            self?.automationEditors.removeAll { $0 === editor }
        }
        automationEditors.append(editor)
        editor.showWindow(nil)
    }

    private var currentAutomationScope: LegacyConfigurationWorkspace.AutomationScope {
        if let server = currentServer,
           let projectionServer = profileLibrary.workspace.servers.first(where: { $0.profile.id == server.id }) {
            if let character = currentCharacter,
               let projectedCharacter = projectionServer.characters.first(where: { $0.id == character.id }) {
                if let puppet = currentPuppet,
                   let projectedPuppet = projectedCharacter.puppets.first(where: { $0.id == puppet.id }) {
                    return .puppet(server: server.id, character: character.id, puppet: projectedPuppet.id)
                }
                return .character(server: server.id, character: character.id)
            }
            return .server(server.id)
        }
        return .global
    }

    func showAutomationDebugger(_ kind: CommandOutcome.DebugAutomationKind) {
        if let existing = automationDebugWindows[kind] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
        } else {
            let controller = AutomationDebugWindowController(kind: kind)
            applyTheme(to: controller)
            controller.onClose = { [weak self] in self?.automationDebugWindows.removeValue(forKey: kind) }
            automationDebugWindows[kind] = controller
            controller.showWindow(nil)
        }
        if kind == .timers {
            Task {
                let entries = await delayScheduler.entries()
                automationDebugWindows[.timers]?.showTimerEntries(entries)
            }
        }
    }

    func showNetworkDebugger() {
        if let networkDebugWindow {
            networkDebugWindow.showWindow(nil)
            networkDebugWindow.window?.makeKeyAndOrderFront(nil)
            networkDebugWindow.focusInitialControl()
            return
        }
        let controller = NetworkDebugWindowController(title: baseWindowTitle)
        applyTheme(to: controller)
        controller.onClose = { [weak self] in self?.networkDebugWindow = nil }
        networkDebugWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusInitialControl()
    }

    func showScriptDebugger() {
        if let scriptDebugWindow {
            scriptDebugWindow.showWindow(nil)
            scriptDebugWindow.window?.makeKeyAndOrderFront(nil)
            scriptDebugWindow.focusInitialControl()
            return
        }
        let controller = ScriptDebugWindowController(title: baseWindowTitle)
        applyTheme(to: controller)
        controller.onClose = { [weak self] in self?.scriptDebugWindow = nil }
        controller.onReset = { [weak self, scriptService] in
            Task {
                await scriptService.reset()
                await MainActor.run {
                    self?.recordScriptDebug(.init(kind: .runtime, message: "Runtime reset."))
                }
            }
        }
        scriptDebugWindow = controller
        controller.replace(with: scriptDebugEntries)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusInitialControl()
    }

    func showLoggingControls() {
        if let loggingWindow {
            loggingWindow.update(entries: activeLogEntries)
            loggingWindow.showWindow(nil)
            loggingWindow.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = LoggingWindowController(entries: activeLogEntries)
        applyTheme(to: controller)
        controller.onClose = { [weak self] in self?.loggingWindow = nil }
        controller.onStop = { [weak self] url in self?.stopLog(at: url) }
        controller.onStopAll = { [weak self] in self?.stopAllLogs() }
        controller.onStart = { [weak self] history in self?.beginManualLog(history: history) }
        loggingWindow = controller
        controller.showWindow(nil)
        if let owner = window, let panel = controller.window {
            owner.addChildWindow(panel, ordered: .above)
            panel.center()
        }
    }

    func applyThemeSettings(_ settings: WorkspaceThemeSettings) {
        preferences.theme = settings
        let palette = settings.palette
        window?.appearance = palette.appearance
        window?.backgroundColor = palette.chrome
        window?.contentView?.appearance = palette.appearance
        window?.contentView?.needsDisplay = true
        window?.contentView?.needsLayout = true
        taskbarView?.layer?.backgroundColor = palette.chrome.cgColor
        sessionTabs.applyTheme(palette)
        output.applyTheme(palette)
        input.applyTheme(palette)
        inputHistoryPane.applyTheme(palette)
        dockController?.applyTheme(palette)
        aiWindow?.applyTheme(palette)
        secondaryInputWindows.forEach { $0.applyTheme(palette) }
        editWindows.forEach { $0.applyTheme(palette) }
        mcpStatusWindow?.applyTheme(palette)
        webViewWindows.values.forEach { $0.applyTheme(palette) }
        triggerSpawnWindows.values.forEach { $0.applyTheme(palette) }
        triggerSpawnTabGroups.values.forEach { $0.applyTheme(palette) }
        let auxiliaryControllers: [NSWindowController] = scriptWindows.values.map { $0 as NSWindowController }
            + automationEditors.map { $0 as NSWindowController }
            + automationDebugWindows.values.map { $0 as NSWindowController }
            + [networkDebugWindow, scriptDebugWindow, loggingWindow, statisticsWindow, atlasWindow]
                .compactMap { $0 as NSWindowController? }
            + triggerStatisticsWindows.values.map { $0 as NSWindowController }
            + gmcpStatisticsWindows.values.map { $0 as NSWindowController }
            + tileMapWindows.values.map { $0 as NSWindowController }
        for controller in auxiliaryControllers {
            controller.window?.appearance = palette.appearance
            controller.window?.backgroundColor = palette.chrome
            controller.window?.contentView?.appearance = palette.appearance
            controller.window?.contentView?.needsDisplay = true
            controller.window?.contentView?.needsLayout = true
        }
        helpWindow?.window?.appearance = palette.appearance
        helpWindow?.window?.backgroundColor = palette.chrome
        helpWindow?.window?.contentView?.appearance = palette.appearance
        helpWindow?.window?.contentView?.needsDisplay = true
    }

    private func applyTheme(to controller: NSWindowController) {
        let palette = preferences.theme.palette
        controller.window?.appearance = palette.appearance
        controller.window?.backgroundColor = palette.chrome
        controller.window?.contentView?.appearance = palette.appearance
        controller.window?.contentView?.needsDisplay = true
        controller.window?.contentView?.needsLayout = true
    }

    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        applyThemeSettings(preferences.theme)
    }

    @objc nonisolated private func localCalendarDidChange(_ notification: Notification) {
        // NSCalendarDayChanged can be posted from a system background queue.
        // Cross the actor boundary explicitly instead of letting the generated
        // Objective-C thunk enforce MainActor isolation on the posting thread.
        Task { @MainActor [weak self] in
            guard let self else { return }
            rollOverLogsIfNeeded()
            scheduleDailyLogRollover()
        }
    }

    func showInputPrefixDialog() {
        let alert = NSAlert()
        alert.messageText = "Input Prefix"
        alert.informativeText = "This text is prepended to every submitted command. Leave it empty to disable the prefix."
        alert.addButton(withTitle: "Set Prefix")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: input.behavior.prefix)
        field.placeholderString = "For example: say "
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.preferences.inputPrefix = field.stringValue
            self?.input.behavior.prefix = field.stringValue
            self?.savePreferences()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    func showNewInputWindow(prefix: String = "", unique: Bool = false) {
        if unique, let existing = secondaryInputWindows.first(where: { $0.prefix == prefix }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SecondaryInputWindowController(
            prefix: prefix,
            checksSpelling: preferences.checksSpelling
        ) { [weak self] value in
            self?.submitInput(value)
        }
        controller.input.completionCandidates = CommandRegistry.knownCommands.map { "/" + $0 }.sorted()
        controller.input.onSmartPaste = { [weak self] lines in self?.handleSmartPaste(lines) ?? false }
        controller.input.onPageUp = { [weak self] in self?.output.performPageUp() ?? false }
        controller.input.onPageDown = { [weak self] in self?.output.performPageDown() ?? false }
        controller.input.onShowSettings = { [weak self] in
            guard let self else { return }
            self.showInputWindowSettings(initialScope: self.activeInputWindowSettingsScope)
        }
        controller.input.onToggleUseGlobalSettings = { [weak self] in self?.toggleInputUseGlobalSettings() }
        controller.input.usesGlobalSettings = activeInputWindowUsesGlobalSettings
        controller.input.canToggleUseGlobalSettings = textWindowIdentity.tabKey != nil
        controller.input.applySettings(activeInputWindowSettings)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.secondaryInputWindows.removeAll { $0 === controller }
        }
        secondaryInputWindows.append(controller)
        controller.applyTheme(preferences.theme.palette)
        controller.showWindow(nil)
        if let owner = window, let child = controller.window {
            owner.addChildWindow(child, ordered: .above)
        }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func showNewEditWindow(options: EditWindowOptions = .init()) {
        let capturedLines = options.captureLineCount > 0
            ? output.capturedText(lineCount: options.captureLineCount, skipping: options.captureSkipCount)
            : ""
        let captured = options.initialText ?? (capturedLines.isEmpty ? "" : options.prepend + capturedLines + options.append)
        if !options.title.isEmpty, let existing = editWindows.first(where: { $0.logicalTitle == options.title }) {
            if !captured.isEmpty { existing.setText(captured) }
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = EditWindowController(
            title: options.title,
            text: captured,
            checksSpelling: options.checksSpelling
        ) { [weak self] value in
            self?.sendToSession(value)
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.editWindows.removeAll { $0 === controller }
        }
        editWindows.append(controller)
        controller.applyTheme(preferences.theme.palette)
        controller.showWindow(nil)
        if let owner = window, let child = controller.window {
            owner.addChildWindow(child, ordered: .above)
        }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func showAtlas() {
        let controller = ensureAtlasWindow()
        presentAtlas(controller)
    }

    func applyInputConversion(_ conversion: InputConversion) {
        if let keyWindow = NSApplication.shared.keyWindow,
           let secondary = secondaryInputWindows.first(where: { $0.window === keyWindow }) {
            secondary.input.apply(conversion)
        } else if let keyWindow = NSApplication.shared.keyWindow,
                  let editor = editWindows.first(where: { $0.window === keyWindow })?.editor {
            editor.string = conversion.apply(to: editor.string)
        } else {
            input.apply(conversion)
        }
    }

    func showFindDialog() {
        let alert = NSAlert()
        alert.messageText = "Find in Output"
        alert.addButton(withTitle: "Find Next")
        alert.addButton(withTitle: "Cancel")
        let query = NSTextField(string: lastFindQuery)
        query.placeholderString = "Text or regular expression"
        let regex = NSButton(checkboxWithTitle: "Regular expression", target: nil, action: nil)
        let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
        let wholeWord = NSButton(checkboxWithTitle: "Whole words", target: nil, action: nil)
        let controls = NSStackView(views: [query, regex, matchCase, wholeWord])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 7
        query.widthAnchor.constraint(equalToConstant: 340).isActive = true
        controls.frame = NSRect(x: 0, y: 0, width: 340, height: 100)
        alert.accessoryView = controls
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.lastFindQuery = query.stringValue
            do {
                _ = try self.output.find(query.stringValue, options: .init(
                    isRegularExpression: regex.state == .on,
                    isCaseSensitive: matchCase.state == .on,
                    wholeWord: wholeWord.state == .on
                ))
            } catch {
                self.appendError("Invalid regular expression: \(error.localizedDescription)")
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    private func configureUI(in window: NSWindow) {
        let root = NSStackView()
        root.orientation = .vertical
        root.distribution = .fill
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        let taskbar = MenuStripView()
        taskbar.owner = self
        taskbarView = taskbar
        taskbar.setAccessibilityIdentifier("sessionBar")
        taskbar.orientation = .horizontal
        taskbar.alignment = .centerY
        taskbar.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        taskbar.spacing = 8
        taskbar.wantsLayer = true
        taskbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        configureTabBarButton(
            applicationMenuButton,
            symbolName: "line.3.horizontal",
            accessibilityLabel: "Application menu",
            accessibilityIdentifier: "tabBarApplicationMenu",
            tintColor: .labelColor,
            action: #selector(showApplicationMenu(_:))
        )
        configureTabBarButton(
            quickConnectButton,
            symbolName: "person.fill",
            accessibilityLabel: "Player Quick Connect",
            accessibilityIdentifier: "tabBarQuickConnect",
            tintColor: .systemPurple,
            action: #selector(showQuickConnectMenu(_:))
        )
        configureTabBarButton(
            profilesButton,
            symbolName: "globe",
            accessibilityLabel: "Worlds & Characters",
            accessibilityIdentifier: "tabBarWorldsAndCharacters",
            tintColor: .systemBlue,
            action: #selector(showProfiles(_:))
        )
        taskbar.addArrangedSubview(applicationMenuButton)
        taskbar.addArrangedSubview(quickConnectButton)
        taskbar.addArrangedSubview(profilesButton)
        stateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stateLabel.setAccessibilityIdentifier("connectionState")
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        activityLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sessionTabs.orientation = .horizontal
        sessionTabs.alignment = .centerY
        sessionTabs.distribution = .fill
        sessionTabs.spacing = 4
        sessionTabs.owner = self
        sessionTabViewport.attach(sessionTabs)
        sessionTabViewport.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sessionTabViewport.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sessionTabViewport.setAccessibilityIdentifier("sessionTabs")
        sessionTabs.setAccessibilityIdentifier("sessionTabStrip")
        taskbar.addArrangedSubview(sessionTabViewport)
        taskbar.addArrangedSubview(stateLabel)
        taskbar.addArrangedSubview(activityLabel)
        taskbar.addArrangedSubview(NSView())
        taskbar.addArrangedSubview(titlebarStatistics.view)

        input.completionCandidates = CommandRegistry.knownCommands.map { "/" + $0 }.sorted()
        input.onSubmit = { [weak self] text in self?.submitInput(text) }
        input.onSmartPaste = { [weak self] lines in self?.handleSmartPaste(lines) ?? false }
        input.onMacro = { [weak self] event in self?.handleKeyboardMacro(event) ?? false }
        input.onPageUp = { [weak self] in self?.output.performPageUp() ?? false }
        input.onPageDown = { [weak self] in self?.output.performPageDown() ?? false }
        input.onShowSettings = { [weak self] in
            guard let self else { return }
            self.showInputWindowSettings(initialScope: self.activeInputWindowSettingsScope)
        }
        input.onToggleUseGlobalSettings = { [weak self] in self?.toggleInputUseGlobalSettings() }
        input.onPreferredHeightChange = { [weak self] height in self?.resizeInput(to: height) }
        input.onTextChange = { [weak self] _ in self?.refreshTitlebarStatistics() }
        input.onHistoryChange = { [weak self] entries in
            guard let self else { return }
            self.inputHistoryPane.update(entries)
            self.recordRecovery(.inputHistory(entries))
        }
        output.onAction = { [weak self] action in self?.perform(action) }
        output.onContextMenu = { [weak self] _ in self?.outputContextMenu() }
        output.onInteractionCompleted = { [weak self] in self?.focusCommandInput() }
        output.onPauseChange = { [weak self] paused, pending in
            guard let self else { return }
            self.activityLabel.stringValue = paused ? "Paused\(pending > 0 ? " — \(pending) new" : "")" : ""
        }
        applyPreferences()

        inputContainer.addSubview(input.containerScrollView)
        NSLayoutConstraint.activate([
            input.containerScrollView.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 8),
            input.containerScrollView.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -8),
            input.containerScrollView.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 7),
            input.containerScrollView.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor, constant: -7),
            inputContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])

        inputSplitView.isVertical = false
        inputSplitView.dividerStyle = .thin
        inputSplitView.delegate = self
        inputSplitView.setAccessibilityIdentifier("commandInputSplit")
        inputSplitView.addArrangedSubview(output.containerView)
        inputSplitView.addArrangedSubview(inputContainer)
        inputSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        inputSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        inputSplitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        inputSplitView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let dockController = WorkspaceDockController(mainView: inputSplitView, ownerWindow: window)
        self.dockController = dockController
        dockController.hostView.setAccessibilityIdentifier("workspaceDockHost")
        rootStackView = root
        workspaceHostView = dockController.hostView
        root.addArrangedSubview(taskbar)
        root.addArrangedSubview(dockController.hostView)
        dockController.onPlacementChange = { [weak self] placement, thickness in
            guard let self else { return }
            self.preferences.dockPlacement = placement
            if [.left, .right, .top, .bottom].contains(placement) {
                self.preferences.lastDockedPlacement = placement
            }
            self.preferences.dockThickness = thickness
            self.savePreferences()
        }
        dockController.onLayoutChange = { [weak self] layout in
            guard let self else { return }
            self.preferences.workspaceLayout = layout
            self.preferences.workspaceLayouts[self.notesKey] = layout
            self.savePreferences()
        }
        dockController.onNotesChange = { [weak self] notes in
            guard let self else { return }
            self.preferences.characterNotes[self.notesKey] = notes
            self.savePreferences()
        }
        dockController.setNotes(preferences.characterNotes[notesKey] ?? "")
        dockController.applyTheme(preferences.theme.palette)
        // Keep the Auto Layout-driven root behind an autoresizing wrapper.
        // The session bar is outside the dock host so it spans the complete
        // window even when the workspace is split into docked panes.
        let contentBounds = window.contentView?.bounds
            ?? NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        let windowContent = NSView(frame: contentBounds)
        windowContent.autoresizingMask = [.width, .height]
        root.frame = windowContent.bounds
        root.autoresizingMask = [.width, .height]
        windowContent.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            root.topAnchor.constraint(equalTo: windowContent.topAnchor),
            root.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),
        ])
        applyMenuStripPosition()
        let verticalResizeHandle = VerticalWindowResizeHandle(
            frame: NSRect(x: 0, y: 0, width: windowContent.bounds.width, height: 8)
        )
        verticalResizeHandle.autoresizingMask = [.width, .maxYMargin]
        windowContent.addSubview(verticalResizeHandle)
        window.contentView = windowContent
        let preferredOutputHeight = output.containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        // This is a layout preference, not a window-size requirement. Keeping it
        // required makes the vertical stack (and docked row layouts in particular)
        // push its fitting height back onto the window during a live resize.
        preferredOutputHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            taskbar.heightAnchor.constraint(equalToConstant: 34),
            preferredOutputHeight,
        ])
        if preferences.dockPlacement == .floating {
            dockController.apply(placement: .floating, thickness: preferences.dockThickness)
        } else if let layout = restoredWorkspaceLayout {
            dockController.apply(layout: layout)
        } else {
            dockController.apply(placement: preferences.dockPlacement, thickness: preferences.dockThickness)
        }
        applyInputWindowSettings()
        refreshDiagnostics()
        window.makeFirstResponder(input)
    }

    func startPuppetSession(
        master: ClientWindowController,
        server: ServerProfile,
        character: CharacterProfile,
        puppet: PuppetProfile
    ) {
        startSession(
            server,
            character: character,
            puppet: puppet,
            master: master,
            policy: profileLibrary.workspace.projection.connectionPolicy
        )
    }

    func startSavedProfileSession(
        _ server: ServerProfile,
        character: CharacterProfile?,
        policy: ConnectionPolicy
    ) {
        startSession(server, character: character, policy: policy)
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }

    private static func configureUnrestrictedSizing(for window: NSWindow) {
        let unrestrictedSize = NSSize(width: 100_000, height: 100_000)
        window.minSize = .zero
        window.maxSize = unrestrictedSize
        window.contentMinSize = .zero
        window.contentMaxSize = unrestrictedSize
        window.contentAspectRatio = .zero
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.minFullScreenContentSize = .zero
        window.maxFullScreenContentSize = unrestrictedSize
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    private static func postFrameChange(for window: NSWindow) {
        NSAccessibility.post(element: window, notification: .windowMoved)
        NSAccessibility.post(element: window, notification: .windowResized)
    }

    private static func publishTestFrame(for window: NSWindow) {
        guard ProcessInfo.processInfo.environment["BEIPMU_UI_TESTING"] == "1" else { return }
        window.setAccessibilityValue("\(Int(window.frame.width))x\(Int(window.frame.height))")
        NSAccessibility.post(element: window, notification: .valueChanged)
    }

    private func startSession(
        _ server: ServerProfile,
        character: CharacterProfile? = nil,
        puppet: PuppetProfile? = nil,
        master: ClientWindowController? = nil,
        policy: ConnectionPolicy = .init(),
        preserveOutput: Bool = false
    ) {
        let recoveryEnabled = master == nil
            && profileLibrary.workspace.projection.logging.restoreLogs
            && (character?.restoreLog ?? true)
        let canResumeRecoveredSession = recoveryCoordinator.consumeResumeFlag()
            && recoveryEnabled
            && currentServer?.id == server.id
            && currentCharacter?.id == character?.id
            && recoveryCoordinator.sessionID != nil
        preferences.workspaceLayouts[notesKey] = dockController.currentLayout
        savePreferences()
        saveSpawnSurfacePreferences()
        if !canResumeRecoveredSession {
            closeSpawnSurfaces()
        }
        saveAtlasSurfacePreferences()
        closeAtlasSurface(preservingDockPlacement: true)
        closeWebViews()
        closeAIWindow(preservingDockPlacement: true)
        stopCurrentSessionAndPersistStatistics()
        if !canResumeRecoveredSession { recoveryCoordinator.discard() }
        isSessionConnected = false
        currentServer = server
        currentCharacter = character
        currentPuppet = puppet
        puppetMaster = master
        if recoveryEnabled {
            recoveryCoordinator.beginOrResume(
                shouldResume: canResumeRecoveredSession,
                serverID: server.id,
                characterID: character?.id,
                serverName: server.name,
                characterName: character?.name,
                existingSessionID: recoveryCoordinator.sessionID
            )
        }
        applyTextWindowSettings()
        applyInputWindowSettings()
        variables = profileLibrary.workspace.projection.variables(for: server, character: character, puppet: puppet)
        let automation = profileLibrary.workspace.projection.automationGroups(for: server, character: character, puppet: puppet)
        aliasGroups = automation.aliases
        triggerGroups = automation.triggers
        keyboardMacroGroups = profileLibrary.workspace.projection.macroGroups(for: server, character: character, puppet: puppet)
        gmcpState.reset()
        mediaState.reset()
        mediaController.flush()
        refreshBaseWindowTitle()
        tabStateDidChange()
        updateWindowTitle()
        dockController.setNotes(preferences.characterNotes[notesKey] ?? "")
        if let layout = restoredWorkspaceLayout {
            dockController.apply(layout: layout)
        }
        restoreSpawnSurfacePreferences()
        restoreAtlasSurfacePreferences()
        restoreWebViewPreferences()
        refreshDiagnostics()
        if let master, let puppet {
            session = nil
            activeCharacterProfile = nil
            output.clear()
            master.attachPuppetChild(self, puppet: puppet)
            masterConnectionStateChanged(connected: master.connectionStateText == "Connected")
            appendClient("Puppet \(puppet.name) is attached to \(character?.name ?? "the character")'s connection.")
            return
        }
        var processor = MUDProtocolPipeline(
            encoding: server.encoding,
            mcp: server.mcp,
            pueblo: server.pueblo,
            limitTelnetCharset: server.limitTelnetCharset
        )
        processor.setTerminalType(terminalType)
        let next = SessionActor(transport: NetworkTransport(), processor: processor, localEcho: localEcho)
        session = next
        activeCharacterProfile = master == nil
            ? character.map { .init(serverID: server.id, characterID: $0.id) }
            : nil
        persistedSessionStatistics = ConnectionStatistics()
        let inputSettings = activeInputWindowSettings
        Task {
            await next.configureLocalEcho(
                inputSettings.localEcho,
                color: Self.rgbColor(hex: inputSettings.localEchoHex)
            )
        }
        if !canResumeRecoveredSession && !preserveOutput {
            output.clear()
        }
        sessionTask = Task { [weak self] in
            let events = await next.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event, from: next)
            }
        }
        let size = output.terminalSize
        Task {
            await next.updateWindowSize(columns: size.columns, rows: size.rows)
            await next.connect(.init(server: server, character: character, puppet: puppet, policy: policy))
        }
    }

    private func stopCurrentSessionAndPersistStatistics() {
        // A new session can replace the current one without the old session
        // delivering a terminal state event. Do not let its writers continue
        // receiving output from the replacement session.
        stopAllLogsIfActive(announcing: false)
        let previousSession = session
        let previousProfile = activeCharacterProfile
        let previousBaseline = persistedSessionStatistics
        sessionTask?.cancel()
        sessionTask = nil
        session = nil
        activeCharacterProfile = nil
        persistedSessionStatistics = ConnectionStatistics()
        guard let previousSession else { return }

        Task { [weak self] in
            await previousSession.disconnect()
            let statistics = await previousSession.statistics()
            guard let self, let previousProfile else { return }
            self.persistCharacterStatistics(
                statistics,
                for: previousProfile,
                since: previousBaseline
            )
        }
    }

    // SessionActor owns runtime counters, while CharacterProfile stores the
    // lifetime totals shown by the configuration editor. Persist deltas so a
    // reconnect or a second tab cannot count the same session twice.
    private func persistActiveCharacterStatistics(
        from source: SessionActor,
        markLastUsed: Bool = false
    ) async {
        guard session === source, let activeCharacterProfile else { return }
        let statistics = await source.statistics()
        persistCharacterStatistics(
            statistics,
            for: activeCharacterProfile,
            since: persistedSessionStatistics,
            lastUsed: markLastUsed ? Date() : nil
        )
        persistedSessionStatistics = statistics
    }

    private func persistCharacterStatistics(
        _ statistics: ConnectionStatistics,
        for profile: ActiveCharacterProfile,
        since baseline: ConnectionStatistics,
        lastUsed: Date? = nil
    ) {
        guard !suppressPersistence else { return }
        let delta = ConnectionStatistics(
            bytesSent: statistics.bytesSent >= baseline.bytesSent
                ? statistics.bytesSent - baseline.bytesSent : 0,
            bytesReceived: statistics.bytesReceived >= baseline.bytesReceived
                ? statistics.bytesReceived - baseline.bytesReceived : 0,
            secondsConnected: max(0, statistics.secondsConnected - baseline.secondsConnected),
            connectionCount: statistics.connectionCount >= baseline.connectionCount
                ? statistics.connectionCount - baseline.connectionCount : 0
        )
        guard let current = profileLibrary.workspace.servers
            .first(where: { $0.profile.id == profile.serverID })?.characters
            .first(where: { $0.id == profile.characterID }) else { return }
        let created = lastUsed != nil && current.created.isEmpty
            ? CharacterProfile.timestamp()
            : nil
        guard delta.bytesSent > 0 || delta.bytesReceived > 0
                || delta.secondsConnected > 0 || delta.connectionCount > 0
                || lastUsed != nil || created != nil else { return }

        do {
            try profileLibrary.mutate { workspace in
                try workspace.updateCharacter(id: profile.characterID, inServerID: profile.serverID) { character in
                    character.bytesSent += delta.bytesSent
                    character.bytesReceived += delta.bytesReceived
                    character.secondsConnected += UInt64(delta.secondsConnected)
                    character.connectionCount += delta.connectionCount
                    if let lastUsed { character.lastUsed = CharacterProfile.timestamp(for: lastUsed) }
                    if let created { character.created = created }
                }
            }
        } catch {
            appendError("Could not save character statistics: \(error.localizedDescription)")
        }
    }

    private func runStartupScriptIfNeeded() {
        guard !Self.didRunStartupScript else { return }
        let configuredPath = profileLibrary.workspace.projection.scripting.startupPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredPath.isEmpty else { return }
        Self.didRunStartupScript = true

        let url: URL
        if configuredPath.hasPrefix("/") || configuredPath.hasPrefix("~") {
            url = URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath)
        } else if let configuration = profileLibrary.workspace.sourceURL {
            url = configuration.deletingLastPathComponent().appendingPathComponent(configuredPath)
        } else {
            appendError("Cannot load startup script without a saved Config.txt location.")
            return
        }

        Task { [weak self, scriptService] in
            do {
                let source = try String(contentsOf: url, encoding: .utf8)
                let result = await scriptService.evaluate(source, host: self?.scriptHostSnapshot ?? .init())
                self?.applyScriptEvaluation(result, showValue: false)
            } catch {
                self?.appendError("Cannot load startup script: \(error.localizedDescription)")
            }
        }
    }

    private func handleConnectionState(_ state: ConnectionState, from source: SessionActor?) async {
        switch state {
        case .disconnected:
            stopLogsForConnectionLoss()
            isSessionConnected = false
            isTerminallyDisconnected = true
            connectionStateText = "Disconnected"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .secondaryLabelColor
            appendConnectionNotice(.disconnected)
        case .resolving:
            isSessionConnected = false
            isTerminallyDisconnected = false
            connectionStateText = "Resolving…"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .systemOrange
        case .connecting:
            isSessionConnected = false
            isTerminallyDisconnected = false
            connectionStateText = "Connecting…"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .systemOrange
        case .connected:
            isSessionConnected = true
            isTerminallyDisconnected = false
            lastTypedAt = Date()
            connectionStateText = "Connected"
            stateLabel.stringValue = connectionStateText
            stateLabel.textColor = .systemGreen
            startAutomaticLog()
            if let source { await persistActiveCharacterStatistics(from: source, markLastUsed: true) }
        case .disconnecting:
            stopLogsForConnectionLoss()
            isSessionConnected = false
            isTerminallyDisconnected = false
            connectionStateText = "Disconnecting…"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .systemOrange
        case let .failed(message):
            stopLogsForConnectionLoss()
            isSessionConnected = false
            isTerminallyDisconnected = true
            connectionStateText = "Failed"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .systemRed
            appendConnectionError(message)
            if let source { await persistActiveCharacterStatistics(from: source) }
        }
        refreshSessionTabsAcrossGroup()
        refreshTitlebarStatistics()
        refreshDiagnostics()
        if case .connected = state { webViewWindows.values.forEach { $0.connectionChanged(connected: true) } }
        if case .disconnected = state { webViewWindows.values.forEach { $0.connectionChanged(connected: false) } }
        if case .failed = state { webViewWindows.values.forEach { $0.connectionChanged(connected: false) } }
        if case .connected = state {
            applyScriptEvaluation(await scriptService.dispatchConnectionEvent("connect", host: scriptHostSnapshot), showValue: false)
            if let server = currentServer, let character = currentCharacter {
                for puppet in character.puppets where puppet.connectWithPlayer {
                    _ = (NSApp.delegate as? ApplicationDelegate)?.openPuppet(
                        master: self, server: server, character: character, puppet: puppet
                    )
                }
            }
        }
        if case .disconnected = state {
            if let source { await persistActiveCharacterStatistics(from: source) }
            applyScriptEvaluation(await scriptService.dispatchConnectionEvent("disconnect", host: scriptHostSnapshot), showValue: false)
        }
        if case .failed = state {
            applyScriptEvaluation(await scriptService.dispatchConnectionEvent("disconnect", host: scriptHostSnapshot), showValue: false)
        }
        puppetChildren.values.forEach { $0.masterConnectionStateChanged(state) }
        if case .disconnecting = state {
            // Puppet windows mirror the master's terminal state only after
            // the transport finishes disconnecting. Their writers still
            // belong to this world session and must stop immediately.
            puppetChildren.values.forEach { $0.stopLogsForConnectionLoss() }
        }
    }

    func applyConnectionStateForTesting(_ state: ConnectionState) async {
        await handleConnectionState(state, from: nil)
    }

    private func handle(_ event: SessionEvent, from source: SessionActor) async {
        guard session === source else { return }
        switch event {
        case let .state(state):
            await handleConnectionState(state, from: source)
        case let .renderedLine(line):
            guard !suppressSessionData else { return }
            if routeMasterLineToPuppet(line, isPrompt: false) { return }
            await presentIncoming(line, isPrompt: false)
        case let .prompt(line):
            guard !suppressSessionData else { return }
            if routeMasterLineToPuppet(line, isPrompt: true) { return }
            await presentIncoming(line, isPrompt: true)
        case let .gmcp(message):
            recordRecovery(.gmcp(message))
            guard !suppressSessionData else { return }
            webViewWindows.values.forEach { $0.observeGMCP(message) }
            let raw = message.payload.isEmpty ? message.package : "\(message.package) \(message.payload)"
            applyScriptEvaluation(
                await scriptService.dispatchConnectionEvent("gmcp", arguments: [raw], host: scriptHostSnapshot),
                showValue: false
            )
            handleAdvancedGMCP(message)
        case let .mcp(message):
            guard !suppressSessionData else { return }
            handleMCP(message)
        case let .encoding(encoding):
            guard !suppressSessionData else { return }
            appendClient("Charset negotiated: \(encoding.rawValue)")
        case let .error(message): appendError(message)
        case let .log(message): appendClient(message)
        case let .connectionNotice(notice): appendConnectionNotice(notice)
        case let .activity(important):
            guard !suppressSessionData else { return }
            if suppressNextSessionActivity { suppressNextSessionActivity = false; break }
            guard window?.isKeyWindow != true else { break }
            unreadCount += 1
            activityLabel.stringValue = important ? "Important — \(unreadCount) unread" : "\(unreadCount) unread"
            updateWindowTitle()
            if important { NSApplication.shared.requestUserAttention(.informationalRequest) }
            Self.updateDockBadge()
        case let .received(data):
            networkDebugWindow?.append(data, received: true)
            let result = await scriptService.dispatchConnectionEvent(
                "receive",
                arguments: [String(decoding: data, as: UTF8.self)],
                host: scriptHostSnapshot
            )
            applyScriptEvaluation(result, showValue: false)
            // SessionActor emits .received before the parsed line/GMCP
            // events for the same network chunk. Preserve Windows'
            // stoppable OnReceive hook by dropping those following events
            // when the callback returns true.
            suppressSessionData = Self.scriptWasHandled(result)
        case let .sent(data):
            networkDebugWindow?.append(data, received: false)
        }
    }

    func puppetController(for id: UUID) -> ClientWindowController? { puppetChildren[id] }
    var ownsNetworkSession: Bool { session != nil }
    var isPuppetAttachment: Bool { currentPuppet != nil && puppetMaster != nil && session == nil }

    func testingAutomationSnapshot() -> (
        variables: [String: String],
        aliasGroupCount: Int,
        triggerGroupCount: Int,
        activeTriggerGroupCount: Int,
        triggerCount: Int,
        macroGroupCount: Int
    ) {
        (
            variables,
            aliasGroups.count,
            triggerGroups.count,
            triggerGroups.filter(\.active).count,
            triggerGroups.reduce(0) { $0 + $1.triggers.count },
            keyboardMacroGroups.count
        )
    }

    func testingReceiveLine(_ text: String) async {
        await presentIncoming(.init(text: text), isPrompt: false)
    }

    func testingProcessInput(_ text: String) {
        processInput(text)
    }

    func restoreRecoverySession(_ snapshot: SessionRecoverySession) {
        recoveryCoordinator.prepareForReplay(snapshot.id)
        output.clear()
        closeSpawnSurfaces()
        gmcpState.reset()
        recoveryCoordinator.withPassiveReplay {
            mediaState.reset()
            input.restoreHistory(
                snapshot.records.reversed().compactMap { record in
                    if case let .inputHistory(values) = record.event { return values }
                    return nil
                }.first ?? []
            )
            for record in snapshot.records {
                switch record.event {
                case let .renderedLine(line):
                    output.append(Self.replayed(line, timestamp: record.timestamp))
                case let .prompt(line):
                    output.append(Self.replayed(line, timestamp: record.timestamp), terminator: "")
                case let .spawnOutput(title, tabGroup, line):
                    restoreSpawnOutput(
                        title: title,
                        tabGroup: tabGroup,
                        line: Self.replayed(line, timestamp: record.timestamp)
                    )
                case .sentInput, .inputHistory:
                    break
                case let .gmcp(message):
                    handleAdvancedGMCP(message)
                }
            }
        }
        appendInformationalNotice("Session restored from a crash. Please reconnect.")
        refreshDiagnostics()
        updateWindowTitle()
    }

    func testingSpawnLines(named title: String) -> [String] {
        triggerSpawnWindows[title]?.retainedLines.map(\.text) ?? []
    }

    func testingOutputLines() -> [String] { output.retainedLines.map(\.text) }
    func testingInputHistory() -> [String] { input.historyEntriesForDisplay }
    func testingGMCPRoom() -> GMCPRoomInfo? { gmcpState.currentRoom }

    func testingSpawnSurfaceState() -> (
        standalone: [String: Bool],
        tabGroups: [String: Bool]
    ) {
        (
            triggerSpawnWindows.mapValues(\.isDocked),
            triggerSpawnTabGroups.mapValues(\.isDocked)
        )
    }

    private func attachPuppetChild(_ controller: ClientWindowController, puppet: PuppetProfile) {
        if let previous = puppetChildren.updateValue(controller, forKey: puppet.id), previous !== controller {
            previous.masterConnectionClosed()
        }
    }

    private func detachPuppetChild(_ id: UUID) {
        puppetChildren.removeValue(forKey: id)
    }

    private func masterConnectionClosed() {
        puppetMaster = nil
        masterConnectionStateChanged(connected: false)
    }

    private func masterConnectionStateChanged(connected: Bool) {
        if !connected { stopLogsForConnectionLoss() }
        let changed = (connectionStateText == "Connected") != connected
        isSessionConnected = connected
        isTerminallyDisconnected = !connected
        if connected, changed { lastTypedAt = Date() }
        connectionStateText = connected ? "Connected" : "Disconnected"
        stateLabel.stringValue = connectionStateText
        stateLabel.textColor = connected ? .systemGreen : .secondaryLabelColor
        refreshTitlebarStatistics()
        webViewWindows.values.forEach { $0.connectionChanged(connected: connected) }
        refreshDiagnostics()
        refreshSessionTabsAcrossGroup()
        guard changed else { return }
        if connected { startAutomaticLog() }
        Task { [weak self, scriptService] in
            guard let self else { return }
            applyScriptEvaluation(
                await scriptService.dispatchConnectionEvent(
                    connected ? "connect" : "disconnect",
                    host: scriptHostSnapshot
                ),
                showValue: false
            )
        }
    }

    private func masterConnectionStateChanged(_ state: ConnectionState) {
        switch state {
        case .connected:
            masterConnectionStateChanged(connected: true)
        case .disconnected, .failed:
            masterConnectionStateChanged(connected: false)
        case .resolving, .connecting:
            isTerminallyDisconnected = false
            refreshSessionTabsAcrossGroup()
        case .disconnecting:
            isTerminallyDisconnected = false
            stopLogsForConnectionLoss()
            refreshSessionTabsAcrossGroup()
        }
    }

    /// Stops connection-scoped logs once, while retaining the normal stop
    /// notice for the first loss event. Subsequent disconnect/failure events
    /// see no active writers and therefore do nothing.
    private func stopLogsForConnectionLoss() {
        stopAllLogsIfActive(announcing: true)
    }

    private func routeMasterLineToPuppet(_ line: RenderedLine, isPrompt: Bool) -> Bool {
        guard currentPuppet == nil, let server = currentServer, let character = currentCharacter else {
            return false
        }
        for puppet in character.puppets {
            guard let routed = PuppetRouter.route(line.text, through: [puppet]) else { continue }
            var child = puppetChildren[puppet.id]
            if child == nil, puppet.autoConnect {
                child = (NSApp.delegate as? ApplicationDelegate)?.openPuppet(
                    master: self, server: server, character: character, puppet: puppet
                )
            }
            guard let child else { continue }
            if puppet.characterLog {
                var logged = line
                logged.text = puppet.characterLogPrefix + line.text
                logged.runs = []
                appendToLogs(logged)
            }
            child.receivePuppetLine(line, route: routed, isPrompt: isPrompt)
            return true
        }
        return false
    }

    private func receivePuppetLine(
        _ source: RenderedLine,
        route: PuppetRouter.RoutedLine,
        isPrompt: Bool
    ) {
        var line = source
        line.text = route.text
        if let removed = route.removedRange {
            let length = removed.count
            line.runs = line.runs.compactMap { run in
                if run.range.upperBound <= removed.lowerBound { return run }
                if run.range.lowerBound >= removed.upperBound {
                    return .init(
                        range: (run.range.lowerBound - length)..<(run.range.upperBound - length),
                        style: run.style
                    )
                }
                let lower = min(run.range.lowerBound, removed.lowerBound)
                let upper = max(removed.lowerBound, run.range.upperBound - length)
                return upper > lower ? .init(range: lower..<upper, style: run.style) : nil
            }
            line.assets = line.assets.compactMap { asset in
                var adjusted = asset
                if asset.characterOffset >= removed.upperBound {
                    adjusted.characterOffset -= length
                } else if asset.characterOffset >= removed.lowerBound {
                    adjusted.characterOffset = removed.lowerBound
                }
                return adjusted
            }
        }
        Task { [weak self] in await self?.presentIncoming(line, isPrompt: isPrompt) }
    }

    private func presentIncoming(_ line: RenderedLine, isPrompt: Bool) async {
        if consumeGrabResponse(line.text) { return }
        webViewWindows.values.forEach { $0.observeReceived(line.text) }
        var presentation = await applyTriggers(to: gmcpState.decorate(line))
        // Windows runs triggers and logging before the Connection display
        // hook. The hook can then mutate the display copy or stop rendering,
        // without changing what was already written to the session log.
        if !presentation.gagLog,
           (isPrompt || presentation.line.source != .localEcho) {
            appendToLogs(presentation.line)
        }
        if !presentation.gagDisplay {
            guard let hookedLine = await applyScriptDisplayHook(to: presentation.line) else { return }
            presentation.line = hookedLine
        }
        let webViewGag = webViewWindows.values.reduce(false) { $1.observeDisplay(presentation.line) || $0 }
        if presentation.line.source == .server {
            _ = atlasWindow?.observeOutput(presentation.line.text)
        }
        if !isPrompt {
            suppressNextSessionActivity = presentation.suppressActivity
            if hasPendingPrompt { output.removeLastLine(); hasPendingPrompt = false }
            if !presentation.gagDisplay, !webViewGag {
                recordRecovery(.renderedLine(presentation.line), at: presentation.line.timestamp)
                output.append(presentation.line)
            }
            return
        }
        if hasPendingPrompt { output.removeLastLine() }
        if !presentation.gagDisplay, !webViewGag {
            recordRecovery(.prompt(presentation.line), at: presentation.line.timestamp)
            output.append(presentation.line, terminator: "")
            hasPendingPrompt = true
        } else {
            hasPendingPrompt = false
        }
    }

    private func consumeGrabResponse(_ text: String) -> Bool {
        guard let prefix = grabPrefix, text.hasPrefix(prefix) else { return false }
        let assignment = String(text.dropFirst(prefix.count))
        grabPrefix = nil
        input.text = assignment
        window?.makeFirstResponder(input)
        appendClient("Grab complete. The editable property assignment is in the command input.")
        return true
    }

    private func submitInput(_ value: String) {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // Windows handles /@ before its normal line splitter, so an
        // immediate script may contain newlines. Keep the complete source
        // together and let the scripting runtime evaluate it as one unit.
        if normalized.hasPrefix("/@") {
            submitLine(normalized)
            return
        }
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines where !line.isEmpty { submitLine(String(line)) }
    }

    private func handleKeyboardMacro(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command),
              let key = Self.legacyMacroKey(for: event),
              let macro = KeyboardMacroEngine.macro(for: key, groups: keyboardMacroGroups)
        else { return false }
        if macro.typeIntoInput {
            input.insertText(macro.macro, replacementRange: input.selectedRange())
        } else {
            for line in Self.logicalLines(in: macro.macro) where !line.isEmpty { submitLine(line) }
        }
        return true
    }

    private static func legacyMacroKey(for event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command) else { return nil }
        guard let base = KeyboardMacroKey.keyName(
            forKeyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers
        ) else { return nil }
        return KeyboardMacroKey.pressedKey(
            key: base,
            control: modifiers.contains(.control),
            alt: modifiers.contains(.option),
            shift: modifiers.contains(.shift)
        )
    }

    private func submitLine(_ line: String) {
        lastTypedAt = Date()
        refreshTitlebarStatistics()
        appendTypedToLogs(line)
        guard line.hasPrefix("/") else { processInput(line); return }
        // /@ is an immediate script escape in Windows SendLines, not a
        // command that participates in Window_Main's OnCommand hook.
        if line.hasPrefix("/@") {
            processInput(line)
            return
        }
        let body = String(line.dropFirst())
        let split = body.firstIndex(where: { $0.isWhitespace })
        let command = split.map { String(body[..<$0]) } ?? body
        let parameters = split.map { body[$0...].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        Task { [weak self, scriptService] in
            guard let self else { return }
            let result = await scriptService.dispatchConnectionEvent(
                "window:command",
                arguments: [command, parameters],
                host: scriptHostSnapshot
            )
            applyScriptEvaluation(result, showValue: false)
            if !Self.scriptWasHandled(result) { processInput(line) }
        }
    }

    private func sendToSession(_ text: String) {
        guard session != nil || puppetMaster != nil else { appendError("Not connected."); return }
        Task { [weak self, scriptService] in
            guard let self else { return }
            let result = await scriptService.dispatchConnectionEvent("send", arguments: [text], host: scriptHostSnapshot)
            applyScriptEvaluation(result, showValue: false)
            if !Self.scriptWasHandled(result) { transmitToSession(text) }
        }
    }

    private func transmitToSession(_ text: String, session explicitSession: SessionActor? = nil) {
        recordRecovery(.sentInput(text))
        appendSentToLogs(text)
        webViewWindows.values.forEach { $0.observeSent(text) }
        if let puppet = currentPuppet, let master = puppetMaster {
            master.transmitPuppetWire(PuppetRouter.outgoing(text, for: puppet))
            return
        }
        guard let session = explicitSession ?? session else { appendError("Not connected."); return }
        let outbound = text
        Task { await session.send(outbound) }
    }

    private func transmitPuppetWire(_ text: String) {
        guard let session else { appendError("The character connection is not connected."); return }
        Task { await session.send(text) }
    }

    private func receiveFromScript(_ text: String) {
        guard let session else { appendError("Not connected."); return }
        Task { [weak self, scriptService] in
            guard let self else { return }
            let result = await scriptService.dispatchConnectionEvent("receive", arguments: [text], host: scriptHostSnapshot)
            applyScriptEvaluation(result, showValue: false)
            if !Self.scriptWasHandled(result) { await session.receive(text) }
        }
    }

    private func applyScriptDisplayHook(to line: RenderedLine) async -> RenderedLine? {
        guard runsScriptServices else { return line }
        let result = await scriptService.dispatchConnectionEvent("display", line: line, host: scriptHostSnapshot)
        applyScriptEvaluation(.init(error: result.error, outputs: result.outputs), showValue: false)
        struct ChangedLine: Decodable { var text: String; var html: String; var handled: Bool? }
        guard let value = result.value,
              let data = value.data(using: .utf8),
              let changed = try? JSONDecoder().decode(ChangedLine.self, from: data) else { return line }
        if changed.handled == true { return nil }
        if changed.text == line.text, !changed.html.contains("<span") { return line }
        var parser = MUDProtocolPipeline(encoding: .utf8, pueblo: true, puebloActive: true)
        for event in parser.consume(Data((changed.html + "\n").utf8)) {
            if case var .line(parsed) = event {
                parsed.source = line.source
                parsed.timestamp = line.timestamp
                return parsed
            }
        }
        var changedLine = line
        changedLine.text = changed.text
        changedLine.runs = []
        return changedLine
    }

    private func appendToLogs(_ line: RenderedLine) {
        loggingCoordinator.append(line)
    }

    private func appendTypedToLogs(_ text: String) {
        loggingCoordinator.appendTyped(text)
    }

    private func appendSentToLogs(_ text: String) {
        loggingCoordinator.appendSent(text)
    }

    private var activeLogEntries: [LoggingWindowController.Entry] {
        loggingCoordinator.activeEntries.map {
            LoggingWindowController.Entry(url: $0.url, isAutomatic: $0.isAutomatic)
        }
    }

    private func refreshLoggingWindow() {
        loggingWindow?.update(entries: activeLogEntries)
    }

    private func beginManualLog(history: LoggingWindowController.StartHistory) {
        let selectedHistory: CommandOutcome.LogHistory = switch history {
        case .now: .none
        case .beginning: .all
        case .topOfWindow: .window
        }
        let panel = NSSavePanel()
        panel.title = "Start Session Log"
        panel.prompt = "Start"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(Self.logDateFormatter.string(from: Date()))-\(baseWindowTitle.safeFilename).txt"
        let start: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.startLog(template: url.path, history: selectedHistory)
        }
        if let window = loggingWindow?.window ?? self.window {
            panel.beginSheetModal(for: window, completionHandler: start)
        } else {
            start(panel.runModal())
        }
    }

    private func startLog(
        template: String,
        history: CommandOutcome.LogHistory,
        appendingDate: Bool = false,
        automatic: Bool = false
    ) {
        loggingCoordinator.start(
            template: template,
            history: history,
            outputHistory: output.retainedLines,
            visibleHistory: output.visibleWindowLines,
            appendingDate: appendingDate,
            automatic: automatic
        )
    }

    private func stopLog(at url: URL, announcing: Bool = true) {
        loggingCoordinator.stop(at: url, announcing: announcing)
    }

    private func stopAllLogs(announcing: Bool = true) {
        if loggingCoordinator.isEmpty {
            if announcing { appendClient("No active logs.") }
            loggingCoordinator.stopAll(announcing: false)
            return
        }
        loggingCoordinator.stopAll(announcing: announcing)
    }

    private func stopAllLogsIfActive(announcing: Bool) {
        loggingCoordinator.stopAllIfActive(announcing: announcing)
    }

    private func startAutomaticLog(announcingMissingSetup: Bool = false) {
        loggingCoordinator.startAutomatic(announcingMissingSetup: announcingMissingSetup)
    }

    private func rollOverLogsIfNeeded(at date: Date = Date()) {
        loggingCoordinator.rollOverIfNeeded(at: date)
    }

    private func scheduleDailyLogRollover() {
        loggingCoordinator.scheduleDailyRollover()
    }

    private func handleSmartPaste(_ lines: [String]) -> Bool {
        let nonempty = lines.filter { !$0.isEmpty }
        let alert = NSAlert()
        alert.messageText = "Paste \(nonempty.count) lines?"
        alert.informativeText = "You can send each line as a separate command, or insert the text into the multiline editor."
        alert.addButton(withTitle: "Send Lines")
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for line in nonempty { submitLine(line) }
            return true
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func perform(_ action: LinkAction) {
        switch action {
        case let .url(value):
            guard let url = URL(string: value) else { appendError("Invalid link: \(value)"); return }
            NSWorkspace.shared.open(url)
        case let .send(value, _):
            sendToSession(value)
        case let .command(value): processInput(value)
        }
    }

    private func processAliasedInput(_ text: String, unmatchedDiagnostic: String? = nil) {
        guard !aliasGroups.isEmpty else {
            handleUnaliasedInput(text, diagnostic: unmatchedDiagnostic)
            return
        }
        do {
            let result = try AliasEngine.process(text, groups: aliasGroups, variables: variables)
            automationDebugWindows[.aliases]?.append(result.trace)
            guard !result.matchedAliases.isEmpty else {
                handleUnaliasedInput(text, diagnostic: unmatchedDiagnostic)
                return
            }
            if result.echo {
                appendClient("Echoing alias result: \(result.text)")
            }
            for line in Self.logicalLines(in: result.text) where !line.isEmpty {
                if result.processCommands, line.hasPrefix("/") {
                    processInput(line)
                } else {
                    sendToSession(line)
                }
            }
        } catch {
            appendError("Alias error: \(error.localizedDescription)")
            handleUnaliasedInput(text, diagnostic: unmatchedDiagnostic)
        }
    }

    private func handleUnaliasedInput(_ text: String, diagnostic: String?) {
        if let diagnostic {
            appendClient(diagnostic)
        } else {
            sendToSession(text)
        }
    }

    private func profileLibraryDidChange() {
        reloadCurrentAutomation(resetRuntimeState: true)
        applyMenuStripPosition()
        refreshDiagnostics()
        updateWindowTitle()
        tabStateDidChange()
    }

    @discardableResult
    private func refreshCurrentProfileReferences() -> Bool {
        guard let currentServer else { return false }
        guard let selected = profileLibrary.workspace.projection.servers.first(where: {
            $0.profile.id == currentServer.id
        }) ?? profileLibrary.workspace.projection.servers.first(where: {
            $0.profile.name.caseInsensitiveCompare(currentServer.name) == .orderedSame
        }) else {
            self.currentServer = nil
            currentCharacter = nil
            currentPuppet = nil
            return false
        }
        self.currentServer = selected.profile
        let previousCharacter = currentCharacter
        if let characterID = previousCharacter?.id {
            let characterName = previousCharacter?.name
            currentCharacter = selected.characters.first { $0.id == characterID }
                ?? selected.characters.first {
                    guard let characterName else { return false }
                    return $0.name.caseInsensitiveCompare(characterName) == .orderedSame
                }
        }
        if currentCharacter == nil {
            currentPuppet = nil
            return previousCharacter == nil
        }
        guard let previousPuppet = currentPuppet else {
            return true
        }
        let puppetID = previousPuppet.id
        let puppetName = previousPuppet.name
        currentPuppet = currentCharacter?.puppets.first { $0.id == puppetID }
            ?? currentCharacter?.puppets.first {
                $0.name.caseInsensitiveCompare(puppetName) == .orderedSame
            }
        return currentPuppet != nil
    }

    private func reloadCurrentAutomation(resetRuntimeState: Bool = false) {
        if refreshCurrentProfileReferences() {
            refreshBaseWindowTitle()
        }
        guard let server = currentServer else {
            variables = [:]
            aliasGroups = []
            triggerGroups = []
            keyboardMacroGroups = []
            if resetRuntimeState { resetTriggerRuntimeState() }
            return
        }
        variables = profileLibrary.workspace.projection.variables(
            for: server,
            character: currentCharacter,
            puppet: currentPuppet
        )
        let groups = profileLibrary.workspace.projection.automationGroups(
            for: server,
            character: currentCharacter,
            puppet: currentPuppet
        )
        aliasGroups = groups.aliases
        triggerGroups = groups.triggers
        keyboardMacroGroups = profileLibrary.workspace.projection.macroGroups(
            for: server,
            character: currentCharacter,
            puppet: currentPuppet
        )
        if resetRuntimeState { resetTriggerRuntimeState() }
    }

    private func refreshBaseWindowTitle() {
        guard let server = currentServer else { return }
        baseWindowTitle = currentCharacter.map { character in
            let suffix = currentPuppet.map { " / \($0.name)" } ?? ""
            return "\(character.name) @ \(server.name)\(suffix)"
        } ?? server.name
    }

    private func resetTriggerRuntimeState() {
        let hadSpawnCapture = spawnCapture != nil
        spawnCapture = nil
        guard isSessionConnected || hadSpawnCapture else { return }
        Task { [triggerEngine] in await triggerEngine.resetRuntimeState() }
    }

    private func showAIWindow(prompt: String? = nil) {
        let controller: AIWindowController
        let isNew: Bool
        if let aiWindow {
            controller = aiWindow
            isNew = false
        } else {
            controller = AIWindowController(profileKey: notesKey)
            isNew = true
            controller.onClose = { [weak self, weak controller] in
                guard let self, self.aiWindow === controller else { return }
                if !self.preservingAIPlacement {
                    self.dockController.undockPane(.ai)
                }
                self.aiWindow = nil
            }
            controller.onDockRequest = { [weak self, weak controller] side in
                guard let self, let controller else { return }
                self.dockAIWindow(controller, side: side)
            }
            controller.onSubmit = { [weak self, weak controller] value in
                guard let self else { return }
                let endpoint = self.currentServer?.aiEndpoint
                let model = self.currentServer?.aiModel ?? ""
                self.aiRequestTask?.cancel()
                self.aiRequestTask = Task {
                    do {
                        let result = try await self.aiClient.request(
                            .init(prompt: value, model: model),
                            endpoint: endpoint,
                            apiKey: ProcessInfo.processInfo.environment["BEIPMU_AI_API_KEY"]
                        )
                        guard !Task.isCancelled else { return }
                        controller?.showResponse(result, for: value)
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        controller?.showError(error.localizedDescription)
                    }
                }
            }
            aiWindow = controller
        }
        controller.updateEndpoint(currentServer?.aiEndpoint)
        controller.applyTheme(preferences.theme.palette)
        if isNew {
            presentAIWindow(controller)
        } else if !controller.isDocked {
            controller.showFloating(self)
        }
        if let prompt, !prompt.isEmpty {
            controller.submitPrompt(prompt)
        }
    }

    private func presentAIWindow(_ controller: AIWindowController) {
        guard !controller.isDocked else { return }
        let view = controller.contentViewForDocking()
        if dockController.restorePane(
            .ai,
            view: view,
            title: "AI",
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(.ai)
                controller.showFloating(self)
            }
        ) {
            return
        }
        dockAIWindow(controller, side: .bottom)
    }

    private func dockAIWindow(_ controller: AIWindowController, side: WebViewDockSide) {
        dockController.dockPane(
            .ai,
            view: controller.contentViewForDocking(),
            title: "AI",
            side: side,
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(.ai)
                controller.showFloating(self)
            }
        )
    }

    private func closeAIWindow(preservingDockPlacement: Bool) {
        guard let controller = aiWindow else { return }
        aiRequestTask?.cancel()
        aiRequestTask = nil
        preservingAIPlacement = preservingDockPlacement
        if preservingDockPlacement, controller.isDocked {
            dockController.releasePane(.ai)
        }
        controller.closeSurface()
        preservingAIPlacement = false
        aiWindow = nil
    }

    private func recallOutput(lineCount: Int, search: String) {
        let retained = output.retainedLines
        let start = max(0, retained.count - lineCount)
        let matches = retained[start...].filter {
            $0.text.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        appendClient("Recall - Starting")
        matches.forEach { output.append($0) }
        appendClient("Recall - Finished")
    }

    private func runCompatibilityTest(_ kind: String) {
        guard let payload = CommandTestFixtures.payload(for: kind) else { return }
        if let session {
            Task { await session.receive(payload) }
        } else {
            var processor = MUDProtocolPipeline(encoding: .utf8, pueblo: true, puebloActive: true)
            for event in processor.consume(Data(payload.utf8)) {
                switch event {
                case let .line(line), let .prompt(line): output.append(line)
                default: break
                }
            }
        }
    }

    private func applyTriggers(to original: RenderedLine) async -> (line: RenderedLine, gagDisplay: Bool, gagLog: Bool, suppressActivity: Bool) {
        guard !triggerGroups.isEmpty || spawnCapture != nil else { return (original, false, false, false) }
        do {
            let effects: [AutomationEffect]
            if let capture = spawnCapture, capture.action.onlyChildrenDuringCapture {
                effects = try await triggerEngine.processOnly(
                    original,
                    triggers: capture.children,
                    variables: variables,
                    isAway: window?.isKeyWindow != true
                )
            } else if triggerGroups.isEmpty {
                effects = []
            } else {
                effects = try await triggerEngine.process(
                    original,
                    groups: triggerGroups,
                    variables: variables,
                    isAway: window?.isKeyWindow != true
                )
            }
            automationDebugWindows[.triggers]?.append(await triggerEngine.lastTrace())
            var line = original
            var gagDisplay = false
            var gagLog = false
            var suppressActivity = false
            var newSpawn: (action: TriggerSpawnAction, children: [Trigger])?
            for effect in effects {
                switch effect {
                case let .replace(range, replacement):
                    guard let swiftRange = Range(range, in: line.text) else { continue }
                    line.text.replaceSubrange(swiftRange, with: replacement)
                    // A filtered fragment may carry its own markup in the
                    // reference client. Until the rich filter parser is
                    // complete, do not retain stale UTF-16 style ranges.
                    line.runs = []
                case let .replaceHTML(range, replacement):
                    guard let swiftRange = Range(range, in: line.text) else { continue }
                    var parser = MUDProtocolPipeline(encoding: .utf8, pueblo: true, puebloActive: true)
                    let fragment = parser.consume(Data((replacement + "\n").utf8)).compactMap { event -> RenderedLine? in
                        if case let .line(value) = event { return value }
                        return nil
                    }.first ?? .init(text: replacement)
                    line.text.replaceSubrange(swiftRange, with: fragment.text)
                    line.runs = fragment.runs.map {
                        .init(range: (range.location + $0.range.lowerBound)..<(range.location + $0.range.upperBound), style: $0.style)
                    }
                case .gagDisplay:
                    gagDisplay = true
                case .gagLog:
                    gagLog = true
                case let .send(text):
                    for value in Self.logicalLines(in: text) where !value.isEmpty { processInput(value) }
                case let .link(range, text):
                    let upperBound = line.text.utf16.count
                    let lower = max(0, min(range.location, upperBound))
                    let upper = max(lower, min(range.location + range.length, upperBound))
                    guard lower < upper else { continue }
                    var style = Self.style(at: lower, in: line) ?? .init()
                    style.link = .send(text, hints: [])
                    line.runs.append(.init(range: lower..<upper, style: style))
                case let .activity(important):
                    markActivity(important: important)
                case .activateWindow:
                    window?.makeKeyAndOrderFront(nil)
                case .suppressActivity:
                    suppressActivity = true
                case let .sound(path):
                    if !isMuted, let sound = NSSound(contentsOf: URL(fileURLWithPath: path), byReference: true) {
                        scriptSounds.removeAll { !$0.isPlaying }
                        scriptSounds.append(sound)
                        sound.play()
                    }
                case let .speech(text):
                    if !isMuted {
                        let utterance = AVSpeechUtterance(string: text)
                        if let identifier = preferences.speechVoiceIdentifier {
                            utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
                        }
                        speechSynthesizer.speak(utterance)
                    }
                case let .script(function, ranges, callbackLine):
                    let result = await scriptService.callTrigger(
                        function,
                        ranges: ranges,
                        line: callbackLine,
                        host: scriptHostSnapshot
                    )
                    applyScriptEvaluation(result, showValue: false)
                case let .notification(text):
                    deliverNotification(text)
                case let .style(range, foreground, background):
                    let upperBound = line.text.utf16.count
                    let lower = max(0, min(range.location, upperBound))
                    let upper = max(lower, min(range.location + range.length, upperBound))
                    guard lower < upper else { continue }
                    var style = Self.style(at: lower, in: line) ?? .init()
                    if let foreground { style.foreground = foreground }
                    if let background { style.background = background }
                    line.runs.append(.init(
                        range: lower..<upper,
                        style: style
                    ))
                case let .resetColors(range, foreground, background):
                    let upperBound = line.text.utf16.count
                    let lower = max(0, min(range.location, upperBound))
                    let upper = max(lower, min(range.location + range.length, upperBound))
                    guard lower < upper else { continue }
                    var style = Self.style(at: lower, in: line) ?? .init()
                    if foreground { style.foreground = nil }
                    if background { style.background = nil }
                    line.runs.append(.init(range: lower..<upper, style: style))
                case let .font(range, face, size):
                    let upperBound = line.text.utf16.count
                    let lower = max(0, min(range.location, upperBound))
                    let upper = max(lower, min(range.location + range.length, upperBound))
                    guard lower < upper else { continue }
                    var style = Self.style(at: lower, in: line) ?? .init()
                    style.fontFace = face
                    style.fontSize = size
                    line.runs.append(.init(range: lower..<upper, style: style))
                case let .appearance(range, patch):
                    let upperBound = line.text.utf16.count
                    let lower = max(0, min(range.location, upperBound))
                    let upper = max(lower, min(range.location + range.length, upperBound))
                    guard lower < upper else { continue }
                    var style = Self.style(at: lower, in: line) ?? .init()
                    patch.applying(to: &style)
                    line.runs.append(.init(range: lower..<upper, style: style))
                case let .paragraph(patch):
                    patch.applying(to: &line.paragraph)
                case let .avatar(url):
                    if let source = URL(string: url) {
                        line.assets.append(.init(kind: .avatar, source: source, altText: "Trigger avatar", characterOffset: 0))
                    }
                case let .stat(update):
                    updateTriggerStatistic(update)
                case let .spawn(action, _, children):
                    if spawnCapture == nil && newSpawn == nil { newSpawn = (action, children) }
                }
            }
            if let newSpawn {
                deliverSpawn(line, action: newSpawn.action, children: newSpawn.children, startsCapture: true)
                gagDisplay = gagDisplay || !newSpawn.action.copy
                gagLog = gagLog || newSpawn.action.gagLog
            } else if let capture = spawnCapture {
                deliverSpawn(line, action: capture.action, children: capture.children, startsCapture: false)
                gagDisplay = gagDisplay || !capture.action.copy
                gagLog = gagLog || capture.action.gagLog
                if matchesCaptureEnd(capture.action.captureUntil, text: line.text) {
                    spawnCapture = nil
                }
            }
            return (line, gagDisplay, gagLog, suppressActivity)
        } catch {
            appendError("Trigger error: \(error.localizedDescription)")
            return (original, false, false, false)
        }
    }

    private func markActivity(important: Bool) {
        guard window?.isKeyWindow != true else { return }
        unreadCount += 1
        activityLabel.stringValue = important ? "Important — \(unreadCount) unread" : "\(unreadCount) unread"
        updateWindowTitle()
        if important { NSApplication.shared.requestUserAttention(.informationalRequest) }
        Self.updateDockBadge()
    }

    private func deliverNotification(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = baseWindowTitle
        content.body = text
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            do {
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                }
                try await center.add(request)
            } catch {
                appendError("Unable to deliver notification: \(error.localizedDescription)")
            }
        }
    }

    private static func logicalLines(in text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func style(at utf16Offset: Int, in line: RenderedLine) -> TextStyle? {
        line.runs.last(where: { $0.range.contains(utf16Offset) })?.style
    }

    private func processInput(_ text: String) {
        switch commandRegistry.parse(text, variables: variables) {
        case .notACommand:
            processAliasedInput(text)
        case let .unrecognizedCommand(diagnostic):
            processAliasedInput(text, unmatchedDiagnostic: diagnostic)
        case let .send(value):
            sendToSession(value)
        case let .display(value): appendClient(value)
        case .clear: output.clear()
        case let .localEcho(enabled):
            updateActiveInputWindowSettings { $0.localEcho = enabled }
            appendClient("Local echo \(enabled ? "on" : "off").")
        case .resetANSI:
            guard let session else { appendError("Not connected."); return }
            Task { await session.resetFormatting() }
            appendClient("ANSI state reset.")
        case .nawsAuto:
            guard let session else { appendError("Not connected."); return }
            let size = output.terminalSize
            Task { await session.sendWindowSize(columns: size.columns, rows: size.rows) }
            appendClient("NAWS sent: \(size.columns) × \(size.rows).")
        case let .naws(columns, rows):
            guard let session else { appendError("Not connected."); return }
            Task { await session.sendWindowSize(columns: columns, rows: rows) }
            appendClient("NAWS sent: \(columns) × \(rows).")
        case let .terminalType(value):
            appendClient("Current TType = \(terminalType)")
            guard let value else { return }
            terminalType = value
            if let session { Task { await session.setTerminalType(value) } }
            appendClient("New TType = \(value)")
        case let .setVariable(name, value): variables[name] = value; appendClient("Set %\(name)%")
        case let .unsetVariable(name): variables.removeValue(forKey: name); appendClient("Unset %\(name)%")
        case let .gmcp(message):
            guard let session else { appendError("Not connected."); return }
            Task { await session.sendRaw(Self.gmcpFrame(message)) }
        case let .gmcpDump(enabled):
            gmcpDumpEnabled = enabled
            appendClient("GMCP dump \(enabled ? "enabled" : "disabled").")
        case let .mediaControl(action):
            switch action {
            case .flush:
                if mediaState.isActive {
                    for event in mediaState.flush() { mediaController.apply(event) }
                    mediaController.flush()
                }
            case .info:
                if mediaState.isActive {
                    appendClient(mediaState.information)
                    appendClient(mediaController.information)
                } else {
                    appendError("MCMP not active")
                }
            }
        case let .tileMap(enabled):
            tileMapsEnabled = enabled
            appendClient("TileMap tag parsing \(enabled ? "ON" : "OFF")")
        case let .switchSpawnTab(group, title):
            guard let controller = triggerSpawnTabGroups[group] else {
                appendError("Tab group not found")
                return
            }
            if !controller.selectTab(named: title) { appendError("Tab not found") }
        case let .mapAddRoom(name, outward, returnCommand):
            guard let atlasWindow, atlasWindow.editor.currentLocation != nil else {
                appendError("The map doesn't currently know your location")
                return
            }
            if !atlasWindow.addRoomAndExit(name: name, outward: outward, returnCommand: returnCommand) {
                appendError("The room could not be added")
            }
        case let .mapAddExit(outward, returnCommand):
            guard let atlasWindow, atlasWindow.editor.currentLocation != nil else {
                appendError("The map doesn't currently know your location")
                return
            }
            if !atlasWindow.addDirectionalExit(outward: outward, returnCommand: returnCommand) {
                appendError("Unknown direction or no room in that direction")
            }
        case .mapGuessLocation:
            guard let atlasWindow else { appendError("No map"); return }
            if atlasWindow.guessLocation(in: output.retainedLines.map(\.text)) == nil {
                appendError("Unable to determine current location")
            }
        case .mapLook:
            guard let description = atlasWindow?.lookDescription() else {
                appendError("The map doesn't currently know your location")
                return
            }
            appendClient(description)
        case let .disconnect(all):
            let controllers = all ? Self.openControllers : [self]
            for controller in controllers { controller.disconnect() }
        case let .reconnect(all):
            let controllers = all ? Self.openControllers : [self]
            for controller in controllers { controller.reconnect() }
        case let .connect(address, character):
            if let saved = profileLibrary.workspace.servers.first(where: {
                $0.profile.name.caseInsensitiveCompare(address) == .orderedSame
            }) {
                let selectedCharacter = character.flatMap { requested in
                    saved.characters.first { $0.name.caseInsensitiveCompare(requested) == .orderedSame }
                }
                if character != nil, selectedCharacter == nil {
                    appendError("Character not found in \(saved.profile.name): \(character!)")
                    return
                }
                startSession(
                    saved.profile,
                    character: selectedCharacter,
                    policy: profileLibrary.workspace.projection.connectionPolicy
                )
                return
            }
            guard character == nil else {
                appendError("World profile not found: \(address)")
                return
            }
            guard let endpoint = Self.endpoint(address) else {
                appendError("Missing port; address must be host:port.")
                return
            }
            startSession(.init(name: address, host: endpoint.host, port: endpoint.port))
        case let .repeatCommand(count, command):
            for _ in 0..<count { processInput(command) }
        case let .delay(action):
            switch action {
            case .list:
                Task {
                    let entries = await delayScheduler.entries()
                    if entries.isEmpty { appendClient("No pending delay actions.") }
                    for entry in entries {
                        appendClient("Delay ID \(entry.id): \(entry.command) in \(entry.seconds)s\(entry.repeating ? " (repeating)" : "")")
                    }
                }
            case .killAll:
                Task { await delayScheduler.killAll(); appendClient("All pending timers erased.") }
            case let .kill(id):
                Task {
                    let killed = await delayScheduler.kill(id)
                    appendClient(killed ? "Timer killed." : "Timer ID not found.")
                }
            case let .schedule(id, repeating, seconds, command):
                Task {
                    let assigned = await delayScheduler.schedule(
                        id: id,
                        repeating: repeating,
                        seconds: seconds,
                        command: command
                    ) { [weak self] command in
                        await MainActor.run { self?.processInput(command) }
                    }
                    appendClient("Starting timer with ID: \(assigned) in \(seconds)s")
                }
            }
        case let .receive(value):
            guard let session else { appendError("Not connected."); return }
            Task { await session.receive(value) }
        case let .receiveGMCP(message):
            guard let session else { appendError("Not connected."); return }
            Task { await session.receiveGMCP(message) }
        case let .ping(value):
            guard let session else { appendError("Not connected."); return }
            appendSentToLogs(value)
            Task { await session.ping(value) }
        case let .setInput(value):
            let target = secondaryInputWindows.first(where: { $0.window?.isKeyWindow == true })?.input ?? input
            guard target.text.isEmpty else { return }
            target.text = value
            target.setSelectedRange(NSRange(location: 0, length: value.utf16.count))
        case let .idle(minutes, command):
            guard let session else { appendError("Must be connected to work."); return }
            if let minutes, let command {
                Task { await session.configureIdle(interval: TimeInterval(minutes) * 60, text: command) }
                appendClient("Idle timer activated: \(minutes) minute(s), sends \(command)")
            } else {
                Task { await session.configureIdle(interval: nil, text: nil) }
                appendClient("Idle timer removed.")
            }
        case .statistics:
            guard let session else { appendError("Not connected."); return }
            Task {
                let stats = await session.statistics()
                appendClient("Connections: \(stats.connectionCount)  Sent: \(stats.bytesSent) bytes  Received: \(stats.bytesReceived) bytes  Online: \(Int(stats.secondsConnected))s")
            }
        case .connectionInfo:
            guard let server = currentServer else { appendError("No connection information available."); return }
            appendClient("\(server.host):\(server.port) — \(server.usesTLS ? (server.verifiesCertificate ? "TLS, verified" : "TLS, unverified") : "plain TCP")")
        case .close: window?.performClose(nil)
        case .exit: NSApplication.shared.terminate(nil)
        case .newWindow:
            NSApplication.shared.sendAction(#selector(ApplicationDelegate.newWindow(_:)), to: nil, from: nil)
        case .newTab:
            NSApplication.shared.sendAction(#selector(ApplicationDelegate.newTab(_:)), to: nil, from: nil)
        case let .newInput(prefix, unique): showNewInputWindow(prefix: prefix, unique: unique)
        case let .newEdit(options): showNewEditWindow(options: options)
        case let .ai(prompt): showAIWindow(prompt: prompt)
        case let .gag(text):
            do {
                _ = try profileLibrary.mutate { try $0.addOrActivateGlobalGag(text) }
                reloadCurrentAutomation()
                appendClient("Gag activated for: \(text)")
            } catch { appendError("Gag: \(error.localizedDescription)") }
        case let .grab(object, property):
            guard session != nil else { appendError("Not connected."); return }
            let token = String(format: "%08X", UInt32.random(in: UInt32.min...UInt32.max))
            grabPrefix = token + " "
            sendToSession("@pemit me=\(grabPrefix!)&\(property) \(object)=[get(\(object)/\(property))]")
        case let .recall(lineCount, search): recallOutput(lineCount: lineCount, search: search)
        case .resetConfiguration:
            onFactoryResetRequest?()
        case .rollTest:
            appendClient(DiceFairnessReport.run().displayText)
        case let .compatibilityTest(kind): runCompatibilityTest(kind)
        case let .webView(request): openWebView(request)
        case .silence:
            mediaController.stop(name: nil)
            scriptSounds.forEach { $0.stop() }
            scriptSounds.removeAll()
            speechSynthesizer.stopSpeaking(at: .immediate)
            appendClient("Stopped local sound playback.")
        case .removeLast: output.removeLastLine()
        case let .wall(value):
            for controller in Self.openControllers {
                guard controller.session != nil else { continue }
                controller.sendToSession(value)
            }
        case let .openDialog(dialog, _):
            switch dialog {
            case "worlds", "characters", "puppets":
                NSApplication.shared.sendAction(#selector(ApplicationDelegate.manageProfiles(_:)), to: nil, from: nil)
            case "settings": showWorkspaceSettings()
            case "aliases": showAutomationEditor(.aliases)
            case "triggers": showAutomationEditor(.triggers)
            case "macros": showAutomationEditor(.macros)
            case "about":
                NSApplication.shared.sendAction(#selector(ApplicationDelegate.showAbout(_:)), to: nil, from: nil)
            default: appendClient("The \(dialog) editor belongs to a later workspace milestone.")
            }
        case .listServers:
            let servers = profileLibrary.workspace.servers
            if servers.isEmpty { appendClient("No server profiles loaded.") }
            for server in servers {
                appendClient("\(server.profile.name) — \(server.profile.host):\(server.profile.port)")
            }
        case .listCharacters:
            let entries = profileLibrary.workspace.servers.flatMap { server in
                server.characters.map { "\(server.profile.name) — \($0.name)" }
            }
            if entries.isEmpty { appendClient("No character profiles loaded.") }
            entries.forEach(appendClient)
        case .listPuppets:
            let entries = profileLibrary.workspace.servers.flatMap { server in
                server.characters.flatMap { character in
                    character.puppets.map { "\(server.profile.name) — \(character.name) — \($0.name)" }
                }
            }
            if entries.isEmpty { appendClient("No puppet profiles loaded.") }
            entries.forEach(appendClient)
        case let .connectPuppet(name):
            let match = currentCharacter?.puppets.first {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            if let match, let server = currentServer, let character = currentCharacter {
                _ = (NSApp.delegate as? ApplicationDelegate)?.openPuppet(
                    master: self, server: server, character: character, puppet: match
                )
            }
            else { appendError("Puppet profile not found: \(name)") }
        case .stopLogs: stopAllLogs()
        case let .startLog(filename, history): startLog(template: filename, history: history)
        case .startAutoLog: startAutomaticLog(announcingMissingSetup: true)
        case let .script(source):
            Task {
                let result = await scriptService.evaluate(source, host: scriptHostSnapshot)
                // Windows' Scripter::Run does not display the JavaScript
                // expression result; scripts communicate through host output
                // methods and errors instead.
                applyScriptEvaluation(result, showValue: false)
            }
        case let .scriptHelp(type):
            Task {
                let runtime = ScriptRuntime()
                if let type {
                    appendClient(await runtime.help(for: type) ?? "Unknown scripting type: \(type)")
                } else {
                    appendClient("Scripting types: " + (await runtime.helpTypes()).joined(separator: ", "))
                }
            }
        case let .openCommandHelp(topic):
            showEmbeddedHelp(topic: topic)
        case .resetScript:
            Task { await scriptService.reset(); appendClient("Scripting runtime reset.") }
        case .cancelCapture:
            if spawnCapture == nil { appendClient("No active spawn capture.") }
            else { spawnCapture = nil; appendClient("Spawn capture cancelled.") }
        case let .debugAutomation(kind):
            showAutomationDebugger(kind)
        case .debugNetwork:
            showNetworkDebugger()
        case let .invoke(name, arguments, _):
            switch name {
            case "tabcolor": setTabColor(arguments.first)
            default: appendClient("/\(name) is registered; its target surface is completed in a later milestone.")
            }
        case let .unimplemented(command): appendError("/\(command) is recognized but not implemented in this milestone.")
        }
    }

    private static var openControllers: [ClientWindowController] {
        NSApplication.shared.windows.compactMap { $0.windowController as? ClientWindowController }
    }

    static func resetProcessStateAfterFactoryReset() {
        didRunStartupScript = false
    }

    private static func updateDockBadge() {
        let total = openControllers.reduce(0) { $0 + $1.unreadCount }
        NSApplication.shared.dockTile.badgeLabel = total > 0 ? String(total) : nil
    }

    func rebuildSessionTabs() {
        let controllers = sessionTabGroup?.controllers ?? [self]
        let selectedController = sessionTabGroup?.selectedController ?? self
        sessionTabs.setTabs(controllers, selectedController: selectedController)
    }

    private func refreshSessionTabsAcrossGroup() {
        if let sessionTabGroup { sessionTabGroup.refreshTabs() }
        else { rebuildSessionTabs() }
    }

    func containsSessionTabStrip(screenPoint: NSPoint) -> Bool {
        guard let window, window.isVisible else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = sessionTabViewport.convert(windowPoint, from: nil)
        return sessionTabViewport.bounds.contains(localPoint)
    }

    func focusCommandInput() {
        window?.makeFirstResponder(input)
    }

    var isCommandInputFocusedForTesting: Bool {
        window?.firstResponder === input
    }

    func startLogForTesting(at url: URL) {
        startLog(template: url.path, history: .none)
    }

    func startDailyLogForTesting(template: String) {
        startLog(template: template, history: .none)
    }

    func rollOverLogsForTesting(at date: Date) {
        rollOverLogsIfNeeded(at: date)
        scheduleDailyLogRollover()
    }

    var activeLogURLsForTesting: [URL] { loggingCoordinator.activeURLs }
    var hasDailyLogRolloverTimerForTesting: Bool { loggingCoordinator.hasDailyRolloverTimer }

    private var sessionTabTitle: String {
        [sessionTabText, sessionWindowTrailingIndicators].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var sessionTabText: String {
        let activity = unreadCount > 0 ? "● " : ""
        return activity + scriptTitlePrefix + baseWindowTitle
    }

    private var sessionTabTrailingIndicators: String {
        [
            isTerminallyDisconnected ? "⚡️" : nil,
            isMuted ? "🔇" : nil,
            loggingCoordinator.isEmpty ? nil : "📝",
        ].compactMap { $0 }.joined(separator: " ")
    }

    private var sessionWindowTrailingIndicators: String {
        [
            isMuted ? "🔇" : nil,
            loggingCoordinator.isEmpty ? nil : "📝",
        ].compactMap { $0 }.joined(separator: " ")
    }

    private func updateWindowTitle() {
        window?.title = sessionTabTitle
        if let sessionTabGroup { sessionTabGroup.refreshTabs() }
        else { rebuildSessionTabs() }
    }

    private func setTabColor(_ value: String?) {
        guard let value, let color = NSColor(htmlColor: value) else {
            sessionTabColor = nil
            if let sessionTabGroup { sessionTabGroup.refreshTabs() }
            else { rebuildSessionTabs() }
            appendClient("Tab color reset.")
            return
        }
        sessionTabColor = color
        if let sessionTabGroup { sessionTabGroup.refreshTabs() }
        else { rebuildSessionTabs() }
        appendClient("Tab color set to \(value).")
    }

    private func applyPreferences() {
        applyTextWindowSettings()
        output.showsInlineImagePreviews = preferences.showsInlineImagePreviews
        triggerSpawnWindows.values.forEach { $0.showsInlineImagePreviews = preferences.showsInlineImagePreviews }
        triggerSpawnTabGroups.values.forEach { $0.showsInlineImagePreviews = preferences.showsInlineImagePreviews }
        if output.isSplit != preferences.outputSplit { output.toggleSplit() }
        input.behavior.prefix = preferences.inputPrefix
        input.isContinuousSpellCheckingEnabled = preferences.checksSpelling
        applyInputWindowSettings()
        applyThemeSettings(preferences.theme)
    }

    private func applyMenuStripPosition() {
        guard let root = rootStackView, let bar = taskbarView, let host = workspaceHostView else { return }
        root.removeArrangedSubview(bar)
        root.removeArrangedSubview(host)
        if profileLibrary.workspace.projection.taskbarOnTop {
            root.addArrangedSubview(bar)
            root.addArrangedSubview(host)
        } else {
            root.addArrangedSubview(host)
            root.addArrangedSubview(bar)
        }
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
    }

    private func savePreferences() {
        guard !suppressPersistence else { return }
        preferences = WorkspacePreferencesStore.saveMergingSessionState(
            preferences,
            sessionKey: notesKey
        )
    }

    private var textWindowIdentity: TextWindowSettingsIdentity {
        .init(
            world: currentServer?.name,
            character: currentCharacter?.name,
            tab: currentServer == nil ? nil : (currentPuppet?.name ?? "Main")
        )
    }

    private var activeTextWindowSettings: TextWindowSettings {
        preferences.textWindowSettings(for: textWindowIdentity)
    }

    private var activeInputWindowSettings: InputWindowSettings {
        preferences.inputWindowSettings(for: textWindowIdentity)
    }

    private var activeInputWindowSettingsScope: TextWindowSettingsEditorView.Scope {
        activeInputWindowUsesGlobalSettings ? .global : .tab
    }

    private var activeTextWindowSettingsScope: TextWindowSettingsEditorView.Scope {
        activeTextWindowUsesGlobalSettings ? .global : .tab
    }

    // Internal accessors keep routing and editor initialization directly testable
    // without presenting an NSAlert.
    var activeInputWindowSettingsScopeForTesting: TextWindowSettingsEditorView.Scope {
        activeInputWindowSettingsScope
    }

    var activeTextWindowSettingsScopeForTesting: TextWindowSettingsEditorView.Scope {
        activeTextWindowSettingsScope
    }

    func inputWindowSettingsEditorStatesForTesting() -> [TextWindowSettingsEditorView.Scope: InputWindowSettingsEditorView.State] {
        inputWindowSettingsEditorStates()
    }

    func textWindowSettingsEditorStatesForTesting() -> [TextWindowSettingsEditorView.Scope: TextWindowSettingsEditorView.State] {
        textWindowSettingsEditorStates()
    }

    private var activeInputWindowUsesGlobalSettings: Bool {
        let identity = textWindowIdentity
        if let key = identity.tabKey, let entry = preferences.tabInputWindowSettings[key] {
            return entry.usesGlobalSettings
        }
        if let key = identity.characterKey, let entry = preferences.characterInputWindowSettings[key] {
            return entry.usesGlobalSettings
        }
        if let key = identity.worldKey, let entry = preferences.worldInputWindowSettings[key] {
            return entry.usesGlobalSettings
        }
        return true
    }

    private var activeTextWindowUsesGlobalSettings: Bool {
        let identity = textWindowIdentity
        if let key = identity.tabKey, let entry = preferences.tabTextWindowSettings[key] {
            return entry.usesGlobalSettings
        }
        if let key = identity.characterKey, let entry = preferences.characterTextWindowSettings[key] {
            return entry.usesGlobalSettings
        }
        if let key = identity.worldKey, let entry = preferences.worldTextWindowSettings[key] {
            return entry.usesGlobalSettings
        }
        return true
    }

    private func inputWindowSettingsEditorStates() -> [TextWindowSettingsEditorView.Scope: InputWindowSettingsEditorView.State] {
        let identity = textWindowIdentity
        let global = preferences.globalInputWindowSettings
        var states: [TextWindowSettingsEditorView.Scope: InputWindowSettingsEditorView.State] = [
            .global: .init(
                label: "Global",
                override: .init(usesGlobalSettings: false, settings: global)
            ),
        ]
        if let key = identity.worldKey {
            states[.world] = .init(
                label: "World — \(identity.world ?? "")",
                override: preferences.worldInputWindowSettings[key]
                    ?? .init(usesGlobalSettings: true, settings: global)
            )
        }
        if let key = identity.characterKey {
            states[.character] = .init(
                label: "Character — \(identity.character ?? "")",
                override: preferences.characterInputWindowSettings[key]
                    ?? .init(usesGlobalSettings: true, settings: global)
            )
        }
        if let key = identity.tabKey {
            states[.tab] = .init(
                label: "Tab — \(identity.tab ?? "")",
                override: preferences.tabInputWindowSettings[key]
                    ?? .init(
                        usesGlobalSettings: activeInputWindowUsesGlobalSettings,
                        settings: activeInputWindowSettings
                    )
            )
        }
        return states
    }

    private func textWindowSettingsEditorStates() -> [TextWindowSettingsEditorView.Scope: TextWindowSettingsEditorView.State] {
        let identity = textWindowIdentity
        let global = preferences.globalTextWindowSettings
        var states: [TextWindowSettingsEditorView.Scope: TextWindowSettingsEditorView.State] = [
            .global: .init(
                label: "Global",
                override: .init(usesGlobalSettings: false, settings: global)
            ),
        ]
        if let key = identity.worldKey {
            states[.world] = .init(
                label: "World — \(identity.world ?? "")",
                override: preferences.worldTextWindowSettings[key]
                    ?? .init(usesGlobalSettings: true, settings: global)
            )
        }
        if let key = identity.characterKey {
            states[.character] = .init(
                label: "Character — \(identity.character ?? "")",
                override: preferences.characterTextWindowSettings[key]
                    ?? .init(usesGlobalSettings: true, settings: global)
            )
        }
        if let key = identity.tabKey {
            states[.tab] = .init(
                label: "Tab — \(identity.tab ?? "")",
                override: preferences.tabTextWindowSettings[key]
                    ?? .init(
                        usesGlobalSettings: activeTextWindowUsesGlobalSettings,
                        settings: activeTextWindowSettings
                    )
            )
        }
        return states
    }

    private func applyTextWindowSettings() {
        output.applySettings(activeTextWindowSettings)
    }

    private func applyInputWindowSettings() {
        let settings = activeInputWindowSettings
        input.usesGlobalSettings = activeInputWindowUsesGlobalSettings
        input.canToggleUseGlobalSettings = textWindowIdentity.tabKey != nil
        input.applySettings(settings)
        secondaryInputWindows.forEach {
            $0.input.usesGlobalSettings = activeInputWindowUsesGlobalSettings
            $0.input.canToggleUseGlobalSettings = textWindowIdentity.tabKey != nil
            $0.input.applySettings(settings)
        }
        localEcho = settings.localEcho
        if let session {
            let color = Self.rgbColor(hex: settings.localEchoHex)
            Task { await session.configureLocalEcho(settings.localEcho, color: color) }
        }
    }

    private func updateActiveInputWindowSettings(_ update: (inout InputWindowSettings) -> Void) {
        let identity = textWindowIdentity
        if let key = identity.tabKey {
            var entry = preferences.tabInputWindowSettings[key]
                ?? .init(usesGlobalSettings: false, settings: activeInputWindowSettings)
            entry.usesGlobalSettings = false
            update(&entry.settings)
            entry.settings = entry.settings.normalized
            preferences.tabInputWindowSettings[key] = entry
        } else {
            update(&preferences.globalInputWindowSettings)
            preferences.globalInputWindowSettings = preferences.globalInputWindowSettings.normalized
            synchronizeLegacyGlobalInputSettings()
        }
        applyInputWindowSettings()
        savePreferences()
        onTextWindowSettingsChange?()
        onWorkspacePreferencesChange?()
    }

    private func synchronizeLegacyGlobalInputSettings() {
        preferences.stickyInput = preferences.globalInputWindowSettings.keepsTextOnSubmit
    }

    private var inputDividerIndex: Int {
        max(0, (inputSplitView.arrangedSubviews.firstIndex { $0 === inputContainer } ?? 1) - 1)
    }

    private func minimumCoordinateForInputSplitDivider(at dividerIndex: Int) -> CGFloat {
        if isInputHistoryPaneVisible, dividerIndex == 1 {
            return Self.minimumOutputHeight
                + inputSplitView.dividerThickness
                + Self.minimumInputHistoryHeight
        }
        return Self.minimumOutputHeight
    }

    private func maximumCoordinateForInputSplitDivider(at dividerIndex: Int) -> CGFloat {
        let splitHeight = inputSplitView.bounds.height
        if isInputHistoryPaneVisible, dividerIndex == 0 {
            return splitHeight
                - (inputSplitView.dividerThickness * 2)
                - Self.minimumInputHistoryHeight
                - Self.minimumInputHeight
        }
        return splitHeight
            - inputSplitView.dividerThickness
            - Self.minimumInputHeight
    }

    private func maximumInputHeightForCurrentSplitLayout() -> CGFloat {
        let splitHeight = inputSplitView.bounds.height
        let reservedHistoryHeight = max(Self.minimumInputHistoryHeight, inputHistoryHeight)
        let reservedHeight = isInputHistoryPaneVisible
            ? Self.minimumOutputHeight + reservedHistoryHeight + (inputSplitView.dividerThickness * 2)
            : Self.minimumOutputHeight + inputSplitView.dividerThickness
        return max(Self.minimumInputHeight, splitHeight - reservedHeight)
    }

    private func boundedInputHeight(_ height: CGFloat) -> CGFloat {
        min(max(Self.minimumInputHeight, height), maximumInputHeightForCurrentSplitLayout())
    }

    private func restoreInputSplitLayout(inputHeight requestedInputHeight: CGFloat? = nil) {
        guard inputSplitView.bounds.height > 0 else { return }
        inputSplitView.layoutSubtreeIfNeeded()
        let splitHeight = inputSplitView.bounds.height
        let inputHeight = boundedInputHeight(requestedInputHeight ?? CGFloat(preferences.inputHeight))
        let inputDividerPosition = splitHeight - inputSplitView.dividerThickness - inputHeight
        isRestoringInputSplitLayout = true
        defer { isRestoringInputSplitLayout = false }
        if isInputHistoryPaneVisible {
            let historyHeight = min(
                max(Self.minimumInputHistoryHeight, inputHistoryHeight),
                max(
                    Self.minimumInputHistoryHeight,
                    inputDividerPosition - inputSplitView.dividerThickness - Self.minimumOutputHeight
                )
            )
            inputSplitView.setPosition(
                max(Self.minimumOutputHeight, inputDividerPosition - inputSplitView.dividerThickness - historyHeight),
                ofDividerAt: 0
            )
        }
        inputSplitView.setPosition(inputDividerPosition, ofDividerAt: inputDividerIndex)
    }

    private func restoreInputHeight() {
        restoreInputSplitLayout()
    }

    func synchronizeInputHeight(_ height: Double) {
        preferences.inputHeight = height
        let wasTrackingInputHeight = tracksInputHeight
        tracksInputHeight = false
        restoreInputHeight()
        tracksInputHeight = wasTrackingInputHeight
    }

    private func resizeInput(to height: CGFloat) {
        guard activeInputWindowSettings.resizesToFitContents, inputSplitView.bounds.height > 0 else { return }
        restoreInputSplitLayout(inputHeight: height)
    }

    private static func rgbColor(hex: String) -> BeipCore.RGBColor? {
        guard let color = NSColor(hexString: hex)?.usingColorSpace(.deviceRGB) else { return nil }
        return BeipCore.RGBColor(
            red: UInt8((color.redComponent * 255).rounded()),
            green: UInt8((color.greenComponent * 255).rounded()),
            blue: UInt8((color.blueComponent * 255).rounded())
        )
    }

    private func updateActiveTextWindowSettings(_ update: (inout TextWindowSettings) -> Void) {
        let identity = textWindowIdentity
        if let key = identity.tabKey {
            var entry = preferences.tabTextWindowSettings[key]
                ?? .init(usesGlobalSettings: false, settings: activeTextWindowSettings)
            entry.usesGlobalSettings = false
            update(&entry.settings)
            entry.settings = entry.settings.normalized
            preferences.tabTextWindowSettings[key] = entry
        } else {
            update(&preferences.globalTextWindowSettings)
            preferences.globalTextWindowSettings = preferences.globalTextWindowSettings.normalized
            synchronizeLegacyGlobalTextSettings()
        }
        applyTextWindowSettings()
        savePreferences()
        onTextWindowSettingsChange?()
        onWorkspacePreferencesChange?()
    }

    private func synchronizeLegacyGlobalTextSettings() {
        let global = preferences.globalTextWindowSettings
        preferences.outputHistoryLimit = global.historyLimit
        preferences.showsTimestamps = global.showsTime || global.showsDate
        preferences.usesFanFoldBackgrounds = global.usesFanFoldBackgrounds
    }

    func reloadTextWindowPreferences() {
        let saved = WorkspacePreferencesStore.load()
        preferences.theme = saved.theme
        preferences.checksSpelling = saved.checksSpelling
        preferences.speechVoiceIdentifier = saved.speechVoiceIdentifier
        preferences.outputSplit = saved.outputSplit
        preferences.outputHistoryLimit = saved.outputHistoryLimit
        preferences.showsTimestamps = saved.showsTimestamps
        preferences.usesFanFoldBackgrounds = saved.usesFanFoldBackgrounds
        preferences.stickyInput = saved.stickyInput
        preferences.showsInlineImagePreviews = saved.showsInlineImagePreviews
        preferences.globalTextWindowSettings = saved.globalTextWindowSettings
        preferences.worldTextWindowSettings = saved.worldTextWindowSettings
        preferences.characterTextWindowSettings = saved.characterTextWindowSettings
        preferences.tabTextWindowSettings = saved.tabTextWindowSettings
        preferences.globalInputWindowSettings = saved.globalInputWindowSettings
        preferences.worldInputWindowSettings = saved.worldInputWindowSettings
        preferences.characterInputWindowSettings = saved.characterInputWindowSettings
        preferences.tabInputWindowSettings = saved.tabInputWindowSettings
        applyTextWindowSettings()
        output.showsInlineImagePreviews = preferences.showsInlineImagePreviews
        triggerSpawnWindows.values.forEach { $0.showsInlineImagePreviews = preferences.showsInlineImagePreviews }
        triggerSpawnTabGroups.values.forEach { $0.showsInlineImagePreviews = preferences.showsInlineImagePreviews }
        applyInputWindowSettings()
        input.isContinuousSpellCheckingEnabled = preferences.checksSpelling
        secondaryInputWindows.forEach { $0.input.isContinuousSpellCheckingEnabled = preferences.checksSpelling }
        if output.isSplit != preferences.outputSplit { output.toggleSplit() }
        applyThemeSettings(preferences.theme)
        applyMenuStripPosition()
    }

    private var notesKey: String {
        ([currentServer?.name, currentCharacter?.name, currentPuppet?.name].compactMap { $0 }.joined(separator: "/").isEmpty
            ? "Untitled"
            : [currentServer?.name, currentCharacter?.name, currentPuppet?.name].compactMap { $0 }.joined(separator: "/"))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private var restoredWorkspaceLayout: WorkspaceLayoutNode? {
        guard let layout = preferences.workspaceLayouts[notesKey] ?? preferences.workspaceLayout else {
            return nil
        }

        // The global layout is a default for new sessions. Spawn panes are
        // session surfaces, so a new session must not inherit one belonging
        // to another world. For an identified session, only retain panes for
        // surfaces that have a matching saved spawn state.
        let saved = currentServer.flatMap { _ in preferences.spawnSurfaces[notesKey] }
        let standaloneTitles = Set(saved?.standaloneWindows.filter { !$0.isEmpty } ?? [])
        let tabGroupTitles = Set(
            saved?.tabGroups
                .filter { !$0.title.isEmpty && !$0.tabs.isEmpty }
                .map(\.title) ?? []
        )

        return layout.removingPanes { pane in
            switch pane {
            case let .spawn(title):
                return !standaloneTitles.contains(title)
            case let .spawnTabs(title):
                return !tabGroupTitles.contains(title)
            default:
                return false
            }
        } ?? .mainOnly
    }

    private func refreshDiagnostics() {
        let serverDescription = currentServer.map {
            "\($0.host):\($0.port)\($0.usesTLS ? " (TLS)" : "")"
        } ?? "None"
        let base = """
        Window: \(baseWindowTitle)
        State: \(connectionStateText)
        Server: \(serverDescription)
        Encoding: \(currentServer?.encoding.rawValue ?? "—")
        Output lines: \(output.visibleLineCount)
        Buffered while paused: \(output.pendingLineCount)
        Muted: \(isMuted ? "Yes" : "No")
        Active logs: \(loggingCoordinator.activeLogCount)
        """
        dockController?.setDiagnostics(base)
        guard let session else { return }
        Task { [weak self] in
            let stats = await session.statistics()
            await MainActor.run {
                self?.dockController?.setDiagnostics(base + """

                Connections: \(stats.connectionCount)
                Sent: \(stats.bytesSent) bytes
                Received: \(stats.bytesReceived) bytes
                Online: \(Int(stats.secondsConnected)) seconds
                """)
            }
        }
    }

    private func refreshConnectionStatistics() async {
        let statistics: ConnectionStatistics
        if let session { statistics = await session.statistics() }
        else { statistics = ConnectionStatistics() }
        statisticsWindow?.update(
            statistics: statistics,
            server: currentServer.map { "\($0.host):\($0.port)" } ?? "None",
            state: connectionStateText
        )
    }

    private func startTitlebarStatisticsUpdates() {
        refreshTitlebarStatistics()
        titlebarStatisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                refreshTitlebarStatistics()
            }
        }
    }

    private func refreshTitlebarStatistics() {
        let typedCount = UInt64(input.string.count)
        let idleSeconds = isSessionConnected ? Date().timeIntervalSince(lastTypedAt) : 0
        guard let session else {
            titlebarStatistics.update(
                typedCount: typedCount,
                onlineSeconds: 0,
                idleSeconds: idleSeconds
            )
            return
        }
        Task { [weak self] in
            let statistics = await session.statistics()
            guard let self else { return }
            titlebarStatistics.update(
                typedCount: typedCount,
                onlineSeconds: statistics.secondsConnected,
                idleSeconds: idleSeconds
            )
        }
    }

    private static func endpoint(_ address: String) -> (host: String, port: UInt16)? {
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            let host = String(address[address.index(after: address.startIndex)..<close])
            let suffix = address[address.index(after: close)...]
            guard suffix.first == ":", let port = UInt16(suffix.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: colon)...]) else { return nil }
        return (String(address[..<colon]), port)
    }

    private static func gmcpFrame(_ message: GMCPMessage) -> Data {
        let separator = message.payload.isEmpty ? "" : " "
        return Data([255, 250, 201]) + Data("\(message.package)\(separator)\(message.payload)".utf8) + Data([255, 240])
    }

    private static func performanceSoakLine(_ index: Int) -> RenderedLine {
        let text = "[\(index)] The quick brown fox crosses a virtualized MU* viewport with wrapped text, Unicode café, and command links."
        let prefixLength = min(text.utf16.count, String("[\(index)]").utf16.count)
        let foreground = RGBColor(
            red: UInt8(96 + index % 128),
            green: UInt8(128 + index % 96),
            blue: UInt8(160 + index % 64)
        )
        let style = TextStyle(
            foreground: foreground,
            bold: index.isMultiple(of: 7),
            italic: index.isMultiple(of: 11),
            underline: index.isMultiple(of: 13),
            blink: index.isMultiple(of: 997) ? .slow : .none,
            link: index.isMultiple(of: 17) ? .command("/statistics") : nil
        )
        return RenderedLine(
            text: text,
            runs: [StyleRun(range: 0..<prefixLength, style: style)],
            paragraph: ParagraphStyle(
                leftIndent: Double(index % 4) * 4,
                wrappedIndent: Double(index % 3) * 8,
                topPadding: index.isMultiple(of: 19) ? 2 : 0,
                bottomPadding: index.isMultiple(of: 23) ? 2 : 0
            ),
            source: index.isMultiple(of: 5) ? .localEcho : .server
        )
    }

    private static func currentResidentSize() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let connectionInfoColor = BeipCore.RGBColor(red: 0, green: 205, blue: 205)
    private static let connectionSuccessColor = BeipCore.RGBColor(red: 0, green: 205, blue: 0)
    private static let connectionAddressColor = BeipCore.RGBColor(red: 80, green: 80, blue: 255)
    private static let connectionErrorColor = BeipCore.RGBColor(red: 255, green: 0, blue: 0)

    private func appendClient(_ text: String) {
        let line = RenderedLine(text: text, source: .client)
        recordRecovery(.renderedLine(line), at: line.timestamp)
        output.append(line)
    }

    private func appendInformationalNotice(_ text: String) {
        appendClient(text, color: Self.connectionInfoColor)
    }

    private func appendConnectionNotice(_ notice: ConnectionNotice) {
        switch notice {
        case let .lookingUp(host, port):
            appendClient("Looking up address \(host):\(port)", color: Self.connectionInfoColor)
        case let .connecting(host, port):
            let prefix = "Address is "
            let address = "\(host):\(port)"
            let suffix = ", Connecting…"
            let text = prefix + address + suffix
            let prefixEnd = prefix.utf16.count
            let addressEnd = prefixEnd + address.utf16.count
            let line = RenderedLine(
                text: text,
                runs: [
                    .init(range: 0..<prefixEnd, style: .init(foreground: Self.connectionSuccessColor)),
                    .init(range: prefixEnd..<addressEnd, style: .init(foreground: Self.connectionAddressColor)),
                    .init(range: addressEnd..<text.utf16.count, style: .init(foreground: Self.connectionSuccessColor)),
                ],
                source: .client
            )
            recordRecovery(.renderedLine(line), at: line.timestamp)
            output.append(line)
        case .connected:
            appendClient("Connected", color: Self.connectionSuccessColor)
        case let .retryScheduled(seconds):
            appendClient("Will try to reconnect in \(seconds) seconds", color: Self.connectionInfoColor)
        case let .retrying(attempt, limit):
            appendClient("Retrying, attempt \(attempt) of \(limit)", color: Self.connectionInfoColor)
        case .retryLimitReached:
            appendClient("Retry limit reached, giving up", color: Self.connectionErrorColor)
        case .disconnected:
            appendClient("Disconnected", color: Self.connectionErrorColor)
        }
    }

    private func appendConnectionError(_ message: String) {
        let prefix = "Error: "
        let text = prefix + message
        let boundary = prefix.utf16.count
        let line = RenderedLine(
            text: text,
            runs: [
                .init(range: 0..<boundary, style: .init(foreground: Self.connectionErrorColor)),
                .init(range: boundary..<text.utf16.count, style: .init(foreground: Self.connectionInfoColor)),
            ],
            source: .client
        )
        recordRecovery(.renderedLine(line), at: line.timestamp)
        output.append(line)
    }

    private func appendClient(_ text: String, color: BeipCore.RGBColor) {
        let line = RenderedLine(
            text: text,
            runs: [.init(range: 0..<text.utf16.count, style: .init(foreground: color))],
            source: .client
        )
        recordRecovery(.renderedLine(line), at: line.timestamp)
        output.append(line)
    }

    private var scriptHostSnapshot: ScriptHostSnapshot {
        let projection = profileLibrary.workspace.projection
        let worlds = projection.servers.map { server in
            ScriptHostSnapshot.World(
                name: server.profile.name,
                host: "\(server.profile.host):\(server.profile.port)",
                characters: server.characters.map { .init(name: $0.name) }
            )
        }
        return .init(
            buildNumber: LegacyConfigurationProjection.currentWindowsVersion,
            version: LegacyConfigurationProjection.currentWindowsVersion,
            buildDate: Self.applicationBuildDate,
            configPath: profileLibrary.workspace.sourceURL?.path ?? "",
            worlds: worlds,
            aliases: projection.automation.aliases.aliases.map {
                .init(description: $0.description, matchText: $0.match.text)
            },
            triggers: projection.automation.triggers.triggers.map {
                .init(description: $0.description, matchText: $0.match.text)
            },
            activeWorld: currentServer?.name,
            activeCharacter: currentCharacter?.name,
            spawnTabGroups: triggerSpawnTabGroups.keys.sorted(),
            secondaryInputs: secondaryInputWindows.map {
                .init(title: $0.logicalTitle, prefix: $0.prefix, text: $0.input.text)
            },
            window: .init(
                title: window?.title ?? baseWindowTitle,
                input: input.text,
                inputPrefix: preferences.inputPrefix,
                inputTitle: input.accessibilityLabel(),
                titlePrefix: scriptTitlePrefix,
                connected: session != nil,
                logging: !loggingCoordinator.isEmpty,
                logFileName: loggingCoordinator.activeURLs.sorted { $0.path < $1.path }.first?.path,
                variables: variables
            )
        )
    }

    private func applyScriptEvaluation(_ result: ScriptEvaluation, showValue: Bool) {
        for action in ScriptOutputRouter.route(result, showValue: showValue) {
            switch action {
            case let .debug(kind, text):
                let entryKind: ScriptDebugWindowController.EntryKind = switch kind {
                case .text: .text
                case .html: .html
                case .error: .error
                }
                recordScriptDebug(.init(kind: entryKind, message: text), revealForError: kind == .error)
                if kind == .text { appendClient("Script: \(text)") }
                else if kind == .html { appendClient("Script HTML: \(text)") }
            case let .display(text): appendClient(text)
            case let .displayHTML(lines): lines.forEach { output.append($0) }
            case let .send(text): sendToSession(text)
            case let .transmit(text): transmitToSession(text)
            case let .receive(text): receiveFromScript(text)
            case let .setInput(text): input.text = text
            case let .setVariable(name, value): variables[name] = value
            case let .deleteVariable(name): variables.removeValue(forKey: name)
            case .closeWindow: window?.performClose(nil)
            case let .activity(important): markActivity(important: important)
            case let .runFile(value):
                let path = (value as NSString).expandingTildeInPath
                Task {
                    do {
                        let source = try String(contentsOfFile: path, encoding: .utf8)
                        let nested = await scriptService.evaluate(source, host: scriptHostSnapshot)
                        applyScriptEvaluation(nested, showValue: false)
                    } catch {
                        appendError("Cannot run script file: \(error.localizedDescription)")
                    }
                }
            case let .playSound(value):
                guard !isMuted,
                      let sound = NSSound(contentsOfFile: (value as NSString).expandingTildeInPath, byReference: true) else { continue }
                scriptSounds.append(sound)
                sound.play()
            case .stopSounds:
                scriptSounds.forEach { $0.stop() }
                scriptSounds.removeAll()
                speechSynthesizer.stopSpeaking(at: .immediate)
            case let .scriptError(text):
                recordScriptDebug(.init(kind: .error, message: text), revealForError: true)
                appendError(text)
            case let .evaluationError(text): appendError(text)
            case .reconnect:
                guard let session else { appendError("No previous connection to reconnect."); continue }
                Task { await session.reconnect() }
            case let .logWrite(text, line): loggingCoordinator.appendScript(text, asLine: line)
            case let .setInputPrefix(value):
                preferences.inputPrefix = value
                input.behavior = .init(prefix: value, isSticky: preferences.stickyInput)
                savePreferences()
            case let .setInputTitle(value): input.setAccessibilityLabel(value)
            case let .setTitlePrefix(value):
                scriptTitlePrefix = value
                updateWindowTitle()
            case let .runCommand(value):
                for line in Self.logicalLines(in: value) where !line.isEmpty { processInput(line) }
            case .openConnectDialog: showConnectDialog()
            case .malformedScriptWindow:
                appendError("Invalid script-window operation.")
            case let .scriptWindow(operation):
                let controller: ScriptWindowController
                if let existing = scriptWindows[operation.identifier] {
                    controller = existing
                } else {
                    guard operation.action == "create" else { continue }
                    controller = .init(operation: operation)
                    applyTheme(to: controller)
                    controller.onClose = { [weak self] in self?.scriptWindows.removeValue(forKey: operation.identifier) }
                    controller.onEvent = { [weak self, scriptService] event, arguments in
                        guard let self else { return }
                        Task {
                            self.applyScriptEvaluation(
                                await scriptService.dispatchConnectionEvent(
                                    "scriptWindow:\(operation.identifier):\(event)",
                                    arguments: arguments,
                                    host: self.scriptHostSnapshot
                                ),
                                showValue: false
                            )
                        }
                    }
                    scriptWindows[operation.identifier] = controller
                    controller.showWindow(self)
                    controller.window?.makeKeyAndOrderFront(nil)
                }
                controller.apply(operation, relativeTo: window)
            case .newMainWindow:
                NSApplication.shared.sendAction(#selector(ApplicationDelegate.newWindow(_:)), to: nil, from: nil)
                Task { [weak self, scriptService] in
                    guard let self else { return }
                    applyScriptEvaluation(
                        await scriptService.dispatchConnectionEvent("app:newWindow", host: scriptHostSnapshot),
                        showValue: false
                    )
                }
            case let .secondaryInput(operation):
                guard let value = operation.strings.first,
                      let controller = secondaryInputWindows.first(where: { $0.logicalTitle == operation.identifier }) else { continue }
                controller.applyScript(action: operation.action, value: value)
            }
        }
    }

    private static func scriptWasHandled(_ result: ScriptEvaluation) -> Bool {
        guard result.error == nil else { return false }
        return result.value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("true") == .orderedSame
    }

    private func recordScriptDebug(
        _ entry: ScriptDebugWindowController.Entry,
        revealForError: Bool = false
    ) {
        scriptDebugEntries.append(entry)
        if scriptDebugEntries.count > 1_000 {
            scriptDebugEntries.removeFirst(scriptDebugEntries.count - 1_000)
        }
        scriptDebugWindow?.append(entry)
        if revealForError,
           profileLibrary.workspace.projection.scripting.debugEnabled,
           scriptDebugWindow == nil {
            showScriptDebugger()
        }
    }

    private static var applicationBuildDate: String? {
        guard let executable = Bundle.main.executableURL,
              let values = try? executable.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }

    private func updateTriggerStatistic(_ update: TriggerStatisticUpdate) {
        let title = update.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Trigger Statistics" : update.title
        var store = triggerStatistics[title] ?? .init()
        store.apply(update)
        triggerStatistics[title] = store

        let controller: TriggerStatisticsWindowController
        if let existing = triggerStatisticsWindows[title] {
            controller = existing
        } else {
            controller = .init(title: title)
            applyTheme(to: controller)
            controller.onClose = { [weak self] in self?.triggerStatisticsWindows.removeValue(forKey: title) }
            triggerStatisticsWindows[title] = controller
        }
        controller.update(store.ordered)
        controller.showWindow(self)
    }

    private func deliverSpawn(
        _ line: RenderedLine,
        action: TriggerSpawnAction,
        children: [Trigger],
        startsCapture: Bool
    ) {
        let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Trigger Spawn" : action.title
        let group = action.tabGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        recordRecovery(
            .spawnOutput(
                title: title,
                tabGroup: group.isEmpty ? nil : group,
                line: line
            ),
            at: line.timestamp
        )
        if group.isEmpty {
            let controller = spawnWindow(named: title)
            if startsCapture, action.clear { controller.clear() }
            controller.append(line)
            presentSpawnWindow(controller, title: title)
        } else {
            let controller = spawnTabGroup(named: group)
            controller.deliver(
                line,
                to: title,
                clear: startsCapture && action.clear,
                showTab: startsCapture && action.showTab
            )
            presentSpawnTabGroup(controller, title: group)
        }
        if startsCapture, !action.captureUntil.isEmpty {
            spawnCapture = .init(title: title, action: action, children: children)
        }
    }

    private func restoreSpawnOutput(
        title: String,
        tabGroup: String?,
        line: RenderedLine
    ) {
        if let tabGroup, !tabGroup.isEmpty {
            let controller = spawnTabGroup(named: tabGroup)
            controller.deliver(
                line,
                to: title,
                clear: false,
                showTab: false,
                highlight: false
            )
            presentSpawnTabGroup(controller, title: tabGroup)
        } else {
            let controller = spawnWindow(named: title)
            controller.append(line)
            presentSpawnWindow(controller, title: title)
        }
    }

    private func recordRecovery(
        _ event: SessionRecoveryEvent,
        at timestamp: Date = Date()
    ) {
        recoveryCoordinator.append(event, at: timestamp)
    }

    private static func replayed(_ line: RenderedLine, timestamp: Date) -> RenderedLine {
        var line = line
        line.timestamp = timestamp
        line.source = .replay
        // Recovery replay is text/state-only. Do not let retained image or
        // other inline assets initiate media work while rebuilding the view.
        line.assets.removeAll(keepingCapacity: false)
        return line
    }

    private func spawnWindow(named title: String) -> TriggerSpawnWindowController {
        if let existing = triggerSpawnWindows[title] { return existing }
        let controller = TriggerSpawnWindowController(title: title)
        controller.applyTheme(preferences.theme.palette)
        controller.showsInlineImagePreviews = preferences.showsInlineImagePreviews
        controller.onAction = { [weak self] action in self?.perform(action) }
        controller.onWindowDragEnded = { [weak self, weak controller] point in
            guard let self, let controller else { return false }
            return self.handleDraggedSpawnWindow(controller, title: title, point: point)
        }
        controller.onClose = { [weak self] in
            guard let self else { return }
            self.dockController.undockPane(.spawn(title))
            self.triggerSpawnWindows.removeValue(forKey: title)
            self.saveSpawnSurfacePreferences()
        }
        controller.onCloseRequest = { [weak controller] in controller?.closeSurface() }
        controller.onDockRequest = { [weak self, weak controller] side in
            guard let self, let controller else { return }
            self.dockSpawnWindow(controller, title: title, side: side)
        }
        if let window = controller.window {
            RuntimeStateContext.setFrameAutosaveName(
                "BeipMUSpawn.\((notesKey + "." + title).safeFilename)",
                for: window
            )
        }
        triggerSpawnWindows[title] = controller
        saveSpawnSurfacePreferences()
        return controller
    }

    private func spawnTabGroup(named title: String) -> TriggerSpawnTabGroupWindowController {
        if let existing = triggerSpawnTabGroups[title] { return existing }
        let controller = TriggerSpawnTabGroupWindowController(title: title)
        controller.applyTheme(preferences.theme.palette)
        controller.showsInlineImagePreviews = preferences.showsInlineImagePreviews
        controller.onAction = { [weak self] action in self?.perform(action) }
        controller.onStructureChange = { [weak self] in self?.saveSpawnSurfacePreferences() }
        controller.onWindowDragEnded = { [weak self, weak controller] point in
            guard let self, let controller else { return false }
            return self.handleDraggedSpawnTabGroup(controller, title: title, point: point)
        }
        controller.onDockedSurfaceDrag = { [weak self] point in
            self?.handleDraggedDockedSpawnTabGroup(title: title, point: point) ?? false
        }
        controller.onTabActivate = { [weak self, scriptService] tab in
            guard let self else { return }
            Task {
                self.applyScriptEvaluation(
                    await scriptService.dispatchConnectionEvent(
                        "spawnTabs:\(title)",
                        arguments: [tab],
                        host: self.scriptHostSnapshot
                    ),
                    showValue: false
                )
            }
        }
        controller.onClose = { [weak self] in
            guard let self else { return }
            self.dockController.undockPane(.spawnTabs(title))
            self.triggerSpawnTabGroups.removeValue(forKey: title)
            self.saveSpawnSurfacePreferences()
        }
        controller.onCloseRequest = { [weak controller] in controller?.closeSurface() }
        controller.onDockRequest = { [weak self, weak controller] side in
            guard let self, let controller else { return }
            self.dockSpawnTabGroup(controller, title: title, side: side)
        }
        if let window = controller.window {
            RuntimeStateContext.setFrameAutosaveName(
                "BeipMUSpawnTabs.\((notesKey + "." + title).safeFilename)",
                for: window
            )
        }
        triggerSpawnTabGroups[title] = controller
        saveSpawnSurfacePreferences()
        return controller
    }

    private func saveSpawnSurfacePreferences() {
        guard !suppressSpawnPersistence, !suppressPersistence else { return }
        let standalone = triggerSpawnWindows.keys.sorted()
        let groups = triggerSpawnTabGroups.sorted { $0.key < $1.key }.map { title, controller in
            SpawnTabGroupPreferences(title: title, tabs: controller.tabTitles, selectedTab: controller.selectedTitle)
        }
        let state = SpawnSurfacePreferences(standaloneWindows: standalone, tabGroups: groups)
        if standalone.isEmpty, groups.isEmpty { preferences.spawnSurfaces.removeValue(forKey: notesKey) }
        else { preferences.spawnSurfaces[notesKey] = state }
        savePreferences()
    }

    private func presentSpawnWindow(_ controller: TriggerSpawnWindowController, title: String) {
        guard !controller.isDocked else { return }
        let pane = WorkspacePaneKind.spawn(title)
        let view = controller.contentViewForDocking()
        if !dockController.restorePane(
            pane,
            view: view,
            title: title,
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(pane)
                controller.showFloating(self)
            },
            onDrag: { [weak self] point in
                self?.handleDraggedDockedSpawn(title: title, point: point) ?? false
            },
            onClose: { [weak controller] in
                controller?.requestClose()
            }
        ) {
            controller.showFloating(self)
        }
    }

    private func presentSpawnTabGroup(_ controller: TriggerSpawnTabGroupWindowController, title: String) {
        guard !controller.isDocked else { return }
        let pane = WorkspacePaneKind.spawnTabs(title)
        let view = controller.contentViewForDocking()
        if !dockController.restorePane(
            pane,
            view: view,
            title: title,
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(pane)
                controller.showFloating(self)
            },
            onDrag: { [weak self] point in
                self?.handleDraggedDockedSpawnTabGroup(title: title, point: point) ?? false
            },
            onClose: { [weak controller] in
                controller?.requestClose()
            }
        ) {
            controller.showFloating(self)
        }
    }

    private func dockSpawnWindow(_ controller: TriggerSpawnWindowController, title: String, side: WebViewDockSide) {
        let pane = WorkspacePaneKind.spawn(title)
        dockController.dockPaneInVerticalStack(
            pane,
            view: controller.contentViewForDocking(),
            title: title,
            side: side,
            matching: Self.isStandaloneSpawnPane,
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(pane)
                controller.showFloating(self)
            },
            onDrag: { [weak self] point in
                self?.handleDraggedDockedSpawn(title: title, point: point) ?? false
            },
            onClose: { [weak controller] in
                controller?.requestClose()
            }
        )
    }

    private func dockSpawnTabGroup(_ controller: TriggerSpawnTabGroupWindowController, title: String, side: WebViewDockSide) {
        let pane = WorkspacePaneKind.spawnTabs(title)
        dockController.dockPane(
            pane,
            view: controller.contentViewForDocking(),
            title: title,
            side: side,
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(pane)
                controller.showFloating(self)
            },
            onDrag: { [weak self] point in
                self?.handleDraggedDockedSpawnTabGroup(title: title, point: point) ?? false
            },
            onClose: { [weak controller] in
                controller?.requestClose()
            }
        )
    }

    private static func isStandaloneSpawnPane(_ pane: WorkspacePaneKind) -> Bool {
        if case .spawn = pane { return true }
        return false
    }

    private func handleDraggedSpawnWindow(
        _ controller: TriggerSpawnWindowController,
        title: String,
        point: NSPoint
    ) -> Bool {
        guard let side = dockController.dockSide(
            forScreenPoint: point,
            threshold: 96,
            allowedSides: [.left, .right]
        ) else {
            return false
        }
        dockSpawnWindow(controller, title: title, side: side)
        saveSpawnSurfacePreferences()
        return true
    }

    private func handleDraggedSpawnTabGroup(
        _ controller: TriggerSpawnTabGroupWindowController,
        title: String,
        point: NSPoint
    ) -> Bool {
        guard let side = dockController.dockSide(
            forScreenPoint: point,
            threshold: 96,
            allowedSides: [.left, .right]
        ) else {
            return false
        }
        dockSpawnTabGroup(controller, title: title, side: side)
        saveSpawnSurfacePreferences()
        return true
    }

    private func handleDraggedDockedSpawn(title: String, point: NSPoint) -> Bool {
        let pane = WorkspacePaneKind.spawn(title)
        if dockController.reorderPaneInVerticalStack(pane, atScreenPoint: point, matching: Self.isStandaloneSpawnPane) {
            return true
        }
        guard let side = dockController.dockSide(forScreenPoint: point) else {
            guard dockController.isOutsideHostWindow(point),
                  let controller = triggerSpawnWindows[title] else { return false }
            dockController.undockPane(pane)
            controller.showFloating(self, near: point)
            saveSpawnSurfacePreferences()
            return true
        }
        dockController.movePaneInVerticalStack(pane, side: side, matching: Self.isStandaloneSpawnPane)
        saveSpawnSurfacePreferences()
        return true
    }

    private func handleDraggedDockedSpawnTabGroup(title: String, point: NSPoint) -> Bool {
        let pane = WorkspacePaneKind.spawnTabs(title)
        guard let side = dockController.dockSide(forScreenPoint: point) else {
            guard dockController.isOutsideHostWindow(point),
                  let controller = triggerSpawnTabGroups[title] else { return false }
            dockController.undockPane(pane)
            controller.showFloating(self, near: point)
            saveSpawnSurfacePreferences()
            return true
        }
        dockController.movePane(pane, side: side)
        saveSpawnSurfacePreferences()
        return true
    }

    private func restoreSpawnSurfacePreferences() {
        guard let state = preferences.spawnSurfaces[notesKey] else { return }
        suppressSpawnPersistence = true
        defer { suppressSpawnPersistence = false }
        for title in state.standaloneWindows where !title.isEmpty {
            presentSpawnWindow(spawnWindow(named: title), title: title)
        }
        for saved in state.tabGroups where !saved.title.isEmpty {
            let group = spawnTabGroup(named: saved.title)
            for title in saved.tabs where !title.isEmpty {
                group.ensureTab(named: title, selected: title == saved.selectedTab)
            }
            if !group.tabTitles.isEmpty { presentSpawnTabGroup(group, title: saved.title) }
        }
    }

    private func closeSpawnSurfaces() {
        suppressSpawnPersistence = true
        let windows = Array(triggerSpawnWindows)
        let groups = Array(triggerSpawnTabGroups)
        triggerSpawnWindows.removeAll()
        triggerSpawnTabGroups.removeAll()
        for (title, controller) in windows {
            dockController?.releasePane(.spawn(title))
            controller.onClose = nil
            controller.closeSurface()
        }
        for (title, controller) in groups {
            dockController?.releasePane(.spawnTabs(title))
            controller.onClose = nil
            controller.closeSurface()
        }
        suppressSpawnPersistence = false
    }

    private func matchesCaptureEnd(_ expression: String, text: String) -> Bool {
        guard !expression.isEmpty,
              let regex = try? NSRegularExpression(pattern: expression) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private func handleAdvancedGMCP(_ message: GMCPMessage) {
        if recoveryCoordinator.isReplaying {
            _ = try? gmcpState.consume(message)
            return
        }
        activityLabel.stringValue = "GMCP: \(message.package)"
        if gmcpDumpEnabled {
            appendClient("GMCP \(message.package) \(message.payload)")
        }
        if !tileMapsEnabled, message.package.lowercased().hasPrefix("beip.tilemap.") { return }
        if handleWebViewGMCP(message) { return }
        if currentServer?.mcmp == true, message.package.lowercased().hasPrefix("client.media.") {
            do {
                for event in try mediaState.consume(message) { mediaController.apply(event) }
            } catch {
                appendError(error.localizedDescription)
            }
            return
        }
        do {
            for event in try gmcpState.consume(message) {
                switch event {
                case let .statisticsPane(title):
                    guard let pane = gmcpState.statisticsPanes[title] else { continue }
                    let controller: GMCPStatisticsWindowController
                    if let existing = gmcpStatisticsWindows[title] {
                        controller = existing
                    } else {
                        controller = .init(title: title)
                        applyTheme(to: controller)
                        controller.onClose = { [weak self] in self?.gmcpStatisticsWindows.removeValue(forKey: title) }
                        gmcpStatisticsWindows[title] = controller
                    }
                    controller.update(pane)
                    controller.showWindow(self)
                case let .tileMap(name):
                    guard let map = gmcpState.tileMaps[name] else { continue }
                    let controller: TileMapWindowController
                    if let existing = tileMapWindows[name] {
                        controller = existing
                    } else {
                        controller = .init(title: name)
                        applyTheme(to: controller)
                        controller.onClose = { [weak self] in self?.tileMapWindows.removeValue(forKey: name) }
                        controller.onChange = { [weak self] map in
                            guard let self else { return }
                            self.gmcpState.updateTileMap(map)
                            self.preferences.tileMapEdits[self.notesKey, default: [:]][name] = map
                            self.savePreferences()
                        }
                        tileMapWindows[name] = controller
                    }
                    let restored = preferences.tileMapEdits[notesKey]?[name]
                    let displayMap = restored.map {
                        $0.columns == map.columns && $0.rows == map.rows && $0.tiles.count == map.tiles.count ? $0 : map
                    } ?? map
                    if displayMap != map { gmcpState.updateTileMap(displayMap) }
                    controller.update(displayMap)
                    controller.showWindow(self)
                case let .roomInfo(room):
                    activityLabel.stringValue = room.area.isEmpty ? "Room: \(room.name)" : "Room: \(room.name) — \(room.area)"
                    atlasWindow?.integrate(room)
                case let .transmit(outgoing):
                    guard let session else { continue }
                    Task { await session.sendRaw(Self.gmcpFrame(outgoing)) }
                case .avatarsChanged:
                    break
                }
            }
        } catch {
            appendError("GMCP \(message.package): \(error.localizedDescription)")
        }
    }

    private func handleWebViewGMCP(_ message: GMCPMessage) -> Bool {
        let package = message.package.lowercased()
        guard package == "webview.open" || package == "webview.close" else { return false }
        do {
            guard let event = try webViewState.consume(message) else { return false }
            switch event {
            case let .close(id):
                if !id.isEmpty { webViewWindows[id]?.closeSurface() }
            case let .open(request):
                switch currentServer?.gmcpWebViewPolicy ?? .ask {
                case .ignore: return true
                case .allow: openWebView(request, serverRequested: true)
                case .ask:
                    let alert = NSAlert()
                    alert.messageText = "Allow WebView?"
                    alert.informativeText = "The server wants to open:\n\n\(request.permissionSummary)"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Ignore Once")
                    alert.addButton(withTitle: "Allow Once")
                    alert.addButton(withTitle: "Allow All")
                    alert.addButton(withTitle: "Ignore All")
                    switch alert.runModal() {
                    case .alertSecondButtonReturn: openWebView(request, serverRequested: true)
                    case .alertThirdButtonReturn:
                        setCurrentServerWebViewPolicy(.allow)
                        openWebView(request, serverRequested: true)
                    case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
                        setCurrentServerWebViewPolicy(.ignore)
                    default: break
                    }
                }
            }
        } catch {
            appendError("GMCP \(message.package): \(error.localizedDescription)")
        }
        return true
    }

    private func setCurrentServerWebViewPolicy(_ policy: ServerWebViewPolicy) {
        guard var server = currentServer else { return }
        server.gmcpWebViewPolicy = policy
        currentServer = server
        do {
            try profileLibrary.mutate { workspace in
                try workspace.updateServer(id: server.id) { $0.profile.gmcpWebViewPolicy = policy }
            }
        } catch {
            appendError("Could not save WebView policy: \(error.localizedDescription)")
        }
    }

    private func openWebView(_ request: WebViewOpenRequest, serverRequested: Bool = false) {
        let key: String
        if request.id.isEmpty {
            key = "__unnamed_\(nextUnnamedWebViewID)"
            nextUnnamedWebViewID += 1
        } else {
            key = request.id
        }
        if let existing = webViewWindows[key] {
            existing.apply(request, allowsFileNavigation: !serverRequested)
            presentWebView(existing, key: key, request: request)
            saveWebViewPreference(request, serverRequested: serverRequested)
            return
        }
        let controller = WebViewWindowController(id: request.id, request: request, allowsFileNavigation: !serverRequested)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.dockController.undockPane(.webView(key))
            self.webViewWindows = self.webViewWindows.filter { $0.value !== controller }
            self.removeWebViewPreference(id: request.id)
        }
        controller.onCommand = { [weak self, weak controller] command in
            guard let self, let controller else { return nil }
            return try self.handleWebViewBridge(command, from: controller)
        }
        controller.onNavigationError = { [weak self] message in
            self?.appendError("WebView \(request.id.isEmpty ? "(unnamed)" : request.id): \(message)")
        }
        controller.onDockRequest = { [weak self, weak controller] side in
            guard let self, let controller else { return }
            self.dockWebView(controller, key: key, side: side)
        }
        webViewWindows[key] = controller
        controller.applyTheme(preferences.theme.palette)
        presentWebView(controller, key: key, request: request)
        saveWebViewPreference(request, serverRequested: serverRequested)
        if serverRequested { appendClient("Server opened WebView: \(request.permissionSummary)") }
    }

    private func presentWebView(_ controller: WebViewWindowController, key: String, request: WebViewOpenRequest) {
        let pane = WorkspacePaneKind.webView(key)
        if let side = request.dock {
            dockWebView(controller, key: key, side: side)
        } else {
            if dockController.containsPane(pane) { dockController.undockPane(pane) }
            removeWebViewPreference(id: controller.logicalID)
            controller.showFloating(self)
        }
    }

    private func dockWebView(_ controller: WebViewWindowController, key: String, side: WebViewDockSide) {
        let pane = WorkspacePaneKind.webView(key)
        let title = controller.logicalID.isEmpty ? "WebView" : controller.logicalID
        controller.recordDockSide(side)
        dockController.dockPane(
            pane,
            view: controller.contentViewForDocking(),
            title: title,
            side: side,
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(pane)
                controller.recordDockSide(nil)
                self.removeWebViewPreference(id: controller.logicalID)
                controller.showFloating(self)
            }
        )
        saveWebViewPreference(controller.currentRequest, serverRequested: controller.isServerRequested)
    }

    private func saveWebViewPreference(_ request: WebViewOpenRequest, serverRequested: Bool) {
        guard let saved = SavedWebViewPane(request), !serverRequested || currentServer?.gmcpWebViewPolicy == .allow else { return }
        var panes = preferences.webViewPanes[notesKey] ?? []
        panes.removeAll { $0.id == saved.id }
        panes.append(saved)
        preferences.webViewPanes[notesKey] = panes.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        savePreferences()
    }

    private func removeWebViewPreference(id: String) {
        guard !id.isEmpty, var panes = preferences.webViewPanes[notesKey] else { return }
        panes.removeAll { $0.id == id }
        if panes.isEmpty { preferences.webViewPanes.removeValue(forKey: notesKey) }
        else { preferences.webViewPanes[notesKey] = panes }
        savePreferences()
    }

    private func restoreWebViewPreferences() {
        guard currentServer?.gmcpWebViewPolicy == .allow else { return }
        for pane in preferences.webViewPanes[notesKey] ?? [] {
            openWebView(pane.request, serverRequested: true)
        }
    }

    private func handleWebViewBridge(_ command: WebViewBridgeCommand, from controller: WebViewWindowController) throws -> Any? {
        switch command {
        case .close: controller.closeSurface(); return true
        case .isConnected: return connectionStateText == "Connected"
        case let .send(text, processAliases):
            if processAliases { processAliasedInput(text) } else { sendToSession(text) }
            return true
        case let .receive(text):
            guard let session else { throw WebViewClientError.notConnected }
            Task { await session.receive(text) }
            return true
        case let .display(text):
            appendClient(text)
            return true
        case let .sendGMCP(package, json):
            guard let session else { throw WebViewClientError.notConnected }
            guard !package.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebViewClientError.invalidPackage }
            Task { await session.sendRaw(Self.gmcpFrame(.init(package: package, payload: json))) }
            return true
        case let .processAliases(text):
            guard !aliasGroups.isEmpty else { return text }
            return try AliasEngine.process(text, groups: aliasGroups, variables: variables).text
        case let .addToInputHistory(text): input.addToHistory(text); return true
        case let .property(name):
            switch name.lowercased() {
            case "worldname": return currentServer?.name
            case "charactername": return currentCharacter?.name
            case "puppetname": return nil
            case "id": return controller.logicalID
            default: return nil
            }
        }
    }

    private func closeWebViews() {
        let values = Array(webViewWindows)
        webViewWindows.removeAll()
        for (key, controller) in values {
            dockController?.releasePane(.webView(key))
            controller.onClose = nil
            controller.closeSurface()
        }
    }

    private func handleMCP(_ message: MCPMessage) {
        activityLabel.stringValue = "MCP: \(message.fullName)"
        switch message.package.lowercased() {
        case "dns-com-awns-status":
            guard let text = message[parameter: "text"] else {
                appendError("MCP status message was missing required parameter 'text'")
                return
            }
            let controller: MCPStatusWindowController
            if let existing = mcpStatusWindow {
                controller = existing
            } else {
                controller = .init()
                controller.applyTheme(preferences.theme.palette)
                controller.onClose = { [weak self] in self?.mcpStatusWindow = nil }
                mcpStatusWindow = controller
            }
            controller.update(text)
            controller.showWindow(self)
        case "dns-org-mud-moo-simpleedit":
            showMCPSimpleEdit(message)
        default:
            appendClient("MCP \(message.fullName)")
        }
    }

    private func showMCPSimpleEdit(_ message: MCPMessage) {
        guard let reference = message[parameter: "reference"],
              let type = message[parameter: "type"],
              let name = message[parameter: "name"] else {
            appendError("MCP SimpleEdit message was missing reference, type, or name")
            return
        }
        let text = message.values(for: "content")?.joined(separator: "\n") ?? message[parameter: "content"] ?? ""
        let state = SimpleEditUploadState(reference: reference, type: type, original: text)
        let upload: (String) -> Void = { [weak self, state] value in
            guard state.lastUploaded != value else { return }
            state.lastUploaded = value
            self?.sendMCPSimpleEdit(value, state: state)
        }
        let controller = EditWindowController(title: name, text: text, checksSpelling: false, onSend: upload)
        controller.onClose = { [weak self, weak controller, state] in
            guard let self, let controller else { return }
            let value = controller.editor.string
            if value != state.original, value != state.lastUploaded { upload(value) }
            self.editWindows.removeAll { $0 === controller }
        }
        editWindows.append(controller)
        controller.applyTheme(preferences.theme.palette)
        controller.showWindow(self)
        if let owner = window, let child = controller.window { owner.addChildWindow(child, ordered: .above) }
        controller.window?.makeKeyAndOrderFront(self)
        appendClient("mcp-simpleedit Editing: \"\(name)\" Type: \(type)")
    }

    private func sendMCPSimpleEdit(_ text: String, state: SimpleEditUploadState) {
        guard let session else { appendError("MCP SimpleEdit cannot upload while disconnected"); return }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        let message = MCPMessage(
            package: "dns-org-mud-moo-simpleedit",
            message: "set",
            parameters: ["reference": state.reference, "type": state.type],
            multiline: lines.isEmpty ? [:] : ["content": lines]
        )
        Task { await session.sendMCP(message) }
        appendClient("mcp-simpleedit Changes uploaded")
    }

    private func ensureAtlasWindow() -> AtlasWindowController {
        if let atlasWindow { return atlasWindow }
        let controller = AtlasWindowController()
        applyTheme(to: controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller, self.atlasWindow === controller else { return }
            if !self.preservingAtlasPlacement {
                self.dockController.undockPane(.atlas)
            }
            self.atlasWindow = nil
            if !self.suppressAtlasPersistence {
                self.preferences.atlasSurfaces.removeValue(forKey: self.notesKey)
                self.savePreferences()
            }
        }
        controller.onDockRequest = { [weak self, weak controller] side in
            guard let self, let controller else { return }
            self.dockAtlas(controller, side: side)
        }
        controller.onSendCommands = { [weak self] commands in
            commands.forEach { self?.processInput($0) }
        }
        controller.onStateChange = { [weak self] state in
            guard let self, !self.suppressAtlasPersistence else { return }
            self.preferences.atlasSurfaces[self.notesKey] = state
            self.savePreferences()
        }
        atlasWindow = controller
        if let owner = window, let child = controller.window { owner.addChildWindow(child, ordered: .above) }
        return controller
    }

    private func presentAtlas(_ controller: AtlasWindowController) {
        guard !controller.isDocked else {
            controller.focusSurface()
            return
        }
        let pane = WorkspacePaneKind.atlas
        if dockController.containsPane(pane) {
            let view = controller.contentViewForDocking()
            if dockController.restorePane(
                pane,
                view: view,
                title: "Atlas",
                onUndock: { [weak self, weak controller] in
                    guard let self, let controller else { return }
                    self.dockController.undockPane(pane)
                    controller.showFloating(self)
                }
            ) {
                return
            }
            controller.showFloating(self)
            return
        }
        controller.showFloating(self)
    }

    private func dockAtlas(_ controller: AtlasWindowController, side: WebViewDockSide) {
        let pane = WorkspacePaneKind.atlas
        dockController.dockPane(
            pane,
            view: controller.contentViewForDocking(),
            title: "Atlas",
            side: side,
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(pane)
                controller.showFloating(self)
            }
        )
    }

    private func saveAtlasSurfacePreferences() {
        guard !suppressPersistence, let atlasWindow else { return }
        preferences.atlasSurfaces[notesKey] = atlasWindow.surfacePreferences
        savePreferences()
    }

    private func restoreAtlasSurfacePreferences() {
        guard let state = preferences.atlasSurfaces[notesKey] else { return }
        let controller = ensureAtlasWindow()
        do {
            try controller.restore(state)
            presentAtlas(controller)
        } catch {
            preferences.atlasSurfaces.removeValue(forKey: notesKey)
            savePreferences()
            appendError("Atlas restore failed: \(error.localizedDescription)")
        }
    }

    private func closeAtlasSurface(preservingDockPlacement: Bool = false) {
        guard let controller = atlasWindow else { return }
        suppressAtlasPersistence = true
        preservingAtlasPlacement = preservingDockPlacement
        if preservingDockPlacement, controller.isDocked {
            dockController.releasePane(.atlas)
        }
        controller.closeSurface()
        atlasWindow = nil
        preservingAtlasPlacement = false
        suppressAtlasPersistence = false
    }

    private func appendError(_ text: String) {
        let style = TextStyle(foreground: .init(red: 255, green: 80, blue: 80))
        let line = RenderedLine(
            text: text,
            runs: [.init(range: 0..<text.utf16.count, style: style)],
            source: .client
        )
        recordRecovery(.renderedLine(line), at: line.timestamp)
        output.append(line)
    }
}

private enum WebViewClientError: LocalizedError {
    case notConnected
    case invalidPackage

    var errorDescription: String? {
        switch self {
        case .notConnected: "WebView client is not connected"
        case .invalidPackage: "WebView GMCP package is empty"
        }
    }
}

@MainActor
private final class VerticalWindowResizeHandle: NSView {
    private var initialWindowFrame = NSRect.zero
    private var initialMouseLocation = NSPoint.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("Resize window vertically")
        setAccessibilityIdentifier("mainWindowVerticalResizeHandle")
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        initialWindowFrame = window.frame
        initialMouseLocation = NSEvent.mouseLocation
        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if nextEvent.type == .leftMouseUp { break }
            resizeWindow(to: NSEvent.mouseLocation)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        resizeWindow(to: NSEvent.mouseLocation)
    }

    private func resizeWindow(to mouseLocation: NSPoint) {
        guard let window, initialWindowFrame.height > 0 else { return }
        let delta = mouseLocation.y - initialMouseLocation.y
        let minimumHeight = max(32, window.frame.height - window.contentLayoutRect.height)
        let height = max(minimumHeight, initialWindowFrame.height - delta)
        let frame = NSRect(
            x: initialWindowFrame.minX,
            y: initialWindowFrame.maxY - height,
            width: initialWindowFrame.width,
            height: height
        )
        window.setFrame(frame, display: true)
        NSAccessibility.post(element: window, notification: .windowMoved)
        NSAccessibility.post(element: window, notification: .windowResized)
        if ProcessInfo.processInfo.environment["BEIPMU_UI_TESTING"] == "1" {
            window.setAccessibilityValue("\(Int(window.frame.width))x\(Int(window.frame.height))")
            NSAccessibility.post(element: window, notification: .valueChanged)
        }
    }
}

@MainActor
final class EmbeddedHelpWindowController: NSWindowController {
    private let search = NSSearchField()
    private let textView: NSTextView

    init() {
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = "BeipMU Help"
        RuntimeStateContext.setFrameAutosaveName("BeipMU.EmbeddedHelp", for: window)
        window.setAccessibilityIdentifier("embeddedHelpWindow")
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.setAccessibilityIdentifier("embeddedHelpText")
        search.placeholderString = "Find a command"
        search.setAccessibilityIdentifier("embeddedHelpSearch")
        search.target = self
        search.action = #selector(searchChanged)
        let root = NSStackView(views: [search, scroll])
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = .init(top: 10, left: 10, bottom: 10, right: 10)
        window.contentView = root
    }

    required init?(coder: NSCoder) { nil }

    func show(topic: String?) {
        search.stringValue = topic ?? ""
        updateText(topic)
    }

    @objc private func searchChanged() { updateText(search.stringValue) }

    private func updateText(_ topic: String?) {
        let query = topic?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let lines = CommandRegistry.commandHelp.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if query.isEmpty {
            textView.string = CommandRegistry.commandHelp
        } else {
            let matches = lines.filter { $0.lowercased().contains(query) }
            textView.string = matches.isEmpty ? "No command help matches ‘\(query)’." : matches.joined(separator: "\n")
        }
        textView.scrollToBeginningOfDocument(nil)
    }
}

private extension String {
    var safeFilename: String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let value = components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "-")
        return value.isEmpty ? "Session" : value
    }
}

private extension NSColor {
    convenience init?(htmlColor value: String) {
        let named: [String: NSColor] = [
            "black": .black, "white": .white, "red": .systemRed, "green": .systemGreen,
            "blue": .systemBlue, "yellow": .systemYellow, "orange": .systemOrange,
            "purple": .systemPurple, "pink": .systemPink, "gray": .systemGray,
            "grey": .systemGray, "cyan": .systemCyan, "teal": .systemTeal,
        ]
        if let color = named[value.lowercased()] {
            self.init(cgColor: color.cgColor)
            return
        }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((number >> 16) & 0xff) / 255,
            green: CGFloat((number >> 8) & 0xff) / 255,
            blue: CGFloat(number & 0xff) / 255,
            alpha: 1
        )
    }
}
