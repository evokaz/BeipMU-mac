import AppKit
import BeipCore
import CoreText
import Foundation

@MainActor
final class VirtualizedOutputView: NSView, NSUserInterfaceValidations, NSViewToolTipOwner {
    struct InlinePreview: Equatable {
        var source: URL
        var altText: String

        init(source: URL, altText: String = "Image") {
            self.source = source
            self.altText = altText
        }
    }

    struct Item {
        var id: UUID
        var attributedText: NSAttributedString
        var contentRange: NSRange
        var assets: [(asset: InlineAsset, displayOffset: Int)]
        var previews: [InlinePreview] = []
        var paragraph: ParagraphStyle = .init()
    }

    /// A measured item is prepared before the document is mutated. Keeping the
    /// width alongside the result prevents a height measured for one split
    /// pane from being reused after its effective width changes.
    struct PreparedItem {
        var item: Item
        var height: Double
        var measuredWidth: CGFloat
    }

    private struct Position: Equatable {
        var item: Int
        var offset: Int
    }

    private struct Selection {
        var lower: Position
        var upper: Position
        var isEmpty: Bool { lower == upper }
    }

    private struct HoveredLink: Equatable {
        var itemID: UUID
        var range: NSRange
    }

    private struct PreviewHit: Equatable {
        var itemID: UUID
        var source: URL
        var rect: NSRect
    }

    private enum PreviewLoadState: Equatable {
        case loading
        case failed
    }

    static let blinkAttribute = NSAttributedString.Key("BeipMUBlink")

    var onLink: ((URL) -> Void)?
    var onContextMenu: ((NSEvent) -> NSMenu?)?
    var onPageUp: (() -> Bool)?
    var onPageDown: (() -> Bool)?
    var onUserScrollToEnd: (() -> Void)?
    var onSelectionCompleted: (() -> Void)?
    var onInteractionWillBegin: (() -> Void)?
    var onInteractionCompleted: (() -> Void)?
    private(set) var renderedItemCount = 0
    private(set) var lastDrawnItemCount = 0

    private var storage: [Item] = []
    private var head = 0
    private var itemIndices: [UUID: Int] = [:]
    private var layoutIndex = LineLayoutIndex()
    private var measuredWidth: CGFloat = 0
    private var anchor: Position?
    private var focus: Position?
    private var mouseDownPosition: Position?
    private var hoveredLink: HoveredLink?
    private var mouseDownPreview: PreviewHit?
    private var trackingArea: NSTrackingArea?
    private var markedItems: Set<UUID> = []
    /// The logical insertion point before which unread content starts. Unlike
    /// a line UUID this remains meaningful when the line at the boundary is
    /// evicted or removed.
    private var newContentBoundaryPosition: Int?
    private var blinkTimer: Timer?
    private var blinkVisible = true
    private var blinkingItemCount = 0
    var blinkInterval: TimeInterval = 0.55 {
        didSet {
            guard blinkInterval != oldValue else { return }
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkVisible = true
            updateBlinkTimer()
            needsDisplay = true
        }
    }
    private var imageCache: [URL: NSImage] = [:]
    private var imageTasks: [URL: Task<Void, Never>] = [:]
    private var previewTasks: [URL: Task<Void, Never>] = [:]
    private var previewStates: [URL: PreviewLoadState] = [:]
    private(set) var previewDownloadCount = 0
    private var animationTimer: Timer?
    private var displayOptions = AccessibilityDisplayOptions.current
    private(set) var batchMutationCountForTesting = 0
    private(set) var scrollAnimationTargetUpdateCountForTesting = 0
    private(set) var heightMeasurementCountForTesting = 0
    var showsInlineImagePreviews = false {
        didSet {
            guard showsInlineImagePreviews != oldValue else { return }
            if !showsInlineImagePreviews { cancelPreviewLoads() }
            rebuildMeasurements()
            needsDisplay = true
        }
    }
    var contentInsets = NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9) {
        didSet { rebuildMeasurements() }
    }
    var fixedContentWidth: CGFloat? {
        didSet { rebuildMeasurements() }
    }
    var canvasBackgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1) {
        didSet { needsDisplay = true }
    }
    var selectionBackgroundColor = NSColor.selectedTextBackgroundColor {
        didSet { needsDisplay = true }
    }
    var selectionForegroundColor = NSColor.selectedTextColor {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("MU star output")
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    var itemCount: Int { storage.count - head }
    var isBlinkTimerActive: Bool { blinkTimer != nil }
    var blinkIntervalForTesting: TimeInterval { blinkInterval }
    private(set) var blinkTimerCreationCountForTesting = 0
    var isAnimationTimerActive: Bool { animationTimer != nil }
    var previewDownloadCountForTesting: Int { previewDownloadCount }
    var selectedRangeIsEmpty: Bool { anchor == nil || anchor == focus }
    var newContentBoundaryItemIDForTesting: UUID? {
        guard let newContentBoundaryPosition else { return nil }
        return item(at: newContentBoundaryPosition)?.id
    }
    var newContentBoundaryPositionForTesting: Int? { newContentBoundaryPosition }
    var effectiveContentWidth: CGFloat { contentWidth }
    var effectiveContentWidthForTesting: CGFloat { effectiveContentWidth }
    func renderedAttributedTextForTesting(at index: Int) -> NSAttributedString? {
        item(at: index).map(attributedTextForLayout(_:))
    }
    func drawnAttributedTextForTesting(at index: Int) -> NSAttributedString? {
        item(at: index).map { attributedTextForDrawing($0, itemIndex: index) }
    }
    func setHoveredLinkForTesting(itemID: UUID?, range: NSRange = .init()) {
        setHoveredLink(itemID.map { HoveredLink(itemID: $0, range: range) })
    }
    func activateLinkForTesting(
        itemID: UUID,
        at offset: Int,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard let physicalIndex = itemIndices[itemID],
              let value = item(at: physicalIndex - head),
              offset >= 0,
              offset < value.attributedText.length,
              let url = value.attributedText.attribute(.link, at: offset, effectiveRange: nil) as? URL else { return }
        activateLink(url, modifierFlags: modifierFlags)
    }
    func activatePreviewForTesting(
        itemID: UUID,
        source: URL,
        modifierFlags: NSEvent.ModifierFlags
    ) {
        guard let physicalIndex = itemIndices[itemID],
              let value = item(at: physicalIndex - head),
              value.previews.contains(where: { $0.source == source }) else { return }
        activatePreview(source, modifierFlags: modifierFlags)
    }
    func inlinePreviewSourcesForTesting(at index: Int) -> [URL] {
        item(at: index)?.previews.map(\.source) ?? []
    }
    func previewRectsForTesting(at index: Int) -> [NSRect] {
        guard let value = item(at: index),
              let y = layoutIndex.yOffset(for: index),
              let height = layoutIndex.height(at: index) else { return [] }
        let rect = NSRect(
            x: contentInsets.left,
            y: contentInsets.top + CGFloat(y),
            width: contentWidth,
            height: CGFloat(height)
        )
        return previewRects(for: value, in: rect)
    }
    func measuredHeightForTesting(at index: Int) -> Double? {
        item(at: index).map(measuredHeight(for:))
    }
    func decorationRectForTesting(at index: Int, in rect: NSRect) -> NSRect? {
        item(at: index).map { paragraphDecorationRect($0.paragraph, in: rect) }
    }
    var selectedItemID: UUID? { focus.flatMap { item(at: $0.item)?.id } }
    var firstVisibleItemID: UUID? {
        guard let clip = enclosingScrollView?.contentView.bounds else { return item(at: 0)?.id }
        let range = layoutIndex.visibleRange(
            intersecting: Double(clip.minY - contentInsets.top)..<Double(clip.maxY - contentInsets.top)
        )
        return item(at: range.lowerBound)?.id
    }

    func setItems(
        _ items: [Item],
        preparedHeights: [Double]? = nil,
        measuredAtWidth: CGFloat? = nil
    ) {
        let boundaryPosition = newContentBoundaryPosition
        storage = items
        head = 0
        anchor = nil
        focus = nil
        if let hoveredLink,
           let item = items.first(where: { $0.id == hoveredLink.itemID }),
           hoveredLink.range.location >= 0,
           hoveredLink.range.length > 0,
           NSMaxRange(hoveredLink.range) <= item.attributedText.length,
           item.attributedText.attribute(.link, at: hoveredLink.range.location, effectiveRange: nil) != nil {
            self.hoveredLink = hoveredLink
        } else {
            self.hoveredLink = nil
        }
        markedItems.formIntersection(items.map(\.id))
        newContentBoundaryPosition = boundaryPosition.map { min(max(0, $0), items.count) }
        blinkingItemCount = items.reduce(0) { $0 + (hasBlink($1) ? 1 : 0) }
        let activePreviewURLs = showsInlineImagePreviews
            ? Set(items.flatMap(\.previews).map(\.source))
            : []
        cancelPreviewLoads(keeping: activePreviewURLs)
        rebuildIndexMap()
        let reusableHeights: [Double]? = if let preparedHeights,
                                             preparedHeights.count == items.count,
                                             let measuredAtWidth,
                                             abs(measuredAtWidth - contentWidth) <= 0.5 {
            preparedHeights
        } else {
            nil
        }
        rebuildMeasurements(using: reusableHeights)
        updateBlinkTimer()
        needsDisplay = true
    }

    /// Measures a batch for the current effective width without changing the
    /// document. The caller can then commit it as one mutation.
    func prepareItem(_ item: Item) -> PreparedItem {
        .init(item: item, height: measuredHeight(for: item), measuredWidth: contentWidth)
    }

    func prepareItems(_ items: [Item]) -> [PreparedItem] {
        items.map(prepareItem(_:))
    }

    /// Returns the heights already held by the primary view. This is used when
    /// a split view has the same effective width and therefore needs no second
    /// Core Text measurement pass.
    func preparedHeightsForCurrentItems() -> (width: CGFloat, heights: [Double]) {
        (
            measuredWidth,
            (0..<itemCount).compactMap { layoutIndex.height(at: $0) }
        )
    }

    func itemsForCurrentContent() -> [Item] { Array(retainedItems) }

    func append(_ item: Item) {
        applyBatch(removingFirst: 0, appending: [item], postsAccessibilityNotification: false)
    }

    /// Evicts a retained prefix and appends the new item as one document
    /// mutation. This keeps the document height, blink timer, and display
    /// invalidation work to one pass while preserving the scrollback offset
    /// for callers that are not following the live end.
    func evictFirstAndAppend(_ appendedItem: Item, removingFirst requestedCount: Int) {
        applyBatch(
            removingFirst: requestedCount,
            appending: [appendedItem],
            postsAccessibilityNotification: false
        )
    }

    /// Applies a prefix eviction and any number of appended items as one
    /// visual mutation. `boundaryPosition` is authoritative when supplied;
    /// this lets OutputTextView apply its shared logical boundary after the
    /// history mutation without applying the prefix adjustment twice.
    /// Marker changes are applied before the one final display invalidation.
    func applyBatch(
        removingFirst requestedCount: Int,
        appending appendedItems: [Item],
        boundaryPosition: Int? = nil,
        boundaryPositionIsAuthoritative: Bool = false,
        markerChanges: [UUID: Bool] = [:],
        postsAccessibilityNotification: Bool = true
    ) {
        applyPreparedBatchMutation(
            removingFirst: requestedCount,
            appending: prepareItems(appendedItems),
            boundaryPosition: boundaryPosition,
            boundaryPositionIsAuthoritative: boundaryPositionIsAuthoritative,
            markerChanges: markerChanges,
            postsAccessibilityNotification: postsAccessibilityNotification
        )
    }

    /// Applies a previously measured batch. If the receiving view's width no
    /// longer matches the preparation width, only that view is remeasured.
    func applyPreparedBatch(
        removingFirst requestedCount: Int,
        appending preparedItems: [PreparedItem],
        boundaryPosition: Int? = nil,
        boundaryPositionIsAuthoritative: Bool = false,
        markerChanges: [UUID: Bool] = [:],
        postsAccessibilityNotification: Bool = true
    ) {
        applyPreparedBatchMutation(
            removingFirst: requestedCount,
            appending: preparedItems,
            boundaryPosition: boundaryPosition,
            boundaryPositionIsAuthoritative: boundaryPositionIsAuthoritative,
            markerChanges: markerChanges,
            postsAccessibilityNotification: postsAccessibilityNotification
        )
    }

    private func applyPreparedBatchMutation(
        removingFirst requestedCount: Int,
        appending preparedItems: [PreparedItem],
        boundaryPosition: Int?,
        boundaryPositionIsAuthoritative: Bool,
        markerChanges: [UUID: Bool],
        postsAccessibilityNotification: Bool
    ) {
        let removed = min(max(0, requestedCount), itemCount)
        let removedHeight = layoutIndex.yOffset(for: removed) ?? 0

        if removed > 0 {
            if let hoveredLink,
               let physicalIndex = itemIndices[hoveredLink.itemID],
               physicalIndex - head < removed {
                self.hoveredLink = nil
            }
            for index in 0..<removed {
                if let removedItem = self.item(at: index) {
                    if hasBlink(removedItem) { blinkingItemCount -= 1 }
                    itemIndices.removeValue(forKey: removedItem.id)
                    markedItems.remove(removedItem.id)
                }
            }
            head += removed
            if let newContentBoundaryPosition {
                self.newContentBoundaryPosition = max(0, newContentBoundaryPosition - removed)
            }
            layoutIndex.removeFirst(removed)
            adjustSelectionAfterRemovingFirst(removed)

            if head >= 1_024, head * 2 >= storage.count {
                storage.removeFirst(head)
                head = 0
                rebuildIndexMap()
            }
        }

        for preparedItem in preparedItems {
            let appendedItem = preparedItem.item
            storage.append(appendedItem)
            if hasBlink(appendedItem) { blinkingItemCount += 1 }
            itemIndices[appendedItem.id] = storage.count - 1
            let height = abs(preparedItem.measuredWidth - contentWidth) <= 0.5
                ? preparedItem.height
                : measuredHeight(for: appendedItem)
            layoutIndex.append(height: height)
        }
        renderedItemCount += preparedItems.count
        for (itemID, marked) in markerChanges {
            if marked { markedItems.insert(itemID) } else { markedItems.remove(itemID) }
        }
        if boundaryPositionIsAuthoritative {
            newContentBoundaryPosition = boundaryPosition.map { min(max(0, $0), itemCount) }
        }
        measuredWidth = contentWidth
        if removed > 0, let scrollView = enclosingScrollView {
            let origin = scrollView.contentView.bounds.origin
            scrollView.contentView.scroll(to: NSPoint(
                x: origin.x,
                y: max(0, origin.y - CGFloat(removedHeight))
            ))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        updateDocumentHeight()
        updateBlinkTimer()
        needsDisplay = true
        guard removed > 0 || !preparedItems.isEmpty || !markerChanges.isEmpty || boundaryPositionIsAuthoritative else {
            return
        }
        batchMutationCountForTesting += 1
        if postsAccessibilityNotification {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    func removeFirst(_ count: Int) {
        let removed = min(max(0, count), itemCount)
        guard removed > 0 else { return }
        if let hoveredLink,
           let physicalIndex = itemIndices[hoveredLink.itemID],
           physicalIndex - head < removed {
            self.hoveredLink = nil
        }
        let removedHeight = layoutIndex.yOffset(for: removed) ?? 0
        for index in 0..<removed {
            if let removedItem = item(at: index) {
                if hasBlink(removedItem) { blinkingItemCount -= 1 }
                itemIndices.removeValue(forKey: removedItem.id)
                markedItems.remove(removedItem.id)
            }
        }
        head += removed
        if let newContentBoundaryPosition {
            self.newContentBoundaryPosition = max(0, newContentBoundaryPosition - removed)
        }
        layoutIndex.removeFirst(removed)
        adjustSelectionAfterRemovingFirst(removed)
        if head >= 1_024, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
            rebuildIndexMap()
        }
        updateDocumentHeight()
        if let scrollView = enclosingScrollView {
            let origin = scrollView.contentView.bounds.origin
            scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: max(0, origin.y - removedHeight)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        updateBlinkTimer()
        needsDisplay = true
    }

    @discardableResult
    func removeLast() -> Item? {
        guard itemCount > 0 else { return nil }
        let item = storage.removeLast()
        if hoveredLink?.itemID == item.id { hoveredLink = nil }
        if hasBlink(item) { blinkingItemCount -= 1 }
        markedItems.remove(item.id)
        itemIndices.removeValue(forKey: item.id)
        if let newContentBoundaryPosition {
            self.newContentBoundaryPosition = min(newContentBoundaryPosition, itemCount)
        }
        layoutIndex.removeLast()
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        }
        clampSelection()
        updateDocumentHeight()
        updateBlinkTimer()
        needsDisplay = true
        return item
    }

    func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        itemIndices.removeAll(keepingCapacity: true)
        layoutIndex.removeAll(keepingCapacity: true)
        anchor = nil
        focus = nil
        hoveredLink = nil
        markedItems.removeAll()
        newContentBoundaryPosition = nil
        blinkingItemCount = 0
        renderedItemCount = 0
        cancelPreviewLoads()
        updateDocumentHeight()
        updateBlinkTimer()
        needsDisplay = true
    }

    func applyAccessibilityDisplayOptions(_ options: AccessibilityDisplayOptions) {
        guard options != displayOptions else { return }
        displayOptions = options
        if options.reduceMotion {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkVisible = true
            animationTimer?.invalidate()
            animationTimer = nil
            resetAnimationsToFirstFrame()
        } else {
            updateBlinkTimer()
            updateAnimationTimer()
        }
        needsDisplay = true
    }

    func select(itemID: UUID, range: NSRange) -> Bool {
        guard let physicalIndex = itemIndices[itemID] else { return false }
        let itemIndex = physicalIndex - head
        guard let value = item(at: itemIndex) else { return false }
        let lower = max(0, min(value.attributedText.length, range.location))
        let upper = max(lower, min(value.attributedText.length, NSMaxRange(range)))
        anchor = Position(item: itemIndex, offset: lower)
        focus = Position(item: itemIndex, offset: upper)
        scrollSelectionToVisible()
        needsDisplay = true
        postSelectionAccessibilityChange()
        return true
    }

    func selectAllContent() {
        guard let last = item(at: itemCount - 1) else { return }
        anchor = .init(item: 0, offset: 0)
        focus = .init(item: itemCount - 1, offset: last.attributedText.length)
        needsDisplay = true
        postSelectionAccessibilityChange()
    }

    func selectedAttributedString() -> NSAttributedString? {
        guard let range = normalizedSelection(), !range.isEmpty else { return nil }
        let result = NSMutableAttributedString()
        for itemIndex in range.lower.item...range.upper.item {
            guard let value = item(at: itemIndex) else { continue }
            let lower = itemIndex == range.lower.item ? range.lower.offset : 0
            let upper = itemIndex == range.upper.item ? range.upper.offset : value.attributedText.length
            guard upper > lower else { continue }
            result.append(value.attributedText.attributedSubstring(
                from: NSRange(location: lower, length: upper - lower)
            ))
        }
        return result
    }

    func selectedString() -> String? { selectedAttributedString()?.string }

    func scrollToEnd(animated: Bool = false) {
        guard let scrollView = enclosingScrollView else { return }
        let target = max(0, bounds.height - scrollView.contentSize.height)
        let point = NSPoint(x: 0, y: target)
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            scrollAnimationTargetUpdateCountForTesting += 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                scrollView.contentView.animator().setBoundsOrigin(point)
            }
        } else {
            scrollView.contentView.scroll(to: point)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
        onUserScrollToEnd?()
    }

    func setMarker(itemID: UUID, marked: Bool) {
        if marked { markedItems.insert(itemID) } else { markedItems.remove(itemID) }
        if let physicalIndex = itemIndices[itemID] {
            setNeedsDisplay(itemRect(at: physicalIndex - head))
        }
    }

    func toggleMarker(itemID: UUID) {
        if !markedItems.insert(itemID).inserted { markedItems.remove(itemID) }
        if let physicalIndex = itemIndices[itemID] {
            setNeedsDisplay(itemRect(at: physicalIndex - head))
        }
    }

    func isMarked(itemID: UUID) -> Bool { markedItems.contains(itemID) }

    func setNewContentBoundary(position: Int?) {
        newContentBoundaryPosition = position.map { min(max(0, $0), itemCount) }
        needsDisplay = true
    }

    /// Compatibility shim for callers that still identify a boundary by the
    /// first unread line. New code should use the logical insertion position.
    func setNewContentBoundary(itemID: UUID?) {
        let position = itemID.flatMap { itemIndices[$0].map { $0 - head } }
        setNewContentBoundary(position: position)
    }

    func itemID(at logicalIndex: Int) -> UUID? { item(at: logicalIndex)?.id }

    func visibleItemCount(in rect: NSRect) -> Int {
        layoutIndex.visibleRange(
            intersecting: Double(rect.minY - contentInsets.top)..<Double(rect.maxY - contentInsets.top)
        ).count
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged, abs(contentWidth - measuredWidth) > 0.5 { rebuildMeasurements() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        rebuildMeasurements()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self
        )
        addTrackingArea(next)
        trackingArea = next
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoveredLink(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredLink(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredLink(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        canvasBackgroundColor.setFill()
        dirtyRect.fill()
        let contentRange = Double(dirtyRect.minY - contentInsets.top)..<Double(dirtyRect.maxY - contentInsets.top)
        let visible = layoutIndex.visibleRange(intersecting: contentRange)
        lastDrawnItemCount = visible.count
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        for index in visible {
            guard let value = item(at: index), let y = layoutIndex.yOffset(for: index),
                  let height = layoutIndex.height(at: index) else { continue }
            let rect = NSRect(
                x: contentInsets.left,
                y: contentInsets.top + CGFloat(y),
                width: contentWidth,
                height: CGFloat(height)
            )
            drawMarker(for: value, in: rect)
            drawParagraphDecoration(value.paragraph, in: rect)
            let attributed = attributedTextForDrawing(value, itemIndex: index)
            let textRect = textRect(for: value, in: rect)
            drawCoreText(attributed, in: textRect, context: context)
            drawAssets(value.assets, attributedText: attributed, in: textRect)
            drawInlinePreviews(value.previews, item: value, in: rect)
        }

        if let boundaryY = newContentBoundaryY,
           dirtyRect.intersects(NSRect(x: 0, y: boundaryY - 2, width: bounds.width, height: 4)) {
            drawNewContentBoundary(at: boundaryY)
        }
    }

    private func drawParagraphDecoration(_ paragraph: ParagraphStyle, in rect: NSRect) {
        let rect = paragraphDecorationRect(paragraph, in: rect)
        if let background = paragraph.background {
            NSColor(
                calibratedRed: CGFloat(background.red) / 255,
                green: CGFloat(background.green) / 255,
                blue: CGFloat(background.blue) / 255,
                alpha: CGFloat(background.alpha) / 255
            ).setFill()
            let radius = paragraph.borderStyle == .round ? min(8, rect.height / 3) : 0
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }
        let color = paragraph.strokeColor.map {
            NSColor(
                calibratedRed: CGFloat($0.red) / 255,
                green: CGFloat($0.green) / 255,
                blue: CGFloat($0.blue) / 255,
                alpha: CGFloat($0.alpha) / 255
            )
        } ?? NSColor.separatorColor
        color.setStroke()
        if paragraph.strokeWidth > 0 {
            let path = NSBezierPath()
            path.lineWidth = paragraph.strokeWidth
            switch paragraph.strokeStyle {
            case .outline:
                let pathRect = rect.insetBy(dx: paragraph.strokeWidth / 2, dy: paragraph.strokeWidth / 2)
                let radius = paragraph.borderStyle == .round ? min(8, pathRect.height / 3) : 0
                path.appendRoundedRect(pathRect, xRadius: radius, yRadius: radius)
            case .top:
                path.move(to: .init(x: rect.minX, y: rect.minY))
                path.line(to: .init(x: rect.maxX, y: rect.minY))
            case .bottom:
                path.move(to: .init(x: rect.minX, y: rect.maxY))
                path.line(to: .init(x: rect.maxX, y: rect.maxY))
            }
            path.stroke()
        }
        if paragraph.horizontalRule {
            let path = NSBezierPath()
            path.move(to: .init(x: rect.minX, y: rect.midY))
            path.line(to: .init(x: rect.maxX, y: rect.midY))
            path.lineWidth = max(1, paragraph.strokeWidth)
            path.stroke()
        }
    }

    private func paragraphDecorationRect(_ paragraph: ParagraphStyle, in rect: NSRect) -> NSRect {
        let left = rect.width * CGFloat(max(0, paragraph.leftIndent) / 100)
        let right = rect.width * CGFloat(max(0, paragraph.rightIndent) / 100)
        return NSRect(
            x: rect.minX + min(left, rect.width),
            y: rect.minY,
            width: max(0, rect.width - left - right),
            height: rect.height
        )
    }

    private func paragraphPreviewContentRect(_ paragraph: ParagraphStyle, in rect: NSRect) -> NSRect {
        let decoration = paragraphDecorationRect(paragraph, in: rect)
        let border = CGFloat(max(0, paragraph.borderWidth))
        let inset = min(border, decoration.width / 2)
        return decoration.insetBy(dx: inset, dy: 0)
    }

    override func mouseDown(with event: NSEvent) {
        onInteractionWillBegin?()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPreview = previewHit(at: point)
        if mouseDownPreview != nil {
            mouseDownPosition = nil
            setHoveredLink(nil)
            return
        }
        updateHoveredLink(at: point)
        guard let position = textPosition(at: point) else {
            mouseDownPosition = nil
            return
        }
        mouseDownPosition = position
        switch event.clickCount {
        case 2:
            let word = wordRange(at: position)
            anchor = .init(item: position.item, offset: word.location)
            focus = .init(item: position.item, offset: NSMaxRange(word))
        case 3...:
            guard let value = item(at: position.item) else { return }
            anchor = .init(item: position.item, offset: 0)
            focus = .init(item: position.item, offset: value.attributedText.length)
        default:
            if event.modifierFlags.contains(.shift), anchor != nil { focus = position }
            else { anchor = position; focus = position }
        }
        needsDisplay = true
        postSelectionAccessibilityChange()
    }

    override func mouseDragged(with event: NSEvent) {
        if mouseDownPreview != nil { return }
        let point = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        if let position = textPosition(at: point) { focus = position }
        needsDisplay = true
        postSelectionAccessibilityChange()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPosition = nil
            mouseDownPreview = nil
            onInteractionCompleted?()
        }
        if let mouseDownPreview {
            let point = convert(event.locationInWindow, from: nil)
            guard let hit = previewHit(at: point), hit == mouseDownPreview else { return }
            activatePreview(hit.source, modifierFlags: event.modifierFlags)
            return
        }
        if !selectedRangeIsEmpty {
            onSelectionCompleted?()
            return
        }
        guard selectedRangeIsEmpty,
              let position = textPosition(at: convert(event.locationInWindow, from: nil)),
              position == mouseDownPosition,
              let value = item(at: position.item),
              position.offset < value.attributedText.length,
              let url = value.attributedText.attribute(.link, at: position.offset, effectiveRange: nil) as? URL else { return }
        activateLink(url, modifierFlags: event.modifierFlags)
    }

    override func resetCursorRects() {
        removeAllToolTips()
        addCursorRect(visibleRect, cursor: .iBeam)
        addToolTip(visibleRect, owner: self, userData: nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if let menu = onContextMenu?(event) { return menu }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    @objc func copy(_ sender: Any?) {
        onInteractionWillBegin?()
        guard let selected = selectedAttributedString(), selected.length > 0 else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selected.string, forType: .string)
        if let html = try? selected.data(
            from: NSRange(location: 0, length: selected.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        ) {
            pasteboard.setData(html, forType: .html)
        }
    }

    override func selectAll(_ sender: Any?) {
        onInteractionWillBegin?()
        selectAllContent()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 116, onPageUp?() == true {
            return
        }
        if event.keyCode == 121, onPageDown?() == true {
            return
        }
        super.keyDown(with: event)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): !selectedRangeIsEmpty
        case #selector(selectAll(_:)): itemCount > 0
        default: true
        }
    }

    nonisolated func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        MainActor.assumeIsolated {
            guard let position = textPosition(at: point), let item = item(at: position.item),
                  item.attributedText.length > 0 else { return "" }
            let index = min(position.offset, item.attributedText.length - 1)
            return item.attributedText.attribute(.toolTip, at: index, effectiveRange: nil) as? String ?? ""
        }
    }

    override func accessibilityValue() -> Any? {
        retainedItems.map { $0.attributedText.string }.joined()
    }

    override func accessibilitySelectedText() -> String? { selectedString() }

    override func accessibilityNumberOfCharacters() -> Int {
        retainedItems.reduce(0) { $0 + $1.attributedText.length }
    }

    private var retainedItems: ArraySlice<Item> { storage[head...] }
    private var contentWidth: CGFloat {
        let available = max(1, bounds.width - contentInsets.left - contentInsets.right)
        return min(available, fixedContentWidth ?? available)
    }

    private func item(at logicalIndex: Int) -> Item? {
        guard logicalIndex >= 0, logicalIndex < itemCount else { return nil }
        return storage[head + logicalIndex]
    }

    private func measuredHeight(for item: Item) -> Double {
        heightMeasurementCountForTesting += 1
        let framesetter = CTFramesetterCreateWithAttributedString(attributedTextForLayout(item))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: item.attributedText.length),
            nil,
            CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            nil
        )
        let compactAssetHeight = item.assets.map { $0.asset.kind == .avatar ? 34.0 : 26.0 }.max() ?? 0
        let previewHeight = inlinePreviewHeight(for: item)
        let verticalSpacing = max(0, item.paragraph.topPadding)
            + max(0, item.paragraph.bottomPadding)
            + max(0, item.paragraph.borderWidth) * 2
        return Double(max(18, compactAssetHeight, ceil(size.height) + 1 + previewHeight + verticalSpacing))
    }

    private func rebuildMeasurements(using preparedHeights: [Double]? = nil) {
        measuredWidth = contentWidth
        layoutIndex.replaceHeights(with: preparedHeights ?? retainedItems.map(measuredHeight(for:)))
        renderedItemCount += itemCount
        updateDocumentHeight()
        needsDisplay = true
    }

    private func updateDocumentHeight() {
        let viewportHeight = enclosingScrollView?.contentSize.height ?? 0
        let height = max(
            viewportHeight,
            CGFloat(layoutIndex.totalHeight) + contentInsets.top + contentInsets.bottom
        )
        if abs(frame.height - height) > 0.5 {
            super.setFrameSize(NSSize(width: frame.width, height: height))
        }
    }

    private func rebuildIndexMap() {
        itemIndices.removeAll(keepingCapacity: true)
        for physicalIndex in head..<storage.count {
            itemIndices[storage[physicalIndex].id] = physicalIndex
        }
    }

    private func itemRect(at index: Int) -> NSRect {
        guard let y = layoutIndex.yOffset(for: index), let height = layoutIndex.height(at: index) else { return .zero }
        return NSRect(x: 0, y: contentInsets.top + y, width: bounds.width, height: height)
    }

    private func attributedTextForDrawing(_ item: Item, itemIndex: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributedTextForLayout(item))
        if let range = selectionRange(in: itemIndex), range.length > 0 {
            result.addAttributes([
                .backgroundColor: selectionBackgroundColor,
                .foregroundColor: selectionForegroundColor,
            ], range: range)
        }
        if !blinkVisible {
            result.enumerateAttribute(Self.blinkAttribute, in: NSRange(location: 0, length: result.length)) { value, range, _ in
                guard value != nil else { return }
                result.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
            }
        }
        if let hoveredLink, hoveredLink.itemID == item.id {
            result.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: hoveredLink.range
            )
        }
        return result
    }

    private func attributedTextForLayout(_ item: Item) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: item.attributedText)
        guard result.length > 0 else { return result }

        let range = NSRange(location: 0, length: result.length)
        let existing = (result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        let leftPixels = contentWidth * CGFloat(item.paragraph.leftIndent / 100)
        let rightPixels = contentWidth * CGFloat(item.paragraph.rightIndent / 100)
        let originalHeadIndent = CGFloat(item.paragraph.leftIndent + item.paragraph.wrappedIndent)
        let extraWrappedIndent = max(0, existing.headIndent - originalHeadIndent)
        let border = CGFloat(max(0, item.paragraph.borderWidth))

        existing.firstLineHeadIndent = leftPixels + border
        existing.headIndent = leftPixels + border + CGFloat(item.paragraph.wrappedIndent) + extraWrappedIndent
        existing.tailIndent = -(rightPixels + border)
        existing.paragraphSpacingBefore = 0
        existing.paragraphSpacing = max(
            0,
            existing.paragraphSpacing - CGFloat(max(0, item.paragraph.bottomPadding))
        )
        result.addAttribute(.paragraphStyle, value: existing, range: range)
        return result
    }

    private func updateHoveredLink(at point: NSPoint) {
        guard previewHit(at: point) == nil else {
            setHoveredLink(nil)
            return
        }
        guard let position = textPosition(at: point),
              let value = item(at: position.item),
              position.offset >= 0,
              position.offset < value.attributedText.length else {
            setHoveredLink(nil)
            return
        }

        var range = NSRange(location: 0, length: 0)
        guard value.attributedText.attribute(.link, at: position.offset, effectiveRange: &range) as? URL != nil else {
            setHoveredLink(nil)
            return
        }
        setHoveredLink(.init(itemID: value.id, range: range))
    }

    private func setHoveredLink(_ next: HoveredLink?) {
        let normalized = next.flatMap { candidate -> HoveredLink? in
            guard let physicalIndex = itemIndices[candidate.itemID],
                  let value = item(at: physicalIndex - head),
                  candidate.range.location >= 0,
                  candidate.range.length > 0,
                  NSMaxRange(candidate.range) <= value.attributedText.length,
                  value.attributedText.attribute(.link, at: candidate.range.location, effectiveRange: nil) != nil else {
                return nil
            }
            return candidate
        }
        guard normalized != hoveredLink else { return }
        let previous = hoveredLink
        hoveredLink = normalized
        for itemID in Set([previous?.itemID, normalized?.itemID].compactMap { $0 }) {
            guard let physicalIndex = itemIndices[itemID] else { continue }
            setNeedsDisplay(itemRect(at: physicalIndex - head))
        }
    }

    private func isBrowserLink(_ url: URL) -> Bool {
        url.scheme?.lowercased() != "beipmu-action"
    }

    private func activateLink(_ url: URL, modifierFlags: NSEvent.ModifierFlags) {
        guard !isBrowserLink(url) || modifierFlags.contains(.command) else { return }
        onLink?(url)
    }

    private func activatePreview(_ url: URL, modifierFlags: NSEvent.ModifierFlags) {
        guard modifierFlags.contains(.command) else { return }
        onLink?(url)
    }

    private func drawCoreText(
        _ attributed: NSAttributedString,
        in rect: NSRect,
        context: CGContext
    ) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: rect.width, height: max(1, rect.height)), transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    private func drawMarker(for item: Item, in rect: NSRect) {
        guard markedItems.contains(item.id) else { return }
        NSColor.systemYellow.setFill()
        let marker = NSRect(x: 1, y: rect.minY + 1, width: 4, height: max(3, rect.height - 2))
        marker.fill()
        if displayOptions.differentiateWithoutColor || displayOptions.increaseContrast {
            NSColor.labelColor.setStroke()
            NSBezierPath(rect: marker).stroke()
        }
    }

    private var newContentBoundaryY: CGFloat? {
        guard let position = newContentBoundaryPosition else { return nil }
        let clamped = min(max(0, position), itemCount)
        let offset: Double
        if clamped < itemCount {
            guard let itemOffset = layoutIndex.yOffset(for: clamped) else { return nil }
            offset = itemOffset
        } else {
            offset = layoutIndex.totalHeight
        }
        return contentInsets.top + CGFloat(offset) - 3
    }

    private func drawNewContentBoundary(at y: CGFloat) {
        NSColor.systemRed.setStroke()
        let path = NSBezierPath()
        // Keep the separator in the inter-line breathing room instead of
        // putting it directly against the first unread glyphs.
        path.move(to: NSPoint(x: contentInsets.left, y: y))
        path.line(to: NSPoint(x: bounds.width - contentInsets.right, y: y))
        path.lineWidth = 2
        path.stroke()
    }

    private func drawAssets(
        _ assets: [(asset: InlineAsset, displayOffset: Int)],
        attributedText: NSAttributedString,
        in rect: NSRect
    ) {
        guard !assets.isEmpty else { return }
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        for entry in assets {
            let point = approximatePoint(
                forCharacterOffset: entry.displayOffset,
                attributedText: attributedText,
                rect: rect
            )
            if let image = imageCache[entry.asset.source] {
                let side: CGFloat = entry.asset.kind == .avatar ? 32 : 24
                let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
                let size = NSSize(width: side * max(0.5, min(2, ratio)), height: side)
                image.draw(
                    in: NSRect(x: point.x, y: point.y, width: size.width, height: size.height),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
            } else {
                scheduleImageLoad(entry.asset.source)
                let symbol = switch entry.asset.kind {
                case .image: "photo"
                case .avatar: "person.crop.square"
                case .icon: "star.square"
                }
                NSImage(systemSymbolName: symbol, accessibilityDescription: entry.asset.altText)?
                    .withSymbolConfiguration(symbolConfig)?
                    .draw(in: NSRect(x: point.x, y: point.y, width: 16, height: 16))
            }
        }
    }

    private func drawInlinePreviews(
        _ previews: [InlinePreview],
        item: Item,
        in rect: NSRect
    ) {
        guard showsInlineImagePreviews, !previews.isEmpty else { return }
        let rects = previewRects(for: item, in: rect)
        for (index, preview) in previews.enumerated() where rects.indices.contains(index) {
            let box = rects[index]
            drawPreview(preview, in: box)
        }
    }

    private func drawPreview(_ preview: InlinePreview, in rect: NSRect) {
        let background = NSColor.controlBackgroundColor.withAlphaComponent(0.5)
        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()

        guard let image = imageCache[preview.source] else {
            schedulePreviewLoad(preview.source)
            let title = previewStates[preview.source] == .failed ? "Unable to load image" : "Loading image…"
            let symbol = previewStates[preview.source] == .failed ? "exclamationmark.triangle" : "photo"
            let symbolSize = min(22, max(14, rect.height * 0.22))
            let symbolRect = NSRect(
                x: rect.midX - symbolSize / 2,
                y: rect.midY - symbolSize / 2 - 10,
                width: symbolSize,
                height: symbolSize
            )
            NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.draw(
                in: symbolRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: min(12, max(9, rect.height * 0.12))),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let label = NSAttributedString(string: title, attributes: attributes)
            let labelSize = label.size()
            label.draw(at: NSPoint(
                x: rect.midX - labelSize.width / 2,
                y: rect.midY + 4
            ))
            return
        }

        let inset = rect.insetBy(dx: 6, dy: 6)
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(inset.width / image.size.width, inset.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(
            in: NSRect(
                x: inset.midX - size.width / 2,
                y: inset.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    private func scheduleImageLoad(_ url: URL) {
        guard imageCache[url] == nil, imageTasks[url] == nil else { return }
        imageTasks[url] = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled, let self else { return }
            imageTasks.removeValue(forKey: url)
            guard let data, let image = NSImage(data: data) else { return }
            imageCache[url] = image
            updateAnimationTimer()
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    private func schedulePreviewLoad(_ url: URL) {
        guard showsInlineImagePreviews,
              Self.isHTTPURL(url),
              imageCache[url] == nil,
              previewTasks[url] == nil,
              previewStates[url] != .failed else { return }
        previewStates[url] = .loading
        previewDownloadCount += 1
        previewTasks[url] = Task { [weak self] in
            let data = try? await URLSession.shared.data(from: url).0
            guard !Task.isCancelled, let self else { return }
            previewTasks.removeValue(forKey: url)
            guard let data, let image = NSImage(data: data) else {
                previewStates[url] = .failed
                needsDisplay = true
                return
            }
            previewStates.removeValue(forKey: url)
            imageCache[url] = image
            updateAnimationTimer()
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    private func cancelPreviewLoads(keeping urls: Set<URL> = []) {
        for url in Array(previewTasks.keys) where !urls.contains(url) {
            guard let task = previewTasks[url] else { continue }
            task.cancel()
            previewTasks.removeValue(forKey: url)
            previewStates.removeValue(forKey: url)
            if !hasCompactAsset(source: url) { imageCache.removeValue(forKey: url) }
        }
        for url in Array(previewStates.keys) where !urls.contains(url) {
            previewStates.removeValue(forKey: url)
            if !hasCompactAsset(source: url) { imageCache.removeValue(forKey: url) }
        }
    }

    private func hasCompactAsset(source url: URL) -> Bool {
        retainedItems.contains { item in item.assets.contains { $0.asset.source == url } }
    }

    private func textRect(for item: Item, in rect: NSRect) -> NSRect {
        let top = CGFloat(max(0, item.paragraph.topPadding) + max(0, item.paragraph.borderWidth))
        return NSRect(
            x: rect.minX,
            y: rect.minY + top,
            width: rect.width,
            height: max(1, textHeight(for: item))
        )
    }

    private func textHeight(for item: Item) -> CGFloat {
        let framesetter = CTFramesetterCreateWithAttributedString(attributedTextForLayout(item))
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: item.attributedText.length),
            nil,
            CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            nil
        )
        return max(18, ceil(size.height) + 1)
    }

    private func previewBoxSize(for paragraph: ParagraphStyle) -> NSSize {
        let contentRect = paragraphPreviewContentRect(
            paragraph,
            in: NSRect(x: 0, y: 0, width: contentWidth, height: 0)
        )
        let width = min(240, max(1, contentRect.width))
        return NSSize(width: width, height: max(1, 160 * width / 240))
    }

    private func inlinePreviewHeight(for item: Item) -> CGFloat {
        guard showsInlineImagePreviews, !item.previews.isEmpty else { return 0 }
        let boxHeight = previewBoxSize(for: item.paragraph).height
        return 4 + CGFloat(item.previews.count) * boxHeight
            + CGFloat(max(0, item.previews.count - 1)) * 6
    }

    private func previewRects(for item: Item, in rect: NSRect) -> [NSRect] {
        guard showsInlineImagePreviews, !item.previews.isEmpty else { return [] }
        let text = textRect(for: item, in: rect)
        let content = paragraphPreviewContentRect(item.paragraph, in: rect)
        let size = previewBoxSize(for: item.paragraph)
        let y = text.maxY + 4
        return item.previews.indices.map { index in
            NSRect(
                x: content.minX,
                y: y + CGFloat(index) * (size.height + 6),
                width: size.width,
                height: size.height
            )
        }
    }

    private func previewHit(at point: NSPoint) -> PreviewHit? {
        let contentRange = Double(point.y - contentInsets.top)..<Double(point.y - contentInsets.top + 0.01)
        let candidates = layoutIndex.visibleRange(intersecting: contentRange)
        for index in candidates {
            guard let item = item(at: index),
                  let y = layoutIndex.yOffset(for: index),
                  let height = layoutIndex.height(at: index) else { continue }
            let rect = NSRect(
                x: contentInsets.left,
                y: contentInsets.top + CGFloat(y),
                width: contentWidth,
                height: CGFloat(height)
            )
            for (preview, previewRect) in zip(item.previews, previewRects(for: item, in: rect))
                where previewRect.contains(point) {
                return .init(itemID: item.id, source: preview.source, rect: previewRect)
            }
        }
        return nil
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func updateAnimationTimer() {
        if displayOptions.reduceMotion {
            animationTimer?.invalidate()
            animationTimer = nil
            resetAnimationsToFirstFrame()
            return
        }
        let hasAnimation = imageCache.values.contains { image in
            image.representations.contains { representation in
                guard let bitmap = representation as? NSBitmapImageRep else { return false }
                return (bitmap.value(forProperty: .frameCount) as? Int ?? 1) > 1
            }
        }
        if hasAnimation, animationTimer == nil {
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advanceAnimations() }
            }
        } else if !hasAnimation {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func advanceAnimations() {
        var advanced = false
        for image in imageCache.values {
            for case let bitmap as NSBitmapImageRep in image.representations {
                let count = bitmap.value(forProperty: .frameCount) as? Int ?? 1
                guard count > 1 else { continue }
                let current = bitmap.value(forProperty: .currentFrame) as? Int ?? 0
                bitmap.setProperty(.currentFrame, withValue: (current + 1) % count)
                advanced = true
            }
        }
        if advanced { needsDisplay = true }
    }

    private func resetAnimationsToFirstFrame() {
        for image in imageCache.values {
            for case let bitmap as NSBitmapImageRep in image.representations {
                if (bitmap.value(forProperty: .frameCount) as? Int ?? 1) > 1 {
                    bitmap.setProperty(.currentFrame, withValue: 0)
                }
            }
        }
    }

    private func approximatePoint(
        forCharacterOffset offset: Int,
        attributedText: NSAttributedString,
        rect: NSRect
    ) -> NSPoint {
        let prefixLength = min(max(0, offset), attributedText.length)
        let prefix = attributedText.attributedSubstring(from: NSRange(location: 0, length: prefixLength))
        let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(prefix), nil, nil, nil)
        return NSPoint(x: min(rect.maxX - 16, rect.minX + CGFloat(width)), y: rect.minY + 1)
    }

    private func textPosition(at point: NSPoint) -> Position? {
        guard let itemIndex = layoutIndex.index(atVerticalOffset: Double(point.y - contentInsets.top)),
              let value = item(at: itemIndex), let y = layoutIndex.yOffset(for: itemIndex),
              let height = layoutIndex.height(at: itemIndex) else { return nil }
        let local = CGPoint(
            x: max(0, point.x - contentInsets.left),
            y: CGFloat(height) - (point.y - contentInsets.top - CGFloat(y))
        )
        let path = CGPath(
            rect: CGRect(
                x: 0,
                y: CGFloat(max(0, value.paragraph.bottomPadding) + max(0, value.paragraph.borderWidth)),
                width: contentWidth,
                height: max(
                    1,
                    CGFloat(height)
                        - CGFloat(max(0, value.paragraph.topPadding) + max(0, value.paragraph.bottomPadding))
                        - CGFloat(max(0, value.paragraph.borderWidth) * 2)
                )
            ),
            transform: nil
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributedTextForLayout(value))
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: value.attributedText.length),
            path,
            nil
        )
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return .init(item: itemIndex, offset: 0) }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var selected = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for index in lines.indices {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(lines[index], &ascent, &descent, nil)
            let lower = origins[index].y - descent
            let upper = origins[index].y + ascent
            let distance = local.y < lower ? lower - local.y : (local.y > upper ? local.y - upper : 0)
            if distance < bestDistance { bestDistance = distance; selected = index }
        }
        let relative = CGPoint(x: local.x - origins[selected].x, y: 0)
        let rawIndex = CTLineGetStringIndexForPosition(lines[selected], relative)
        let offset = max(0, min(value.attributedText.length, rawIndex == kCFNotFound ? 0 : rawIndex))
        return .init(item: itemIndex, offset: offset)
    }

    private func wordRange(at position: Position) -> NSRange {
        guard let value = item(at: position.item), value.attributedText.length > 0 else { return .init() }
        let text = value.attributedText.string as NSString
        let start = min(position.offset, text.length - 1)
        let composed = text.rangeOfComposedCharacterSequence(at: start)
        let word = CharacterSet.alphanumerics
            .union(.nonBaseCharacters)
            .union(CharacterSet(charactersIn: "_"))
        let whitespace = CharacterSet.whitespacesAndNewlines
        func category(of range: NSRange) -> Int {
            let scalars = text.substring(with: range).unicodeScalars
            if scalars.allSatisfy(whitespace.contains) { return 1 }
            if scalars.allSatisfy(word.contains) { return 2 }
            return 0
        }
        let selectedCategory = category(of: composed)
        guard selectedCategory != 0 else { return composed }
        var lower = composed.location
        var upper = NSMaxRange(composed)
        while lower > 0 {
            let previous = text.rangeOfComposedCharacterSequence(at: lower - 1)
            guard category(of: previous) == selectedCategory else { break }
            lower = previous.location
        }
        while upper < text.length {
            let next = text.rangeOfComposedCharacterSequence(at: upper)
            guard category(of: next) == selectedCategory else { break }
            upper = NSMaxRange(next)
        }
        return NSRange(location: lower, length: upper - lower)
    }

    private func normalizedSelection() -> Selection? {
        guard let anchor, let focus else { return nil }
        return compare(anchor, focus) <= 0
            ? Selection(lower: anchor, upper: focus)
            : Selection(lower: focus, upper: anchor)
    }

    private func compare(_ lhs: Position, _ rhs: Position) -> Int {
        if lhs.item != rhs.item { return lhs.item < rhs.item ? -1 : 1 }
        if lhs.offset == rhs.offset { return 0 }
        return lhs.offset < rhs.offset ? -1 : 1
    }

    private func selectionRange(in itemIndex: Int) -> NSRange? {
        guard let selection = normalizedSelection(),
              itemIndex >= selection.lower.item, itemIndex <= selection.upper.item,
              let value = item(at: itemIndex) else { return nil }
        let lower = itemIndex == selection.lower.item ? selection.lower.offset : 0
        let upper = itemIndex == selection.upper.item ? selection.upper.offset : value.attributedText.length
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    private func scrollSelectionToVisible() {
        guard let focus, let y = layoutIndex.yOffset(for: focus.item),
              let height = layoutIndex.height(at: focus.item) else { return }
        scrollToVisible(NSRect(x: 0, y: contentInsets.top + y, width: bounds.width, height: height))
    }

    private func adjustSelectionAfterRemovingFirst(_ count: Int) {
        func adjusted(_ position: Position?) -> Position? {
            guard let position, position.item >= count else { return nil }
            return .init(item: position.item - count, offset: position.offset)
        }
        anchor = adjusted(anchor)
        focus = adjusted(focus)
    }

    private func clampSelection() {
        guard itemCount > 0 else { anchor = nil; focus = nil; return }
        func clamped(_ position: Position?) -> Position? {
            guard let position else { return nil }
            let index = min(position.item, itemCount - 1)
            let length = item(at: index)?.attributedText.length ?? 0
            return .init(item: index, offset: min(position.offset, length))
        }
        anchor = clamped(anchor)
        focus = clamped(focus)
    }

    private func updateBlinkTimer() {
        if displayOptions.reduceMotion || blinkInterval <= 0 {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkVisible = true
            return
        }
        if blinkingItemCount > 0, blinkTimer == nil {
            blinkTimerCreationCountForTesting += 1
            blinkTimer = Timer.scheduledTimer(withTimeInterval: blinkInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.blinkVisible.toggle()
                    self?.needsDisplay = true
                }
            }
        } else if blinkingItemCount == 0 {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkVisible = true
        }
    }

    private func hasBlink(_ item: Item) -> Bool {
        guard item.attributedText.length > 0 else { return false }
        var found = false
        item.attributedText.enumerateAttribute(
            Self.blinkAttribute,
            in: NSRange(location: 0, length: item.attributedText.length)
        ) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    private func postSelectionAccessibilityChange() {
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        applyAccessibilityDisplayOptions(.current)
    }
}
