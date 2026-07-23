import AppKit
import BeipCore
import BeipPersistence
import UniformTypeIdentifiers

@MainActor
final class AtlasWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private let canvas: AtlasCanvasView
    private let mapPopup = NSPopUpButton()
    private let toolControl = NSSegmentedControl(labels: ["Select", "Pan", "Room", "Exit", "Rect", "Image", "Label", "Locate", "Path", "Run"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let liveTracking = NSButton(checkboxWithTitle: "Live track", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "No current room")
    private var resources: [String: Data] = [:]
    private var sourceURL: URL?
    private var searchResults: [AtlasSearchResult] = []
    private var searchIndex = -1
    private var suppressStateChange = false
    var onClose: (() -> Void)?
    var onSendCommands: (([String]) -> Void)?
    var onStateChange: ((AtlasSurfacePreferences) -> Void)?

    var editor: AtlasEditor {
        get { canvas.editor }
        set { canvas.editor = newValue }
    }
    var surfacePreferences: AtlasSurfacePreferences {
        .init(
            filePath: sourceURL?.path,
            mapIndex: canvas.editor.mapIndex,
            currentMapIndex: canvas.editor.currentLocation?.mapIndex,
            currentRoomIndex: canvas.editor.currentLocation?.roomIndex,
            scale: canvas.editor.viewport.scale,
            originX: canvas.editor.viewport.origin.x,
            originY: canvas.editor.viewport.origin.y,
            selectionFilterRaw: canvas.editor.selectionFilter.rawValue,
            liveTracking: canvas.editor.liveTracking
        )
    }

    init(atlas: Atlas = .init()) {
        canvas = AtlasCanvasView(editor: .init(atlas: atlas))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Atlas"
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BeipMU.Atlas")
        window.setAccessibilityIdentifier("atlasWindow")
        super.init(window: window)
        window.delegate = self
        configureUI()
        wireCanvas()
        refresh()
        canvas.centerAll()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { onClose?() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(canvas)
    }

    func load(_ url: URL) throws {
        let archive = try AtlasReader.readArchive(from: url)
        resources = archive.resources
        sourceURL = url
        canvas.resources = resources
        canvas.editor = .init(atlas: archive.atlas)
        window?.title = "Atlas — \(url.lastPathComponent)"
        refresh()
        canvas.centerAll()
    }

    func restore(_ state: AtlasSurfacePreferences) throws {
        suppressStateChange = true
        defer { suppressStateChange = false }
        if let path = state.filePath, FileManager.default.fileExists(atPath: path) {
            try load(URL(fileURLWithPath: path))
        }
        if canvas.editor.atlas.maps.indices.contains(state.mapIndex) { canvas.editor.mapIndex = state.mapIndex }
        if let map = state.currentMapIndex, let room = state.currentRoomIndex {
            canvas.editor.setCurrentLocation(.init(mapIndex: map, roomIndex: room))
        }
        canvas.editor.viewport = .init(scale: state.scale, origin: .init(x: state.originX, y: state.originY))
        canvas.editor.selectionFilter = .init(rawValue: state.selectionFilterRaw)
        canvas.editor.liveTracking = state.liveTracking
        refresh()
    }

    func integrate(_ room: GMCPRoomInfo) {
        let location = canvas.editor.integrate(room)
        canvas.center(on: location)
        refresh()
    }

    @discardableResult
    func recordTypedExit(_ text: String) -> AtlasLocation? {
        let location = canvas.editor.recordTypedExit(text)
        if let location { canvas.center(on: location); refresh() }
        return location
    }

    @discardableResult
    func observeOutput(_ text: String) -> AtlasLocation? {
        let location = canvas.editor.observeOutput(text)
        if let location { canvas.center(on: location); refresh() }
        return location
    }

    func addRoomAndExit(name: String, outward: String, returnCommand: String) -> Bool {
        guard canvas.editor.currentLocation != nil else { return false }
        guard let location = canvas.editor.addRoomAndExit(name: name, outward: outward, returnCommand: returnCommand) else { return false }
        canvas.center(on: location)
        refresh()
        return true
    }

    func addDirectionalExit(outward: String, returnCommand: String) -> Bool {
        let result = canvas.editor.addExitToDirectionalRoom(outward: outward, returnCommand: returnCommand)
        refresh()
        return result
    }

    @discardableResult
    func guessLocation(in lines: [String]) -> AtlasLocation? {
        let location = canvas.editor.guessLocation(in: lines)
        if let location { canvas.center(on: location); refresh() }
        return location
    }

    func lookDescription() -> String? {
        guard let current = canvas.editor.currentLocation else { return nil }
        let room = canvas.editor.atlas.maps[current.mapIndex].rooms[current.roomIndex]
        let exits = canvas.editor.exitsFromCurrentRoom()
        let description = exits.isEmpty ? "(none)" : exits.map { "\($0.command) \($0.destinationName)" }.joined(separator: "  ")
        return "Location: \(room.name)\nExits: \(description)"
    }

    private func configureUI() {
        guard let window else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 7
        toolbar.edgeInsets = .init(top: 7, left: 8, bottom: 7, right: 8)
        toolbar.addArrangedSubview(button("Open", #selector(openDocument)))
        toolbar.addArrangedSubview(button("Save", #selector(saveDocument)))
        toolbar.addArrangedSubview(button("Save As", #selector(saveDocumentAs)))
        toolbar.addArrangedSubview(NSBox.separator())
        mapPopup.target = self
        mapPopup.action = #selector(changeMap)
        mapPopup.setAccessibilityLabel("Atlas map")
        toolbar.addArrangedSubview(mapPopup)
        toolbar.addArrangedSubview(button("+", #selector(addMap)))
        toolbar.addArrangedSubview(button("−", #selector(removeMap)))
        toolbar.addArrangedSubview(NSBox.separator())
        toolControl.target = self
        toolControl.action = #selector(changeTool)
        toolControl.selectedSegment = 0
        toolControl.setAccessibilityLabel("Atlas editing tool")
        toolbar.addArrangedSubview(toolControl)
        toolbar.addArrangedSubview(button("Center", #selector(centerCurrentRoom)))
        toolbar.addArrangedSubview(button("Palette", #selector(editPalette)))
        toolbar.addArrangedSubview(button("Copy", #selector(copySelection)))
        toolbar.addArrangedSubview(button("Paste", #selector(pasteSelection)))
        toolbar.addArrangedSubview(button("Export", #selector(exportImage)))
        toolbar.addArrangedSubview(button("Undo", #selector(undo)))
        toolbar.addArrangedSubview(button("Redo", #selector(redo)))

        let filters = NSStackView()
        filters.orientation = .horizontal
        filters.alignment = .centerY
        filters.spacing = 8
        filters.edgeInsets = .init(top: 5, left: 10, bottom: 5, right: 10)
        filters.addArrangedSubview(NSTextField(labelWithString: "Select:"))
        for (title, value) in [
            ("Rooms", AtlasSelectionFilter.rooms), ("Exits", .exits), ("Rectangles", .rectangles),
            ("Images", .images), ("Labels", .labels),
        ] {
            let control = NSButton(checkboxWithTitle: title, target: self, action: #selector(changeFilter(_:)))
            control.state = .on
            control.tag = Int(value.rawValue)
            filters.addArrangedSubview(control)
        }
        liveTracking.target = self
        liveTracking.action = #selector(changeLiveTracking(_:))
        liveTracking.state = canvas.editor.liveTracking ? .on : .off
        liveTracking.setAccessibilityLabel("Live map tracking")
        filters.addArrangedSubview(liveTracking)
        search.placeholderString = "Find rooms"
        search.delegate = self
        search.target = self
        search.action = #selector(findNext)
        search.widthAnchor.constraint(equalToConstant: 190).isActive = true
        filters.addArrangedSubview(search)
        filters.addArrangedSubview(status)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)

        root.addArrangedSubview(toolbar)
        root.addArrangedSubview(filters)
        root.addArrangedSubview(canvas)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            toolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            filters.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
    }

    private func wireCanvas() {
        canvas.onChange = { [weak self] in self?.refresh() }
        canvas.onCreate = { [weak self] kind, rect in self?.create(kind, rect: rect) }
        canvas.onCreateExit = { [weak self] from, to in self?.createExit(from: from, to: to) }
        canvas.onSendPath = { [weak self] commands in self?.onSendCommands?(commands) }
        canvas.onEditProperties = { [weak self] in self?.editSelectedProperties() }
        canvas.onCopy = { [weak self] in _ = self?.copySelection() }
        canvas.onPaste = { [weak self] in _ = self?.pasteSelection() }
    }

    private func refresh() {
        mapPopup.removeAllItems()
        mapPopup.addItems(withTitles: canvas.editor.atlas.maps.map(\.name))
        if canvas.editor.atlas.maps.indices.contains(canvas.editor.mapIndex) {
            mapPopup.selectItem(at: canvas.editor.mapIndex)
        }
        if let current = canvas.editor.currentLocation,
           canvas.editor.atlas.maps.indices.contains(current.mapIndex),
           canvas.editor.atlas.maps[current.mapIndex].rooms.indices.contains(current.roomIndex) {
            let room = canvas.editor.atlas.maps[current.mapIndex].rooms[current.roomIndex]
            status.stringValue = "Current: \(room.name)"
        } else {
            status.stringValue = "No current room"
        }
        liveTracking.state = canvas.editor.liveTracking ? .on : .off
        canvas.needsDisplay = true
        if !suppressStateChange { onStateChange?(surfacePreferences) }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action)
        value.bezelStyle = .rounded
        return value
    }

    @objc private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "atlas") ?? .xml]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try load(url) } catch { NSApplication.shared.presentError(error) }
    }

    @objc private func saveDocument() {
        guard let sourceURL else { saveDocumentAs(); return }
        do { try AtlasWriter.write(.init(atlas: canvas.editor.atlas, resources: resources), to: sourceURL) }
        catch { NSApplication.shared.presentError(error) }
    }

    @objc private func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "atlas") ?? .xml]
        panel.nameFieldStringValue = sourceURL?.lastPathComponent ?? "Map.atlas"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceURL = url
        saveDocument()
        window?.title = "Atlas — \(url.lastPathComponent)"
    }

    @objc private func changeMap() {
        guard canvas.editor.atlas.maps.indices.contains(mapPopup.indexOfSelectedItem) else { return }
        canvas.editor.mapIndex = mapPopup.indexOfSelectedItem
        canvas.editor.selection = []
        canvas.centerAll()
        refresh()
    }

    @objc private func addMap() {
        guard let name = prompt(title: "New Map", label: "Map name", value: "Map \(canvas.editor.atlas.maps.count + 1)") else { return }
        _ = canvas.editor.addMap(named: name)
        refresh()
        canvas.centerAll()
    }

    @objc private func removeMap() {
        guard canvas.editor.mapIndex >= 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(canvas.editor.currentMap?.name ?? "map")?"
        alert.informativeText = "Rooms and exits on this map will be removed. Undo remains available."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        canvas.editor.removeMap(at: canvas.editor.mapIndex)
        refresh()
    }

    @objc private func changeTool() {
        canvas.tool = AtlasCanvasView.Tool(rawValue: toolControl.selectedSegment) ?? .select
    }

    @objc private func centerCurrentRoom() {
        guard let location = canvas.editor.currentLocation else { NSSound.beep(); return }
        canvas.center(on: location)
    }

    @objc private func changeLiveTracking(_ sender: NSButton) {
        canvas.editor.liveTracking = sender.state == .on
        refresh()
    }

    @objc private func changeFilter(_ sender: NSButton) {
        let value = AtlasSelectionFilter(rawValue: UInt8(sender.tag))
        if sender.state == .on { canvas.editor.selectionFilter.insert(value) }
        else { canvas.editor.selectionFilter.remove(value) }
        canvas.needsDisplay = true
    }

    @objc private func undo() { canvas.editor.undo(); refresh() }
    @objc private func redo() { canvas.editor.redo(); refresh() }

    @objc private func findNext() {
        if searchResults.isEmpty || searchResults.first?.name.range(of: search.stringValue, options: .caseInsensitive) == nil {
            searchResults = canvas.editor.findRooms(search.stringValue)
            searchIndex = -1
        }
        guard !searchResults.isEmpty else { NSSound.beep(); return }
        searchIndex = (searchIndex + 1) % searchResults.count
        let result = searchResults[searchIndex]
        canvas.editor.mapIndex = result.location.mapIndex
        canvas.editor.selection = Set(canvas.editor.objectID(for: result.location).map { [$0] } ?? [])
        canvas.center(on: result.location)
        refresh()
    }

    @objc private func editPalette() {
        let alert = NSAlert()
        alert.messageText = "Atlas Palette"
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let background = NSTextField(string: canvas.editor.atlas.attributes["color_background"] ?? "#202124")
        let exits = NSTextField(string: canvas.editor.atlas.attributes["color_exit"] ?? "#8A8A8A")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Background:"), background],
            [NSTextField(labelWithString: "Exits:"), exits],
        ])
        grid.frame = NSRect(x: 0, y: 0, width: 320, height: 64)
        alert.accessoryView = grid
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        canvas.editor.updatePalette(background: background.stringValue, exit: exits.stringValue)
        refresh()
    }

    @discardableResult
    @objc func copySelection() -> Bool {
        guard let fragment = canvas.editor.selectionFragment() else { NSSound.beep(); return false }
        let data = AtlasWriter.data(for: Atlas(maps: [fragment]))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .atlasFragment)
        pasteboard.setString(String(decoding: data, as: UTF8.self), forType: .string)
        return true
    }

    @discardableResult
    @objc func pasteSelection() -> Bool {
        let pasteboard = NSPasteboard.general
        let data = pasteboard.data(forType: .atlasFragment)
            ?? pasteboard.string(forType: .string)?.data(using: .utf8)
        guard let data, let atlas = try? AtlasReader.read(from: data), let fragment = atlas.maps.first else {
            NSSound.beep()
            return false
        }
        guard !canvas.editor.paste(fragment).isEmpty else { return false }
        refresh()
        return true
    }

    @objc private func exportImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .pdf]
        panel.nameFieldStringValue = "\(canvas.editor.currentMap?.name ?? "Map").png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let data = url.pathExtension.lowercased() == "pdf" ? canvas.pdfData() : canvas.pngData()
        do { try data.write(to: url, options: .atomic) }
        catch { NSApplication.shared.presentError(error) }
    }

    private func editSelectedProperties() {
        guard canvas.editor.selection.count == 1, let id = canvas.editor.selection.first,
              let element = canvas.editor.element(at: id) else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "Map Object Properties"
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let fields: [(String, NSTextField)]
        switch element {
        case let .room(value):
            fields = [("Name", NSTextField(string: value.name)), ("Fill color", NSTextField(string: value.color ?? "")), ("Outline color", NSTextField(string: value.outlineColor ?? ""))]
        case let .exit(value):
            fields = [("Command there", NSTextField(string: value.nameFrom ?? "")), ("Command back", NSTextField(string: value.nameTo ?? ""))]
        case let .rectangle(value): fields = [("Fill color", NSTextField(string: value.color ?? ""))]
        case let .image(value): fields = [("Image source", NSTextField(string: value.source))]
        case let .label(value): fields = [("Text", NSTextField(string: value.text)), ("Color", NSTextField(string: value.color ?? ""))]
        case .unknown: return
        }
        let grid = NSGridView(views: fields.map { [NSTextField(labelWithString: "\($0.0):"), $0.1] })
        grid.frame = NSRect(x: 0, y: 0, width: 390, height: CGFloat(max(1, fields.count) * 30))
        alert.accessoryView = grid
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let updated: Atlas.MapElement
        switch element {
        case var .room(value):
            value.name = fields[0].1.stringValue
            value.color = fields[1].1.stringValue.nilIfEmpty
            value.outlineColor = fields[2].1.stringValue.nilIfEmpty
            updated = .room(value)
        case var .exit(value):
            value.nameFrom = fields[0].1.stringValue.nilIfEmpty
            value.nameTo = fields[1].1.stringValue.nilIfEmpty
            updated = .exit(value)
        case var .rectangle(value): value.color = fields[0].1.stringValue.nilIfEmpty; updated = .rectangle(value)
        case var .image(value): value.source = fields[0].1.stringValue; updated = .image(value)
        case var .label(value): value.text = fields[0].1.stringValue; value.color = fields[1].1.stringValue.nilIfEmpty; updated = .label(value)
        case .unknown: return
        }
        canvas.editor.updateElement(at: id, to: updated)
        refresh()
    }

    private func create(_ kind: AtlasCanvasView.Tool, rect: Atlas.Rect) {
        switch kind {
        case .room:
            guard let name = prompt(title: "Create Room", label: "Room name", value: "Room") else { return }
            _ = canvas.editor.addRoom(name: name, rect: rect)
        case .rectangle:
            _ = canvas.editor.addRectangle(rect: rect, color: "#3A3A3A")
        case .label:
            guard let text = prompt(title: "Create Label", label: "Label text", value: "Label") else { return }
            _ = canvas.editor.addLabel(text: text, rect: rect, color: "#FFFFFF")
        case .image:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg, .gif]
            guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            let path = "images/\(url.lastPathComponent)"
            resources[path] = data
            canvas.resources = resources
            _ = canvas.editor.addImage(source: path, rect: rect)
        default: return
        }
        refresh()
    }

    private func createExit(from: AtlasLocation, to: AtlasLocation) {
        let alert = NSAlert()
        alert.messageText = "Create Exit"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let outward = NSTextField(string: "")
        let returning = NSTextField(string: "")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Command there:"), outward],
            [NSTextField(labelWithString: "Command back:"), returning],
        ])
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: 64)
        alert.accessoryView = grid
        guard alert.runModal() == .alertFirstButtonReturn, !outward.stringValue.isEmpty else { return }
        _ = canvas.editor.addExit(
            from: from.roomIndex,
            to: to.roomIndex,
            nameFrom: outward.stringValue,
            nameTo: returning.stringValue.isEmpty ? nil : returning.stringValue,
            map: from.mapIndex,
            destinationMap: to.mapIndex
        )
        refresh()
    }

    private func prompt(title: String, label: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        field.placeholderString = label
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

@MainActor
final class AtlasCanvasView: NSView {
    enum Tool: Int { case select, pan, room, exit, rectangle, image, label, locate, path, speedRun }

    var editor: AtlasEditor { didSet { needsDisplay = true } }
    var resources: [String: Data] = [:] { didSet { imageCache.removeAll(); needsDisplay = true } }
    var tool: Tool = .select
    var onChange: (() -> Void)?
    var onCreate: ((Tool, Atlas.Rect) -> Void)?
    var onCreateExit: ((AtlasLocation, AtlasLocation) -> Void)?
    var onSendPath: (([String]) -> Void)?
    var onEditProperties: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    private var mouseStart: NSPoint?
    private var worldStart: Atlas.Point?
    private var isPanning = false
    private var imageCache: [String: NSImage] = [:]
    private var highlightedPath: [AtlasPathStep] = []
    private var highlightedDestination: AtlasLocation?

    init(editor: AtlasEditor) {
        self.editor = editor
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Atlas map canvas")
        setAccessibilityHelp("Use the toolbar to select, pan, create map objects, set location, or speed-run a path.")
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let background = color(editor.atlas.attributes["color_background"]) ?? NSColor(calibratedWhite: 0.10, alpha: 1)
        background.setFill()
        dirtyRect.fill()
        drawGrid(in: dirtyRect)
        guard let map = editor.currentMap else { return }
        for (index, element) in map.elements.enumerated() where element.kind == .exit {
            draw(element, index: index, map: map)
        }
        for (index, element) in map.elements.enumerated() where element.kind != .exit {
            draw(element, index: index, map: map)
        }
        drawPath()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        mouseStart = point
        worldStart = world(point)
        isPanning = tool == .pan || event.buttonNumber == 2 || (tool == .select && hitTestObject(at: point) == nil)
        guard tool == .select, !isPanning, let id = hitTestObject(at: point) else { return }
        if event.modifierFlags.contains(.shift) {
            if editor.selection.contains(id) { editor.selection.remove(id) } else { editor.selection.insert(id) }
        } else if !editor.selection.contains(id) {
            editor.selection = [id]
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPanning, let start = mouseStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        editor.viewport.origin.x += point.x - start.x
        editor.viewport.origin.y += point.y - start.y
        mouseStart = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = worldStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let end = world(point)
        defer { mouseStart = nil; worldStart = nil; isPanning = false }
        if isPanning { onChange?(); return }
        switch tool {
        case .select:
            let dx = end.x - start.x
            let dy = end.y - start.y
            if hypot(dx, dy) > 2 / editor.viewport.scale { editor.moveSelection(dx: dx, dy: dy, snap: event.modifierFlags.contains(.control) ? nil : 10) }
        case .room, .rectangle, .image, .label:
            var rect = Atlas.Rect(x1: start.x, y1: start.y, x2: end.x, y2: end.y).standardized
            if rect.width < 4 || rect.height < 4 { rect = .init(x1: start.x, y1: start.y, x2: start.x + 100, y2: start.y + 70) }
            onCreate?(tool, rect)
        case .exit:
            guard let startPoint = mouseStart,
                  let from = roomLocation(at: startPoint), let to = roomLocation(at: point), from != to else { NSSound.beep(); return }
            onCreateExit?(from, to)
        case .locate:
            if let location = roomLocation(at: point) { editor.setCurrentLocation(location); center(on: location) }
        case .speedRun:
            guard let destination = roomLocation(at: point), let path = editor.shortestPath(to: destination) else { NSSound.beep(); return }
            highlightedPath = path
            highlightedDestination = destination
            onSendPath?(path.map(\.command))
        case .path:
            guard let destination = roomLocation(at: point), let path = editor.shortestPath(to: destination) else { NSSound.beep(); return }
            if highlightedDestination == destination, let first = path.first {
                onSendPath?([first.command])
                editor.setCurrentLocation(first.destination)
                highlightedPath = editor.shortestPath(to: destination) ?? []
            } else {
                highlightedDestination = destination
                highlightedPath = path
            }
        case .pan: break
        }
        onChange?()
    }

    override func scrollWheel(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        editor.viewport.zoom(by: event.scrollingDeltaY > 0 ? 1.12 : 0.89, around: .init(x: anchor.x, y: anchor.y))
        needsDisplay = true
        onChange?()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 51 || event.keyCode == 117 { editor.deleteSelection(); onChange?(); return }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            if flags.contains(.shift) { editor.redo() } else { editor.undo() }
            onChange?()
            return
        }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" { onCopy?(); return }
        if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v" { onPaste?(); return }
        if event.charactersIgnoringModifiers == "+" || event.charactersIgnoringModifiers == "=" {
            editor.viewport.zoom(by: 1.2, around: .init(x: bounds.midX, y: bounds.midY)); needsDisplay = true; return
        }
        if event.charactersIgnoringModifiers == "-" {
            editor.viewport.zoom(by: 0.8, around: .init(x: bounds.midX, y: bounds.midY)); needsDisplay = true; return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let id = hitTestObject(at: point), !editor.selection.contains(id) {
            editor.selection = [id]
            needsDisplay = true
        }
        guard !editor.selection.isEmpty else { return nil }
        let menu = NSMenu(title: "Map Object")
        menu.addItem(withTitle: "Properties…", action: #selector(showProperties), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(copyObjects), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring to Front", action: #selector(bringToFront), keyEquivalent: "")
        menu.addItem(withTitle: "Send to Back", action: #selector(sendToBack), keyEquivalent: "")
        menu.addItem(withTitle: "Delete", action: #selector(deleteObjects), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    @objc private func showProperties() { onEditProperties?() }
    @objc private func copyObjects() { onCopy?() }
    @objc private func bringToFront() { editor.bringSelectionToFront(); onChange?() }
    @objc private func sendToBack() { editor.sendSelectionToBack(); onChange?() }
    @objc private func deleteObjects() { editor.deleteSelection(); onChange?() }

    func pngData() -> Data {
        layoutSubtreeIfNeeded()
        guard bounds.width > 0, bounds.height > 0,
              let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return Data() }
        cacheDisplay(in: bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }

    func pdfData() -> Data { dataWithPDF(inside: bounds) }

    func centerAll() {
        guard let map = editor.currentMap else { return }
        let rects = map.elements.compactMap(\.rect)
        guard let first = rects.first else {
            editor.viewport = .init(scale: 1, origin: .init(x: bounds.midX, y: bounds.midY))
            needsDisplay = true
            return
        }
        let union = rects.dropFirst().reduce(first.standardized) { value, next in
            let next = next.standardized
            return .init(x1: min(value.x1, next.x1), y1: min(value.y1, next.y1), x2: max(value.x2, next.x2), y2: max(value.y2, next.y2))
        }
        let scale = min(2, max(0.1, min((bounds.width - 80) / max(1, union.width), (bounds.height - 80) / max(1, union.height))))
        editor.viewport = .init(scale: scale, origin: .init(
            x: bounds.midX - union.center.x * scale,
            y: bounds.midY - union.center.y * scale
        ))
        needsDisplay = true
    }

    func center(on location: AtlasLocation) {
        guard editor.atlas.maps.indices.contains(location.mapIndex), editor.atlas.maps[location.mapIndex].rooms.indices.contains(location.roomIndex) else { return }
        editor.mapIndex = location.mapIndex
        let center = editor.atlas.maps[location.mapIndex].rooms[location.roomIndex].rect.center
        editor.viewport.origin = .init(x: bounds.midX - center.x * editor.viewport.scale, y: bounds.midY - center.y * editor.viewport.scale)
        needsDisplay = true
    }

    private func drawGrid(in dirty: NSRect) {
        let spacing = max(10, 50 * editor.viewport.scale)
        let path = NSBezierPath()
        var x = editor.viewport.origin.x.truncatingRemainder(dividingBy: spacing)
        while x < bounds.maxX { path.move(to: .init(x: x, y: bounds.minY)); path.line(to: .init(x: x, y: bounds.maxY)); x += spacing }
        var y = editor.viewport.origin.y.truncatingRemainder(dividingBy: spacing)
        while y < bounds.maxY { path.move(to: .init(x: bounds.minX, y: y)); path.line(to: .init(x: bounds.maxX, y: y)); y += spacing }
        NSColor.white.withAlphaComponent(0.06).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func draw(_ element: Atlas.MapElement, index: Int, map: Atlas.Map) {
        let selected = editor.selection.contains(.init(mapIndex: editor.mapIndex, elementIndex: index))
        switch element {
        case let .rectangle(value):
            (color(value.color) ?? NSColor.systemGreen.withAlphaComponent(0.25)).setFill()
            NSBezierPath(rect: view(value.rect)).fill()
        case let .image(value):
            image(value.source)?.draw(in: view(value.rect), from: .zero, operation: .sourceOver, fraction: 1)
        case let .label(value):
            let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color(value.color) ?? .labelColor, .font: NSFont.systemFont(ofSize: max(8, CGFloat(editor.atlas.labelFont?.size ?? 9) * editor.viewport.scale))]
            value.text.draw(in: view(value.rect), withAttributes: attributes)
        case let .room(value):
            let rect = view(value.rect)
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            (color(value.color) ?? NSColor.controlAccentColor.withAlphaComponent(0.65)).setFill()
            path.fill()
            (color(value.outlineColor) ?? NSColor.white.withAlphaComponent(0.75)).setStroke()
            path.lineWidth = selected ? 3 : 1
            path.stroke()
            let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: max(8, CGFloat(editor.atlas.roomFont?.size ?? 9) * editor.viewport.scale), weight: .medium)]
            value.name.draw(in: rect.insetBy(dx: 5, dy: 4), withAttributes: attributes)
            if let current = editor.currentLocation, editor.objectID(for: current) == .init(mapIndex: editor.mapIndex, elementIndex: index) {
                NSColor.systemYellow.setStroke()
                let currentPath = NSBezierPath(ovalIn: rect.insetBy(dx: -5, dy: -5))
                currentPath.lineWidth = 3
                currentPath.stroke()
            }
        case let .exit(value):
            let rooms = map.rooms
            var points: [Atlas.Point] = []
            if let from = Int(value.from ?? ""), rooms.indices.contains(from) { points.append(rooms[from].rect.center) }
            points += value.points
            if let to = Int(value.to ?? ""), rooms.indices.contains(to) { points.append(rooms[to].rect.center) }
            guard points.count >= 2 else { return }
            let path = NSBezierPath()
            path.move(to: view(points[0]))
            points.dropFirst().forEach { path.line(to: view($0)) }
            (color(editor.atlas.attributes["color_exit"]) ?? .secondaryLabelColor).setStroke()
            path.lineWidth = selected ? 4 : 2
            path.stroke()
        case .unknown: break
        }
        if selected, element.kind != .room, let rect = element.rect {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let selection = NSBezierPath(rect: view(rect).insetBy(dx: -3, dy: -3))
            selection.lineWidth = 2
            selection.stroke()
        }
    }

    private func drawPath() {
        for step in highlightedPath {
            guard editor.atlas.maps.indices.contains(step.destination.mapIndex), step.destination.mapIndex == editor.mapIndex,
                  editor.atlas.maps[step.destination.mapIndex].rooms.indices.contains(step.destination.roomIndex) else { continue }
            NSColor.systemYellow.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: view(editor.atlas.maps[step.destination.mapIndex].rooms[step.destination.roomIndex].rect), xRadius: 8, yRadius: 8).fill()
        }
    }

    private func hitTestObject(at point: NSPoint) -> AtlasObjectID? {
        guard let map = editor.currentMap else { return nil }
        for (index, element) in map.elements.enumerated().reversed() {
            guard let kind = element.kind, editor.selectionFilter.contains(kind) else { continue }
            if let rect = element.rect, view(rect).insetBy(dx: -5, dy: -5).contains(point) {
                return .init(mapIndex: editor.mapIndex, elementIndex: index)
            }
            if case let .exit(exit) = element, exitHit(exit, at: point, map: map) {
                return .init(mapIndex: editor.mapIndex, elementIndex: index)
            }
        }
        return nil
    }

    private func roomLocation(at point: NSPoint) -> AtlasLocation? {
        guard let map = editor.currentMap else { return nil }
        return map.rooms.enumerated().reversed().first { view($0.element.rect).contains(point) }.map {
            .init(mapIndex: editor.mapIndex, roomIndex: $0.offset)
        }
    }

    private func exitHit(_ value: Atlas.Exit, at point: NSPoint, map: Atlas.Map) -> Bool {
        var points: [Atlas.Point] = []
        if let from = Int(value.from ?? ""), map.rooms.indices.contains(from) { points.append(map.rooms[from].rect.center) }
        points += value.points
        if let to = Int(value.to ?? ""), map.rooms.indices.contains(to) { points.append(map.rooms[to].rect.center) }
        return zip(points, points.dropFirst()).contains { distance(point, from: view($0.0), to: view($0.1)) < 7 }
    }

    private func distance(_ point: NSPoint, from: NSPoint, to: NSPoint) -> CGFloat {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - from.x, point.y - from.y) }
        let t = min(1, max(0, ((point.x - from.x) * dx + (point.y - from.y) * dy) / length))
        return hypot(point.x - (from.x + t * dx), point.y - (from.y + t * dy))
    }

    private func image(_ source: String) -> NSImage? {
        if let cached = imageCache[source] { return cached }
        let value = resources[source].flatMap(NSImage.init(data:))
        if let value { imageCache[source] = value }
        return value
    }

    private func color(_ value: String?) -> NSColor? {
        guard var value, value.hasPrefix("#") else { return nil }
        value.removeFirst()
        if value.count < 6 { value = String(repeating: "0", count: 6 - value.count) + value }
        return NSColor(hexString: "#" + String(value.prefix(6)))
    }

    private func view(_ rect: Atlas.Rect) -> NSRect {
        let rect = rect.standardized
        let first = view(.init(x: rect.x1, y: rect.y1))
        let second = view(.init(x: rect.x2, y: rect.y2))
        return .init(x: first.x, y: first.y, width: second.x - first.x, height: second.y - first.y)
    }

    private func view(_ point: Atlas.Point) -> NSPoint {
        .init(x: point.x * editor.viewport.scale + editor.viewport.origin.x, y: point.y * editor.viewport.scale + editor.viewport.origin.y)
    }

    private func world(_ point: NSPoint) -> Atlas.Point {
        .init(x: (point.x - editor.viewport.origin.x) / editor.viewport.scale, y: (point.y - editor.viewport.origin.y) / editor.viewport.scale)
    }
}

private extension Atlas.MapElement {
    var kind: AtlasObjectKind? {
        switch self {
        case .room: .room
        case .exit: .exit
        case .rectangle: .rectangle
        case .image: .image
        case .label: .label
        case .unknown: nil
        }
    }

    var rect: Atlas.Rect? {
        switch self {
        case let .room(value): value.rect
        case let .rectangle(value): value.rect
        case let .image(value): value.rect
        case let .label(value): value.rect
        case .exit, .unknown: nil
        }
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }
}

private extension NSPasteboard.PasteboardType {
    static let atlasFragment = Self("org.beipmu.atlas-fragment")
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
