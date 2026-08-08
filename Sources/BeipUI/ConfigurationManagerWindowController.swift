import AppKit
import BeipCore
import BeipPersistence

private final class TopAlignedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class OutlineDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class TabbableFormTextView: NSTextView {
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(self)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(self)
    }
}

@MainActor
final class ConfigurationManagerWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private enum Selection: Equatable {
        case server(UUID)
        case character(server: UUID, character: UUID)
        case puppet(server: UUID, character: UUID, puppet: UUID)
    }

    private enum ActiveList {
        case saved
        case samples
    }

    private final class ProfileNode {
        let selection: Selection
        let title: String
        let symbol: String
        var children: [ProfileNode]

        init(selection: Selection, title: String, symbol: String, children: [ProfileNode] = []) {
            self.selection = selection
            self.title = title
            self.symbol = symbol
            self.children = children
        }
    }

    private let library: ProfileLibrary
    private let table = NSOutlineView()
    private let samplesTable = NSOutlineView()
    private let detailStack = NSStackView()
    private let detailScroll = NSScrollView()
    private var profileNodes: [ProfileNode] = []
    private var sampleNodes: [ProfileNode] = []
    private var sampleServers: [LegacyConfigurationProjection.Server] = []
    private var selection: Selection?
    private var sampleSelection: Selection?
    private var activeList: ActiveList = .saved
    private var libraryObserverID: UUID?
    private let onConnectProfile: ((ServerProfile, CharacterProfile?) -> Void)?
    private let onShowStatistics: (() -> Void)?

    private var nameField: NSTextField?
    private var hostField: NSTextField?
    private var portField: NSTextField?
    private var serverInfoField: NSTextView?
    private var expirationField: NSTextField?
    private var encodingPopup: NSPopUpButton?
    private var webViewPolicyPopup: NSPopUpButton?
    private var connectField: NSTextView?
    private var characterInfoField: NSTextView?
    private var passwordField: NSTextField?
    private var passwordContainer: NSView?
    private var idleMinutesField: NSTextField?
    private var idleTextField: NSTextField?
    private var characterLogFilenameField: NSTextField?
    private var receivePrefixField: NSTextField?
    private var sendPrefixField: NSTextField?
    private var puppetLogFilenameField: NSTextField?
    private var puppetCharacterLogPrefixField: NSTextField?
    private var checks: [String: NSButton] = [:]
    private var newButton: NSButton?
    private var deleteButton: NSButton?

    init(
        library: ProfileLibrary,
        onConnectProfile: ((ServerProfile, CharacterProfile?) -> Void)? = nil,
        onShowStatistics: (() -> Void)? = nil
    ) {
        self.library = library
        self.onConnectProfile = onConnectProfile
        self.onShowStatistics = onShowStatistics
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 768, height: 654),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 700, height: 540)
        window.title = "Worlds"
        window.setAccessibilityIdentifier("configurationManager")
        window.titlebarSeparatorStyle = .line
        super.init(window: window)
        window.setFrameAutosaveName("BeipMUWorlds")
        window.center()
        configureUI(in: window)
        loadSampleWorlds()
        libraryObserverID = library.addChangeObserver { [weak self] in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        MainActor.assumeIsolated {
            library.removeChangeObserver(libraryObserverID)
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    private func configureUI(in window: NSWindow) {
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .width
        sidebar.spacing = 0
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 328).isActive = true

        configureOutline(table, identifier: "configurationProfileList")
        let tableDocument = OutlineDocumentView()
        tableDocument.translatesAutoresizingMaskIntoConstraints = false
        table.translatesAutoresizingMaskIntoConstraints = false
        tableDocument.addSubview(table)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: tableDocument.leadingAnchor),
            table.trailingAnchor.constraint(lessThanOrEqualTo: tableDocument.trailingAnchor),
            table.topAnchor.constraint(equalTo: tableDocument.topAnchor),
            table.bottomAnchor.constraint(equalTo: tableDocument.bottomAnchor),
        ])
        let tableScroll = scrollView(for: tableDocument)
        tableScroll.focusRingType = .none
        table.widthAnchor.constraint(equalTo: tableDocument.widthAnchor).isActive = true
        tableScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        tableScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        sidebar.addArrangedSubview(tableScroll)
        tableDocument.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -29).isActive = true

        let separator = NSBox()
        separator.boxType = .custom
        separator.fillColor = .separatorColor
        separator.borderColor = .separatorColor
        separator.borderWidth = 0
        separator.heightAnchor.constraint(equalToConstant: 4).isActive = true
        sidebar.addArrangedSubview(separator)

        let samplesTitle = NSTextField(labelWithString: "Sample Worlds")
        samplesTitle.font = .systemFont(ofSize: 13)
        samplesTitle.heightAnchor.constraint(equalToConstant: 22).isActive = true
        samplesTitle.setAccessibilityIdentifier("sampleWorldsHeading")
        sidebar.addArrangedSubview(samplesTitle)

        configureOutline(samplesTable, identifier: "sampleWorldsList")
        let samplesScroll = scrollView(for: samplesTable)
        samplesScroll.heightAnchor.constraint(equalToConstant: 144).isActive = true
        samplesScroll.setContentHuggingPriority(.required, for: .vertical)
        samplesScroll.setContentCompressionResistancePriority(.required, for: .vertical)
        sidebar.addArrangedSubview(samplesScroll)

        detailStack.orientation = .vertical
        detailStack.alignment = .width
        detailStack.distribution = .fill
        detailStack.spacing = 5
        detailStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        detailStack.translatesAutoresizingMaskIntoConstraints = false

        let detailDocument = TopAlignedDocumentView()
        detailDocument.translatesAutoresizingMaskIntoConstraints = false
        detailDocument.addSubview(detailStack)
        detailScroll.documentView = detailDocument
        detailScroll.hasVerticalScroller = true
        detailScroll.hasHorizontalScroller = false
        detailScroll.drawsBackground = true
        detailScroll.backgroundColor = .windowBackgroundColor
        detailScroll.setAccessibilityIdentifier("profileDetailScroll")
        NSLayoutConstraint.activate([
            detailStack.leadingAnchor.constraint(equalTo: detailDocument.leadingAnchor),
            detailStack.trailingAnchor.constraint(equalTo: detailDocument.trailingAnchor),
            detailStack.topAnchor.constraint(equalTo: detailDocument.topAnchor),
            detailStack.bottomAnchor.constraint(equalTo: detailDocument.bottomAnchor),
            detailDocument.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
            detailDocument.heightAnchor.constraint(greaterThanOrEqualTo: detailScroll.contentView.heightAnchor),
        ])

        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let split = NSStackView(views: [sidebar, divider, detailScroll])
        split.orientation = .horizontal
        split.alignment = .height
        split.distribution = .fill
        split.spacing = 0
        split.setContentHuggingPriority(.defaultLow, for: .horizontal)
        split.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        split.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let new = button("New...", identifier: "newWorld", action: #selector(showNewMenu(_:)))
        newButton = new
        let imported = button("Import...", identifier: "importWorld", action: #selector(importConfiguration(_:)))
        let connect = button("Connect", identifier: "connectWorld", action: #selector(connectSelection(_:)))
        connect.keyEquivalent = "\r"
        let copy = button("Copy", identifier: "copyWorld", action: #selector(copySelection(_:)))
        let exported = button("Export...", identifier: "exportWorld", action: #selector(exportConfiguration(_:)))
        let deleted = button("Delete", identifier: "deleteWorld", action: #selector(deleteSelection(_:)))
        deleteButton = deleted
        let leftFooter = NSStackView(views: [
            buttonRow([new, imported, connect]),
            buttonRow([copy, exported, deleted]),
        ])
        leftFooter.orientation = .vertical
        leftFooter.spacing = 3
        leftFooter.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)

        let statistics = button("Statistics", identifier: "worldStatistics", action: #selector(showStatistics(_:)))
        let help = button("Help", identifier: "worldHelp", action: #selector(showHelp(_:)))
        let apply = button("Apply", identifier: "applyWorldChanges", action: #selector(applyManager(_:)))
        let ok = button("OK", identifier: "applyProfileChanges", action: #selector(closeManager(_:)))
        ok.keyEquivalent = "\r"
        let cancel = button("Cancel", identifier: "cancelWorlds", action: #selector(cancelManager(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let rightFooter = NSStackView(views: [
            buttonRow([statistics, help]),
            buttonRow([apply, ok, cancel]),
        ])
        rightFooter.orientation = .vertical
        rightFooter.spacing = 3
        rightFooter.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        rightFooter.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rightFooter.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [leftFooter, rightFooter])
        footer.orientation = .horizontal
        footer.alignment = .height
        footer.distribution = .fill
        footer.spacing = 0
        footer.heightAnchor.constraint(equalToConstant: 52).isActive = true
        footer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [split, footer])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        let contentView = NSView()
        window.contentView = contentView
        contentView.addSubview(root)
        let doneAlias = NSButton(title: "Done", target: self, action: #selector(closeManager(_:)))
        doneAlias.isHidden = true
        contentView.addSubview(doneAlias)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            root.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            split.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
            sidebar.widthAnchor.constraint(equalTo: split.widthAnchor, multiplier: 0.425),
            leftFooter.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
        ])
        root.distribution = .fill
        root.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        split.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        sidebar.setContentHuggingPriority(.defaultLow, for: .vertical)
        sidebar.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        detailScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        detailScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func configureOutline(_ outline: NSOutlineView, identifier: String) {
        outline.headerView = nil
        outline.rowHeight = 21
        outline.indentationPerLevel = 16
        outline.style = .plain
        outline.focusRingType = .none
        outline.selectionHighlightStyle = .regular
        outline.backgroundColor = .textBackgroundColor
        outline.usesAlternatingRowBackgroundColors = false
        let column = NSTableColumn(identifier: .init(identifier + ".column"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.delegate = self
        outline.dataSource = self
        outline.setAccessibilityIdentifier(identifier)
        outline.setAccessibilityLabel(identifier == "sampleWorldsList" ? "Sample worlds" : "Saved worlds and characters")
    }

    private func scrollView(for documentView: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = documentView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        return scroll
    }

    private func button(_ title: String, identifier: String, action: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: action)
        value.controlSize = .regular
        value.setAccessibilityIdentifier(identifier)
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return value
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 4
        return row
    }

    private func loadSampleWorlds() {
        guard let url = Bundle.module.url(forResource: "SampleConfig", withExtension: "txt"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let document = try? LegacyConfigurationDocument(source: source),
              let workspace = try? LegacyConfigurationWorkspace(document: document) else {
            sampleServers = []
            return
        }
        sampleServers = workspace.servers.sorted { $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending }
        sampleNodes = sampleServers.map(makeNode)
        samplesTable.reloadData()
    }

    private func makeNode(_ server: LegacyConfigurationProjection.Server) -> ProfileNode {
        let characterNodes = server.characters.map { character in
            ProfileNode(
                selection: .character(server: server.profile.id, character: character.id),
                title: character.name,
                symbol: "person",
                children: character.puppets.map { puppet in
                    ProfileNode(
                        selection: .puppet(
                            server: server.profile.id,
                            character: character.id,
                            puppet: puppet.id
                        ),
                        title: puppet.name,
                        symbol: "person.2"
                    )
                }
            )
        }
        return ProfileNode(
            selection: .server(server.profile.id),
            title: server.profile.name,
            symbol: "desktopcomputer",
            children: characterNodes
        )
    }

    private func reload(select requested: Selection? = nil) {
        let retained = requested ?? selection
        profileNodes = library.workspace.servers.map(makeNode)
        table.reloadData()
        profileNodes.forEach { node in
            if !node.children.isEmpty { table.expandItem(node) }
            node.children.forEach { child in
                if !child.children.isEmpty { table.expandItem(child) }
            }
        }

        if let retained, let node = node(for: retained, in: profileNodes) {
            selection = retained
            table.selectRowIndexes(IndexSet(integer: table.row(forItem: node)), byExtendingSelection: false)
        } else if let first = profileNodes.first {
            selection = first.selection
            table.selectRowIndexes(IndexSet(integer: table.row(forItem: first)), byExtendingSelection: false)
        } else {
            selection = nil
            table.deselectAll(nil)
        }
        rebuildDetails()
        updateTitle()
        deleteButton?.isEnabled = selection != nil && activeList == .saved
    }

    private func updateTitle() {
        let dirty = library.workspace.isDirty ? " — Edited" : ""
        window?.title = dirty.isEmpty ? "Worlds" : "Worlds & Characters\(dirty)"
    }

    private func node(for selection: Selection, in nodes: [ProfileNode]) -> ProfileNode? {
        for node in nodes {
            if node.selection == selection { return node }
            if let child = self.node(for: selection, in: node.children) { return child }
        }
        return nil
    }

    private func rootNodes(for outlineView: NSOutlineView) -> [ProfileNode] {
        outlineView === table ? profileNodes : sampleNodes
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return rootNodes(for: outlineView).count }
        return (item as? ProfileNode)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let item = item as? ProfileNode { return item.children[index] }
        return rootNodes(for: outlineView)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ProfileNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ProfileNode else { return nil }
        let cell = NSTableCellView()
        let image = NSImageView(
            image: NSImage(systemSymbolName: node.symbol, accessibilityDescription: node.title) ?? NSImage()
        )
        image.contentTintColor = .secondaryLabelColor
        image.imageScaling = .scaleProportionallyDown
        let label = NSTextField(labelWithString: node.title)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        image.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 1),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 15),
            image.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let outlineView = notification.object as? NSOutlineView,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? ProfileNode else { return }
        if outlineView === table {
            activeList = .saved
            selection = node.selection
            rebuildDetails()
        } else {
            activeList = .samples
            sampleSelection = node.selection
        }
        deleteButton?.isEnabled = activeList == .saved && selection != nil
    }

    // Kept as a small compatibility shim for the native UI tests and for
    // callers that used the original flat NSTableView implementation.
    func tableViewSelectionDidChange(_ notification: Notification) {
        outlineViewSelectionDidChange(
            Notification(name: NSOutlineView.selectionDidChangeNotification, object: table)
        )
    }

    private func rebuildDetails() {
        detailStack.arrangedSubviews.forEach {
            detailStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        clearControls()
        guard let selection else {
            let empty = NSTextField(labelWithString: "Select a world or character to edit it.")
            empty.textColor = .secondaryLabelColor
            detailStack.addArrangedSubview(empty)
            return
        }
        switch selection {
        case let .server(id): buildServerForm(id: id)
        case let .character(server, character): buildCharacterForm(serverID: server, characterID: character)
        case let .puppet(server, character, puppet):
            buildPuppetForm(serverID: server, characterID: character, puppetID: puppet)
        }
        let detailSpacer = NSView()
        detailSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        detailSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        detailStack.addArrangedSubview(detailSpacer)
        resetDetailScrollPosition()
        refreshKeyViewLoop()
    }

    private func resetDetailScrollPosition() {
        detailScroll.documentView?.layoutSubtreeIfNeeded()
        detailScroll.contentView.scroll(to: .zero)
        detailScroll.reflectScrolledClipView(detailScroll.contentView)
    }

    private func refreshKeyViewLoop() {
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.recalculateKeyViewLoop()
        if let nameField, let hostField, let portField,
           portField.accessibilityIdentifier() == "worldPort" {
            nameField.nextKeyView = hostField
            hostField.nextKeyView = portField
        }
    }

    private func buildServerForm(id: UUID) {
        guard let server = library.workspace.servers.first(where: { $0.profile.id == id })?.profile else { return }
        addHeading("Server")

        let name = textField(server.name, identifier: "worldName")
        let host = textField("\(server.host):\(server.port)", identifier: "worldHost")
        let hiddenPort = textField(String(server.port), identifier: "worldPort")
        hiddenPort.alphaValue = 0
        hiddenPort.widthAnchor.constraint(equalToConstant: 1).isActive = true
        hiddenPort.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let info = multilineTextField(server.info, identifier: "worldInfo", height: 60)
        let infoText = info.documentView as? NSTextView
        let expiration = textField(String(server.characterExpirationTime), identifier: "worldCharacterExpiration")
        expiration.widthAnchor.constraint(equalToConstant: 92).isActive = true
        expiration.alignment = .right
        let encoding = popup(titles: TextEncoding.allCases.map(\.rawValue), selected: server.encoding.rawValue, identifier: "worldEncoding")
        let webViews = popup(
            titles: ServerWebViewPolicy.allCases.map(\.title),
            selected: (server.gmcpWebViewPolicy ?? .ask).title,
            identifier: "worldWebViewPolicy"
        )
        nameField = name
        hostField = host
        portField = hiddenPort
        serverInfoField = infoText
        expirationField = expiration
        encodingPopup = encoding
        webViewPolicyPopup = webViews
        detailStack.addArrangedSubview(formRow("Name", control: name, labelWidth: 38))
        detailStack.addArrangedSubview(formRow("Info", control: info, labelWidth: 38, alignsToTop: true))
        detailStack.addArrangedSubview(formRow("Host", control: host, labelWidth: 38))
        detailStack.addArrangedSubview(hiddenPort)

        let tls = check("tls", "Use TLS (SSL)", server.usesTLS, action: #selector(toggleTLS(_:)))
        let verify = check("verify", "Verify Certificate", server.verifiesCertificate)
        verify.isEnabled = server.usesTLS
        addCheck(tls)
        addCheck(verify)
        addCheck(check("pueblo", "Pueblo (Experimental, let us know)", server.pueblo))
        addCheck(check("prompts", "Invisible MUD Prompt Workaround", server.prompts))
        addCheck(check("mcp", "Enable MCP (Mud Client Protocol)", server.mcp))
        addCheck(check("mcmp", "Enable MCMP (Mud Client Media Protocol over GMCP)", server.mcmp))
        addCheck(check("ipv4", "Force IPV4 host address lookup", server.forceIPv4))
        addCheck(check("naws", "Send NAWS when window resizes", server.sendNAWSOnResize))
        detailStack.addArrangedSubview(formRow("GMCP WebViews", control: webViews, labelWidth: 108))
        detailStack.addArrangedSubview(formRow("Text Encoding", control: encoding, labelWidth: 108))
        addCheck(check("charset", "Limit CHARSET negotiation to chosen encoding", server.limitTelnetCharset))
        let expirationRow = NSStackView(views: [
            NSTextField(labelWithString: "Character Expiration Time (Days)"), expiration, NSView(),
        ])
        expirationRow.orientation = .horizontal
        expirationRow.alignment = .centerY
        expirationRow.spacing = 5
        expirationRow.arrangedSubviews[0].setContentHuggingPriority(.required, for: .horizontal)
        detailStack.addArrangedSubview(expirationRow)
        name.nextKeyView = host
        host.nextKeyView = hiddenPort
    }

    private func buildCharacterForm(serverID: UUID, characterID: UUID) {
        guard let character = library.workspace.servers.first(where: { $0.profile.id == serverID })?
            .characters.first(where: { $0.id == characterID }) else { return }
        addHeading("Character")

        let name = textField(character.name, identifier: "characterName")
        let password = NSSecureTextField(string: character.password)
        password.setAccessibilityIdentifier("characterPassword")
        let passwordRow = passwordControl(password)
        let connect = multilineTextField(character.connectText, identifier: "characterConnectText", height: 60)
        let info = multilineTextField(character.info, identifier: "characterInfo", height: 60)
        let connectText = connect.documentView as? NSTextView
        let infoText = info.documentView as? NSTextView
        let form = NSStackView(views: [
            formRow("Name", control: name, labelWidth: 62),
            formRow("Password", control: passwordRow, labelWidth: 62),
            formRow("Connect\nString", control: connect, labelWidth: 62, alignsToTop: true),
            formRow("Info", control: info, labelWidth: 62, alignsToTop: true),
        ])
        form.orientation = .vertical
        form.alignment = .width
        form.spacing = 5
        form.setAccessibilityIdentifier("characterForm")
        addDetailSubview(form)

        let idleEnabled = character.idleTimeout != nil
        let idleCheck = check("idleEnabled", "If idle for", idleEnabled, action: #selector(toggleIdle(_:)))
        let idleMinutes = textField(character.idleTimeout.map { String(Int($0 / 60)) } ?? "", identifier: "characterIdleMinutes")
        idleMinutes.alignment = .right
        idleMinutes.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let minutesLabel = NSTextField(labelWithString: "minutes, send")
        let idleText = textField(character.idleText, identifier: "characterIdleText")
        idleText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let idleRow = NSStackView(views: [idleCheck, idleMinutes, minutesLabel, idleText])
        idleRow.orientation = .horizontal
        idleRow.alignment = .centerY
        idleRow.distribution = .fill
        idleRow.spacing = 5
        let autoConnect = check("autoConnect", "Connect at startup", character.autoConnect)
        let logFilename = textField(character.logFilename, identifier: "characterLogFilename")
        let chooseLog = button("Log File...", identifier: "chooseCharacterLogFile", action: #selector(chooseCharacterLogFile(_:)))
        let logRow = NSStackView(views: [chooseLog, logFilename])
        logRow.orientation = .horizontal
        logRow.distribution = .fill
        logRow.spacing = 5
        logFilename.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let logDate = check("characterLogDate", "Append Current Date To Log File Name", character.logAppendsDate)
        let restoreLog = check("restoreLog", "Restore Log", character.restoreLog)
        let behavior = NSStackView(views: [
            idleRow,
            checkboxRow(autoConnect),
            logRow,
            checkboxRow(logDate),
            checkboxRow(restoreLog),
        ])
        behavior.orientation = .vertical
        behavior.alignment = .width
        behavior.distribution = .fill
        behavior.spacing = 4
        behavior.setAccessibilityIdentifier("characterBehavior")
        addDetailSubview(behavior)

        let lastUsed = readOnlyField(character.lastUsed.isEmpty ? "Unknown" : character.lastUsed, identifier: "characterLastUsed")
        let totalTime = readOnlyField(formatDuration(character.secondsConnected), identifier: "characterTotalTime")
        let dateCreated = readOnlyField(character.created.isEmpty ? "Unknown" : character.created, identifier: "characterDateCreated")
        let timesConnected = readOnlyField(String(character.connectionCount), identifier: "characterTimesConnected")
        let bytesReceived = readOnlyField(String(character.bytesReceived), identifier: "characterBytesReceived")
        let bytesSent = readOnlyField(String(character.bytesSent), identifier: "characterBytesSent")
        addDetailSubview(formRow("Last Used", control: lastUsed, labelWidth: 66))
        addDetailSubview(statRow("Total Time Connected", value: totalTime, labelWidth: 136, resetTag: 1))
        addDetailSubview(statRow("Date Created", value: dateCreated, labelWidth: 90, resetTag: 2))
        addDetailSubview(formRow("Times connected", control: timesConnected, labelWidth: 110))
        let bytesRow = NSStackView(views: [
            NSTextField(labelWithString: "Bytes Received:"), bytesReceived,
            NSTextField(labelWithString: "Sent:"), bytesSent,
        ])
        bytesRow.orientation = .horizontal
        bytesRow.alignment = .centerY
        bytesRow.distribution = .fill
        bytesRow.spacing = 5
        bytesRow.arrangedSubviews[0].setContentHuggingPriority(.required, for: .horizontal)
        bytesRow.arrangedSubviews[2].setContentHuggingPriority(.required, for: .horizontal)
        bytesReceived.widthAnchor.constraint(equalTo: bytesSent.widthAnchor).isActive = true
        addDetailSubview(bytesRow)

        nameField = name
        passwordField = password
        passwordContainer = passwordRow
        connectField = connectText
        characterInfoField = infoText
        idleMinutesField = idleMinutes
        idleTextField = idleText
        characterLogFilenameField = logFilename
        updateIdleControls(enabled: idleEnabled)
    }

    private func buildPuppetForm(serverID: UUID, characterID: UUID, puppetID: UUID) {
        guard let puppet = library.workspace.servers.first(where: { $0.profile.id == serverID })?
            .characters.first(where: { $0.id == characterID })?
            .puppets.first(where: { $0.id == puppetID }) else { return }
        addHeading("Puppet")
        let name = textField(puppet.name, identifier: "puppetName")
        let receive = textField(puppet.receivePrefix, identifier: "puppetReceivePrefix")
        let send = textField(puppet.sendPrefix, identifier: "puppetSendPrefix")
        let logFilename = textField(puppet.logFilename, identifier: "puppetLogFilename")
        let characterLogPrefix = textField(puppet.characterLogPrefix, identifier: "puppetCharacterLogPrefix")
        let form = NSStackView(views: [
            formRow("Name", control: name, labelWidth: 105),
            formRow("Receive prefix", control: receive, labelWidth: 105),
            formRow("Send prefix", control: send, labelWidth: 105),
            formRow("Log filename", control: logFilename, labelWidth: 105),
            formRow("Character log prefix", control: characterLogPrefix, labelWidth: 105),
        ])
        form.orientation = .vertical
        form.alignment = .width
        form.spacing = 5
        detailStack.addArrangedSubview(form)
        addCheck(check("regex", "Receive prefix is a regular expression", puppet.receivePrefixIsRegex))
        addCheck(check("hide", "Hide receive prefix", puppet.hideReceivePrefix))
        addCheck(check("autoConnect", "Auto-connect puppet", puppet.autoConnect))
        addCheck(check("withPlayer", "Connect with player", puppet.connectWithPlayer))
        addCheck(check("removePrefix", "Remove accidental outgoing prefix", puppet.removeAccidentalPrefix))
        addCheck(check("puppetLogDate", "Append date to puppet log filename", puppet.logAppendsDate))
        addCheck(check("puppetCharacterLog", "Copy routed lines to the character log", puppet.characterLog))
        nameField = name
        receivePrefixField = receive
        sendPrefixField = send
        puppetLogFilenameField = logFilename
        puppetCharacterLogPrefixField = characterLogPrefix
    }

    private func addHeading(_ title: String) {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 14, weight: .bold)
        heading.alignment = .left
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heading.heightAnchor.constraint(equalToConstant: 20).isActive = true
        addDetailSubview(heading)
    }

    private func textField(_ value: String, identifier: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.setAccessibilityIdentifier(identifier)
        field.controlSize = .regular
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func readOnlyField(_ value: String, identifier: String) -> NSTextField {
        let field = textField(value, identifier: identifier)
        field.isEditable = false
        field.isSelectable = true
        field.isEnabled = false
        return field
    }

    private func multilineTextField(_ value: String, identifier: String, height: CGFloat) -> NSScrollView {
        let text = TabbableFormTextView()
        text.string = value
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.setAccessibilityIdentifier(identifier)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return scroll
    }

    private func passwordControl(_ secureField: NSSecureTextField) -> NSView {
        let show = NSButton(title: "Show", target: self, action: #selector(togglePassword(_:)))
        show.setButtonType(.pushOnPushOff)
        show.setAccessibilityIdentifier("showCharacterPassword")
        let stack = NSStackView(views: [secureField, show])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 5
        secureField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func popup(titles: [String], selected: String, identifier: String) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: titles)
        popup.selectItem(withTitle: selected)
        popup.setAccessibilityIdentifier(identifier)
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return popup
    }

    private func formRow(
        _ title: String,
        control: NSView,
        labelWidth: CGFloat,
        alignsToTop: Bool = false
    ) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.usesSingleLineMode = false
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.alignment = .left
        label.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = alignsToTop ? .top : .centerY
        row.distribution = .fill
        row.spacing = 5
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        return row
    }

    private func statRow(_ title: String, value: NSTextField, labelWidth: CGFloat, resetTag: Int) -> NSStackView {
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetCharacterStat(_:)))
        reset.tag = resetTag
        reset.setAccessibilityIdentifier(resetTag == 1 ? "resetCharacterTotal" : "resetCharacterDate")
        let row = formRow(title, control: value, labelWidth: labelWidth)
        row.addArrangedSubview(reset)
        return row
    }

    private func check(
        _ key: String,
        _ title: String,
        _ enabled: Bool,
        action: Selector? = nil
    ) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: action == nil ? nil : self, action: action)
        button.state = enabled ? .on : .off
        button.alignment = .left
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityIdentifier(key)
        checks[key] = button
        return button
    }

    private func addCheck(_ button: NSButton) {
        let row = checkboxRow(button)
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        detailStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -16).isActive = true
    }

    private func checkboxRow(_ button: NSButton) -> NSStackView {
        let row = NSStackView(views: [button, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 0
        button.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private func addDetailSubview(_ view: NSView) {
        detailStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -16).isActive = true
    }

    private func clearControls() {
        nameField = nil
        hostField = nil
        portField = nil
        serverInfoField = nil
        expirationField = nil
        encodingPopup = nil
        webViewPolicyPopup = nil
        connectField = nil
        characterInfoField = nil
        passwordField = nil
        passwordContainer = nil
        idleMinutesField = nil
        idleTextField = nil
        characterLogFilenameField = nil
        receivePrefixField = nil
        sendPrefixField = nil
        checks = [:]
        puppetLogFilenameField = nil
        puppetCharacterLogPrefixField = nil
    }

    @objc private func showNewMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let server = NSMenuItem(title: "Server", action: #selector(addWorld(_:)), keyEquivalent: "")
        let character = NSMenuItem(title: "Character", action: #selector(addCharacter(_:)), keyEquivalent: "")
        let puppet = NSMenuItem(title: "Puppet", action: #selector(addPuppet(_:)), keyEquivalent: "")
        [server, character, puppet].forEach { $0.target = self; menu.addItem($0) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func addWorld(_ sender: Any?) {
        do {
            var newID: UUID!
            try library.mutate { newID = $0.addServer() }
            reload(select: .server(newID))
        } catch { present(error) }
    }

    @objc private func addCharacter(_ sender: Any?) {
        guard let serverID = selectedServerID else { NSSound.beep(); return }
        do {
            var newID: UUID!
            try library.mutate { newID = try $0.addCharacter(toServerID: serverID) }
            reload(select: .character(server: serverID, character: newID))
        } catch { present(error) }
    }

    @objc private func addPuppet(_ sender: Any?) {
        guard let ids = selectedCharacterIDs else { NSSound.beep(); return }
        do {
            var newID: UUID!
            try library.mutate {
                newID = try $0.addPuppet(toCharacterID: ids.character, inServerID: ids.server)
            }
            reload(select: .puppet(server: ids.server, character: ids.character, puppet: newID))
        } catch { present(error) }
    }

    @objc private func deleteSelection(_ sender: Any?) {
        guard let selection, activeList == .saved else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this entry?"
        alert.informativeText = "The entry and its children will be removed from Config.txt when you confirm."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try library.mutate { workspace in
                switch selection {
                case let .server(id): try workspace.removeServer(id: id)
                case let .character(server, character): try workspace.removeCharacter(id: character, fromServerID: server)
                case let .puppet(server, character, puppet):
                    try workspace.removePuppet(id: puppet, fromCharacterID: character, serverID: server)
                }
            }
            reload()
        } catch { present(error) }
    }

    @objc private func connectSelection(_ sender: Any?) {
        guard let profile = profileForActiveSelection() else { NSSound.beep(); return }
        onConnectProfile?(profile.server, profile.character)
    }

    @objc private func showStatistics(_ sender: Any?) {
        onShowStatistics?()
    }

    @objc private func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Worlds"
        alert.informativeText = "Saved worlds and characters are shown at the top left. Sample worlds can be copied into your saved list, then edited or connected."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func copySelection(_ sender: Any?) {
        do {
            if activeList == .samples, let sampleSelection,
               let source = sampleServer(for: sampleSelection) {
                var copiedID: UUID!
                try library.mutate { workspace in copiedID = try copyServer(source, into: &workspace) }
                reload(select: .server(copiedID))
                return
            }
            guard let selection, let source = savedProfile(for: selection) else { return }
            var copiedSelection: Selection?
            try library.mutate { workspace in
                copiedSelection = try copySavedProfile(source, selection: selection, into: &workspace)
            }
            reload(select: copiedSelection)
        } catch { present(error) }
    }

    private func copyServer(
        _ source: LegacyConfigurationProjection.Server,
        into workspace: inout LegacyConfigurationWorkspace
    ) throws -> UUID {
        let newServerID = workspace.addServer(named: copiedName(source.profile.name))
        let newServerName = workspace.servers.first { $0.profile.id == newServerID }?.profile.name
        try workspace.updateServer(id: newServerID) { target in
            target.profile = source.profile
            target.profile.id = newServerID
            target.profile.name = newServerName ?? copiedName(source.profile.name)
        }
        for character in source.characters {
            let newCharacterID = try workspace.addCharacter(toServerID: newServerID, named: character.name)
            try workspace.updateCharacter(id: newCharacterID, inServerID: newServerID) { target in
                target = character
                target.id = newCharacterID
                target.restoreLogIndex = -1
            }
            for puppet in character.puppets {
                let newPuppetID = try workspace.addPuppet(
                    toCharacterID: newCharacterID,
                    inServerID: newServerID,
                    named: puppet.name
                )
                try workspace.updatePuppet(
                    id: newPuppetID,
                    inCharacterID: newCharacterID,
                    serverID: newServerID
                ) { target in
                    target = puppet
                    target.id = newPuppetID
                }
            }
        }
        return newServerID
    }

    private enum SavedProfile {
        case server(LegacyConfigurationProjection.Server)
        case character(CharacterProfile)
        case puppet(PuppetProfile)
    }

    private func savedProfile(for selection: Selection) -> SavedProfile? {
        switch selection {
        case let .server(id):
            return library.workspace.servers.first { $0.profile.id == id }.map(SavedProfile.server)
        case let .character(server, character):
            return library.workspace.servers.first { $0.profile.id == server }?.characters
                .first { $0.id == character }.map(SavedProfile.character)
        case let .puppet(server, character, puppet):
            return library.workspace.servers.first { $0.profile.id == server }?.characters
                .first { $0.id == character }?.puppets.first { $0.id == puppet }.map(SavedProfile.puppet)
        }
    }

    private func copySavedProfile(
        _ source: SavedProfile,
        selection: Selection,
        into workspace: inout LegacyConfigurationWorkspace
    ) throws -> Selection {
        switch (source, selection) {
        case let (.server(server), .server):
            return .server(try copyServer(server, into: &workspace))
        case let (.character(character), .character(serverID, _)):
            let newID = try workspace.addCharacter(toServerID: serverID, named: copiedName(character.name))
            let newCharacterName = workspace.servers
                .first { $0.profile.id == serverID }?.characters
                .first { $0.id == newID }?.name
            try workspace.updateCharacter(id: newID, inServerID: serverID) { target in
                target = character
                target.id = newID
                target.name = newCharacterName ?? copiedName(character.name)
                target.restoreLogIndex = -1
            }
            return .character(server: serverID, character: newID)
        case let (.puppet(puppet), .puppet(serverID, characterID, _)):
            let newID = try workspace.addPuppet(
                toCharacterID: characterID,
                inServerID: serverID,
                named: puppet.name
            )
            try workspace.updatePuppet(id: newID, inCharacterID: characterID, serverID: serverID) { target in
                target = puppet
                target.id = newID
            }
            return .puppet(server: serverID, character: characterID, puppet: newID)
        default:
            throw LegacyConfigurationWorkspace.WorkspaceError.serverNotFound
        }
    }

    private func copiedName(_ name: String) -> String {
        "\(name) - copy"
    }

    private func sampleServer(for selection: Selection) -> LegacyConfigurationProjection.Server? {
        let serverID: UUID
        switch selection {
        case let .server(id), let .character(server: id, character: _), let .puppet(server: id, character: _, puppet: _):
            serverID = id
        }
        return sampleServers.first { $0.profile.id == serverID }
    }

    private func profileForActiveSelection() -> (server: ServerProfile, character: CharacterProfile?)? {
        if activeList == .samples, let sampleSelection, let sample = sampleServer(for: sampleSelection) {
            let characterID: UUID? = switch sampleSelection {
            case .server: nil
            case let .character(_, character), let .puppet(_, character, _): character
            }
            return (sample.profile, characterID.flatMap { id in sample.characters.first { $0.id == id } })
        }
        guard let selection else { return nil }
        switch selection {
        case let .server(id):
            return library.workspace.servers.first { $0.profile.id == id }.map { ($0.profile, nil) }
        case let .character(server, character), let .puppet(server, character, _):
            guard let server = library.workspace.servers.first(where: { $0.profile.id == server }),
                  let character = server.characters.first(where: { $0.id == character }) else { return nil }
            return (server.profile, character)
        }
    }

    @objc private func importConfiguration(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Import World Configuration"
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try library.importConfiguration(from: url)
            reload()
        } catch { present(error) }
    }

    @objc private func exportConfiguration(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "Export World Configuration"
        panel.nameFieldStringValue = "Config-export.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try library.export(to: url) }
        catch { present(error) }
    }

    @objc private func closeManager(_ sender: Any?) {
        do {
            try applyCurrentSelection()
            close()
        } catch { present(error) }
    }

    @objc private func applyManager(_ sender: Any?) {
        do { try applyCurrentSelection() }
        catch { present(error) }
    }

    @objc private func cancelManager(_ sender: Any?) {
        close()
    }

    private func applyCurrentSelection() throws {
        guard let selection else { return }
        try library.mutate { workspace in
            switch selection {
            case let .server(id):
                guard let nameField, let hostField else { throw ValidationError.invalidWorld }
                guard let endpoint = parseEndpoint(hostField.stringValue, fallbackPort: portField?.stringValue),
                      !endpoint.host.isEmpty else { throw ValidationError.invalidWorld }
                try workspace.updateServer(id: id) { server in
                    server.profile.name = nameField.stringValue
                    server.profile.host = endpoint.host
                    server.profile.port = endpoint.port
                    server.profile.info = serverInfoField?.string ?? ""
                    server.profile.characterExpirationTime = max(0, expirationField?.integerValue ?? 0)
                    server.profile.encoding = TextEncoding(rawValue: encodingPopup?.titleOfSelectedItem ?? "") ?? .cp1252
                    server.profile.usesTLS = checked("tls")
                    server.profile.verifiesCertificate = checked("verify")
                    server.profile.forceIPv4 = checked("ipv4")
                    server.profile.pueblo = checked("pueblo")
                    server.profile.prompts = checked("prompts")
                    server.profile.mcp = checked("mcp")
                    server.profile.mcmp = checked("mcmp")
                    server.profile.gmcpWebViewPolicy = ServerWebViewPolicy.allCases.first {
                        $0.title == self.webViewPolicyPopup?.titleOfSelectedItem
                    } ?? .ask
                    server.profile.sendNAWSOnResize = checked("naws")
                    server.profile.limitTelnetCharset = checked("charset")
                }
            case let .character(server, character):
                guard let nameField else { return }
                try workspace.updateCharacter(id: character, inServerID: server) { value in
                    value.name = nameField.stringValue
                    value.connectText = connectField?.string ?? ""
                    value.password = passwordField?.stringValue ?? ""
                    value.info = characterInfoField?.string ?? ""
                    value.autoConnect = checked("autoConnect")
                    value.idleTimeout = checked("idleEnabled")
                        ? TimeInterval(max(0, idleMinutesField?.doubleValue ?? 0) * 60)
                        : nil
                    value.idleText = checked("idleEnabled") ? (idleTextField?.stringValue ?? "") : ""
                    value.logFilename = characterLogFilenameField?.stringValue ?? ""
                    value.logAppendsDate = checked("characterLogDate")
                    value.restoreLog = checked("restoreLog")
                }
            case let .puppet(server, character, puppet):
                guard let nameField else { return }
                try workspace.updatePuppet(id: puppet, inCharacterID: character, serverID: server) { value in
                    value.name = nameField.stringValue
                    value.receivePrefix = receivePrefixField?.stringValue ?? ""
                    value.sendPrefix = sendPrefixField?.stringValue ?? ""
                    value.receivePrefixIsRegex = checked("regex")
                    value.hideReceivePrefix = checked("hide")
                    value.autoConnect = checked("autoConnect")
                    value.connectWithPlayer = checked("withPlayer")
                    value.removeAccidentalPrefix = checked("removePrefix")
                    value.logFilename = puppetLogFilenameField?.stringValue ?? ""
                    value.logAppendsDate = checked("puppetLogDate")
                    value.characterLog = checked("puppetCharacterLog")
                    value.characterLogPrefix = puppetCharacterLogPrefixField?.stringValue ?? ""
                }
            }
        }
    }

    private func checked(_ key: String) -> Bool { checks[key]?.state == .on }

    private func parseEndpoint(_ value: String, fallbackPort: String?) -> (host: String, port: UInt16)? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let suffix = text[text.index(after: close)...]
            let port = suffix.first == ":" ? UInt16(suffix.dropFirst()) : UInt16(fallbackPort ?? "")
            return port.map { (host, $0) }
        }
        if let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]) {
            return (String(text[..<colon]), port)
        }
        return UInt16(fallbackPort ?? "").map { (text, $0) }
    }

    @objc private func toggleTLS(_ sender: NSButton) {
        checks["verify"]?.isEnabled = sender.state == .on
    }

    @objc private func toggleIdle(_ sender: NSButton) {
        updateIdleControls(enabled: sender.state == .on)
    }

    private func updateIdleControls(enabled: Bool) {
        idleMinutesField?.isEnabled = enabled
        idleTextField?.isEnabled = enabled
        if enabled, idleMinutesField?.stringValue.isEmpty == true {
            idleMinutesField?.stringValue = "5"
        }
    }

    @objc private func togglePassword(_ sender: NSButton) {
        guard let current = passwordField, let container = passwordContainer as? NSStackView else { return }
        let replacement: NSTextField = sender.state == .on
            ? NSTextField(string: current.stringValue)
            : NSSecureTextField(string: current.stringValue)
        replacement.setAccessibilityIdentifier("characterPassword")
        replacement.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let index = container.arrangedSubviews.firstIndex(of: current) ?? 0
        container.removeArrangedSubview(current)
        current.removeFromSuperview()
        container.insertArrangedSubview(replacement, at: index)
        passwordField = replacement
    }

    @objc private func resetCharacterStat(_ sender: NSButton) {
        guard case let .character(serverID, characterID) = selection else { return }
        do {
            try library.mutate { workspace in
                try workspace.updateCharacter(id: characterID, inServerID: serverID) { character in
                    if sender.tag == 1 {
                        character.bytesSent = 0
                        character.bytesReceived = 0
                        character.secondsConnected = 0
                        character.connectionCount = 0
                        character.lastUsed = ""
                    } else {
                        character.created = Self.currentDateString()
                    }
                }
            }
            reload(select: selection)
        } catch { present(error) }
    }

    @objc private func chooseCharacterLogFile(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "Choose Character Log File"
        panel.nameFieldStringValue = characterLogFilenameField?.stringValue.isEmpty == false
            ? characterLogFilenameField!.stringValue
            : "Character.log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        characterLogFilenameField?.stringValue = url.path
    }

    private var selectedServerID: UUID? {
        guard let selection else { return nil }
        switch selection {
        case let .server(id): return id
        case let .character(server, _), let .puppet(server, _, _): return server
        }
    }

    private var selectedCharacterIDs: (server: UUID, character: UUID)? {
        guard let selection else { return nil }
        switch selection {
        case let .character(server, character), let .puppet(server, character, _): return (server, character)
        default: return nil
        }
    }

    private func formatDuration(_ seconds: UInt64) -> String {
        if seconds == 0 { return "0s" }
        let minutes = seconds / 60
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m \(seconds % 60)s"
    }

    private static func currentDateString() -> String {
        CharacterProfile.timestamp()
    }

    private func present(_ error: Error) {
        if let window { window.presentError(error) }
        else { NSApplication.shared.presentError(error) }
    }
}

private enum ValidationError: LocalizedError {
    case invalidWorld

    var errorDescription: String? {
        "Enter a host and a port between 1 and 65535."
    }
}
