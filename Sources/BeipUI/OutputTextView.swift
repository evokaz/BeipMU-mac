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

    func applyTheme(_ palette: WorkspaceThemePalette) {
        defaultForeground = palette.foreground
        defaultBackground = palette.background
        scrollView.backgroundColor = palette.background
        secondaryScrollView?.backgroundColor = palette.background
        outputView.canvasBackgroundColor = palette.background
        secondaryOutputView?.canvasBackgroundColor = palette.background
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
        containerView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        containerView.setContentHuggingPriority(.defaultLow, for: .vertical)
        containerView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        super.init()
        outputView.onLink = { [weak self] url in self?.perform(url: url) }
    }

    func clear() {
        history.clear()
        lineContentRanges.removeAll(keepingCapacity: true)
        outputView.removeAll()
        secondaryOutputView?.removeAll()
        currentMatchIndex = nil
        currentSearchSignature = nil
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
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let cellWidth = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let cellHeight = max(1, NSLayoutManager().defaultLineHeight(for: font))
        let contentSize = scrollView.contentSize
        let columns = max(1, min(Int(UInt16.max), Int((contentSize.width - 18) / cellWidth)))
        let rows = max(1, min(Int(UInt16.max), Int((contentSize.height - 14) / cellHeight)))
        return (UInt16(columns), UInt16(rows))
    }

    func append(_ line: RenderedLine, terminator: String = "\n") {
        let shouldFollowEnd = isScrolledNearEnd
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
            if shouldFollowEnd { outputView.scrollToEnd() }
            secondaryOutputView?.scrollToEnd()
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
        guard let selected = outputView.selectedString(), !selected.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected, forType: .string)
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

        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: max(1, outputView.bounds.width), height: 1))
        view.canvasBackgroundColor = defaultBackground
        view.autoresizingMask = [.width]
        view.onLink = { [weak self] url in self?.perform(url: url) }
        let secondary = Self.makeScrollView(documentView: view, backgroundColor: defaultBackground)
        secondary.setAccessibilityLabel("Live output split")
        secondaryOutputView = view
        secondaryScrollView = secondary
        containerView.addArrangedSubview(secondary)
        containerView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        secondary.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        view.setItems(currentItems())
        view.scrollToEnd()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.secondaryOutputView != nil else { return }
            self.containerView.layoutSubtreeIfNeeded()
            self.containerView.setPosition(self.containerView.bounds.height * 0.5, ofDividerAt: 0)
        }
    }

    func toggleMarkerForSelectedLine() {
        guard let id = outputView.selectedItemID else { NSSound.beep(); return }
        outputView.toggleMarker(itemID: id)
        secondaryOutputView?.toggleMarker(itemID: id)
    }

    private var isScrolledNearEnd: Bool {
        let clip = scrollView.contentView.bounds
        return clip.maxY >= outputView.bounds.height - 24
    }

    private func rebuild(
        scrollToEnd: Bool = false,
        finalTerminator: String = "\n",
        preservingScrollPosition: Bool = false
    ) {
        let oldOrigin = scrollView.contentView.bounds.origin
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
            scrollView.contentView.scroll(to: oldOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func makeItem(
        for line: RenderedLine,
        terminator: String,
        lineIndex: Int
    ) -> VirtualizedOutputView.Item {
        let timestamp = showsTimestamps ? "[\(timestampFormatter.string(from: line.timestamp))] " : ""
        let value = NSMutableAttributedString(string: timestamp + line.text + terminator, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: defaultForeground,
            .toolTip: DateFormatter.localizedString(
                from: line.timestamp,
                dateStyle: .medium,
                timeStyle: .medium
            ),
        ])
        if !timestamp.isEmpty {
            value.addAttributes([
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            ], range: NSRange(location: 0, length: timestamp.utf16.count))
        }
        let textOffset = timestamp.utf16.count
        for run in line.runs where run.range.lowerBound >= 0 && run.range.upperBound <= line.text.utf16.count {
            let range = NSRange(location: textOffset + run.range.lowerBound, length: run.range.count)
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let color = run.style.foreground {
                attributes[.foregroundColor] = NSColor(color).withAlphaComponent(run.style.faint ? 0.55 : 1)
            } else if run.style.faint {
                attributes[.foregroundColor] = defaultForeground.withAlphaComponent(0.55)
            }
            if let color = run.style.background { attributes[.backgroundColor] = NSColor(color) }
            var traits: NSFontTraitMask = []
            if run.style.bold { traits.insert(.boldFontMask) }
            if run.style.italic { traits.insert(.italicFontMask) }
            attributes[.font] = NSFontManager.shared.convert(
                NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                toHaveTrait: traits
            )
            if run.style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.style.strikeout { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if run.style.blink != .none { attributes[VirtualizedOutputView.blinkAttribute] = run.style.blink.rawValue }
            if let action = run.style.link {
                attributes[.link] = Self.url(for: action)
                attributes[.cursor] = NSCursor.pointingHand
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
        paragraph.headIndent = CGFloat(line.paragraph.leftIndent + line.paragraph.wrappedIndent)
        paragraph.tailIndent = -CGFloat(line.paragraph.rightIndent)
        paragraph.paragraphSpacingBefore = CGFloat(line.paragraph.topPadding)
        paragraph.paragraphSpacing = CGFloat(line.paragraph.bottomPadding)
        value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
        if let color = line.paragraph.background {
            value.addAttribute(.backgroundColor, value: NSColor(color), range: NSRange(location: 0, length: value.length))
        } else if usesFanFoldBackgrounds, lineIndex.isMultiple(of: 2) {
            value.addAttribute(
                .backgroundColor,
                value: defaultForeground.withAlphaComponent(0.035),
                range: NSRange(location: 0, length: value.length)
            )
        }
        let contentRange = NSRange(location: textOffset, length: line.text.utf16.count)
        lineContentRanges[line.id] = contentRange
        return .init(
            id: line.id,
            attributedText: value,
            contentRange: contentRange,
            assets: line.assets.map { ($0, textOffset + $0.characterOffset) }
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
}
