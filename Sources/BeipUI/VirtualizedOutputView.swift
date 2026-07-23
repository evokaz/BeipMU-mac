import AppKit
import BeipCore
import CoreText

@MainActor
final class VirtualizedOutputView: NSView, NSUserInterfaceValidations, NSViewToolTipOwner {
    struct Item {
        var id: UUID
        var attributedText: NSAttributedString
        var contentRange: NSRange
        var assets: [(asset: InlineAsset, displayOffset: Int)]
        var paragraph: ParagraphStyle = .init()
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

    static let blinkAttribute = NSAttributedString.Key("BeipMUBlink")

    var onLink: ((URL) -> Void)?
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
    private var markedItems: Set<UUID> = []
    private var blinkTimer: Timer?
    private var blinkVisible = true
    private var blinkingItemCount = 0
    private var imageCache: [URL: NSImage] = [:]
    private var imageTasks: [URL: Task<Void, Never>] = [:]
    private var animationTimer: Timer?
    private var displayOptions = AccessibilityDisplayOptions.current
    private let horizontalInset: CGFloat = 9
    private let verticalInset: CGFloat = 7
    var canvasBackgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1) {
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
    var isAnimationTimerActive: Bool { animationTimer != nil }
    var selectedRangeIsEmpty: Bool { anchor == nil || anchor == focus }
    var selectedItemID: UUID? { focus.flatMap { item(at: $0.item)?.id } }
    var firstVisibleItemID: UUID? {
        guard let clip = enclosingScrollView?.contentView.bounds else { return item(at: 0)?.id }
        let range = layoutIndex.visibleRange(
            intersecting: Double(clip.minY - verticalInset)..<Double(clip.maxY - verticalInset)
        )
        return item(at: range.lowerBound)?.id
    }

    func setItems(_ items: [Item]) {
        storage = items
        head = 0
        anchor = nil
        focus = nil
        markedItems.formIntersection(items.map(\.id))
        blinkingItemCount = items.reduce(0) { $0 + (hasBlink($1) ? 1 : 0) }
        rebuildIndexMap()
        rebuildMeasurements()
        updateBlinkTimer()
        needsDisplay = true
    }

    func append(_ item: Item) {
        storage.append(item)
        if hasBlink(item) { blinkingItemCount += 1 }
        itemIndices[item.id] = storage.count - 1
        layoutIndex.append(height: measuredHeight(for: item))
        renderedItemCount += 1
        updateDocumentHeight()
        updateBlinkTimer()
        setNeedsDisplay(itemRect(at: itemCount - 1))
    }

    func removeFirst(_ count: Int) {
        let removed = min(max(0, count), itemCount)
        guard removed > 0 else { return }
        let removedHeight = layoutIndex.yOffset(for: removed) ?? 0
        for index in 0..<removed {
            if let removedItem = item(at: index) {
                if hasBlink(removedItem) { blinkingItemCount -= 1 }
                itemIndices.removeValue(forKey: removedItem.id)
                markedItems.remove(removedItem.id)
            }
        }
        head += removed
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
        if hasBlink(item) { blinkingItemCount -= 1 }
        markedItems.remove(item.id)
        let heights = (0..<(itemCount - 1)).compactMap(layoutIndex.height(at:))
        layoutIndex.replaceHeights(with: heights)
        clampSelection()
        rebuildIndexMap()
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
        markedItems.removeAll()
        blinkingItemCount = 0
        renderedItemCount = 0
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

    func scrollToEnd() {
        guard let scrollView = enclosingScrollView else { return }
        let target = max(0, bounds.height - scrollView.contentSize.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func toggleMarker(itemID: UUID) {
        if !markedItems.insert(itemID).inserted { markedItems.remove(itemID) }
        if let physicalIndex = itemIndices[itemID] {
            setNeedsDisplay(itemRect(at: physicalIndex - head))
        }
    }

    func isMarked(itemID: UUID) -> Bool { markedItems.contains(itemID) }

    func visibleItemCount(in rect: NSRect) -> Int {
        layoutIndex.visibleRange(
            intersecting: Double(rect.minY - verticalInset)..<Double(rect.maxY - verticalInset)
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

    override func draw(_ dirtyRect: NSRect) {
        canvasBackgroundColor.setFill()
        dirtyRect.fill()
        let contentRange = Double(dirtyRect.minY - verticalInset)..<Double(dirtyRect.maxY - verticalInset)
        let visible = layoutIndex.visibleRange(intersecting: contentRange)
        lastDrawnItemCount = visible.count
        guard !visible.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }

        for index in visible {
            guard let value = item(at: index), let y = layoutIndex.yOffset(for: index),
                  let height = layoutIndex.height(at: index) else { continue }
            let rect = NSRect(
                x: horizontalInset,
                y: verticalInset + CGFloat(y),
                width: contentWidth,
                height: CGFloat(height)
            )
            drawMarker(for: value, in: rect)
            drawParagraphDecoration(value.paragraph, in: rect)
            let attributed = attributedTextForDrawing(value, itemIndex: index)
            drawCoreText(attributed, in: rect, context: context)
            drawAssets(value.assets, attributedText: attributed, in: rect)
        }
    }

    private func drawParagraphDecoration(_ paragraph: ParagraphStyle, in rect: NSRect) {
        let color = paragraph.strokeColor.map {
            NSColor(
                calibratedRed: CGFloat($0.red) / 255,
                green: CGFloat($0.green) / 255,
                blue: CGFloat($0.blue) / 255,
                alpha: CGFloat($0.alpha) / 255
            )
        } ?? NSColor.separatorColor
        color.setStroke()
        if paragraph.borderWidth > 0 {
            let inset = paragraph.borderWidth / 2
            let pathRect = rect.insetBy(dx: inset, dy: inset)
            let radius = paragraph.borderStyle == .round ? min(8, pathRect.height / 3) : 0
            let path = NSBezierPath(roundedRect: pathRect, xRadius: radius, yRadius: radius)
            path.lineWidth = paragraph.borderWidth
            path.stroke()
        }
        if paragraph.strokeWidth > 0 {
            let path = NSBezierPath()
            path.lineWidth = paragraph.strokeWidth
            switch paragraph.strokeStyle {
            case .outline:
                path.appendRect(rect.insetBy(dx: paragraph.strokeWidth / 2, dy: paragraph.strokeWidth / 2))
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let position = textPosition(at: point) else { return }
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
        let point = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        if let position = textPosition(at: point) { focus = position }
        needsDisplay = true
        postSelectionAccessibilityChange()
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPosition = nil }
        guard selectedRangeIsEmpty,
              let position = textPosition(at: convert(event.locationInWindow, from: nil)),
              position == mouseDownPosition,
              let value = item(at: position.item),
              position.offset < value.attributedText.length,
              let url = value.attributedText.attribute(.link, at: position.offset, effectiveRange: nil) as? URL else { return }
        onLink?(url)
    }

    override func resetCursorRects() {
        removeAllToolTips()
        addCursorRect(visibleRect, cursor: .iBeam)
        addToolTip(visibleRect, owner: self, userData: nil)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    @objc func copy(_ sender: Any?) {
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

    override func selectAll(_ sender: Any?) { selectAllContent() }

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
    private var contentWidth: CGFloat { max(1, bounds.width - horizontalInset * 2) }

    private func item(at logicalIndex: Int) -> Item? {
        guard logicalIndex >= 0, logicalIndex < itemCount else { return nil }
        return storage[head + logicalIndex]
    }

    private func measuredHeight(for item: Item) -> Double {
        let framesetter = CTFramesetterCreateWithAttributedString(item.attributedText)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: item.attributedText.length),
            nil,
            CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            nil
        )
        let assetHeight = item.assets.map { $0.asset.kind == .avatar ? 34.0 : 26.0 }.max() ?? 0
        return Double(max(18, assetHeight, ceil(size.height) + 1))
    }

    private func rebuildMeasurements() {
        measuredWidth = contentWidth
        layoutIndex.replaceHeights(with: retainedItems.map(measuredHeight(for:)))
        renderedItemCount += itemCount
        updateDocumentHeight()
        needsDisplay = true
    }

    private func updateDocumentHeight() {
        let viewportHeight = enclosingScrollView?.contentSize.height ?? 0
        let height = max(viewportHeight, CGFloat(layoutIndex.totalHeight) + verticalInset * 2)
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
        return NSRect(x: 0, y: verticalInset + y, width: bounds.width, height: height)
    }

    private func attributedTextForDrawing(_ item: Item, itemIndex: Int) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: item.attributedText)
        if let range = selectionRange(in: itemIndex), range.length > 0 {
            result.addAttributes([
                .backgroundColor: NSColor.selectedTextBackgroundColor,
                .foregroundColor: NSColor.selectedTextColor,
            ], range: range)
        }
        guard !blinkVisible else { return result }
        result.enumerateAttribute(Self.blinkAttribute, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard value != nil else { return }
            result.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
        }
        return result
    }

    private func drawCoreText(_ attributed: NSAttributedString, in rect: NSRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
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

    private func scheduleImageLoad(_ url: URL) {
        guard imageCache[url] == nil, imageTasks[url] == nil else { return }
        imageTasks[url] = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard let self else { return }
            imageTasks.removeValue(forKey: url)
            guard let data, let image = NSImage(data: data) else { return }
            imageCache[url] = image
            updateAnimationTimer()
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
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
        guard let itemIndex = layoutIndex.index(atVerticalOffset: Double(point.y - verticalInset)),
              let value = item(at: itemIndex), let y = layoutIndex.yOffset(for: itemIndex),
              let height = layoutIndex.height(at: itemIndex) else { return nil }
        let local = CGPoint(
            x: max(0, point.x - horizontalInset),
            y: CGFloat(height) - (point.y - verticalInset - CGFloat(y))
        )
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: contentWidth, height: CGFloat(height)),
            transform: nil
        )
        let framesetter = CTFramesetterCreateWithAttributedString(value.attributedText)
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
        scrollToVisible(NSRect(x: 0, y: verticalInset + y, width: bounds.width, height: height))
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
        if displayOptions.reduceMotion {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkVisible = true
            return
        }
        if blinkingItemCount > 0, blinkTimer == nil {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
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
