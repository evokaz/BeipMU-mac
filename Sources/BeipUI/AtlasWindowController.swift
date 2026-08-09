import AppKit
import BeipCore
import BeipPersistence
import UniformTypeIdentifiers

@MainActor
final class AtlasWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private let canvas: AtlasCanvasView
    private let content = NSView()
    private let dockingAccessory = DockSurfaceAccessoryViewController()
    private let mapPopup = NSPopUpButton()
    private let exitsPopup = NSPopUpButton()
    private let search = NSSearchField()
    private let liveTracking = NSButton(checkboxWithTitle: "Auto-map", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "No current room")
    private let zoomStatus = NSTextField(labelWithString: "100%")
    private var toolButtons: [NSButton] = []
    private var filterButtons: [NSButton] = []
    private var toolbarCategories: [(title: String, buttons: [NSButton], view: NSView, separator: NSView?, naturalWidth: CGFloat)] = []
    private weak var toolbarOverflowButton: NSButton?
    private weak var toolbarView: NSStackView?
    private var updatingToolbarOverflow = false
    private weak var filterOverflowButton: NSButton?
    private weak var filterView: NSStackView?
    private weak var filterLabel: NSTextField?
    private var filterControlWidths: [CGFloat] = []
    private var updatingFilterOverflow = false
    private var resources: [String: Data] = [:]
    private var sourceURL: URL?
    private var searchResults: [AtlasSearchResult] = []
    private var searchIndex = -1
    private var suppressStateChange = false
    private(set) var isDocked = false
    var onClose: (() -> Void)?
    var onSendCommands: (([String]) -> Void)?
    var onStateChange: ((AtlasSurfacePreferences) -> Void)?
    var onDockRequest: ((WebViewDockSide) -> Void)? {
        didSet { dockingAccessory.onDockRequest = onDockRequest }
    }

    var editor: AtlasEditor {
        get { canvas.editor }
        set { canvas.editor = newValue }
    }
    var toolbarOverflowMenuForTesting: NSMenu { makeToolbarOverflowMenu() }
    var filterOverflowMenuForTesting: NSMenu { makeFilterOverflowMenu() }
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
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Atlas"
        window.minSize = NSSize(width: 680, height: 440)
        window.isReleasedWhenClosed = false
        RuntimeStateContext.setFrameAutosaveName("BeipMU.Atlas", for: window)
        window.setAccessibilityIdentifier("atlasWindow")
        super.init(window: window)
        window.delegate = self
        window.addTitlebarAccessoryViewController(dockingAccessory)
        configureUI()
        wireCanvas()
        refresh()
        canvas.centerAll()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { onClose?() }

    func contentViewForDocking() -> NSView {
        window?.orderOut(nil)
        if window?.contentView === content { window?.contentView = nil }
        content.removeFromSuperview()
        isDocked = true
        return content
    }

    func showFloating(_ sender: Any?) {
        if isDocked {
            content.removeFromSuperview()
            window?.contentView = content
            isDocked = false
        }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        window?.makeFirstResponder(canvas)
    }

    func focusSurface() {
        if isDocked {
            canvas.window?.makeKeyAndOrderFront(nil)
            canvas.window?.makeFirstResponder(canvas)
        } else {
            showFloating(nil)
        }
    }

    func closeSurface() {
        if isDocked {
            content.removeFromSuperview()
            window?.contentView = content
            isDocked = false
        }
        close()
    }

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
        guard canvas.editor.liveTracking else { return }
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
        let root = AtlasRootStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false
        root.onLayout = { [weak self] in
            self?.updateToolbarOverflow()
            self?.updateFilterOverflow()
        }

        let toolbarGroups: [(String, [NSButton])] = [
            ("File", [
                imageButton("Open", symbol: "folder", action: #selector(openDocument)),
                imageButton("Save", symbol: "square.and.arrow.down", action: #selector(saveDocument)),
                imageButton("Save As", symbol: "doc.badge.plus", action: #selector(saveDocumentAs)),
            ]),
            ("Navigation", [
                toolButton("Locate", symbol: "location.fill", tool: .locate),
                toolButton("Path", symbol: "point.topleft.down.to.point.bottomright.curvepath", tool: .path),
                toolButton("Run", symbol: "figure.run", tool: .speedRun),
                imageButton("Center current room", symbol: "scope", action: #selector(centerCurrentRoom)),
            ]),
            ("Create", [
                toolButton("Create room", symbol: "circle", tool: .room),
                toolButton("Create exit", symbol: "arrow.right", tool: .exit),
                toolButton("Create rectangle", symbol: "rectangle", tool: .rectangle),
                toolButton("Create image", symbol: "photo", tool: .image),
                toolButton("Create label", symbol: "tag", tool: .label),
            ]),
            ("Select", [
                toolButton("Select", symbol: "cursorarrow", tool: .select, accessibilityLabel: "Atlas editing tool"),
                toolButton("Pan", symbol: "hand.draw", tool: .pan),
                imageButton("Copy", symbol: "doc.on.doc", action: #selector(copySelection)),
                imageButton("Paste", symbol: "clipboard", action: #selector(pasteSelection)),
                imageButton("Undo", symbol: "arrow.uturn.backward", action: #selector(undo)),
                imageButton("Redo", symbol: "arrow.uturn.forward", action: #selector(redo)),
            ]),
            ("View", [
                imageButton("Zoom out", symbol: "minus.magnifyingglass", action: #selector(zoomOut)),
                imageButton("Actual size", symbol: "1.magnifyingglass", action: #selector(actualSize)),
                imageButton("Zoom in", symbol: "plus.magnifyingglass", action: #selector(zoomIn)),
                imageButton("Fit map", symbol: "arrow.up.left.and.arrow.down.right", action: #selector(fitMap)),
                imageButton("Palette", symbol: "paintpalette", action: #selector(editPalette)),
                imageButton("Export", symbol: "square.and.arrow.up", action: #selector(exportImage)),
            ]),
        ]

        let toolbar = AtlasToolbarStackView()
        toolbar.orientation = .horizontal
        toolbar.alignment = .top
        toolbar.spacing = 0
        toolbar.edgeInsets = .init(top: 5, left: 6, bottom: 4, right: 6)
        toolbar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (title, buttons) in toolbarGroups {
            let separator: NSView?
            if toolbar.arrangedSubviews.isEmpty {
                separator = nil
            } else {
                let value = NSBox.separator()
                toolbar.addArrangedSubview(value)
                separator = value
            }
            let group = toolbarGroup(title, controls: buttonStrip(buttons))
            toolbar.addArrangedSubview(group)
            toolbarCategories.append((
                title: title,
                buttons: buttons,
                view: group,
                separator: separator,
                naturalWidth: group.fittingSize.width
            ))
        }
        let toolbarOverflowButton = imageButton(
            "More Atlas tools",
            symbol: "ellipsis.circle",
            action: #selector(showToolbarOverflow(_:))
        )
        toolbarOverflowButton.isHidden = true
        toolbar.addArrangedSubview(toolbarOverflowButton)
        self.toolbarOverflowButton = toolbarOverflowButton
        toolbarView = toolbar
        toolbar.onLayout = { [weak self] in self?.updateToolbarOverflow() }

        let mapBar = NSStackView()
        mapBar.orientation = .horizontal
        mapBar.alignment = .centerY
        mapBar.spacing = 7
        mapBar.edgeInsets = .init(top: 5, left: 8, bottom: 5, right: 8)
        mapBar.addArrangedSubview(NSTextField(labelWithString: "Map:"))
        mapPopup.target = self
        mapPopup.action = #selector(changeMap)
        mapPopup.setAccessibilityLabel("Atlas map")
        mapPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mapBar.addArrangedSubview(mapPopup)
        mapBar.addArrangedSubview(imageButton("Add map", symbol: "plus", action: #selector(addMap)))
        mapBar.addArrangedSubview(imageButton("Remove map", symbol: "minus", action: #selector(removeMap)))
        mapBar.addArrangedSubview(NSBox.separator())
        exitsPopup.target = self
        exitsPopup.action = #selector(takeExit)
        exitsPopup.setAccessibilityLabel("Known exits")
        exitsPopup.toolTip = "Send a command for an exit from the current room"
        let exitsWidth = exitsPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 130)
        exitsWidth.priority = .defaultHigh
        exitsWidth.isActive = true
        mapBar.addArrangedSubview(exitsPopup)
        mapBar.addArrangedSubview(NSBox.separator())
        zoomStatus.alignment = .right
        zoomStatus.setAccessibilityLabel("Map zoom")
        let zoomWidth = zoomStatus.widthAnchor.constraint(equalToConstant: 44)
        zoomWidth.priority = .defaultHigh
        zoomWidth.isActive = true
        mapBar.addArrangedSubview(zoomStatus)

        let filters = AtlasFilterStackView()
        filters.orientation = .horizontal
        filters.alignment = .centerY
        filters.spacing = 8
        filters.edgeInsets = .init(top: 5, left: 10, bottom: 5, right: 10)
        filters.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let filterLabel = NSTextField(labelWithString: "Select:")
        filters.addArrangedSubview(filterLabel)
        self.filterLabel = filterLabel
        for (title, value) in [
            ("Rooms", AtlasSelectionFilter.rooms), ("Exits", .exits), ("Rectangles", .rectangles),
            ("Images", .images), ("Labels", .labels),
        ] {
            let control = NSButton(checkboxWithTitle: title, target: self, action: #selector(changeFilter(_:)))
            control.state = .on
            control.tag = Int(value.rawValue)
            filterButtons.append(control)
            filters.addArrangedSubview(control)
        }
        liveTracking.target = self
        liveTracking.action = #selector(changeLiveTracking(_:))
        liveTracking.state = canvas.editor.liveTracking ? .on : .off
        liveTracking.toolTip = "Create and connect rooms from game output while you move"
        liveTracking.setAccessibilityLabel("Automatic mapping")
        filters.addArrangedSubview(liveTracking)
        filterControlWidths = (filterButtons + [liveTracking]).map { $0.fittingSize.width }
        let filterOverflowButton = imageButton(
            "More selection filters",
            symbol: "ellipsis.circle",
            action: #selector(showFilterOverflow(_:))
        )
        filterOverflowButton.isHidden = true
        filters.addArrangedSubview(filterOverflowButton)
        self.filterOverflowButton = filterOverflowButton
        filterView = filters
        filters.onLayout = { [weak self] in self?.updateFilterOverflow() }
        search.placeholderString = "Find Rooms"
        search.delegate = self
        search.target = self
        search.action = #selector(findNext)
        let minimumSearchWidth = search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        minimumSearchWidth.priority = .required
        minimumSearchWidth.isActive = true
        let searchWidth = search.widthAnchor.constraint(equalToConstant: 190)
        searchWidth.priority = .defaultHigh
        searchWidth.isActive = true
        search.setContentCompressionResistancePriority(.required, for: .horizontal)
        filters.addArrangedSubview(search)
        filters.addArrangedSubview(status)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)

        mapBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filters.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(toolbar)
        root.addArrangedSubview(mapBar)
        root.addArrangedSubview(filters)
        root.addArrangedSubview(canvas)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 58),
            toolbar.widthAnchor.constraint(equalTo: root.widthAnchor),
            mapBar.heightAnchor.constraint(equalToConstant: 34),
            filters.heightAnchor.constraint(equalToConstant: 36),
            filters.widthAnchor.constraint(equalTo: root.widthAnchor),
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        window.contentView = content
        prepareForLayerBackedDrawing(root)
        toolbar.layer?.zPosition = 2
        mapBar.layer?.zPosition = 2
        filters.layer?.zPosition = 2
        canvas.layer?.zPosition = 1
        DispatchQueue.main.async { [weak self] in self?.updateToolbarOverflow() }
        DispatchQueue.main.async { [weak self] in self?.updateFilterOverflow() }
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
        exitsPopup.removeAllItems()
        let exits = canvas.editor.exitsFromCurrentRoom()
        if exits.isEmpty {
            exitsPopup.addItem(withTitle: "No known exits")
            exitsPopup.isEnabled = false
        } else {
            exitsPopup.addItem(withTitle: "Take exit…")
            for value in exits {
                exitsPopup.addItem(withTitle: "\(value.command) → \(value.destinationName)")
                exitsPopup.lastItem?.representedObject = value.command
            }
            exitsPopup.isEnabled = true
            exitsPopup.selectItem(at: 0)
        }
        liveTracking.state = canvas.editor.liveTracking ? .on : .off
        zoomStatus.stringValue = "\(Int((canvas.editor.viewport.scale * 100).rounded()))%"
        for button in toolButtons {
            button.state = button.tag == canvas.tool.rawValue ? .on : .off
        }
        for button in filterButtons {
            let filter = AtlasSelectionFilter(rawValue: UInt8(button.tag))
            button.state = canvas.editor.selectionFilter.contains(filter) ? .on : .off
        }
        canvas.needsDisplay = true
        if !suppressStateChange { onStateChange?(surfacePreferences) }
    }

    private func imageButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let value = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
        value.title = title
        value.bezelStyle = .texturedRounded
        value.imagePosition = .imageOnly
        value.imageScaling = .scaleProportionallyDown
        value.contentTintColor = .labelColor
        value.toolTip = title
        value.setAccessibilityLabel(title)
        let width = value.widthAnchor.constraint(equalToConstant: 31)
        width.priority = .defaultHigh
        width.isActive = true
        value.heightAnchor.constraint(equalToConstant: 26).isActive = true
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return value
    }

    private func toolButton(_ title: String, symbol: String, tool: AtlasCanvasView.Tool, accessibilityLabel: String? = nil) -> NSButton {
        let value = imageButton(title, symbol: symbol, action: #selector(selectTool(_:)))
        value.setButtonType(.toggle)
        value.tag = tool.rawValue
        value.setAccessibilityLabel(accessibilityLabel ?? title)
        value.state = tool == .select ? .on : .off
        toolButtons.append(value)
        return value
    }

    private func buttonStrip(_ buttons: [NSButton]) -> NSStackView {
        let value = NSStackView(views: buttons)
        value.orientation = .horizontal
        value.alignment = .centerY
        value.spacing = 3
        return value
    }

    private func toolbarGroup(_ title: String, controls: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        let value = NSStackView(views: [controls, label])
        value.orientation = .vertical
        value.alignment = .centerX
        value.spacing = 2
        value.edgeInsets = .init(top: 0, left: 6, bottom: 0, right: 6)
        return value
    }

    private func updateToolbarOverflow() {
        guard !updatingToolbarOverflow,
              let toolbarView,
              let toolbarOverflowButton,
              toolbarView.bounds.width > 0 else { return }

        let edgeWidth = toolbarView.edgeInsets.left + toolbarView.edgeInsets.right
        let separatorWidth = toolbarCategories.compactMap(\.separator).first?.fittingSize.width ?? 1
        let categoryWidths = toolbarCategories.map(\.naturalWidth)
        let naturalWidth = edgeWidth + categoryWidths.reduce(0, +)
            + separatorWidth * CGFloat(max(0, toolbarCategories.count - 1))
        let hasOverflow = naturalWidth > toolbarView.bounds.width + 1
        var visibleCount = toolbarCategories.count
        if hasOverflow {
            let availableWidth = max(0, toolbarView.bounds.width - edgeWidth - toolbarOverflowButton.fittingSize.width)
            var usedWidth: CGFloat = 0
            visibleCount = 0
            for width in categoryWidths {
                let addition = width + (visibleCount == 0 ? 0 : separatorWidth)
                guard usedWidth + addition <= availableWidth else { break }
                usedWidth += addition
                visibleCount += 1
            }
        }

        updatingToolbarOverflow = true
        toolbarOverflowButton.isHidden = !hasOverflow
        for (index, category) in toolbarCategories.enumerated() {
            let isVisible = index < visibleCount
            category.view.isHidden = !isVisible
            category.separator?.isHidden = !isVisible
        }
        updatingToolbarOverflow = false
    }

    private func makeToolbarOverflowMenu() -> NSMenu {
        let menu = NSMenu(title: "Atlas Tools")
        menu.autoenablesItems = false
        for category in toolbarCategories where category.view.isHidden {
            let categoryItem = NSMenuItem(title: category.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: category.title)
            submenu.autoenablesItems = false
            for button in category.buttons {
                let item = NSMenuItem(
                    title: button.title,
                    action: #selector(invokeToolbarCommand(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = button
                item.image = button.image
                item.state = button.state
                item.isEnabled = button.isEnabled
                submenu.addItem(item)
            }
            categoryItem.submenu = submenu
            menu.addItem(categoryItem)
        }
        return menu
    }

    @objc private func showToolbarOverflow(_ sender: NSButton) {
        let menu = makeToolbarOverflowMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func invokeToolbarCommand(_ sender: NSMenuItem) {
        guard let button = sender.representedObject as? NSButton,
              let action = button.action else { return }
        _ = NSApp.sendAction(action, to: button.target, from: button)
    }

    private func updateFilterOverflow() {
        guard !updatingFilterOverflow,
              let filterView,
              let filterOverflowButton,
              let filterLabel,
              filterView.bounds.width > 0 else { return }

        let controls = filterButtons + [liveTracking]
        let controlWidths = filterControlWidths
        let edgeWidth = filterView.edgeInsets.left + filterView.edgeInsets.right
        let spacing = filterView.spacing
        let labelWidth = filterLabel.fittingSize.width
        let overflowWidth = filterOverflowButton.fittingSize.width
        let statusWidth = status.fittingSize.width

        func requiredWidth(visibleCount: Int, showsOverflow: Bool, showsStatus: Bool, searchWidth: CGFloat) -> CGFloat {
            var widths = [labelWidth]
            widths.append(contentsOf: controlWidths.prefix(visibleCount))
            if showsOverflow { widths.append(overflowWidth) }
            widths.append(searchWidth)
            if showsStatus { widths.append(statusWidth) }
            return edgeWidth + widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        }

        let availableWidth = filterView.bounds.width
        var visibleCount = controls.count
        var showsStatus = requiredWidth(
            visibleCount: controls.count,
            showsOverflow: false,
            showsStatus: true,
            searchWidth: 190
        ) <= availableWidth

        if !showsStatus {
            while visibleCount > 0,
                  requiredWidth(
                    visibleCount: visibleCount,
                    showsOverflow: visibleCount < controls.count,
                    showsStatus: false,
                    searchWidth: 120
                  ) > availableWidth {
                visibleCount -= 1
            }
            showsStatus = false
        }

        let hasOverflow = visibleCount < controls.count
        updatingFilterOverflow = true
        for (index, control) in controls.enumerated() { control.isHidden = index >= visibleCount }
        filterOverflowButton.isHidden = !hasOverflow
        status.isHidden = !showsStatus
        updatingFilterOverflow = false
    }

    private func makeFilterOverflowMenu() -> NSMenu {
        let menu = NSMenu(title: "Selection Filters")
        menu.autoenablesItems = false
        for button in filterButtons + [liveTracking] where button.isHidden {
            let item = NSMenuItem(
                title: button.title,
                action: #selector(invokeFilterCommand(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = button
            item.state = button.state
            item.isEnabled = button.isEnabled
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showFilterOverflow(_ sender: NSButton) {
        let menu = makeFilterOverflowMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func invokeFilterCommand(_ sender: NSMenuItem) {
        guard let button = sender.representedObject as? NSButton else { return }
        button.performClick(nil)
    }

    private func prepareForLayerBackedDrawing(_ view: NSView) {
        view.wantsLayer = true
        if let button = view as? NSButton {
            button.contentTintColor = .labelColor
        } else if let label = view as? NSTextField, !label.isEditable {
            label.textColor = label.textColor ?? .labelColor
        }
        for child in view.subviews { prepareForLayerBackedDrawing(child) }
        view.needsDisplay = true
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

    @objc private func selectTool(_ sender: NSButton) {
        canvas.tool = AtlasCanvasView.Tool(rawValue: sender.tag) ?? .select
        for button in toolButtons { button.state = button === sender ? .on : .off }
        window?.makeFirstResponder(canvas)
    }

    @objc private func centerCurrentRoom() {
        guard let location = canvas.editor.currentLocation else { NSSound.beep(); return }
        canvas.center(on: location)
        refresh()
    }

    @objc private func takeExit() {
        guard let command = exitsPopup.selectedItem?.representedObject as? String else { return }
        onSendCommands?([command])
    }

    @objc private func zoomIn() { zoom(by: 1.25) }
    @objc private func zoomOut() { zoom(by: 0.8) }
    @objc private func actualSize() {
        let factor = 1 / canvas.editor.viewport.scale
        zoom(by: factor)
    }
    @objc private func fitMap() {
        canvas.centerAll()
        refresh()
    }

    private func zoom(by factor: Double) {
        canvas.editor.viewport.zoom(by: factor, around: .init(x: canvas.bounds.midX, y: canvas.bounds.midY))
        refresh()
    }

    @objc private func changeLiveTracking(_ sender: NSButton) {
        canvas.editor.liveTracking = sender.state == .on
        refresh()
    }

    @objc private func changeFilter(_ sender: NSButton) {
        let value = AtlasSelectionFilter(rawValue: UInt8(sender.tag))
        if sender.state == .on { canvas.editor.selectionFilter.insert(value) }
        else { canvas.editor.selectionFilter.remove(value) }
        refresh()
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
        func geometryFields(_ rect: Atlas.Rect) -> [(String, NSTextField)] {
            let value = rect.standardized
            return [
                ("X", NSTextField(string: Self.number(value.x1))),
                ("Y", NSTextField(string: Self.number(value.y1))),
                ("Width", NSTextField(string: Self.number(value.width))),
                ("Height", NSTextField(string: Self.number(value.height))),
            ]
        }
        let fields: [(String, NSTextField)]
        switch element {
        case let .room(value):
            fields = [
                ("Name", NSTextField(string: value.name)),
                ("Fill color", NSTextField(string: value.color ?? "")),
                ("Outline color", NSTextField(string: value.outlineColor ?? "")),
            ] + geometryFields(value.rect)
        case let .exit(value):
            fields = [("Command there", NSTextField(string: value.nameFrom ?? "")), ("Command back", NSTextField(string: value.nameTo ?? ""))]
        case let .rectangle(value): fields = [("Fill color", NSTextField(string: value.color ?? ""))] + geometryFields(value.rect)
        case let .image(value): fields = [("Image source", NSTextField(string: value.source))] + geometryFields(value.rect)
        case let .label(value): fields = [("Text", NSTextField(string: value.text)), ("Color", NSTextField(string: value.color ?? ""))] + geometryFields(value.rect)
        case .unknown: return
        }
        let grid = NSGridView(views: fields.map { [NSTextField(labelWithString: "\($0.0):"), $0.1] })
        grid.frame = NSRect(x: 0, y: 0, width: 390, height: CGFloat(max(1, fields.count) * 30))
        alert.accessoryView = grid
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let fieldValues = Dictionary(uniqueKeysWithValues: fields.map { ($0.0, $0.1.stringValue) })
        func updatedRect(_ original: Atlas.Rect) -> Atlas.Rect? {
            guard let x = fieldValues["X"].flatMap(Double.init),
                  let y = fieldValues["Y"].flatMap(Double.init),
                  let width = fieldValues["Width"].flatMap(Double.init),
                  let height = fieldValues["Height"].flatMap(Double.init),
                  width >= 10, height >= 10 else { return nil }
            return .init(x1: x, y1: y, x2: x + width, y2: y + height)
        }
        let updated: Atlas.MapElement
        switch element {
        case var .room(value):
            guard let rect = updatedRect(value.rect) else { NSSound.beep(); return }
            value.name = fieldValues["Name"] ?? value.name
            value.color = fieldValues["Fill color"]?.nilIfEmpty
            value.outlineColor = fieldValues["Outline color"]?.nilIfEmpty
            value.rect = rect
            updated = .room(value)
        case var .exit(value):
            value.nameFrom = fieldValues["Command there"]?.nilIfEmpty
            value.nameTo = fieldValues["Command back"]?.nilIfEmpty
            updated = .exit(value)
        case var .rectangle(value):
            guard let rect = updatedRect(value.rect) else { NSSound.beep(); return }
            value.color = fieldValues["Fill color"]?.nilIfEmpty
            value.rect = rect
            updated = .rectangle(value)
        case var .image(value):
            guard let rect = updatedRect(value.rect) else { NSSound.beep(); return }
            value.source = fieldValues["Image source"] ?? value.source
            value.rect = rect
            updated = .image(value)
        case var .label(value):
            guard let rect = updatedRect(value.rect) else { NSSound.beep(); return }
            value.text = fieldValues["Text"] ?? value.text
            value.color = fieldValues["Color"]?.nilIfEmpty
            value.rect = rect
            updated = .label(value)
        case .unknown: return
        }
        canvas.editor.updateElement(at: id, to: updated)
        refresh()
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private func create(_ kind: AtlasCanvasView.Tool, rect: Atlas.Rect) {
        let created: AtlasObjectID?
        switch kind {
        case .room:
            guard let name = prompt(title: "Create Room", label: "Room name", value: "Room") else { return }
            created = canvas.editor.addRoom(name: name, rect: rect)
            if canvas.editor.currentLocation == nil, let map = canvas.editor.currentMap, !map.rooms.isEmpty {
                canvas.editor.setCurrentLocation(.init(mapIndex: canvas.editor.mapIndex, roomIndex: map.rooms.count - 1))
            }
        case .rectangle:
            created = canvas.editor.addRectangle(rect: rect, color: "#3A3A3A")
        case .label:
            guard let text = prompt(title: "Create Label", label: "Label text", value: "Label") else { return }
            created = canvas.editor.addLabel(text: text, rect: rect, color: "#FFFFFF")
        case .image:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg, .gif]
            guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
            let path = "images/\(url.lastPathComponent)"
            resources[path] = data
            canvas.resources = resources
            created = canvas.editor.addImage(source: path, rect: rect)
        default:
            created = nil
        }
        guard let created else { return }
        canvas.editor.selection = [created]
        canvas.tool = .select
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

private final class AtlasToolbarStackView: NSStackView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class AtlasRootStackView: NSStackView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class AtlasFilterStackView: NSStackView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

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
    private var resizingID: AtlasObjectID?
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
        if tool == .select, let id = resizeHandleHit(at: point) {
            resizingID = id
            isPanning = false
            return
        }
        isPanning = tool == .pan || event.buttonNumber == 2 || (tool == .select && hitTestObject(at: point) == nil)
        guard tool == .select, !isPanning, let id = hitTestObject(at: point) else { return }
        if event.modifierFlags.contains(.shift) {
            if editor.selection.contains(id) { editor.selection.remove(id) } else { editor.selection.insert(id) }
        } else if !editor.selection.contains(id) {
            editor.selection = [id]
        }
        needsDisplay = true
        if event.clickCount == 2 { onEditProperties?() }
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
        defer { mouseStart = nil; worldStart = nil; isPanning = false; resizingID = nil }
        if let id = resizingID, let element = editor.element(at: id), let original = element.rect {
            let x2 = event.modifierFlags.contains(.control) ? end.x : (end.x / 10).rounded() * 10
            let y2 = event.modifierFlags.contains(.control) ? end.y : (end.y / 10).rounded() * 10
            editor.resizeElement(at: id, to: .init(x1: original.standardized.x1, y1: original.standardized.y1, x2: x2, y2: y2))
            onChange?()
            return
        }
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
            editor.viewport.zoom(by: 1.2, around: .init(x: bounds.midX, y: bounds.midY))
            needsDisplay = true
            onChange?()
            return
        }
        if event.charactersIgnoringModifiers == "-" {
            editor.viewport.zoom(by: 0.8, around: .init(x: bounds.midX, y: bounds.midY))
            needsDisplay = true
            onChange?()
            return
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
        if selected, editor.selection.count == 1, let rect = element.rect {
            NSColor.keyboardFocusIndicatorColor.setFill()
            NSBezierPath(rect: resizeHandle(for: rect)).fill()
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

    private func resizeHandleHit(at point: NSPoint) -> AtlasObjectID? {
        guard editor.selection.count == 1, let id = editor.selection.first,
              id.mapIndex == editor.mapIndex, let rect = editor.element(at: id)?.rect,
              resizeHandle(for: rect).insetBy(dx: -3, dy: -3).contains(point) else { return nil }
        return id
    }

    private func resizeHandle(for rect: Atlas.Rect) -> NSRect {
        let value = view(rect)
        return .init(x: value.maxX - 5, y: value.maxY - 5, width: 10, height: 10)
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
