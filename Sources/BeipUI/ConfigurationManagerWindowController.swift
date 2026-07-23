import AppKit
import BeipCore
import BeipPersistence

@MainActor
final class ConfigurationManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Selection: Equatable {
        case server(UUID)
        case character(server: UUID, character: UUID)
        case puppet(server: UUID, character: UUID, puppet: UUID)
    }

    private struct Row {
        var selection: Selection
        var title: String
        var level: Int
        var symbol: String
    }

    private let library: ProfileLibrary
    private let table = NSTableView()
    private let detailStack = NSStackView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var selection: Selection?

    private var nameField: NSTextField?
    private var hostField: NSTextField?
    private var portField: NSTextField?
    private var encodingPopup: NSPopUpButton?
    private var webViewPolicyPopup: NSPopUpButton?
    private var aiEndpointField: NSTextField?
    private var aiModelField: NSTextField?
    private var connectField: NSTextField?
    private var passwordField: NSSecureTextField?
    private var idleMinutesField: NSTextField?
    private var idleTextField: NSTextField?
    private var receivePrefixField: NSTextField?
    private var sendPrefixField: NSTextField?
    private var puppetLogFilenameField: NSTextField?
    private var puppetCharacterLogPrefixField: NSTextField?
    private var checks: [String: NSButton] = [:]
    var onRequestSaveAs: (() -> Void)?

    init(library: ProfileLibrary) {
        self.library = library
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 720, height: 520)
        super.init(window: window)
        window.setFrameAutosaveName("BeipMUConfigurationManager")
        window.center()
        configureUI(in: window)
        library.onChange = { [weak self] in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    private func configureUI(in window: NSWindow) {
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.spacing = 8
        sidebar.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 8)

        let title = NSTextField(labelWithString: "Worlds & Characters")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        sidebar.addArrangedSubview(title)

        table.headerView = nil
        table.rowHeight = 28
        table.style = .sourceList
        table.addTableColumn(NSTableColumn(identifier: .init("Profile")))
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityIdentifier("configurationProfileList")
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        sidebar.addArrangedSubview(tableScroll)

        let addWorld = NSButton(title: "+ World", target: self, action: #selector(addWorld(_:)))
        let addCharacter = NSButton(title: "+ Character", target: self, action: #selector(addCharacter(_:)))
        let addPuppet = NSButton(title: "+ Puppet", target: self, action: #selector(addPuppet(_:)))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeSelection(_:)))
        let buttons = NSStackView(views: [addWorld, addCharacter, addPuppet, NSView(), remove])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        sidebar.addArrangedSubview(buttons)
        sidebar.widthAnchor.constraint(equalToConstant: 300).isActive = true

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 12
        detailStack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        let detailDocument = NSView()
        detailDocument.translatesAutoresizingMaskIntoConstraints = false
        detailDocument.addSubview(detailStack)
        let detailScroll = NSScrollView()
        detailScroll.documentView = detailDocument
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        NSLayoutConstraint.activate([
            detailStack.leadingAnchor.constraint(equalTo: detailDocument.leadingAnchor),
            detailStack.trailingAnchor.constraint(equalTo: detailDocument.trailingAnchor),
            detailStack.topAnchor.constraint(equalTo: detailDocument.topAnchor),
            detailStack.bottomAnchor.constraint(equalTo: detailDocument.bottomAnchor),
            detailDocument.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
            detailDocument.heightAnchor.constraint(greaterThanOrEqualTo: detailScroll.contentView.heightAnchor),
        ])

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(detailScroll)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = [.command]
        let footer = NSStackView(views: [statusLabel, NSView(), save])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let root = NSStackView(views: [split, footer])
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    private func reload(select requested: Selection? = nil) {
        let retained = requested ?? selection
        rows = library.workspace.servers.flatMap { server -> [Row] in
            var values = [Row(
                selection: .server(server.profile.id),
                title: server.profile.name,
                level: 0,
                symbol: "network"
            )]
            for character in server.characters {
                values.append(.init(
                    selection: .character(server: server.profile.id, character: character.id),
                    title: character.name,
                    level: 1,
                    symbol: "person"
                ))
                values += character.puppets.map {
                    .init(
                        selection: .puppet(server: server.profile.id, character: character.id, puppet: $0.id),
                        title: $0.name,
                        level: 2,
                        symbol: "person.2"
                    )
                }
            }
            return values
        }
        table.reloadData()
        if let retained, let index = rows.firstIndex(where: { $0.selection == retained }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            selection = retained
        } else if !rows.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            selection = rows[0].selection
        } else {
            selection = nil
        }
        rebuildDetails()
        let dirty = library.workspace.isDirty ? " — Edited" : ""
        window?.title = "\(library.displayName)\(dirty)"
        if let recovery = library.workspace.recoveredFrom {
            statusLabel.stringValue = "Recovered read-only source from \(recovery.lastPathComponent); save to commit it."
        } else {
            statusLabel.stringValue = library.workspace.sourceURL?.path ?? "Unsaved configuration"
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let value = rows[row]
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: value.symbol, accessibilityDescription: nil) ?? NSImage())
        let label = NSTextField(labelWithString: value.title)
        label.lineBreakMode = .byTruncatingTail
        image.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: CGFloat(7 + value.level * 18)),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { selection = nil; rebuildDetails(); return }
        selection = rows[row].selection
        rebuildDetails()
    }

    private func rebuildDetails() {
        detailStack.arrangedSubviews.forEach {
            detailStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        clearControls()
        guard let selection else {
            let empty = NSTextField(labelWithString: "Add a world to begin building your connection profiles.")
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
    }

    private func buildServerForm(id: UUID) {
        guard let server = library.workspace.servers.first(where: { $0.profile.id == id })?.profile else { return }
        addHeading("World", subtitle: "Connection and protocol settings")
        let name = textField(server.name, identifier: "worldName")
        let host = textField(server.host, identifier: "worldHost")
        let port = textField(String(server.port), identifier: "worldPort")
        let encoding = NSPopUpButton()
        encoding.addItems(withTitles: TextEncoding.allCases.map(\.rawValue))
        encoding.selectItem(withTitle: server.encoding.rawValue)
        encoding.setAccessibilityIdentifier("worldEncoding")
        nameField = name; hostField = host; portField = port; encodingPopup = encoding
        let aiEndpoint = textField(server.aiEndpoint?.absoluteString ?? "", identifier: "worldAIEndpoint")
        let aiModel = textField(server.aiModel, identifier: "worldAIModel")
        aiEndpointField = aiEndpoint
        aiModelField = aiModel
        let webViewPolicy = NSPopUpButton()
        webViewPolicy.addItems(withTitles: ServerWebViewPolicy.allCases.map(\.title))
        webViewPolicy.selectItem(withTitle: (server.gmcpWebViewPolicy ?? .ask).title)
        webViewPolicy.setAccessibilityIdentifier("worldWebViewPolicy")
        webViewPolicyPopup = webViewPolicy
        detailStack.addArrangedSubview(grid([
            ("Name:", name), ("Host:", host), ("Port:", port), ("Encoding:", encoding),
            ("Server WebViews:", webViewPolicy), ("AI endpoint:", aiEndpoint), ("AI model:", aiModel),
        ]))
        addCheck("tls", "Use TLS", server.usesTLS)
        addCheck("verify", "Verify TLS certificate", server.verifiesCertificate)
        addCheck("ipv4", "Force IPv4", server.forceIPv4)
        addCheck("pueblo", "Enable Pueblo", server.pueblo)
        addCheck("prompts", "Recognize prompts", server.prompts)
        addCheck("mcp", "Enable MCP", server.mcp)
        addCheck("mcmp", "Enable MCMP", server.mcmp)
        addCheck("naws", "Send window size on resize", server.sendNAWSOnResize)
        addCheck("charset", "Limit Telnet charset negotiation", server.limitTelnetCharset)
        addApplyButton()
    }

    private func buildCharacterForm(serverID: UUID, characterID: UUID) {
        guard let character = library.workspace.servers.first(where: { $0.profile.id == serverID })?
            .characters.first(where: { $0.id == characterID }) else { return }
        addHeading("Character", subtitle: "Login, startup, and idle behavior")
        let name = textField(character.name, identifier: "characterName")
        let connect = textField(character.connectText, identifier: "characterConnectText")
        let password = NSSecureTextField(string: character.password)
        password.setAccessibilityIdentifier("characterPassword")
        let idleMinutes = textField(character.idleTimeout.map { String(Int($0 / 60)) } ?? "", identifier: "characterIdleMinutes")
        let idleText = textField(character.idleText, identifier: "characterIdleText")
        nameField = name; connectField = connect; passwordField = password
        idleMinutesField = idleMinutes; idleTextField = idleText
        detailStack.addArrangedSubview(grid([
            ("Name:", name), ("Connect text:", connect), ("Password:", password),
            ("Idle minutes:", idleMinutes), ("Idle command:", idleText),
        ]))
        addCheck("autoConnect", "Connect at startup", character.autoConnect)
        addApplyButton()
    }

    private func buildPuppetForm(serverID: UUID, characterID: UUID, puppetID: UUID) {
        guard let puppet = library.workspace.servers.first(where: { $0.profile.id == serverID })?
            .characters.first(where: { $0.id == characterID })?
            .puppets.first(where: { $0.id == puppetID }) else { return }
        addHeading("Puppet", subtitle: "Route incoming lines and prefix outgoing commands")
        let name = textField(puppet.name, identifier: "puppetName")
        let receive = textField(puppet.receivePrefix, identifier: "puppetReceivePrefix")
        let send = textField(puppet.sendPrefix, identifier: "puppetSendPrefix")
        let logFilename = textField(puppet.logFilename, identifier: "puppetLogFilename")
        let characterLogPrefix = textField(puppet.characterLogPrefix, identifier: "puppetCharacterLogPrefix")
        nameField = name; receivePrefixField = receive; sendPrefixField = send
        puppetLogFilenameField = logFilename
        puppetCharacterLogPrefixField = characterLogPrefix
        detailStack.addArrangedSubview(grid([
            ("Name:", name), ("Receive prefix:", receive), ("Send prefix:", send),
            ("Log filename:", logFilename), ("Character log prefix:", characterLogPrefix),
        ]))
        addCheck("regex", "Receive prefix is a regular expression", puppet.receivePrefixIsRegex)
        addCheck("hide", "Hide receive prefix", puppet.hideReceivePrefix)
        addCheck("autoConnect", "Auto-connect puppet", puppet.autoConnect)
        addCheck("withPlayer", "Connect with player", puppet.connectWithPlayer)
        addCheck("removePrefix", "Remove accidental outgoing prefix", puppet.removeAccidentalPrefix)
        addCheck("puppetLogDate", "Append date to puppet log filename", puppet.logAppendsDate)
        addCheck("puppetCharacterLog", "Copy routed lines to the character log", puppet.characterLog)
        addApplyButton()
    }

    private func addHeading(_ title: String, subtitle: String) {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let detail = NSTextField(labelWithString: subtitle)
        detail.textColor = .secondaryLabelColor
        detailStack.addArrangedSubview(heading)
        detailStack.addArrangedSubview(detail)
    }

    private func textField(_ value: String, identifier: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.setAccessibilityIdentifier(identifier)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        return field
    }

    private func grid(_ rows: [(String, NSView)]) -> NSGridView {
        let view = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
        view.column(at: 0).xPlacement = .trailing
        view.column(at: 1).width = 360
        view.rowSpacing = 9
        view.columnSpacing = 10
        return view
    }

    private func addCheck(_ key: String, _ title: String, _ enabled: Bool) {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = enabled ? .on : .off
        button.setAccessibilityIdentifier(key)
        checks[key] = button
        detailStack.addArrangedSubview(button)
    }

    private func addApplyButton() {
        let button = NSButton(title: "Apply Changes", target: self, action: #selector(applyChanges(_:)))
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("applyProfileChanges")
        detailStack.addArrangedSubview(button)
    }

    private func clearControls() {
        nameField = nil; hostField = nil; portField = nil; encodingPopup = nil; webViewPolicyPopup = nil
        aiEndpointField = nil; aiModelField = nil
        connectField = nil; passwordField = nil; idleMinutesField = nil; idleTextField = nil
        receivePrefixField = nil; sendPrefixField = nil; checks = [:]
        puppetLogFilenameField = nil; puppetCharacterLogPrefixField = nil
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

    @objc private func removeSelection(_ sender: Any?) {
        guard let selection else { return }
        let alert = NSAlert()
        alert.messageText = "Remove this profile?"
        alert.informativeText = "The entry and its children will be removed from Config.txt when you save."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try library.mutate { workspace in
                switch selection {
                case let .server(id): try workspace.removeServer(id: id)
                case let .character(server, character):
                    try workspace.removeCharacter(id: character, fromServerID: server)
                case let .puppet(server, character, puppet):
                    try workspace.removePuppet(id: puppet, fromCharacterID: character, serverID: server)
                }
            }
            reload()
        } catch { present(error) }
    }

    @objc private func applyChanges(_ sender: Any?) {
        guard let selection else { return }
        do {
            try library.mutate { workspace in
                switch selection {
                case let .server(id):
                    guard let nameField, let hostField, let port = UInt16(portField?.stringValue ?? ""),
                          !hostField.stringValue.isEmpty else { throw ValidationError.invalidWorld }
                    try workspace.updateServer(id: id) { server in
                        server.profile.name = nameField.stringValue
                        server.profile.host = hostField.stringValue
                        server.profile.port = port
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
                        let endpointText = aiEndpointField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        server.profile.aiEndpoint = endpointText.isEmpty ? nil : URL(string: endpointText)
                        server.profile.aiModel = aiModelField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    }
                case let .character(server, character):
                    guard let nameField else { return }
                    try workspace.updateCharacter(id: character, inServerID: server) { value in
                        value.name = nameField.stringValue
                        value.connectText = connectField?.stringValue ?? ""
                        value.password = passwordField?.stringValue ?? ""
                        value.autoConnect = checked("autoConnect")
                        value.idleTimeout = idleMinutesField.flatMap { $0.stringValue.isEmpty ? nil : TimeInterval($0.doubleValue * 60) }
                        value.idleText = idleTextField?.stringValue ?? ""
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
            reload(select: selection)
        } catch { present(error) }
    }

    @objc private func save(_ sender: Any?) {
        guard library.workspace.sourceURL != nil else { onRequestSaveAs?(); return }
        Task {
            do { try await library.save() }
            catch { present(error) }
        }
    }

    private func checked(_ key: String) -> Bool { checks[key]?.state == .on }

    private var selectedServerID: UUID? {
        switch selection {
        case let .server(id): id
        case let .character(server, _), let .puppet(server, _, _): server
        case nil: nil
        }
    }

    private var selectedCharacterIDs: (server: UUID, character: UUID)? {
        switch selection {
        case let .character(server, character), let .puppet(server, character, _): (server, character)
        default: nil
        }
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
