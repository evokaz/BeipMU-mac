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
    var onRequestSaveAs: (() -> Void)?

    init(library: ProfileLibrary) {
        self.library = library
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 860, height: 560)
        window.title = "Worlds & Characters"
        window.setAccessibilityIdentifier("configurationManager")
        window.titlebarSeparatorStyle = .line
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
        sidebar.spacing = 10
        sidebar.edgeInsets = NSEdgeInsets(top: 16, left: 14, bottom: 12, right: 10)

        let title = NSTextField(labelWithString: "Worlds & Characters")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        sidebar.addArrangedSubview(title)

        table.headerView = nil
        table.rowHeight = 30
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
        [addWorld, addCharacter, addPuppet, remove].forEach { $0.controlSize = .small }
        let addButtons = NSStackView(views: [addWorld, addCharacter, addPuppet])
        addButtons.orientation = .horizontal
        addButtons.spacing = 6
        let removeRow = NSStackView(views: [NSView(), remove])
        removeRow.orientation = .horizontal
        removeRow.spacing = 6
        let buttons = NSStackView(views: [addButtons, removeRow])
        buttons.orientation = .vertical
        buttons.alignment = .width
        buttons.spacing = 6
        sidebar.addArrangedSubview(buttons)
        sidebar.widthAnchor.constraint(equalToConstant: 280).isActive = true

        detailStack.orientation = .vertical
        detailStack.alignment = .width
        detailStack.spacing = 16
        detailStack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 28, right: 28)
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

        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        detailScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let split = NSStackView(views: [sidebar, divider, detailScroll])
        split.orientation = .horizontal
        split.alignment = .height
        split.spacing = 0

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
        let contentView = NSView()
        window.contentView = contentView
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
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
        window?.title = "Worlds & Characters\(dirty)"
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
        addHeading("Character", subtitle: "")
        let name = textField(character.name, identifier: "characterName")
        let connect = multilineTextField(character.connectText, identifier: "characterConnectText")
        let info = multilineInfoField(character.info)
        let password = NSSecureTextField(string: character.password)
        password.setAccessibilityIdentifier("characterPassword")
        password.placeholderString = "Replaces %PASSWORD% in the connect string"
        let passwordRow = passwordControl(password)
        let idleMinutes = textField(character.idleTimeout.map { String(Int($0 / 60)) } ?? "", identifier: "characterIdleMinutes")
        idleMinutes.alignment = .right
        idleMinutes.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let idleText = textField(character.idleText, identifier: "characterIdleText")
        idleText.placeholderString = "Command to send while idle"
        let logFilename = textField(character.logFilename, identifier: "characterLogFilename")
        logFilename.placeholderString = "Automatic log file"
        nameField = name; passwordField = password; passwordContainer = passwordRow
        idleMinutesField = idleMinutes; idleTextField = idleText
        characterLogFilenameField = logFilename
        let characterForm = NSStackView(views: [
            formRow("Name:", control: name),
            formRow("Password:", control: passwordRow),
            formRow("Connect String:", control: connect, alignsToTop: true),
            formRow("Info:", control: info, alignsToTop: true),
        ])
        characterForm.orientation = .vertical
        characterForm.alignment = .width
        characterForm.spacing = 10
        characterForm.setAccessibilityIdentifier("characterForm")
        detailStack.addArrangedSubview(characterForm)
        characterForm.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -56).isActive = true

        let autoConnect = check("autoConnect", "Connect automatically when BeipMU opens", character.autoConnect)
        let idleEnabled = character.idleTimeout != nil
        let idleCheck = check("idleEnabled", "When idle for", idleEnabled, action: #selector(toggleIdle(_:)))
        let minutesLabel = NSTextField(labelWithString: "minutes, send")
        let idleRow = NSStackView(views: [idleCheck, idleMinutes, minutesLabel, idleText])
        idleRow.orientation = .horizontal
        idleRow.alignment = .centerY
        idleRow.spacing = 8
        idleText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        idleText.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let chooseLog = NSButton(title: "Log File…", target: self, action: #selector(chooseCharacterLogFile(_:)))
        chooseLog.setAccessibilityIdentifier("chooseCharacterLogFile")
        let logRow = NSStackView(views: [chooseLog, logFilename])
        logRow.orientation = .horizontal
        logRow.spacing = 8
        logFilename.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let logDate = check(
            "characterLogDate",
            "Append current date to log file name",
            character.logAppendsDate
        )
        let behavior = NSStackView(views: [idleRow, autoConnect, logRow, logDate])
        behavior.orientation = .vertical
        behavior.alignment = .width
        behavior.spacing = 10
        behavior.setAccessibilityIdentifier("characterBehavior")
        detailStack.addArrangedSubview(behavior)
        behavior.widthAnchor.constraint(equalTo: detailStack.widthAnchor, constant: -56).isActive = true
        updateIdleControls(enabled: idleEnabled)
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
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        let detail = NSTextField(labelWithString: subtitle)
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 13)
        detailStack.addArrangedSubview(heading)
        if !subtitle.isEmpty { detailStack.addArrangedSubview(detail) }
    }

    private func textField(_ value: String, identifier: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.setAccessibilityIdentifier(identifier)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        return field
    }

    private func multilineTextField(_ value: String, identifier: String) -> NSScrollView {
        let text = NSTextView()
        text.string = value
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textContainerInset = NSSize(width: 5, height: 6)
        text.setAccessibilityIdentifier(identifier)
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 86).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        connectField = text
        return scroll
    }

    private func multilineInfoField(_ value: String) -> NSScrollView {
        let retainedConnectField = connectField
        let scroll = multilineTextField(value, identifier: "characterInfo")
        characterInfoField = connectField
        connectField = retainedConnectField
        return scroll
    }

    private func passwordControl(_ secureField: NSSecureTextField) -> NSView {
        let show = NSButton(title: "Show", target: self, action: #selector(togglePassword(_:)))
        show.setButtonType(.pushOnPushOff)
        show.setAccessibilityIdentifier("showCharacterPassword")
        let stack = NSStackView(views: [secureField, show])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        secureField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func section(title: String, subtitle: String, content: NSView) -> NSBox {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: subtitle)
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [heading, detail, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.setContentHuggingPriority(.required, for: .vertical)
        detail.maximumNumberOfLines = 0
        detail.lineBreakMode = .byWordWrapping
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.cornerRadius = 8
        box.fillColor = .controlBackgroundColor
        box.setAccessibilityIdentifier(title == "Account" ? "characterAccountSection" : "characterBehaviorSection")
        box.contentViewMargins = NSSize(width: 14, height: 14)
        box.contentView = stack
        box.setContentHuggingPriority(.required, for: .vertical)
        box.setContentCompressionResistancePriority(.required, for: .vertical)
        box.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 28).isActive = true
        return box
    }

    private func formRow(_ title: String, control: NSView, alignsToTop: Bool = false) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 100).isActive = true
        label.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = alignsToTop ? .top : .centerY
        row.spacing = 10
        return row
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
        detailStack.addArrangedSubview(check(key, title, enabled))
    }

    private func check(
        _ key: String,
        _ title: String,
        _ enabled: Bool,
        action: Selector? = nil
    ) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: action == nil ? nil : self, action: action)
        button.state = enabled ? .on : .off
        button.setAccessibilityIdentifier(key)
        checks[key] = button
        return button
    }

    private func addApplyButton() {
        let button = NSButton(title: "Apply Changes", target: self, action: #selector(applyChanges(_:)))
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("applyProfileChanges")
        let row = NSStackView(views: [button, NSView()])
        row.orientation = .horizontal
        detailStack.addArrangedSubview(row)
    }

    private func clearControls() {
        nameField = nil; hostField = nil; portField = nil; encodingPopup = nil; webViewPolicyPopup = nil
        aiEndpointField = nil; aiModelField = nil
        connectField = nil; characterInfoField = nil; passwordField = nil; passwordContainer = nil
        idleMinutesField = nil; idleTextField = nil
        characterLogFilenameField = nil
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
        let replacement: NSTextField
        if sender.state == .on {
            replacement = NSTextField(string: current.stringValue)
        } else {
            replacement = NSSecureTextField(string: current.stringValue)
        }
        replacement.placeholderString = "Used for %PASSWORD% in the connect text"
        replacement.setAccessibilityIdentifier("characterPassword")
        replacement.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let index = container.arrangedSubviews.firstIndex(of: current) ?? 0
        container.removeArrangedSubview(current)
        current.removeFromSuperview()
        container.insertArrangedSubview(replacement, at: index)
        passwordField = replacement
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
