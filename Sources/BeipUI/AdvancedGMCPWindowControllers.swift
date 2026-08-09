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
    private let paletteView = TilePaletteView()
    private let tileField = NSTextField(string: "0")
    private let mode = NSSegmentedControl(labels: ["Paint", "Select"], trackingMode: .selectOne, target: nil, action: nil)
    private let encoding = NSPopUpButton()
    private let selectionStatus = NSTextField(labelWithString: "No selection")
    var onClose: (() -> Void)?
    var onChange: ((GMCPTileMap) -> Void)?

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
        panel.minSize = NSSize(width: 320, height: 220)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.25
        scroll.maxMagnification = 8
        scroll.documentView = mapView
        let paletteScroll = NSScrollView()
        paletteScroll.hasVerticalScroller = true
        paletteScroll.hasHorizontalScroller = true
        paletteScroll.documentView = paletteView
        paletteScroll.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let undo = NSButton(title: "Undo", target: nil, action: nil)
        let redo = NSButton(title: "Redo", target: nil, action: nil)
        let apply = NSButton(title: "Use tile", target: nil, action: nil)
        let fill = NSButton(title: "Fill", target: nil, action: nil)
        let cut = NSButton(title: "Cut", target: nil, action: nil)
        let copy = NSButton(title: "Copy", target: nil, action: nil)
        let paste = NSButton(title: "Paste", target: nil, action: nil)
        let copyPayload = NSButton(title: "Copy GMCP", target: nil, action: nil)
        tileField.alignment = .right
        tileField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        tileField.setAccessibilityIdentifier("tileMapTileIndex")
        mode.selectedSegment = 0
        mode.setAccessibilityIdentifier("tileMapEditMode")
        encoding.addItems(withTitles: ["Hex 4", "Hex 8", "Base64 8", "ZBase64 8"])
        encoding.setAccessibilityIdentifier("tileMapEncoding")
        selectionStatus.setAccessibilityIdentifier("tileMapSelection")
        let controls = NSStackView(views: [
            mode, NSTextField(labelWithString: "Tile:"), tileField, apply, fill,
            cut, copy, paste, encoding, copyPayload, NSView(), selectionStatus, undo, redo,
        ])
        controls.orientation = .horizontal
        controls.spacing = 8
        let editors = NSStackView(views: [scroll, paletteScroll])
        editors.orientation = .horizontal
        editors.spacing = 8
        let content = NSStackView(views: [controls, editors])
        content.orientation = .vertical
        content.spacing = 8
        content.edgeInsets = .init(top: 8, left: 8, bottom: 8, right: 8)
        panel.contentView = content
        super.init(window: panel)
        panel.delegate = self
        undo.target = self
        undo.action = #selector(undoEdit(_:))
        redo.target = self
        redo.action = #selector(redoEdit(_:))
        apply.target = self
        apply.action = #selector(setTile(_:))
        fill.target = self
        fill.action = #selector(fillMap(_:))
        cut.target = self
        cut.action = #selector(cutSelection(_:))
        copy.target = self
        copy.action = #selector(copySelection(_:))
        paste.target = self
        paste.action = #selector(pasteSelection(_:))
        copyPayload.target = self
        copyPayload.action = #selector(copyGMCPPayload(_:))
        mode.target = self
        mode.action = #selector(changeMode(_:))
        encoding.target = self
        encoding.action = #selector(changeEncoding(_:))
        mapView.onChange = { [weak self] map in self?.onChange?(map) }
        mapView.onSelectionChange = { [weak self] selection in
            self?.selectionStatus.stringValue = selection.map {
                "\($0.columns)×\($0.rows) at \($0.column),\($0.row)"
            } ?? "No selection"
        }
        mapView.onTilesetChange = { [weak self] image, map in
            self?.paletteView.update(image: image, map: map)
        }
        paletteView.onSelect = { [weak self] tile in
            self?.tileField.integerValue = tile
            _ = self?.mapView.setSelectedTile(tile)
        }
    }

    required init?(coder: NSCoder) { nil }

    func update(_ map: GMCPTileMap) {
        window?.title = map.name
        mapView.update(map)
        encoding.selectItem(at: Self.encodingIndex(map.encoding))
    }

    @objc private func setTile(_ sender: Any?) {
        guard let value = Int(tileField.stringValue) else { NSSound.beep(); return }
        guard mapView.setSelectedTile(value) else { NSSound.beep(); return }
        paletteView.selectedTile = value
    }

    @objc private func fillMap(_ sender: Any?) {
        guard let value = Int(tileField.stringValue), mapView.fill(with: value) else { NSSound.beep(); return }
    }
    @objc private func undoEdit(_ sender: Any?) { mapView.undo() }
    @objc private func redoEdit(_ sender: Any?) { mapView.redo() }
    @objc private func cutSelection(_ sender: Any?) { if !mapView.cutSelection() { NSSound.beep() } }
    @objc private func copySelection(_ sender: Any?) { if !mapView.copySelection() { NSSound.beep() } }
    @objc private func pasteSelection(_ sender: Any?) { if !mapView.pasteSelection() { NSSound.beep() } }
    @objc private func copyGMCPPayload(_ sender: Any?) { mapView.copyGMCPPayload() }
    @objc private func changeMode(_ sender: Any?) {
        mapView.mode = mode.selectedSegment == 0 ? .paint : .select
    }
    @objc private func changeEncoding(_ sender: Any?) {
        let value: GMCPTileMap.Encoding = switch encoding.indexOfSelectedItem {
        case 0: .hex4
        case 1: .hex8
        case 2: .base64_8
        default: .zbase64_8
        }
        if !mapView.setEncoding(value) {
            encoding.selectItem(at: Self.encodingIndex(mapView.currentMap.encoding))
            NSSound.beep()
        }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private static func encodingIndex(_ value: GMCPTileMap.Encoding) -> Int {
        switch value {
        case .hex4: 0
        case .hex8: 1
        case .base64_8: 2
        case .zbase64_8: 3
        }
    }
}

@MainActor
private final class TileMapView: NSView {
    enum Mode { case paint, select }

    private static let scrapType = NSPasteboard.PasteboardType("com.beipmu.tilemap-scrap")
    private var map = GMCPTileMap(name: "Tile Map")
    private var editor = TileMapEditor(map: .init(name: "Tile Map"))
    private var tileset: NSImage?
    private var imageTask: Task<Void, Never>?
    private var selection: TileMapEditor.Selection?
    private var dragStart: TileMapEditor.Coordinate?
    private var dragCurrent: TileMapEditor.Coordinate?
    private var movingSelection = false
    private var paintStroke: Set<TileMapEditor.Coordinate> = []
    var mode: Mode = .paint {
        didSet {
            if mode == .paint { selection = nil; onSelectionChange?(nil) }
            needsDisplay = true
        }
    }
    private(set) var selectedTile = 0
    var onChange: ((GMCPTileMap) -> Void)?
    var onSelectionChange: ((TileMapEditor.Selection?) -> Void)?
    var onTilesetChange: ((NSImage?, GMCPTileMap) -> Void)?
    var currentMap: GMCPTileMap { editor.map }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

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
        if editor.map != value {
            editor = TileMapEditor(map: value)
            selection = nil
            onSelectionChange?(nil)
        }
        frame.size = NSSize(
            width: max(1, value.columns * value.tileWidth),
            height: max(1, value.rows * value.tileHeight)
        )
        setAccessibilityLabel("Tile map \(value.name)")
        setAccessibilityValue("\(value.columns) columns by \(value.rows) rows")
        if urlChanged { loadTileset(value.tileURL) }
        else { onTilesetChange?(tileset, value) }
        needsDisplay = true
    }

    func setSelectedTile(_ value: Int) -> Bool {
        guard (0...editor.maximumTileValue).contains(value) else { return false }
        selectedTile = value
        return true
    }

    func fill(with value: Int) -> Bool {
        do {
            try editor.fill(value: value)
            applyEditorChange()
            return true
        } catch { return false }
    }

    func setEncoding(_ value: GMCPTileMap.Encoding) -> Bool {
        do {
            try editor.setEncoding(value)
            applyEditorChange()
            return true
        } catch { return false }
    }

    func undo() {
        guard editor.undo() else { NSSound.beep(); return }
        selection = nil
        onSelectionChange?(nil)
        applyEditorChange()
    }

    func redo() {
        guard editor.redo() else { NSSound.beep(); return }
        selection = nil
        onSelectionChange?(nil)
        applyEditorChange()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let coordinate = coordinate(for: event) else { return }
        dragStart = coordinate
        dragCurrent = coordinate
        if mode == .paint {
            paintStroke = [coordinate]
        } else if let selection, contains(coordinate, in: selection) {
            movingSelection = true
        } else {
            movingSelection = false
            selection = nil
            onSelectionChange?(nil)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let coordinate = coordinate(for: event) else { return }
        dragCurrent = coordinate
        if mode == .paint { paintStroke.insert(coordinate) }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = coordinate(for: event) ?? dragCurrent ?? start
        defer {
            dragStart = nil
            dragCurrent = nil
            movingSelection = false
            paintStroke.removeAll()
            needsDisplay = true
        }
        do {
            if mode == .paint {
                try editor.setTiles(Dictionary(uniqueKeysWithValues: paintStroke.map { ($0, selectedTile) }))
                applyEditorChange()
                return
            }
            if movingSelection, let selection {
                self.selection = try editor.move(
                    selection,
                    by: .init(column: end.column - start.column, row: end.row - start.row)
                )
                onSelectionChange?(self.selection)
                applyEditorChange()
            } else {
                selection = Self.selection(from: start, to: end)
                onSelectionChange?(selection)
            }
        } catch { NSSound.beep() }
    }

    func copySelection() -> Bool {
        guard let selection, let scrap = try? editor.copy(selection),
              let data = try? JSONEncoder().encode(scrap) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: Self.scrapType)
        return true
    }

    func cutSelection() -> Bool {
        guard copySelection(), let selection else { return false }
        do {
            _ = try editor.cut(selection)
            self.selection = nil
            onSelectionChange?(nil)
            applyEditorChange()
            return true
        } catch { return false }
    }

    func pasteSelection() -> Bool {
        guard let data = NSPasteboard.general.data(forType: Self.scrapType),
              let scrap = try? JSONDecoder().decode(TileMapEditor.Scrap.self, from: data) else { return false }
        let origin = selection.map { TileMapEditor.Coordinate(column: $0.column, row: $0.row) }
            ?? .init(column: 0, row: 0)
        do {
            try editor.paste(scrap, at: origin)
            selection = .init(column: origin.column, row: origin.row, columns: scrap.columns, rows: scrap.rows)
            onSelectionChange?(selection)
            applyEditorChange()
            return true
        } catch { return false }
    }

    func copyGMCPPayload() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(editor.clipboardPayload(), forType: .string)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": _ = copySelection(); return
            case "x": _ = cutSelection(); return
            case "v": _ = pasteSelection(); return
            case "z" where modifiers.contains(.shift): redo(); return
            case "z": undo(); return
            default: break
            }
        }
        if event.keyCode == 51, let selection {
            do {
                _ = try editor.cut(selection)
                self.selection = nil
                onSelectionChange?(nil)
                applyEditorChange()
            } catch { NSSound.beep() }
            return
        }
        super.keyDown(with: event)
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
        if let selection {
            let rect = NSRect(
                x: selection.column * map.tileWidth,
                y: selection.row * map.tileHeight,
                width: selection.columns * map.tileWidth,
                height: selection.rows * map.tileHeight
            )
            NSColor.selectedControlColor.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
            path.lineWidth = 3
            path.stroke()
        } else if mode == .select, let start = dragStart, let end = dragCurrent {
            let preview = Self.selection(from: start, to: end)
            let rect = NSRect(
                x: preview.column * map.tileWidth,
                y: preview.row * map.tileHeight,
                width: preview.columns * map.tileWidth,
                height: preview.rows * map.tileHeight
            )
            NSColor.keyboardFocusIndicatorColor.setStroke()
            NSBezierPath(rect: rect).stroke()
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
            onTilesetChange?(tileset, map)
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    private func applyEditorChange() {
        map = editor.map
        needsDisplay = true
        onChange?(map)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func coordinate(for event: NSEvent) -> TileMapEditor.Coordinate? {
        guard map.tileWidth > 0, map.tileHeight > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let coordinate = TileMapEditor.Coordinate(
            column: Int(floor(point.x / CGFloat(map.tileWidth))),
            row: Int(floor(point.y / CGFloat(map.tileHeight)))
        )
        guard (0..<map.columns).contains(coordinate.column),
              (0..<map.rows).contains(coordinate.row) else { return nil }
        return coordinate
    }

    private func contains(_ coordinate: TileMapEditor.Coordinate, in selection: TileMapEditor.Selection) -> Bool {
        (selection.column..<(selection.column + selection.columns)).contains(coordinate.column)
            && (selection.row..<(selection.row + selection.rows)).contains(coordinate.row)
    }

    private static func selection(
        from start: TileMapEditor.Coordinate,
        to end: TileMapEditor.Coordinate
    ) -> TileMapEditor.Selection {
        .init(
            column: min(start.column, end.column),
            row: min(start.row, end.row),
            columns: abs(start.column - end.column) + 1,
            rows: abs(start.row - end.row) + 1
        )
    }
}

@MainActor
private final class TilePaletteView: NSView {
    private var image: NSImage?
    private var tileWidth = 16
    private var tileHeight = 16
    var selectedTile = 0 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Tile picker")
    }

    required init?(coder: NSCoder) { nil }

    func update(image: NSImage?, map: GMCPTileMap) {
        self.image = image
        tileWidth = max(1, map.tileWidth)
        tileHeight = max(1, map.tileHeight)
        frame.size = image?.size ?? NSSize(width: 160, height: 160)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let image else { return }
        let point = convert(event.locationInWindow, from: nil)
        let columns = max(1, Int(image.size.width) / tileWidth)
        let column = Int(point.x) / tileWidth
        let row = Int(point.y) / tileHeight
        guard column >= 0, row >= 0, column < columns,
              row < max(1, Int(image.size.height) / tileHeight) else { return }
        selectedTile = row * columns + column
        onSelect?(selectedTile)
        setAccessibilityValue("Tile \(selectedTile)")
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        guard let image else {
            "Tile image unavailable".draw(
                at: NSPoint(x: 8, y: 8),
                withAttributes: [.foregroundColor: NSColor.secondaryLabelColor]
            )
            return
        }
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        let columns = max(1, Int(image.size.width) / tileWidth)
        let rect = NSRect(
            x: (selectedTile % columns) * tileWidth,
            y: (selectedTile / columns) * tileHeight,
            width: tileWidth,
            height: tileHeight
        )
        NSColor.selectedControlColor.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
        path.lineWidth = 3
        path.stroke()
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
