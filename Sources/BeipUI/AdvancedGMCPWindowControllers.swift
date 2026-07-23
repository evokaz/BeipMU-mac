import AppKit
import BeipCore

@MainActor
final class GMCPStatisticsWindowController: NSWindowController, NSWindowDelegate {
    private let stack = NSStackView()
    var onClose: (() -> Void)?

    init(title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 300),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.setAccessibilityIdentifier("gmcpStatisticsWindow")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let content = NSView()
        content.wantsLayer = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = .init(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        content.addSubview(scroll)
        panel.contentView = content
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func update(_ pane: GMCPStatisticsPane) {
        window?.title = pane.title
        window?.contentView?.layer?.backgroundColor = pane.background.flatMap(NSColor.init)?.cgColor
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for statistic in pane.orderedValues {
            let row = row(for: statistic)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        if pane.values.isEmpty {
            let empty = NSTextField(labelWithString: "No statistics")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
        }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private func row(for statistic: GMCPStatistic) -> NSView {
        let name = NSTextField(labelWithString: statistic.name)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        name.textColor = statistic.nameColor.flatMap(NSColor.init) ?? .labelColor
        name.alignment = switch statistic.nameAlignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        name.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        name.widthAnchor.constraint(greaterThanOrEqualToConstant: 95).isActive = true

        let value = NSTextField(labelWithString: valueDescription(statistic.value))
        value.textColor = statistic.valueColor.flatMap(NSColor.init) ?? .labelColor
        value.lineBreakMode = .byTruncatingTail
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.addArrangedSubview(name)
        row.addArrangedSubview(value)
        if let progress = progressIndicator(for: statistic.value) {
            row.addArrangedSubview(progress)
            progress.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        }
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel("\(statistic.name): \(valueDescription(statistic.value))")
        return row
    }

    private func progressIndicator(for value: GMCPStatisticValue) -> NSView? {
        let amount: Double
        let style: GMCPBarStyle
        switch value {
        case let .range(range):
            amount = range.upper == range.lower ? 0 : (range.value - range.lower) / (range.upper - range.lower)
            style = range.style
        case let .progress(progress):
            amount = progress.value
            style = progress.style
        case .integer, .string: return nil
        }
        return GMCPProgressView(amount: min(1, max(0, amount)), style: style)
    }

    private func valueDescription(_ value: GMCPStatisticValue) -> String {
        switch value {
        case let .integer(number): String(number)
        case let .string(text): text
        case let .range(range): "\(Self.format(range.value)) [\(Self.format(range.lower))…\(Self.format(range.upper))]"
        case let .progress(progress): progress.label.isEmpty ? "\(Int(progress.value * 100))%" : progress.label
        }
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }
}

@MainActor
private final class GMCPProgressView: NSView {
    private let amount: Double
    private let style: GMCPBarStyle

    init(amount: Double, style: GMCPBarStyle) {
        self.amount = amount
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 14))
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Progress")
        setAccessibilityValue(amount)
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { .init(width: 120, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        let displayOptions = AccessibilityDisplayOptions.current
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        (style.empty.flatMap(NSColor.init) ?? NSColor.controlBackgroundColor).setFill()
        path.fill()
        let filledWidth = max(0, bounds.width * amount)
        if filledWidth > 0 {
            let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: filledWidth, height: bounds.height), xRadius: 3, yRadius: 3)
            (style.fill.flatMap(NSColor.init) ?? NSColor.controlAccentColor).setFill()
            fill.fill()
        }
        if style.outline != .transparent || displayOptions.increaseContrast {
            (style.outline.flatMap(NSColor.init) ?? NSColor.separatorColor).setStroke()
            path.lineWidth = displayOptions.increaseContrast ? 2 : 1
            path.stroke()
        }
        if displayOptions.differentiateWithoutColor {
            let value = "\(Int((amount * 100).rounded()))%" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
            let size = value.size(withAttributes: attributes)
            value.draw(
                at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }
}

@MainActor
final class TileMapWindowController: NSWindowController, NSWindowDelegate {
    private let mapView = TileMapView()
    var onClose: (() -> Void)?

    init(title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.setAccessibilityIdentifier("tileMapWindow")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 8
        scroll.documentView = mapView
        panel.contentView = scroll
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func update(_ map: GMCPTileMap) {
        window?.title = map.name
        mapView.update(map)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

@MainActor
private final class TileMapView: NSView {
    private var map = GMCPTileMap(name: "Tile Map")
    private var tileset: NSImage?
    private var imageTask: Task<Void, Never>?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Tile map")
    }

    required init?(coder: NSCoder) { nil }

    func update(_ value: GMCPTileMap) {
        let urlChanged = value.tileURL != map.tileURL
        map = value
        frame.size = NSSize(
            width: max(1, value.columns * value.tileWidth),
            height: max(1, value.rows * value.tileHeight)
        )
        setAccessibilityLabel("Tile map \(value.name)")
        setAccessibilityValue("\(value.columns) columns by \(value.rows) rows")
        if urlChanged { loadTileset(value.tileURL) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let tileset, map.tileWidth > 0, map.tileHeight > 0 else {
            let message = map.tileURL == nil ? "Waiting for tile image" : "Loading tile image…"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.white,
            ]
            message.draw(at: NSPoint(x: 12, y: 12), withAttributes: attributes)
            return
        }
        let tilesPerRow = max(1, Int(tileset.size.width) / map.tileWidth)
        for row in 0..<map.rows {
            for column in 0..<map.columns {
                let index = row * map.columns + column
                guard map.tiles.indices.contains(index) else { continue }
                let tile = Int(map.tiles[index])
                let sourceColumn = tile % tilesPerRow
                let sourceRow = tile / tilesPerRow
                let destination = NSRect(
                    x: column * map.tileWidth,
                    y: row * map.tileHeight,
                    width: map.tileWidth,
                    height: map.tileHeight
                )
                guard dirtyRect.intersects(destination) else { continue }
                let source = NSRect(
                    x: sourceColumn * map.tileWidth,
                    y: sourceRow * map.tileHeight,
                    width: map.tileWidth,
                    height: map.tileHeight
                )
                tileset.draw(in: destination, from: source, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
            }
        }
    }

    private func loadTileset(_ url: URL?) {
        imageTask?.cancel()
        tileset = nil
        guard let url else { return }
        imageTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled, let self else { return }
            if let data { tileset = NSImage(data: data) }
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }
}

@MainActor
final class ImageViewerWindowController: NSWindowController, NSWindowDelegate {
    private let imageView = NSImageView()
    private let status = NSTextField(labelWithString: "No images")
    private var urls: [URL] = []
    private var index = 0
    private var imageTask: Task<Void, Never>?
    var onClose: (() -> Void)?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 300),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Image Viewer"
        panel.setAccessibilityIdentifier("imageViewerWindow")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let previous = NSButton(title: "Previous", target: nil, action: nil)
        let next = NSButton(title: "Next", target: nil, action: nil)
        let browser = NSButton(title: "Open in Browser", target: nil, action: nil)
        let controls = NSStackView(views: [previous, next, status, browser])
        controls.spacing = 8

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = !AccessibilityDisplayOptions.current.reduceMotion
        imageView.setAccessibilityIdentifier("imageViewerImage")
        let content = NSStackView(views: [controls, imageView])
        content.orientation = .vertical
        content.spacing = 8
        content.edgeInsets = .init(top: 8, left: 8, bottom: 8, right: 8)
        panel.contentView = content
        super.init(window: panel)
        panel.delegate = self
        previous.target = self
        previous.action = #selector(showPrevious)
        next.target = self
        next.action = #selector(showNext)
        browser.target = self
        browser.action = #selector(openInBrowser)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    func open(_ url: URL) {
        if urls.count == 20 { urls.removeFirst() }
        urls.append(url)
        index = urls.count - 1
        loadCurrent()
        showWindow(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    var imageAnimationEnabled: Bool { imageView.animates }

    func applyAccessibilityDisplayOptions(_ options: AccessibilityDisplayOptions) {
        imageView.animates = !options.reduceMotion
    }

    @objc private func showPrevious() {
        guard index > 0 else { return }
        index -= 1
        loadCurrent()
    }

    @objc private func showNext() {
        guard index + 1 < urls.count else { return }
        index += 1
        loadCurrent()
    }

    @objc private func openInBrowser() {
        guard urls.indices.contains(index) else { return }
        NSWorkspace.shared.open(urls[index])
    }

    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        applyAccessibilityDisplayOptions(.current)
    }

    private func loadCurrent() {
        imageTask?.cancel()
        imageView.image = nil
        let url = urls[index]
        status.stringValue = "Loading \(index + 1) of \(urls.count)…"
        window?.title = "Image Viewer (\(index + 1) of \(urls.count))"
        imageTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            guard !Task.isCancelled, let self else { return }
            imageView.image = data.flatMap(NSImage.init(data:))
            status.stringValue = imageView.image == nil ? "Unable to load image" : "\(index + 1) of \(urls.count)"
            imageView.setAccessibilityLabel(url.lastPathComponent.isEmpty ? "Downloaded image" : url.lastPathComponent)
        }
    }
}

private extension NSColor {
    convenience init?(_ color: GMCPDisplayColor) {
        guard case let .rgb(value) = color else { return nil }
        self.init(
            calibratedRed: CGFloat(value.red) / 255,
            green: CGFloat(value.green) / 255,
            blue: CGFloat(value.blue) / 255,
            alpha: 1
        )
    }

    convenience init(_ color: BeipCore.RGBColor) {
        self.init(
            calibratedRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        )
    }
}
