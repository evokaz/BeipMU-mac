import AppKit
import BeipCore

/// Coordinates retained rendered lines with the line-virtualized Core Text
/// view. The document view measures retained rows but only draws the rows
/// intersecting its clip view, keeping history size independent of paint cost.
@MainActor
final class OutputTextView: NSObject {
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
    private var secondaryScrollView: NSScrollView?
    private var defaultForeground = NSColor(calibratedWhite: 0.9, alpha: 1)
    private var defaultBackground = NSColor(calibratedWhite: 0.05, alpha: 1)
    private let timestampFormatter: DateFormatter
    private var history = OutputHistory(limit: 10_000)
    private var lineContentRanges: [UUID: NSRange] = [:]
    private var currentMatchIndex: Int?
    private var currentSearchSignature: SearchSignature?
    private var settings = TextWindowSettings()
    private var automaticMarkerID: UUID?

    private struct SearchSignature: Equatable {
        var query: String
        var options: OutputSearchOptions
        var backwards: Bool
    }

    var showsTimestamps = false { didSet { rebuild(preservingScrollPosition: true) } }
    var usesFanFoldBackgrounds = false { didSet { rebuild(preservingScrollPosition: true) } }
    var isPaused: Bool { history.isPaused }
    var pendingLineCount: Int { history.pendingLines.count }
    var visibleLineCount: Int { history.count }
    var isSplit: Bool { secondaryOutputView != nil }
    var lastDrawnLineCount: Int { outputView.lastDrawnItemCount }
    var renderedLineCount: Int { outputView.itemCount }
    var visiblePaintCandidateCount: Int {
        outputView.visibleItemCount(in: scrollView.contentView.bounds)
    }
    var retainedLines: [RenderedLine] { history.lines }
    var visibleWindowLines: [RenderedLine] {
        let lines = history.lines
        guard let id = outputView.firstVisibleItemID,
              let index = lines.firstIndex(where: { $0.id == id }) else { return lines }
        return Array(lines[index...])
    }
    var historyLimit: Int {
        get { history.limit }
        set { history.limit = newValue; rebuild(preservingScrollPosition: true) }
    }

    var hasSelectedLine: Bool { outputView.selectedItemID != nil }
    var appliedSettingsForTesting: TextWindowSettings { settings }
    var primaryOutputViewForTesting: VirtualizedOutputView { outputView }
    var primaryScrollViewForTesting: NSScrollView { scrollView }
    var secondaryScrollViewForTesting: NSScrollView? { secondaryScrollView }

    func applySettings(_ suppliedSettings: TextWindowSettings) {
        settings = suppliedSettings.normalized
        let foreground = NSColor(hexString: settings.foregroundHex) ?? .textColor
        let background = NSColor(hexString: settings.backgroundHex) ?? .textBackgroundColor
        defaultForeground = settings.invertBrightness ? foreground.invertingBrightness : foreground
        defaultBackground = settings.invertBrightness ? background.invertingBrightness : background
        history.limit = settings.historyLimit
        showsTimestamps = settings.showsTime || settings.showsDate
        usesFanFoldBackgrounds = settings.usesFanFoldBackgrounds
        timestampFormatter.dateFormat = timestampFormat
        scrollView.backgroundColor = defaultBackground
        secondaryScrollView?.backgroundColor = defaultBackground
        configure(view: outputView)
        if let secondaryOutputView { configure(view: secondaryOutputView) }
        rebuild(preservingScrollPosition: true)
    }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        // Text-window colors are independently configurable. The workspace theme
        // still owns surrounding window chrome and supplies legacy defaults.
        if settings.foregroundHex.isEmpty { defaultForeground = palette.foreground }
        if settings.backgroundHex.isEmpty { defaultBackground = palette.background }
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
        outputView = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 900, height: 1))
        scrollView = NSScrollView()
        scrollView.documentView = outputView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        outputView.autoresizingMask = [.width]
        containerView = NSSplitView()
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
        outputView.onLink = { [weak self] url in self?.perform(url: url) }
        outputView.onPageUp = { [weak self] in self?.performPageUp() ?? false }
        outputView.onPageDown = { [weak self] in self?.performPageDown() ?? false }
        outputView.onSelectionCompleted = { [weak self] in self?.copySelectionAsPlainText() }
    }

    func clear() {
        history.clear()
        lineContentRanges.removeAll(keepingCapacity: true)
        outputView.removeAll()
        secondaryOutputView?.removeAll()
        currentMatchIndex = nil
        currentSearchSignature = nil
        automaticMarkerID = nil
        notifyPauseChange()
        NSAccessibility.post(element: outputView, notification: .valueChanged)
    }

    func removeLastLine() {
        guard let line = history.removeLast() else { return }
        lineContentRanges.removeValue(forKey: line.id)
        outputView.removeLast()
        secondaryOutputView?.removeLast()
        currentMatchIndex = nil
        notifyPauseChange()
    }

    func removeSelectedLine() {
        guard let id = outputView.selectedItemID, history.remove(id: id) != nil else {
            NSSound.beep()
            return
        }
        lineContentRanges.removeValue(forKey: id)
        if automaticMarkerID == id { automaticMarkerID = nil }
        rebuild(preservingScrollPosition: true)
    }

    func setPaused(_ paused: Bool) {
        guard paused != history.isPaused else { return }
        if paused {
            history.pause()
        } else {
            history.resume()
            rebuild(scrollToEnd: true)
        }
        notifyPauseChange()
    }

    func togglePaused() { setPaused(!history.isPaused) }

    var terminalSize: (columns: UInt16, rows: UInt16) {
        let font = defaultFont
        let cellWidth = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let cellHeight = max(1, NSLayoutManager().defaultLineHeight(for: font))
        let contentSize = scrollView.contentSize
        let columns = max(1, min(Int(UInt16.max), Int((contentSize.width - 18) / cellWidth)))
        let rows = max(1, min(Int(UInt16.max), Int((contentSize.height - 14) / cellHeight)))
        return (UInt16(columns), UInt16(rows))
    }

    func append(_ line: RenderedLine, terminator: String = "\n") {
        let expectedRemovalCount = max(0, history.count + 1 - history.limit)
        let removedIDs = history.oldestLineIDs(expectedRemovalCount)
        let removedCount = history.append(line)
        guard !history.isPaused else { notifyPauseChange(); return }
        if terminator != "\n" {
            rebuild(scrollToEnd: true, finalTerminator: terminator)
        } else {
            if removedCount > 0 {
                removedIDs.forEach { lineContentRanges.removeValue(forKey: $0) }
                outputView.removeFirst(removedCount)
                secondaryOutputView?.removeFirst(removedCount)
            }
            let item = makeItem(for: line, terminator: terminator, lineIndex: history.count - 1)
            outputView.append(item)
            secondaryOutputView?.append(item)
            if settings.scrollsToBottomOnNewText {
                clearAutomaticMarker()
                outputView.scrollToEnd(animated: settings.smoothScrolling)
            } else if settings.showsNewContentMarkers, automaticMarkerID == nil {
                automaticMarkerID = line.id
                outputView.setMarker(itemID: line.id, marked: true)
                secondaryOutputView?.setMarker(itemID: line.id, marked: true)
            }
        }
        currentMatchIndex = nil
        NSAccessibility.post(element: outputView, notification: .valueChanged)
    }

    @discardableResult
    func find(
        _ query: String,
        options: OutputSearchOptions = .init(),
        backwards: Bool = false
    ) throws -> Bool {
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
        copySelectionAsPlainText(from: outputView)
    }

    private func copySelectionAsPlainText(from view: VirtualizedOutputView) {
        guard let selected = view.selectedString(), !selected.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected, forType: .string)
        showSelectionCopiedPopupIfNeeded()
    }

    func copySelectionAsHTML() {
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
        let text = visibleWindowLines.map(\.text).joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showSelectionCopiedPopupIfNeeded()
    }

    func selectAll() { outputView.selectAllContent() }

    func toggleSplit() {
        if let secondaryScrollView {
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
        guard settings.splitsOnPageUp else { return false }
        let scrollbackOrigin = scrollView.contentView.bounds.origin
        if !isSplit {
            enableSplit(scrollbackOrigin: scrollbackOrigin) { [weak self] scrollView in
                self?.scrollPage(in: scrollView, direction: -1)
            }
            return true
        }
        guard let secondaryScrollView else { return false }
        scrollPage(in: secondaryScrollView, direction: -1)
        return true
    }

    @discardableResult
    func performPageDown() -> Bool {
        guard settings.splitsOnPageUp else { return false }
        let scrollbackOrigin = scrollView.contentView.bounds.origin
        if !isSplit {
            enableSplit(scrollbackOrigin: scrollbackOrigin) { [weak self] scrollView in
                self?.scrollPage(in: scrollView, direction: 1)
            }
            return true
        }
        guard let secondaryScrollView else { return false }
        if isAtBottom(secondaryScrollView) {
            toggleSplit()
        } else {
            scrollPage(in: secondaryScrollView, direction: 1)
        }
        return true
    }

    private func enableSplit(
        scrollbackOrigin: NSPoint,
        scrollAdjustment: (@MainActor (NSScrollView) -> Void)? = nil
    ) {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: max(1, outputView.bounds.width), height: 1))
        view.canvasBackgroundColor = defaultBackground
        view.autoresizingMask = [.width]
        view.onLink = { [weak self] url in self?.perform(url: url) }
        view.onContextMenu = onContextMenu
        view.onPageUp = { [weak self] in self?.performPageUp() ?? false }
        view.onPageDown = { [weak self] in self?.performPageDown() ?? false }
        view.onSelectionCompleted = { [weak self, weak view] in
            guard let view else { return }
            self?.copySelectionAsPlainText(from: view)
        }
        configure(view: view)
        let secondary = Self.makeScrollView(documentView: view, backgroundColor: defaultBackground)
        secondary.setAccessibilityLabel("Paused output scrollback")
        secondary.borderType = .lineBorder
        secondaryOutputView = view
        view.onInteractionCompleted = onInteractionCompleted
        secondaryScrollView = secondary
        containerView.insertArrangedSubview(secondary, at: 0)
        containerView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        secondary.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        view.setItems(currentItems())
        restoreScrollPosition(in: secondary, to: scrollbackOrigin)
        scrollAdjustment?(secondary)
        if settings.scrollsToBottomOnNewText {
            outputView.scrollToEnd()
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.secondaryOutputView != nil else { return }
            self.containerView.layoutSubtreeIfNeeded()
            self.containerView.setPosition(self.containerView.bounds.height * 0.5, ofDividerAt: 0)
            self.restoreScrollPosition(in: secondary, to: scrollbackOrigin)
            scrollAdjustment?(secondary)
            if self.settings.scrollsToBottomOnNewText {
                self.outputView.scrollToEnd()
            }
        }
    }

    func toggleMarkerForSelectedLine() {
        guard let id = outputView.selectedItemID else { NSSound.beep(); return }
        outputView.toggleMarker(itemID: id)
        secondaryOutputView?.toggleMarker(itemID: id)
    }

    private var defaultFont: NSFont {
        NSFont(name: settings.fontName, size: settings.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
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
        view.contentInsets = .init(
            top: CGFloat(settings.marginTop + 7),
            left: CGFloat(settings.marginLeft + 9),
            bottom: CGFloat(settings.marginBottom + 7),
            right: CGFloat(settings.marginRight + 9)
        )
        let cellWidth = max(1, ("M" as NSString).size(withAttributes: [.font: defaultFont]).width)
        view.fixedContentWidth = settings.usesFixedWidth
            ? CGFloat(settings.fixedWidthCharacters) * cellWidth
            : nil
    }

    private func clearAutomaticMarker() {
        guard let id = automaticMarkerID else { return }
        outputView.setMarker(itemID: id, marked: false)
        secondaryOutputView?.setMarker(itemID: id, marked: false)
        automaticMarkerID = nil
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
        preservingScrollPosition: Bool = false
    ) {
        let oldOrigin = scrollView.contentView.bounds.origin
        let oldSecondaryOrigin = secondaryScrollView?.contentView.bounds.origin
        lineContentRanges.removeAll(keepingCapacity: true)
        let lines = history.lines
        let items = lines.enumerated().map { index, line in
            makeItem(
                for: line,
                terminator: index == lines.count - 1 ? finalTerminator : "\n",
                lineIndex: index
            )
        }
        outputView.setItems(items)
        secondaryOutputView?.setItems(items)
        if scrollToEnd {
            outputView.scrollToEnd()
        } else if preservingScrollPosition {
            restoreScrollPosition(in: scrollView, to: oldOrigin)
        }
        if let secondaryScrollView, let oldSecondaryOrigin {
            restoreScrollPosition(in: secondaryScrollView, to: oldSecondaryOrigin)
        }
    }

    private func restoreScrollPosition(in scrollView: NSScrollView, to origin: NSPoint) {
        let maxY = max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentSize.height)
        let point = NSPoint(x: origin.x, y: min(max(0, origin.y), maxY))
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scrollPage(in scrollView: NSScrollView, direction: CGFloat) {
        let origin = scrollView.contentView.bounds.origin
        let distance = max(1, scrollView.contentSize.height - 20)
        restoreScrollPosition(
            in: scrollView,
            to: NSPoint(x: origin.x, y: origin.y + distance * direction)
        )
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
            ? DateFormatter.localizedString(from: line.timestamp, dateStyle: .medium, timeStyle: .medium)
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
                .font: NSFont(name: settings.fontName, size: max(6, settings.fontSize - 1))
                    ?? NSFont.monospacedSystemFont(ofSize: max(6, settings.fontSize - 1), weight: .regular),
            ], range: NSRange(location: 0, length: timestamp.utf16.count))
        }
        let textOffset = timestamp.utf16.count
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
                attributes[.link] = Self.url(for: action)
                attributes[.cursor] = NSCursor.pointingHand
                if run.style.foreground == nil {
                    let link = NSColor(hexString: settings.webLinkHex) ?? .linkColor
                    attributes[.foregroundColor] = settings.invertBrightness ? link.invertingBrightness : link
                }
            }
            value.addAttributes(attributes, range: range)
        }

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
            assets: line.assets.map { ($0, textOffset + $0.characterOffset) },
            paragraph: line.paragraph
        )
    }

    private func currentItems() -> [VirtualizedOutputView.Item] {
        history.lines.enumerated().map { index, line in
            makeItem(for: line, terminator: "\n", lineIndex: index)
        }
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
        let scroll = NSScrollView()
        scroll.documentView = documentView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = backgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
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
