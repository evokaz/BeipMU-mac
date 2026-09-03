import AppKit
import BeipCore

@MainActor
private final class OutputContainerView: NSSplitView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

@MainActor
private final class OutputClipView: NSClipView {
    var onScroll: (() -> Void)?
    var onUserScroll: ((_ previousY: CGFloat, _ currentY: CGFloat) -> Void)?

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: newOrigin)
        onScroll?()
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(newOrigin)
        onScroll?()
    }

    override func scrollWheel(with event: NSEvent) {
        let previousY = bounds.origin.y
        super.scrollWheel(with: event)
        // NSScrollView can apply the final wheel delta after this override
        // returns. Inspect the viewport on the next main-loop turn so the
        // reported destination includes that movement.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onUserScroll?(previousY, self.bounds.origin.y)
        }
    }
}

@MainActor
private final class OutputScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }
}

@MainActor
private final class OutputScroller: NSScroller {
    var onUserScrollEnded: ((_ previousY: CGFloat, _ currentY: CGFloat) -> Void)?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let previousY = enclosingScrollView?.contentView.bounds.origin.y
        super.mouseDown(with: event)
        guard let previousY,
              let currentY = enclosingScrollView?.contentView.bounds.origin.y else { return }
        onUserScrollEnded?(previousY, currentY)
    }
}

/// Owns one unread cycle for all output surfaces belonging to a session.
/// Membership is weak so closing a floating or docked surface cannot retain it
/// (or clear the cycle of the remaining surfaces).
@MainActor
final class SharedUnreadBoundaryCoordinator {
    private final class Member {
        weak var output: OutputTextView?

        init(_ output: OutputTextView) { self.output = output }
    }

    private var members: [Member] = []
    private var positions: [ObjectIdentifier: Int] = [:]
    private var dismissalTimer: Timer?
    private(set) var isCycleActive = false
    private static let dismissalInterval: TimeInterval = 60

    func register(_ output: OutputTextView) {
        pruneMembers()
        guard !members.contains(where: { $0.output === output }) else { return }
        members.append(Member(output))
        guard isCycleActive else { return }
        positions[ObjectIdentifier(output)] = output.logicalLineCountForUnreadBoundary
        output.applyUnreadBoundaryPositionFromCoordinator(
            output.showsNewContentMarkers ? output.logicalLineCountForUnreadBoundary : nil
        )
        updateDismissalTimer()
    }

    func unregister(_ output: OutputTextView) {
        members.removeAll { $0.output == nil || $0.output === output }
        positions.removeValue(forKey: ObjectIdentifier(output))
        updateDismissalTimer()
    }

    func willAppend(to output: OutputTextView) {
        guard output.showsNewContentMarkers, !output.isFocusedForUnreadBoundary else { return }
        if !isCycleActive { activate() }
    }

    func settingsChanged(for output: OutputTextView, showsMarkers: Bool) {
        guard isCycleActive else {
            output.applyUnreadBoundaryPositionFromCoordinator(nil)
            return
        }
        let key = ObjectIdentifier(output)
        positions[key] = min(max(0, positions[key] ?? output.logicalLineCountForUnreadBoundary), output.logicalLineCountForUnreadBoundary)
        output.applyUnreadBoundaryPositionFromCoordinator(
            showsMarkers ? positions[key] : nil
        )
    }

    func focusChanged(for output: OutputTextView) {
        guard members.contains(where: { $0.output === output }) else { return }
        updateDismissalTimer()
    }

    func userDidScrollToEnd(from output: OutputTextView) {
        guard isCycleActive,
              members.contains(where: { $0.output === output }) else { return }
        clear()
    }

    func outputDidRemoveFirst(_ output: OutputTextView, count: Int) {
        guard isCycleActive, count > 0 else { return }
        let key = ObjectIdentifier(output)
        positions[key] = max(0, (positions[key] ?? 0) - count)
        clampAndApply(output)
    }

    func outputDidRemoveLast(_ output: OutputTextView) {
        guard isCycleActive else { return }
        clampAndApply(output)
    }

    func outputDidRemoveLine(_ output: OutputTextView, at index: Int) {
        guard isCycleActive else { return }
        let key = ObjectIdentifier(output)
        let oldPosition = positions[key] ?? 0
        positions[key] = oldPosition > index ? oldPosition - 1 : oldPosition
        clampAndApply(output)
    }

    func outputDidClear(_ output: OutputTextView) {
        guard isCycleActive else {
            output.applyUnreadBoundaryPositionFromCoordinator(nil)
            return
        }
        positions[ObjectIdentifier(output)] = 0
        output.applyUnreadBoundaryPositionFromCoordinator(output.showsNewContentMarkers ? 0 : nil)
    }

    /// Rebuilds can combine a prefix eviction with unrelated appends. Use the
    /// previous retained IDs to preserve the insertion position without tying
    /// the boundary itself to any one line.
    func outputDidRebuild(_ output: OutputTextView, previousLines: [RenderedLine]) {
        guard isCycleActive else { return }
        let currentLines = output.retainedLines
        let key = ObjectIdentifier(output)
        var position = positions[key] ?? 0
        if let first = currentLines.first,
           let prefixCount = previousLines.firstIndex(where: { $0.id == first.id }) {
            position = max(0, position - prefixCount)
        } else if currentLines.isEmpty {
            position = 0
        }
        positions[key] = min(max(0, position), currentLines.count)
        clampAndApply(output)
    }

    func clear() {
        isCycleActive = false
        dismissalTimer?.invalidate()
        dismissalTimer = nil
        pruneMembers()
        positions.removeAll(keepingCapacity: true)
        members.compactMap(\.output).forEach {
            $0.applyUnreadBoundaryPositionFromCoordinator(nil)
        }
    }

    private func activate() {
        pruneMembers()
        isCycleActive = true
        positions.removeAll(keepingCapacity: true)
        for output in members.compactMap(\.output) {
            let position = output.logicalLineCountForUnreadBoundary
            positions[ObjectIdentifier(output)] = position
            output.applyUnreadBoundaryPositionFromCoordinator(
                output.showsNewContentMarkers ? position : nil
            )
        }
        updateDismissalTimer()
    }

    private func clampAndApply(_ output: OutputTextView) {
        let position = min(max(0, positions[ObjectIdentifier(output)] ?? 0), output.logicalLineCountForUnreadBoundary)
        positions[ObjectIdentifier(output)] = position
        output.applyUnreadBoundaryPositionFromCoordinator(
            output.showsNewContentMarkers ? position : nil
        )
    }

    private func updateDismissalTimer() {
        pruneMembers()
        guard isCycleActive,
              members.contains(where: { $0.output?.isFocusedForUnreadBoundary == true }) else {
            dismissalTimer?.invalidate()
            dismissalTimer = nil
            return
        }
        guard dismissalTimer == nil else { return }
        dismissalTimer = Timer.scheduledTimer(
            withTimeInterval: Self.dismissalInterval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clear() }
        }
    }

    private func pruneMembers() {
        let liveIDs = Set(members.compactMap { $0.output.map(ObjectIdentifier.init) })
        members.removeAll { $0.output == nil }
        positions = positions.filter { liveIDs.contains($0.key) }
    }
}

/// Coordinates retained rendered lines with the line-virtualized Core Text
/// view. The document view measures retained rows but only draws the rows
/// intersecting its clip view, keeping history size independent of paint cost.
@MainActor
final class OutputTextView: NSObject {
    private static let outputBatchLineLimit = 256
    private static let outputBatchFrameInterval: Duration = .milliseconds(16)
    private static let outputBatchTimeBudgetNanoseconds: UInt64 = 6_000_000
    private static let smoothScrollInterval: Duration = .milliseconds(120)

    let containerView: NSSplitView
    private let scrollView: NSScrollView
    var onAction: ((LinkAction) -> Void)?
    var onPauseChange: ((Bool, Int) -> Void)?
    var onInteractionCompleted: (() -> Void)? {
        didSet {
            outputView.onInteractionCompleted = onInteractionCompleted
            secondaryOutputView?.onInteractionCompleted = onInteractionCompleted
        }
    }
    var onContextMenu: ((NSEvent) -> NSMenu?)? {
        didSet {
            outputView.onContextMenu = onContextMenu
            secondaryOutputView?.onContextMenu = onContextMenu
        }
    }

    private let outputView: VirtualizedOutputView
    private var secondaryOutputView: VirtualizedOutputView?
    private var blinkInterval: TimeInterval = 0.55
    private var secondaryScrollView: NSScrollView?
    private var defaultForeground = NSColor(calibratedWhite: 0.9, alpha: 1)
    private var defaultBackground = NSColor(calibratedWhite: 0.05, alpha: 1)
    private var themePalette = WorkspaceThemeSettings().palette
    private var defaultFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var timestampFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var cellWidth: CGFloat = 1
    private var cellHeight: CGFloat = 1
    private let timestampFormatter: DateFormatter
    private let tooltipDateFormatter: DateFormatter
    private var history = OutputHistory(limit: 10_000)
    private var lineContentRanges: [UUID: NSRange] = [:]
    private var currentMatchIndex: Int?
    private var currentSearchSignature: SearchSignature?
    private var settings = TextWindowSettings()
    private var automaticMarkerID: UUID?
    private var unterminatedLineID: UUID?
    private var newContentBoundaryPosition: Int?
    private var windowIsFocused = true
    private var unreadBoundaryCoordinator = SharedUnreadBoundaryCoordinator()
    private var programmaticScrollGeneration = 0
    private var isPerformingProgrammaticScroll = false
    private var rebuildGeneration = 0
    private struct PendingOutputDescriptor {
        var line: RenderedLine
        var terminator: String
        var lineIndex: Int
        var evictionEpoch: Int
    }

    private var pendingOutputDescriptors: [PendingOutputDescriptor] = []
    private var pendingOutputHead = 0
    private var pendingPrefixEvictionCount = 0
    private var pendingMarkerChanges: [UUID: Bool] = [:]
    private var pendingBoundaryUpdate = false
    private var pendingFlushTask: Task<Void, Never>?
    private var isQueueingOutputMutation = false
    private var pendingEvictionEpoch = 0
    private var isDrainingOutputSynchronously = false
    private var tailAnimationTask: Task<Void, Never>?
    private var tailQuietTask: Task<Void, Never>?
    private var tailAnimationGeneration = 0
    private var tailQuietGeneration = 0
    private var tailAnimationInFlight = false
    private var tailCatchUpMode = false
    private(set) var outputSliceCountForTesting = 0
    private(set) var maximumOutputLinesPerSliceForTesting = 0
    private(set) var catchUpScrollCountForTesting = 0
    private weak var observedWindow: NSWindow?
    private lazy var webURLDetector: NSDataDetector = {
        try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private struct SearchSignature: Equatable {
        var query: String
        var options: OutputSearchOptions
        var backwards: Bool
    }

    private var showsTimestamps = false
    private var usesFanFoldBackgrounds = false
    var showsInlineImagePreviews = false {
        didSet {
            guard showsInlineImagePreviews != oldValue else { return }
            flushPendingOutput()
            outputView.showsInlineImagePreviews = showsInlineImagePreviews
            secondaryOutputView?.showsInlineImagePreviews = showsInlineImagePreviews
            rebuild(preservingScrollPosition: true)
        }
    }
    var isPaused: Bool { history.isPaused }
    var pendingLineCount: Int { history.pendingLines.count }
    var visibleLineCount: Int { history.count }
    var isSplit: Bool { secondaryOutputView != nil }
    var renderedLineCount: Int { outputView.itemCount }
    var visiblePaintCandidateCount: Int {
        outputView.visibleItemCount(in: scrollView.contentView.bounds)
    }
    var retainedLines: [RenderedLine] { history.lines }
    var visibleWindowLines: [RenderedLine] {
        flushPendingOutput()
        let lines = history.lines
        guard let id = outputView.firstVisibleItemID,
              let index = lines.firstIndex(where: { $0.id == id }) else { return lines }
        return Array(lines[index...])
    }
    var historyLimit: Int {
        get { history.limit }
        set {
            flushPendingOutput()
            let previousLines = history.lines
            history.limit = newValue
            rebuild(preservingScrollPosition: true, previousLines: previousLines)
        }
    }

    var hasSelectedLine: Bool { outputView.selectedItemID != nil }
    var appliedSettingsForTesting: TextWindowSettings { settings }
    var primaryOutputViewForTesting: VirtualizedOutputView { outputView }
    var primaryScrollViewForTesting: NSScrollView { scrollView }
    var secondaryScrollViewForTesting: NSScrollView? { secondaryScrollView }
    var newContentBoundaryIDForTesting: UUID? {
        guard let position = newContentBoundaryPosition,
              history.lines.indices.contains(position) else { return nil }
        return history.lines[position].id
    }
    var newContentBoundaryPositionForTesting: Int? { newContentBoundaryPosition }
    var rebuildGenerationForTesting: Int { rebuildGeneration }
    var pendingOutputLineCountForTesting: Int { pendingOutputDescriptorCount }
    var pendingOutputItemCountForTesting: Int { pendingOutputDescriptorCount }
    var batchMutationCountForTesting: Int { outputView.batchMutationCountForTesting }
    var sliceCountForTesting: Int { outputSliceCountForTesting }
    var renderSliceCountForTesting: Int { outputSliceCountForTesting }
    var maxLinesPerSliceForTesting: Int { maximumOutputLinesPerSliceForTesting }
    var maxOutputLinesPerSliceForTesting: Int { maximumOutputLinesPerSliceForTesting }
    var maximumLinesPerSliceForTesting: Int { maximumOutputLinesPerSliceForTesting }
    var catchUpScrollsForTesting: Int { catchUpScrollCountForTesting }
    var blinkIntervalForTesting: TimeInterval { blinkInterval }

    func applyBlinkInterval(_ interval: TimeInterval) {
        blinkInterval = interval
        outputView.blinkInterval = interval
        secondaryOutputView?.blinkInterval = interval
    }

    func reportUserScrollForTesting(from previousY: CGFloat, to currentY: CGFloat) {
        acknowledgeUserScroll(in: scrollView, from: previousY, to: currentY)
    }

    var logicalLineCountForUnreadBoundary: Int { history.count }
    var showsNewContentMarkers: Bool { settings.showsNewContentMarkers }
    var isFocusedForUnreadBoundary: Bool { windowIsFocused }

    private var pendingOutputDescriptorCount: Int {
        max(0, pendingOutputDescriptors.count - pendingOutputHead)
    }

    func applySettings(_ suppliedSettings: TextWindowSettings) {
        flushPendingOutput()
        resetTailScrollTracking()
        settings = suppliedSettings.normalized
        unreadBoundaryCoordinator.settingsChanged(for: self, showsMarkers: settings.showsNewContentMarkers)
        let foreground = NSColor(hexString: settings.foregroundHex) ?? themePalette.foreground
        let background = NSColor(hexString: settings.backgroundHex) ?? themePalette.background
        defaultForeground = settings.invertBrightness ? foreground.invertingBrightness : foreground
        defaultBackground = settings.invertBrightness ? background.invertingBrightness : background
        refreshFontCaches()
        let previousLines = history.lines
        history.limit = settings.historyLimit
        showsTimestamps = settings.showsTime || settings.showsDate
        usesFanFoldBackgrounds = settings.usesFanFoldBackgrounds
        timestampFormatter.dateFormat = timestampFormat
        scrollView.backgroundColor = defaultBackground
        secondaryScrollView?.backgroundColor = defaultBackground
        configure(view: outputView)
        if let secondaryOutputView { configure(view: secondaryOutputView) }
        rebuild(preservingScrollPosition: true, previousLines: previousLines)
    }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        flushPendingOutput()
        resetTailScrollTracking()
        // Text-window colors are independently configurable. The workspace theme
        // still owns surrounding window chrome and supplies legacy defaults.
        themePalette = palette
        let foreground = NSColor(hexString: settings.foregroundHex) ?? palette.foreground
        let background = NSColor(hexString: settings.backgroundHex) ?? palette.background
        defaultForeground = settings.invertBrightness ? foreground.invertingBrightness : foreground
        defaultBackground = settings.invertBrightness ? background.invertingBrightness : background
        scrollView.backgroundColor = defaultBackground
        secondaryScrollView?.backgroundColor = defaultBackground
        configure(view: outputView)
        if let secondaryOutputView { configure(view: secondaryOutputView) }
        rebuild(preservingScrollPosition: true)
    }

    func capturedText(lineCount: Int, skipping skipCount: Int) -> String {
        guard lineCount > 0 else { return "" }
        let lines = history.lines
        let end = max(0, lines.count - max(0, skipCount))
        let start = max(0, end - lineCount)
        guard start < end else { return "" }
        return lines[start..<end].map(\.text).joined(separator: "\n") + "\n"
    }

    override init() {
        timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "HH:mm:ss"
        tooltipDateFormatter = DateFormatter()
        tooltipDateFormatter.locale = .autoupdatingCurrent
        tooltipDateFormatter.dateStyle = .medium
        tooltipDateFormatter.timeStyle = .medium
        outputView = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 900, height: 1))
        scrollView = OutputScrollView()
        scrollView.contentView = OutputClipView()
        scrollView.documentView = outputView
        scrollView.hasVerticalScroller = true
        scrollView.verticalScroller = OutputScroller()
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        Self.fitDocumentWidth(outputView, in: scrollView)
        let container = OutputContainerView()
        containerView = container
        containerView.isVertical = false
        containerView.dividerStyle = .thin
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addArrangedSubview(scrollView)
        containerView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        containerView.setContentHuggingPriority(.defaultLow, for: .vertical)
        containerView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let preferredScrollHeight = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        preferredScrollHeight.priority = .defaultHigh
        preferredScrollHeight.isActive = true
        super.init()
        unreadBoundaryCoordinator.register(self)
        container.onWindowChange = { [weak self] window in self?.observeWindow(window) }
        scrollView.contentView.postsBoundsChangedNotifications = true
        addScrollObserver(for: scrollView)
        observeWindow(container.window)
        refreshFontCaches()
        outputView.onLink = { [weak self] url in self?.perform(url: url) }
        outputView.onPageUp = { [weak self] in self?.performPageUp() ?? false }
        outputView.onPageDown = { [weak self] in self?.performPageDown() ?? false }
        outputView.onSelectionCompleted = { [weak self] in self?.copySelectionAsPlainText() }
        outputView.onInteractionWillBegin = { [weak self] in self?.flushPendingOutput() }
        outputView.onUserScrollToEnd = { [weak self] in
            self?.clearNewContentBoundaryIfAtBottom(in: self?.scrollView)
        }
        outputView.showsInlineImagePreviews = showsInlineImagePreviews
    }

    func setUnreadBoundaryCoordinator(_ coordinator: SharedUnreadBoundaryCoordinator) {
        guard unreadBoundaryCoordinator !== coordinator else { return }
        unreadBoundaryCoordinator.unregister(self)
        unreadBoundaryCoordinator = coordinator
        coordinator.register(self)
    }

    func unregisterFromUnreadBoundaryCoordinator() {
        unreadBoundaryCoordinator.unregister(self)
    }

    func applyUnreadBoundaryPositionFromCoordinator(_ position: Int?) {
        newContentBoundaryPosition = position.map { min(max(0, $0), history.count) }
        guard pendingOutputDescriptorCount == 0, !isQueueingOutputMutation else {
            pendingBoundaryUpdate = true
            return
        }
        pendingBoundaryUpdate = false
        outputView.setNewContentBoundary(position: newContentBoundaryPosition)
        secondaryOutputView?.setNewContentBoundary(position: newContentBoundaryPosition)
    }

    func clear() {
        discardPendingOutput()
        history.clear()
        lineContentRanges.removeAll(keepingCapacity: true)
        unterminatedLineID = nil
        performProgrammaticScroll {
            outputView.removeAll()
            secondaryOutputView?.removeAll()
        }
        currentMatchIndex = nil
        currentSearchSignature = nil
        automaticMarkerID = nil
        // Clearing history acknowledges nothing. If this output belongs to an
        // active shared cycle its boundary simply moves to the empty end.
        unreadBoundaryCoordinator.outputDidClear(self)
        notifyPauseChange()
        NSAccessibility.post(element: outputView, notification: .valueChanged)
    }

    func removeLastLine() {
        flushPendingOutput()
        guard let line = history.removeLast() else { return }
        lineContentRanges.removeValue(forKey: line.id)
        if unterminatedLineID == line.id { unterminatedLineID = nil }
        if automaticMarkerID == line.id { automaticMarkerID = nil }
        performProgrammaticScroll {
            outputView.removeLast()
            secondaryOutputView?.removeLast()
        }
        unreadBoundaryCoordinator.outputDidRemoveLast(self)
        currentMatchIndex = nil
        notifyPauseChange()
    }

    func removeSelectedLine() {
        flushPendingOutput()
        guard let id = outputView.selectedItemID,
              let removedIndex = history.lines.firstIndex(where: { $0.id == id }),
              history.remove(id: id) != nil else {
            NSSound.beep()
            return
        }
        lineContentRanges.removeValue(forKey: id)
        if unterminatedLineID == id { unterminatedLineID = nil }
        if automaticMarkerID == id { automaticMarkerID = nil }
        // A selected line at/after the boundary does not move it; lines before
        // the insertion point shift that point back by one.
        unreadBoundaryCoordinator.outputDidRemoveLine(self, at: removedIndex)
        rebuild(preservingScrollPosition: true)
    }

    func setPaused(_ paused: Bool) {
        flushPendingOutput()
        guard paused != history.isPaused else { return }
        if paused {
            history.pause()
        } else {
            let previousLines = history.lines
            if !history.pendingLines.isEmpty {
                unreadBoundaryCoordinator.willAppend(to: self)
            }
            history.resume()
            rebuild(scrollToEnd: true, previousLines: previousLines)
        }
        notifyPauseChange()
    }

    func togglePaused() { setPaused(!history.isPaused) }

    var terminalSize: (columns: UInt16, rows: UInt16) {
        let contentSize = scrollView.contentSize
        let columns = max(1, min(Int(UInt16.max), Int((contentSize.width - 18) / cellWidth)))
        let rows = max(1, min(Int(UInt16.max), Int((contentSize.height - 14) / cellHeight)))
        return (UInt16(columns), UInt16(rows))
    }

    func append(_ line: RenderedLine, terminator: String = "\n") {
        isQueueingOutputMutation = true
        defer { isQueueingOutputMutation = false }
        if !history.isPaused { unreadBoundaryCoordinator.willAppend(to: self) }
        let expectedRemovalCount = max(0, history.count + 1 - history.limit)
        let removedIDs = history.oldestLineIDs(expectedRemovalCount)
        let removedCount = history.append(line)
        if terminator.isEmpty {
            unterminatedLineID = line.id
        } else if unterminatedLineID == line.id {
            unterminatedLineID = nil
        }
        guard !history.isPaused else { notifyPauseChange(); return }

        var evictedAutomaticMarkerID: UUID?
        if removedCount > 0 {
            removedIDs.forEach { lineContentRanges.removeValue(forKey: $0) }
            if let unterminatedLineID, removedIDs.contains(unterminatedLineID) {
                self.unterminatedLineID = nil
            }
            unreadBoundaryCoordinator.outputDidRemoveFirst(self, count: removedCount)
            if let automaticMarkerID, removedIDs.contains(automaticMarkerID) {
                self.automaticMarkerID = nil
                evictedAutomaticMarkerID = automaticMarkerID
            }
        }
        // Keep only value-type source data in the pending queue. Attributed
        // strings, link detection, preview discovery, and Core Text sizing are
        // intentionally deferred to the frame-budgeted drain.
        enqueue(
            .init(
                line: line,
                terminator: terminator,
                lineIndex: history.count - 1,
                evictionEpoch: pendingEvictionEpoch
            ),
            removingFirst: removedCount,
            removedIDs: removedIDs
        )
        if let evictedAutomaticMarkerID {
            pendingMarkerChanges[evictedAutomaticMarkerID] = false
        }
        if settings.scrollsToBottomOnNewText {
            clearAutomaticMarker()
        } else if settings.showsNewContentMarkers, automaticMarkerID == nil {
            automaticMarkerID = line.id
            queueMarkerChange(itemID: line.id, marked: true)
        }
        currentMatchIndex = nil
        if settings.scrollsToBottomOnNewText {
            noteLiveOutputArrived()
        }
        schedulePendingOutputFlushIfNeeded()
    }

    @discardableResult
    func find(
        _ query: String,
        options: OutputSearchOptions = .init(),
        backwards: Bool = false
    ) throws -> Bool {
        flushPendingOutput()
        let matches = try history.search(query, options: options).compactMap { match -> (UUID, NSRange)? in
            guard let content = lineContentRanges[match.lineID] else { return nil }
            return (
                match.lineID,
                NSRange(location: content.location + match.range.lowerBound, length: match.range.count)
            )
        }
        guard !matches.isEmpty else {
            NSSound.beep()
            currentMatchIndex = nil
            currentSearchSignature = nil
            return false
        }

        let signature = SearchSignature(query: query, options: options, backwards: backwards)
        let index: Int
        if currentSearchSignature == signature, let currentMatchIndex {
            index = backwards
                ? (currentMatchIndex - 1 + matches.count) % matches.count
                : (currentMatchIndex + 1) % matches.count
        } else {
            index = backwards ? matches.count - 1 : 0
        }
        currentSearchSignature = signature
        currentMatchIndex = index
        _ = outputView.select(itemID: matches[index].0, range: matches[index].1)
        return true
    }

    func copySelectionAsPlainText() {
        flushPendingOutput()
        copySelectionAsPlainText(from: outputView)
    }

    private func copySelectionAsPlainText(from view: VirtualizedOutputView) {
        flushPendingOutput()
        guard let selected = view.selectedString(), !selected.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected, forType: .string)
        showSelectionCopiedPopupIfNeeded()
    }

    func copySelectionAsHTML() {
        flushPendingOutput()
        guard let selected = outputView.selectedAttributedString(), selected.length > 0,
              let data = try? selected.data(
                from: NSRange(location: 0, length: selected.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
              ) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .html)
        NSPasteboard.general.setString(selected.string, forType: .string)
        showSelectionCopiedPopupIfNeeded()
    }

    func copyScreenToClipboard() {
        flushPendingOutput()
        let text = visibleWindowLines.map(\.text).joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showSelectionCopiedPopupIfNeeded()
    }

    func selectAll() {
        flushPendingOutput()
        outputView.selectAllContent()
    }

    func toggleSplit() {
        flushPendingOutput()
        if let secondaryScrollView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: secondaryScrollView.contentView
            )
            containerView.removeArrangedSubview(secondaryScrollView)
            secondaryScrollView.removeFromSuperview()
            self.secondaryScrollView = nil
            secondaryOutputView = nil
            return
        }

        enableSplit(scrollbackOrigin: scrollView.contentView.bounds.origin)
    }

    @discardableResult
    func performPageUp() -> Bool {
        flushPendingOutput()
        guard settings.splitsOnPageUp else { return false }
        let scrollbackOrigin = scrollView.contentView.bounds.origin
        if !isSplit {
            enableSplit(scrollbackOrigin: scrollbackOrigin) { [weak self] scrollView in
                self?.scrollPage(in: scrollView, direction: -1, userInitiated: true)
            }
            return true
        }
        guard let secondaryScrollView else { return false }
        scrollPage(in: secondaryScrollView, direction: -1, userInitiated: true)
        return true
    }

    @discardableResult
    func performPageDown() -> Bool {
        flushPendingOutput()
        guard settings.splitsOnPageUp else { return false }
        let scrollbackOrigin = scrollView.contentView.bounds.origin
        if !isSplit {
            enableSplit(scrollbackOrigin: scrollbackOrigin) { [weak self] scrollView in
                self?.scrollPage(in: scrollView, direction: 1, userInitiated: true)
            }
            return true
        }
        guard let secondaryScrollView else { return false }
        if isAtBottom(secondaryScrollView) {
            unreadBoundaryCoordinator.userDidScrollToEnd(from: self)
            toggleSplit()
        } else {
            scrollPage(in: secondaryScrollView, direction: 1, userInitiated: true)
        }
        return true
    }

    private func enableSplit(
        scrollbackOrigin: NSPoint,
        scrollAdjustment: (@MainActor (NSScrollView) -> Void)? = nil
    ) {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: max(1, outputView.bounds.width), height: 1))
        view.blinkInterval = blinkInterval
        view.canvasBackgroundColor = defaultBackground
        view.showsInlineImagePreviews = showsInlineImagePreviews
        view.onLink = { [weak self] url in self?.perform(url: url) }
        view.onContextMenu = onContextMenu
        view.onPageUp = { [weak self] in self?.performPageUp() ?? false }
        view.onPageDown = { [weak self] in self?.performPageDown() ?? false }
        view.onSelectionCompleted = { [weak self, weak view] in
            guard let view else { return }
            self?.copySelectionAsPlainText(from: view)
        }
        view.onInteractionWillBegin = { [weak self] in self?.flushPendingOutput() }
        configure(view: view)
        let secondary = Self.makeScrollView(documentView: view, backgroundColor: defaultBackground)
        view.onUserScrollToEnd = { [weak self, weak secondary] in
            self?.clearNewContentBoundaryIfAtBottom(in: secondary)
        }
        Self.fitDocumentWidth(view, in: secondary)
        secondary.setAccessibilityLabel("Paused output scrollback")
        secondary.borderType = .lineBorder
        secondaryOutputView = view
        view.onInteractionCompleted = onInteractionCompleted
        secondaryScrollView = secondary
        addScrollObserver(for: secondary)
        containerView.insertArrangedSubview(secondary, at: 0)
        containerView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        secondary.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        let initialItems = outputView.itemsForCurrentContent()
        let primaryPreparation = outputView.preparedHeightsForCurrentItems()
        performProgrammaticScroll {
            view.setItems(
                initialItems,
                preparedHeights: primaryPreparation.heights,
                measuredAtWidth: primaryPreparation.width
            )
            view.setNewContentBoundary(position: newContentBoundaryPosition)
            if let automaticMarkerID {
                view.setMarker(itemID: automaticMarkerID, marked: true)
            }
        }
        performProgrammaticScroll {
            restoreScrollPosition(in: secondary, to: scrollbackOrigin)
            scrollAdjustment?(secondary)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.secondaryOutputView != nil else { return }
            self.containerView.layoutSubtreeIfNeeded()
            self.containerView.setPosition(self.containerView.bounds.height * 0.5, ofDividerAt: 0)
            self.performProgrammaticScroll {
                self.restoreScrollPosition(in: secondary, to: scrollbackOrigin)
                scrollAdjustment?(secondary)
            }
            if self.settings.scrollsToBottomOnNewText {
                self.scrollLiveOutputToEnd()
            }
        }
    }

    func toggleMarkerForSelectedLine() {
        flushPendingOutput()
        guard let id = outputView.selectedItemID else { NSSound.beep(); return }
        outputView.toggleMarker(itemID: id)
        secondaryOutputView?.toggleMarker(itemID: id)
    }

    private var timestampFormat: String {
        switch (settings.showsDate, settings.showsTime, settings.uses24HourTime) {
        case (true, true, true): "yyyy-MM-dd HH:mm:ss"
        case (true, true, false): "yyyy-MM-dd h:mm:ss a"
        case (true, false, _): "yyyy-MM-dd"
        case (false, true, true): "HH:mm:ss"
        case (false, true, false): "h:mm:ss a"
        case (false, false, _): ""
        }
    }

    private func configure(view: VirtualizedOutputView) {
        view.canvasBackgroundColor = defaultBackground
        view.selectionBackgroundColor = themePalette.accent.withAlphaComponent(0.55)
        view.selectionForegroundColor = NSColor.maximumContrastColor(against: themePalette.accent)
        view.contentInsets = .init(
            top: CGFloat(settings.marginTop + 7),
            left: CGFloat(settings.marginLeft + 9),
            bottom: CGFloat(settings.marginBottom + 7),
            right: CGFloat(settings.marginRight + 9)
        )
        view.fixedContentWidth = settings.usesFixedWidth
            ? CGFloat(settings.fixedWidthCharacters) * cellWidth
            : nil
    }

    private func refreshFontCaches() {
        defaultFont = NSFont(name: settings.fontName, size: settings.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        timestampFont = NSFont(name: settings.fontName, size: max(6, settings.fontSize - 1))
            ?? NSFont.monospacedSystemFont(ofSize: max(6, settings.fontSize - 1), weight: .regular)
        cellWidth = max(1, ("M" as NSString).size(withAttributes: [.font: defaultFont]).width)
        cellHeight = max(1, NSLayoutManager().defaultLineHeight(for: defaultFont))
    }

    private func enqueue(
        _ descriptor: PendingOutputDescriptor,
        removingFirst removedCount: Int,
        removedIDs: [UUID]
    ) {
        // Pending descriptors are always the newest suffix of history. Any
        // evicted pending IDs therefore form a prefix of this queue; older IDs
        // belong to the already-rendered prefix and are coalesced into one
        // prefix removal for the next visual mutation.
        for removedID in removedIDs.prefix(removedCount) {
            if pendingOutputHead < pendingOutputDescriptors.count,
               pendingOutputDescriptors[pendingOutputHead].line.id == removedID {
                pendingOutputHead += 1
            } else {
                pendingPrefixEvictionCount += 1
            }
        }
        pendingEvictionEpoch += removedCount
        var descriptor = descriptor
        descriptor.evictionEpoch = pendingEvictionEpoch
        pendingOutputDescriptors.append(descriptor)
        compactPendingOutputDescriptorsIfNeeded()
    }

    private func compactPendingOutputDescriptorsIfNeeded() {
        guard pendingOutputHead >= 1_024,
              pendingOutputHead * 2 >= pendingOutputDescriptors.count else { return }
        pendingOutputDescriptors = Array(pendingOutputDescriptors[pendingOutputHead...])
        pendingOutputHead = 0
    }

    private func queueMarkerChange(itemID: UUID, marked: Bool) {
        if pendingOutputDescriptorCount > 0 {
            pendingMarkerChanges[itemID] = marked
        } else {
            outputView.setMarker(itemID: itemID, marked: marked)
            secondaryOutputView?.setMarker(itemID: itemID, marked: marked)
        }
    }

    private func schedulePendingOutputFlushIfNeeded() {
        guard pendingOutputDescriptorCount > 0 else { return }
        guard pendingFlushTask == nil else { return }
        pendingFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.outputBatchFrameInterval)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingFlushTask = nil
            self.drainPendingOutputSlice(automatic: true)
            if self.pendingOutputDescriptorCount > 0 {
                self.schedulePendingOutputFlushIfNeeded()
            }
        }
    }

    /// Synchronously commits output that has been made visible to history but
    /// not yet to AppKit. Callers use this as a visual-state barrier before
    /// selection, copying, prompt replacement, and other structural changes.
    func flushPendingOutput() {
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        guard !isDrainingOutputSynchronously else { return }
        isDrainingOutputSynchronously = true
        defer { isDrainingOutputSynchronously = false }

        while hasPendingOutputMutation {
            guard drainPendingOutputSlice(automatic: false) else { break }
        }
    }

    private func discardPendingOutput() {
        pendingFlushTask?.cancel()
        pendingFlushTask = nil
        pendingOutputDescriptors.removeAll(keepingCapacity: true)
        pendingOutputHead = 0
        pendingPrefixEvictionCount = 0
        pendingMarkerChanges.removeAll(keepingCapacity: true)
        pendingBoundaryUpdate = false
        pendingEvictionEpoch = 0
    }

    func prepareForTeardown() {
        discardPendingOutput()
        tailAnimationTask?.cancel()
        tailAnimationTask = nil
        tailQuietTask?.cancel()
        tailQuietTask = nil
    }

    private var hasPendingOutputMutation: Bool {
        pendingOutputDescriptorCount > 0
            || pendingPrefixEvictionCount > 0
            || !pendingMarkerChanges.isEmpty
            || pendingBoundaryUpdate
    }

    /// Drains one bounded slice. All expensive work for the selected lines is
    /// prepared before either document view is mutated, allowing the primary
    /// view's measured heights to be reused by a same-width split view.
    @discardableResult
    private func drainPendingOutputSlice(automatic: Bool) -> Bool {
        guard hasPendingOutputMutation else { return false }

        let start = DispatchTime.now().uptimeNanoseconds
        let deadline = start + Self.outputBatchTimeBudgetNanoseconds
        var preparedItems: [VirtualizedOutputView.PreparedItem] = []
        preparedItems.reserveCapacity(min(Self.outputBatchLineLimit, pendingOutputDescriptorCount))
        let secondaryNeedsPreparation = secondaryOutputView.map {
            abs(outputView.effectiveContentWidth - $0.effectiveContentWidth) > 0.5
        } ?? false
        var secondaryPreparedItems: [VirtualizedOutputView.PreparedItem] = []
        if secondaryNeedsPreparation {
            secondaryPreparedItems.reserveCapacity(min(Self.outputBatchLineLimit, pendingOutputDescriptorCount))
        }

        while pendingOutputHead < pendingOutputDescriptors.count {
            let descriptor = pendingOutputDescriptors[pendingOutputHead]
            pendingOutputHead += 1
            let lineIndex = max(
                0,
                descriptor.lineIndex - (pendingEvictionEpoch - descriptor.evictionEpoch)
            )
            let item = makeItem(
                for: descriptor.line,
                terminator: descriptor.terminator,
                lineIndex: lineIndex
            )
            preparedItems.append(outputView.prepareItem(item))
            if secondaryNeedsPreparation, let secondaryOutputView {
                secondaryPreparedItems.append(secondaryOutputView.prepareItem(item))
            }

            // The first item is unconditional: a pathological attributed line
            // must make progress even when it consumes the complete budget.
            if preparedItems.count >= Self.outputBatchLineLimit
                || (automatic && DispatchTime.now().uptimeNanoseconds >= deadline) {
                break
            }
        }

        // A marker or logical-boundary update can be pending without a line;
        // commit that update as its own small mutation.
        guard !preparedItems.isEmpty || pendingPrefixEvictionCount > 0
            || !pendingMarkerChanges.isEmpty || pendingBoundaryUpdate else {
            return false
        }

        let removingFirst = pendingPrefixEvictionCount
        let markerChanges = pendingMarkerChanges
        let boundaryPosition = newContentBoundaryPosition
        pendingPrefixEvictionCount = 0
        pendingMarkerChanges.removeAll(keepingCapacity: true)
        pendingBoundaryUpdate = false
        compactPendingOutputDescriptorsIfNeeded()

        let committedSecondaryItems = secondaryNeedsPreparation ? secondaryPreparedItems : preparedItems

        performProgrammaticScroll {
            outputView.applyPreparedBatch(
                removingFirst: removingFirst,
                appending: preparedItems,
                boundaryPosition: boundaryPosition,
                // Reapply the logical position on every slice. While rendering
                // trails history, a boundary may be beyond the current item
                // count and must move forward as later slices arrive.
                boundaryPositionIsAuthoritative: true,
                markerChanges: markerChanges,
                postsAccessibilityNotification: true
            )
            secondaryOutputView?.applyPreparedBatch(
                removingFirst: removingFirst,
                appending: committedSecondaryItems,
                boundaryPosition: boundaryPosition,
                boundaryPositionIsAuthoritative: true,
                markerChanges: markerChanges,
                postsAccessibilityNotification: false
            )
            if !preparedItems.isEmpty, settings.scrollsToBottomOnNewText {
                followLiveOutput(hasQueuedOutput: pendingOutputDescriptorCount > 0)
            }
        }

        outputSliceCountForTesting += 1
        maximumOutputLinesPerSliceForTesting = max(
            maximumOutputLinesPerSliceForTesting,
            preparedItems.count
        )
        return true
    }

    private func clearAutomaticMarker() {
        guard let id = automaticMarkerID else { return }
        automaticMarkerID = nil
        queueMarkerChange(itemID: id, marked: false)
    }

    func setWindowFocused(_ focused: Bool) {
        guard windowIsFocused != focused else {
            unreadBoundaryCoordinator.focusChanged(for: self)
            return
        }
        windowIsFocused = focused
        unreadBoundaryCoordinator.focusChanged(for: self)
    }

    private func clearNewContentBoundaryIfAtBottom(in scrollView: NSScrollView?) {
        guard !isPerformingProgrammaticScroll else { return }
        flushPendingOutput()
        guard
              let scrollView,
              isAtBottom(scrollView) else { return }
        unreadBoundaryCoordinator.userDidScrollToEnd(from: self)
    }

    private func noteLiveOutputArrived() {
        tailQuietGeneration += 1
        tailQuietTask?.cancel()
        tailQuietTask = nil
    }

    private func followLiveOutput(hasQueuedOutput: Bool) {
        let shouldCatchUp = settings.smoothScrolling
            && (hasQueuedOutput || tailAnimationInFlight || tailCatchUpMode)

        if shouldCatchUp {
            tailAnimationTask?.cancel()
            tailAnimationTask = nil
            tailAnimationInFlight = false
            catchUpScrollCountForTesting += 1
            scrollLiveOutputToEnd(animated: false)
            enterTailCatchUpMode()
            return
        }

        scrollLiveOutputToEnd(animated: settings.smoothScrolling)
        guard settings.smoothScrolling else { return }

        tailAnimationInFlight = true
        tailAnimationGeneration += 1
        let generation = tailAnimationGeneration
        tailAnimationTask?.cancel()
        tailAnimationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.smoothScrollInterval)
            } catch {
                return
            }
            guard let self,
                  self.tailAnimationGeneration == generation else { return }
            self.tailAnimationTask = nil
            self.tailAnimationInFlight = false
        }
    }

    private func enterTailCatchUpMode() {
        tailCatchUpMode = true
        tailQuietGeneration += 1
        let generation = tailQuietGeneration
        tailQuietTask?.cancel()
        tailQuietTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.smoothScrollInterval)
            } catch {
                return
            }
            guard let self,
                  self.tailQuietGeneration == generation,
                  self.pendingOutputDescriptorCount == 0 else { return }
            self.tailQuietTask = nil
            self.tailCatchUpMode = false
        }
    }

    private func resetTailScrollTracking() {
        tailAnimationGeneration += 1
        tailQuietGeneration += 1
        tailAnimationTask?.cancel()
        tailAnimationTask = nil
        tailQuietTask?.cancel()
        tailQuietTask = nil
        tailAnimationInFlight = false
        tailCatchUpMode = false
    }

    private func scrollLiveOutputToEnd(animated: Bool = false) {
        programmaticScrollGeneration += 1
        let generation = programmaticScrollGeneration
        isPerformingProgrammaticScroll = true
        outputView.scrollToEnd(animated: animated)
        guard animated else {
            isPerformingProgrammaticScroll = false
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.programmaticScrollGeneration == generation else { return }
            self.isPerformingProgrammaticScroll = false
        }
    }

    private func addScrollObserver(for scrollView: NSScrollView) {
        if let clipView = scrollView.contentView as? OutputClipView {
            clipView.onUserScroll = { [weak self, weak scrollView] previousY, currentY in
                guard let self, let scrollView else { return }
                self.acknowledgeUserScroll(in: scrollView, from: previousY, to: currentY)
            }
        }
        if let scroller = scrollView.verticalScroller as? OutputScroller {
            scroller.onUserScrollEnded = { [weak self, weak scrollView] previousY, currentY in
                guard let self, let scrollView else { return }
                self.acknowledgeUserScroll(in: scrollView, from: previousY, to: currentY)
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(outputScrollBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func acknowledgeUserScroll(
        in scrollView: NSScrollView,
        from previousY: CGFloat,
        to currentY: CGFloat
    ) {
        guard !isPerformingProgrammaticScroll else { return }
        flushPendingOutput()
        guard
              currentY > previousY,
              isAtBottom(scrollView) else { return }
        unreadBoundaryCoordinator.userDidScrollToEnd(from: self)
    }

    private func observeWindow(_ window: NSWindow?) {
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
        }
        observedWindow = window
        guard let window else { return }

        setWindowFocused(window.isKeyWindow)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(outputWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(outputWindowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    @objc private func outputScrollBoundsChanged(_ notification: Notification) {
        // Bounds notifications also arrive for layout, history mutation, and
        // automatic follow. User acknowledgement is wired to explicit wheel
        // and scroll-to-end events instead of treating every bounds change as
        // an acknowledgement.
    }

    @objc private func outputWindowDidBecomeKey(_ notification: Notification) {
        setWindowFocused(true)
    }

    @objc private func outputWindowDidResignKey(_ notification: Notification) {
        setWindowFocused(false)
    }

    private func showSelectionCopiedPopupIfNeeded() {
        guard settings.showsSelectionCopiedPopup else { return }
        let label = NSTextField(labelWithString: "Copied")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        label.layer?.cornerRadius = 6
        label.frame = NSRect(x: max(8, containerView.bounds.midX - 42), y: 12, width: 84, height: 28)
        label.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        containerView.addSubview(label)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak label] in label?.removeFromSuperview() }
    }

    private func rebuild(
        scrollToEnd: Bool = false,
        finalTerminator: String = "\n",
        preservingScrollPosition: Bool = false,
        previousLines: [RenderedLine]? = nil
    ) {
        flushPendingOutput()
        rebuildGeneration += 1
        let oldOrigin = scrollView.contentView.bounds.origin
        let oldSecondaryOrigin = secondaryScrollView?.contentView.bounds.origin
        lineContentRanges.removeAll(keepingCapacity: true)
        let lines = history.lines
        if let unterminatedLineID, !lines.contains(where: { $0.id == unterminatedLineID }) {
            self.unterminatedLineID = nil
        }
        let items = lines.enumerated().map { index, line in
            makeItem(
                for: line,
                terminator: line.id == unterminatedLineID
                    ? ""
                    : (index == lines.count - 1 ? finalTerminator : "\n"),
                lineIndex: index
            )
        }
        let primaryPreparation = outputView.prepareItems(items)
        performProgrammaticScroll {
            outputView.setItems(
                items,
                preparedHeights: primaryPreparation.map(\.height),
                measuredAtWidth: outputView.effectiveContentWidth
            )
            secondaryOutputView?.setItems(
                items,
                preparedHeights: primaryPreparation.map(\.height),
                measuredAtWidth: outputView.effectiveContentWidth
            )
        }
        if scrollToEnd {
            scrollLiveOutputToEnd()
        } else if preservingScrollPosition {
            performProgrammaticScroll {
                restoreScrollPosition(in: scrollView, to: oldOrigin)
            }
        }
        if let secondaryScrollView, let oldSecondaryOrigin {
            performProgrammaticScroll {
                restoreScrollPosition(in: secondaryScrollView, to: oldSecondaryOrigin)
            }
        }
        unreadBoundaryCoordinator.outputDidRebuild(
            self,
            previousLines: previousLines ?? lines
        )
    }

    private func restoreScrollPosition(in scrollView: NSScrollView, to origin: NSPoint) {
        let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentSize.height)
        let point = NSPoint(x: origin.x, y: min(max(0, origin.y), maxY))
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func performProgrammaticScroll(_ action: () -> Void) {
        let wasPerformingProgrammaticScroll = isPerformingProgrammaticScroll
        isPerformingProgrammaticScroll = true
        action()
        isPerformingProgrammaticScroll = wasPerformingProgrammaticScroll
    }

    private func scrollPage(
        in scrollView: NSScrollView,
        direction: CGFloat,
        userInitiated: Bool = false
    ) {
        let origin = scrollView.contentView.bounds.origin
        let distance = max(1, scrollView.contentSize.height - 20)
        restoreScrollPosition(
            in: scrollView,
            to: NSPoint(x: origin.x, y: origin.y + distance * direction)
        )
        if userInitiated, isAtBottom(scrollView) {
            unreadBoundaryCoordinator.userDidScrollToEnd(from: self)
        }
    }

    private func isAtBottom(_ scrollView: NSScrollView) -> Bool {
        let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentSize.height)
        return maxY - scrollView.contentView.bounds.origin.y <= 1
    }

    private func makeItem(
        for line: RenderedLine,
        terminator: String,
        lineIndex: Int
    ) -> VirtualizedOutputView.Item {
        let timestamp = showsTimestamps ? "[\(timestampFormatter.string(from: line.timestamp))] " : ""
        let toolTip: String? = settings.showsDateTimeToolTip
            ? tooltipDateFormatter.string(from: line.timestamp)
            : nil
        let value = NSMutableAttributedString(string: timestamp + line.text + terminator, attributes: [
            .font: defaultFont,
            .foregroundColor: defaultForeground,
        ])
        if let toolTip {
            value.addAttribute(.toolTip, value: toolTip, range: NSRange(location: 0, length: value.length))
        }
        if !timestamp.isEmpty {
            value.addAttributes([
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: timestampFont,
            ], range: NSRange(location: 0, length: timestamp.utf16.count))
        }
        let textOffset = timestamp.utf16.count
        var explicitLinkRanges: [NSRange] = []
        for run in line.runs where run.range.lowerBound >= 0 && run.range.upperBound <= line.text.utf16.count {
            let range = NSRange(location: textOffset + run.range.lowerBound, length: run.range.count)
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let color = run.style.foreground {
                let foreground = NSColor(color)
                attributes[.foregroundColor] = (settings.invertBrightness
                    ? foreground.invertingBrightness
                    : foreground).withAlphaComponent(run.style.faint ? 0.55 : 1)
            } else if run.style.faint {
                attributes[.foregroundColor] = defaultForeground.withAlphaComponent(0.55)
            }
            if let color = run.style.background {
                let background = NSColor(color)
                attributes[.backgroundColor] = settings.invertBrightness
                    ? background.invertingBrightness
                    : background
            }
            var traits: NSFontTraitMask = []
            if run.style.bold { traits.insert(.boldFontMask) }
            if run.style.italic { traits.insert(.italicFontMask) }
            let size = CGFloat(run.style.fontSize ?? settings.fontSize)
            let baseFont = if run.style.fontFace == nil, run.style.fontSize == nil {
                defaultFont
            } else {
                run.style.fontFace.flatMap { NSFont(name: $0, size: size) }
                    ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
            attributes[.font] = NSFontManager.shared.convert(
                baseFont,
                toHaveTrait: traits
            )
            if run.style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.style.strikeout { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if run.style.blink != .none { attributes[VirtualizedOutputView.blinkAttribute] = run.style.blink.rawValue }
            if let action = run.style.link {
                explicitLinkRanges.append(NSRange(location: run.range.lowerBound, length: run.range.count))
                attributes[.link] = Self.url(for: action)
                attributes[.cursor] = NSCursor.pointingHand
                if run.style.foreground == nil {
                    let link = NSColor(hexString: settings.webLinkHex) ?? .linkColor
                    attributes[.foregroundColor] = settings.invertBrightness ? link.invertingBrightness : link
                }
            }
            value.addAttributes(attributes, range: range)
        }

        applyAutomaticWebLinks(
            to: value,
            lineText: line.text,
            textOffset: textOffset,
            excluding: explicitLinkRanges
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch line.paragraph.alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        paragraph.firstLineHeadIndent = CGFloat(line.paragraph.leftIndent)
        paragraph.headIndent = CGFloat(
            line.paragraph.leftIndent + line.paragraph.wrappedIndent + Double(settings.wrappedLineIndent)
        )
        paragraph.tailIndent = -CGFloat(line.paragraph.rightIndent)
        paragraph.paragraphSpacingBefore = CGFloat(line.paragraph.topPadding)
        paragraph.paragraphSpacing = CGFloat(line.paragraph.bottomPadding + Double(settings.paragraphSpacing))
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 8 * max(
            1,
            ("M" as NSString).size(withAttributes: [.font: defaultFont]).width
        )
        value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
        if let color = line.paragraph.background {
            value.addAttribute(.backgroundColor, value: NSColor(color), range: NSRange(location: 0, length: value.length))
        } else if usesFanFoldBackgrounds, lineIndex.isMultiple(of: 2) {
            value.addAttribute(
                .backgroundColor,
                value: NSColor(hexString: settings.fanFoldFirstHex)
                    ?? defaultForeground.withAlphaComponent(0.035),
                range: NSRange(location: 0, length: value.length)
            )
        } else if usesFanFoldBackgrounds {
            value.addAttribute(
                .backgroundColor,
                value: NSColor(hexString: settings.fanFoldSecondHex)
                    ?? defaultForeground.withAlphaComponent(0.015),
                range: NSRange(location: 0, length: value.length)
            )
        }
        let contentRange = NSRange(location: textOffset, length: line.text.utf16.count)
        lineContentRanges[line.id] = contentRange
        return .init(
            id: line.id,
            attributedText: value,
            contentRange: contentRange,
            assets: line.assets
                .filter { $0.kind != .image }
                .map { ($0, textOffset + $0.characterOffset) },
            previews: inlineImagePreviews(for: line),
            paragraph: line.paragraph
        )
    }

    private func inlineImagePreviews(for line: RenderedLine) -> [VirtualizedOutputView.InlinePreview] {
        guard showsInlineImagePreviews else { return [] }

        struct Candidate {
            var preview: VirtualizedOutputView.InlinePreview
            var location: Int
            var order: Int
        }

        var candidates: [Candidate] = []
        var order = 0
        for asset in line.assets where asset.kind == .image {
            guard Self.isHTTPURL(asset.source) else { continue }
            candidates.append(.init(
                preview: .init(source: asset.source, altText: asset.altText),
                location: max(0, asset.characterOffset),
                order: order
            ))
            order += 1
        }

        if Self.containsHTTPURLScheme(in: line.text) {
            let source = line.text as NSString
            let sourceRange = NSRange(location: 0, length: source.length)
            for match in webURLDetector.matches(in: line.text, options: [], range: sourceRange) {
                guard match.resultType == .link,
                      match.range.location >= 0,
                      match.range.length > 0,
                      NSMaxRange(match.range) <= source.length else { continue }
                let raw = source.substring(with: match.range)
                let candidateText = Self.trimmedImageURLText(raw)
                guard let url = URL(string: candidateText),
                      Self.isHTTPURL(url),
                      Self.imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
                candidates.append(.init(
                    preview: .init(source: url, altText: "Image"),
                    location: match.range.location,
                    order: order
                ))
                order += 1
            }
        }

        var seen = Set<String>()
        return candidates
            .sorted {
                if $0.location != $1.location { return $0.location < $1.location }
                return $0.order < $1.order
            }
            .compactMap { candidate in
                seen.insert(candidate.preview.source.absoluteString).inserted ? candidate.preview : nil
            }
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func containsHTTPURLScheme(in text: String) -> Bool {
        text.range(of: "http://", options: .caseInsensitive) != nil
            || text.range(of: "https://", options: .caseInsensitive) != nil
    }

    private static func trimmedImageURLText(_ value: String) -> String {
        var result = value
        while let last = result.last, ".,!?;:)]}".contains(last) {
            result.removeLast()
        }
        return result
    }

    private func applyAutomaticWebLinks(
        to value: NSMutableAttributedString,
        lineText: String,
        textOffset: Int,
        excluding explicitLinkRanges: [NSRange]
    ) {
        guard !lineText.isEmpty, Self.containsHTTPURLScheme(in: lineText) else { return }
        let source = lineText as NSString
        let sourceRange = NSRange(location: 0, length: source.length)
        let linkColor = NSColor(hexString: settings.webLinkHex) ?? .linkColor
        let displayedLinkColor = settings.invertBrightness ? linkColor.invertingBrightness : linkColor

        for match in webURLDetector.matches(in: lineText, options: [], range: sourceRange) {
            guard match.resultType == .link,
                  let url = match.url,
                  url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https",
                  match.range.location >= 0,
                  match.range.length > 0,
                  NSMaxRange(match.range) <= source.length else { continue }

            let matchedText = source.substring(with: match.range).lowercased()
            guard matchedText.hasPrefix("http://") || matchedText.hasPrefix("https://") else { continue }

            let valueRange = NSRange(
                location: textOffset + match.range.location,
                length: match.range.length
            )
            for uncoveredRange in ranges(in: valueRange, excluding: explicitLinkRanges.map {
                NSRange(location: textOffset + $0.location, length: $0.length)
            }) {
                value.addAttributes([
                    .link: url,
                    .cursor: NSCursor.pointingHand,
                    .foregroundColor: displayedLinkColor,
                ], range: uncoveredRange)
            }
        }
    }

    private func ranges(in range: NSRange, excluding excludedRanges: [NSRange]) -> [NSRange] {
        var remaining = [range]
        for excluded in excludedRanges {
            remaining = remaining.flatMap { candidate in
                let intersectionStart = max(candidate.location, excluded.location)
                let intersectionEnd = min(NSMaxRange(candidate), NSMaxRange(excluded))
                guard intersectionStart < intersectionEnd else { return [candidate] }

                var result: [NSRange] = []
                if candidate.location < intersectionStart {
                    result.append(NSRange(
                        location: candidate.location,
                        length: intersectionStart - candidate.location
                    ))
                }
                if intersectionEnd < NSMaxRange(candidate) {
                    result.append(NSRange(
                        location: intersectionEnd,
                        length: NSMaxRange(candidate) - intersectionEnd
                    ))
                }
                return result
            }
        }
        return remaining
    }

    private func notifyPauseChange() { onPauseChange?(history.isPaused, history.pendingLines.count) }

    private func perform(url: URL) {
        if url.scheme == "beipmu-action", let action = Self.decodeAction(url) {
            onAction?(action)
        } else {
            onAction?(.url(url.absoluteString))
        }
    }

    private static func url(for action: LinkAction) -> URL {
        switch action {
        case let .url(value): return URL(string: value) ?? URL(string: "about:blank")!
        case let .send(value, hints):
            var components = URLComponents()
            components.scheme = "beipmu-action"
            components.host = "send"
            components.queryItems = [URLQueryItem(name: "value", value: value)]
                + hints.map { URLQueryItem(name: "hint", value: $0) }
            return components.url!
        case let .command(value):
            var components = URLComponents()
            components.scheme = "beipmu-action"
            components.host = "command"
            components.queryItems = [URLQueryItem(name: "value", value: value)]
            return components.url!
        }
    }

    private static func decodeAction(_ url: URL) -> LinkAction? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "value" })?.value else { return nil }
        switch components.host {
        case "send":
            return .send(
                value,
                hints: components.queryItems?.filter { $0.name == "hint" }.compactMap(\.value) ?? []
            )
        case "command": return .command(value)
        default: return nil
        }
    }

    private static func makeScrollView(documentView: NSView, backgroundColor: NSColor) -> NSScrollView {
        let scroll = OutputScrollView()
        scroll.contentView = OutputClipView()
        scroll.documentView = documentView
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = OutputScroller()
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = backgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    private static func fitDocumentWidth(_ documentView: NSView, in scrollView: NSScrollView) {
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
    }
}

private extension NSColor {
    convenience init(_ color: BeipCore.RGBColor) {
        self.init(
            calibratedRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: CGFloat(color.alpha) / 255
        )
    }

    var invertingBrightness: NSColor {
        guard let rgb = usingColorSpace(.deviceRGB) else { return self }
        return NSColor(
            calibratedRed: 1 - rgb.redComponent,
            green: 1 - rgb.greenComponent,
            blue: 1 - rgb.blueComponent,
            alpha: rgb.alphaComponent
        )
    }
}
