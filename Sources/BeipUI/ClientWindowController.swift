import AppKit
import BeipAutomation
import BeipCore
import BeipProtocols
import BeipScriptRuntime

@MainActor
final class ClientWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let output = OutputTextView()
    private let input = NSTextField()
    private let stateLabel = NSTextField(labelWithString: "Disconnected")
    private let activityLabel = NSTextField(labelWithString: "")
    private let tabButton = NSButton(title: "New Tab", target: nil, action: nil)
    private let commandRegistry = CommandRegistry()
    private let delayScheduler = DelayScheduler()
    private let scriptService = ScriptServiceClient()
    private var variables: [String: String] = [:]
    private var session: SessionActor?
    private var sessionTask: Task<Void, Never>?
    private var currentServer: ServerProfile?
    private var localEcho = true
    private var terminalType = "Beip"
    private var gmcpDumpEnabled = false
    private var hasPendingPrompt = false
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BeipMU"
        window.minSize = NSSize(width: 520, height: 360)
        super.init(window: window)
        window.delegate = self
        configureUI(in: window)
        appendClient("Welcome to BeipMU for Mac. Choose Connection → Connect… to begin.")
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        sessionTask?.cancel()
        if let session { Task { await session.disconnect() } }
        onClose?()
    }

    func windowDidResize(_ notification: Notification) {
        guard let session else { return }
        let size = output.terminalSize
        Task { await session.updateWindowSize(columns: size.columns, rows: size.rows) }
    }

    func showConnectDialog() {
        let alert = NSAlert()
        alert.messageText = "Connect to a MU*"
        alert.informativeText = "Enter a host and port. Certificate verification defaults to the Windows-compatible off setting."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let host = NSTextField(string: currentServer?.host ?? "lambda.moo.mud.org")
        let port = NSTextField(string: currentServer.map { String($0.port) } ?? "8888")
        let tls = NSButton(checkboxWithTitle: "Use TLS", target: nil, action: nil)
        tls.state = currentServer?.usesTLS == true ? .on : .off
        let verify = NSButton(checkboxWithTitle: "Verify TLS certificate", target: nil, action: nil)
        verify.state = currentServer?.verifiesCertificate == true ? .on : .off
        let resizeNAWS = NSButton(checkboxWithTitle: "Send window size updates", target: nil, action: nil)
        resizeNAWS.state = currentServer?.sendNAWSOnResize == true ? .on : .off

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Host:"), host],
            [NSTextField(labelWithString: "Port:"), port],
            [NSView(), tls],
            [NSView(), verify],
            [NSView(), resizeNAWS],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 260
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 350, height: 138)
        alert.accessoryView = grid

        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let self,
                  let rawPort = UInt16(port.stringValue),
                  !host.stringValue.isEmpty else { return }
            let profile = ServerProfile(
                name: host.stringValue,
                host: host.stringValue,
                port: rawPort,
                usesTLS: tls.state == .on,
                verifiesCertificate: verify.state == .on,
                sendNAWSOnResize: resizeNAWS.state == .on
            )
            self.startSession(profile)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: complete) }
        else { complete(alert.runModal()) }
    }

    func disconnect() {
        guard let session else { return }
        Task { await session.disconnect() }
    }

    func clearOutput() { output.clear() }

    private func configureUI(in window: NSWindow) {
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        let taskbar = NSStackView()
        taskbar.orientation = .horizontal
        taskbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        taskbar.spacing = 8
        taskbar.wantsLayer = true
        taskbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        stateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        activityLabel.textColor = .secondaryLabelColor
        tabButton.bezelStyle = .recessed
        tabButton.isEnabled = false
        taskbar.addArrangedSubview(stateLabel)
        taskbar.addArrangedSubview(NSView())
        taskbar.addArrangedSubview(activityLabel)
        taskbar.addArrangedSubview(tabButton)

        input.placeholderString = "Enter text or /help"
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        input.delegate = self
        input.target = self
        input.action = #selector(sendInput(_:))
        input.translatesAutoresizingMaskIntoConstraints = false

        let inputContainer = NSView()
        inputContainer.addSubview(input)
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 8),
            input.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -8),
            input.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 8),
            input.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor, constant: -8),
            inputContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
        ])

        root.addArrangedSubview(taskbar)
        root.addArrangedSubview(output.scrollView)
        root.addArrangedSubview(inputContainer)
        window.contentView = NSView()
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            taskbar.heightAnchor.constraint(equalToConstant: 34),
            output.scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        window.center()
        window.makeFirstResponder(input)
    }

    private func startSession(_ server: ServerProfile) {
        sessionTask?.cancel()
        if let session { Task { await session.disconnect() } }
        currentServer = server
        var processor = MUDProtocolPipeline(
            encoding: server.encoding,
            pueblo: server.pueblo,
            limitTelnetCharset: server.limitTelnetCharset
        )
        processor.setTerminalType(terminalType)
        let next = SessionActor(transport: NetworkTransport(), processor: processor, localEcho: localEcho)
        session = next
        output.clear()
        appendClient("Connecting to \(server.host):\(server.port)…")
        sessionTask = Task { [weak self] in
            let events = await next.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.handle(event)
            }
        }
        let size = output.terminalSize
        Task {
            await next.updateWindowSize(columns: size.columns, rows: size.rows)
            await next.connect(.init(server: server))
        }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case let .state(state):
            switch state {
            case .disconnected: stateLabel.stringValue = "Disconnected"; stateLabel.textColor = .secondaryLabelColor
            case .resolving: stateLabel.stringValue = "Resolving…"; stateLabel.textColor = .systemOrange
            case .connecting: stateLabel.stringValue = "Connecting…"; stateLabel.textColor = .systemOrange
            case .connected: stateLabel.stringValue = "Connected"; stateLabel.textColor = .systemGreen
            case .disconnecting: stateLabel.stringValue = "Disconnecting…"; stateLabel.textColor = .systemOrange
            case let .failed(message): stateLabel.stringValue = "Failed"; stateLabel.textColor = .systemRed; appendError(message)
            }
        case let .renderedLine(line):
            if hasPendingPrompt { output.removeLastLine(); hasPendingPrompt = false }
            output.append(line)
        case let .prompt(line):
            if hasPendingPrompt { output.removeLastLine() }
            output.append(line, terminator: "")
            hasPendingPrompt = true
        case let .gmcp(message): activityLabel.stringValue = "GMCP: \(message.package)"
        case let .mcp(message): activityLabel.stringValue = "MCP: \(message)"
        case let .encoding(encoding): appendClient("Charset negotiated: \(encoding.rawValue)")
        case let .error(message): appendError(message)
        case let .log(message): appendClient(message)
        case .activity, .received, .sent: break
        }
    }

    @objc private func sendInput(_ sender: NSTextField) {
        let text = sender.stringValue
        guard !text.isEmpty else { return }
        sender.stringValue = ""
        processInput(text)
    }

    private func processInput(_ text: String) {
        switch commandRegistry.parse(text, variables: variables) {
        case .notACommand:
            guard let session else { appendError("Not connected."); return }
            Task { await session.send(text) }
        case let .send(value):
            guard let session else { appendError("Not connected."); return }
            Task { await session.send(value) }
        case let .display(value): appendClient(value)
        case .clear: output.clear()
        case let .localEcho(enabled):
            localEcho = enabled
            if let session { Task { await session.configureLocalEcho(enabled) } }
            appendClient("Local echo \(enabled ? "on" : "off").")
        case .resetANSI:
            guard let session else { appendError("Not connected."); return }
            Task { await session.resetFormatting() }
            appendClient("ANSI state reset.")
        case .nawsAuto:
            guard let session else { appendError("Not connected."); return }
            let size = output.terminalSize
            Task { await session.sendWindowSize(columns: size.columns, rows: size.rows) }
            appendClient("NAWS sent: \(size.columns) × \(size.rows).")
        case let .naws(columns, rows):
            guard let session else { appendError("Not connected."); return }
            Task { await session.sendWindowSize(columns: columns, rows: rows) }
            appendClient("NAWS sent: \(columns) × \(rows).")
        case let .terminalType(value):
            appendClient("Current TType = \(terminalType)")
            guard let value else { return }
            terminalType = value
            if let session { Task { await session.setTerminalType(value) } }
            appendClient("New TType = \(value)")
        case let .setVariable(name, value): variables[name] = value; appendClient("Set %\(name)%")
        case let .unsetVariable(name): variables.removeValue(forKey: name); appendClient("Unset %\(name)%")
        case let .gmcp(message):
            guard let session else { appendError("Not connected."); return }
            Task { await session.sendRaw(Self.gmcpFrame(message)) }
        case let .gmcpDump(enabled):
            gmcpDumpEnabled = enabled
            appendClient("GMCP dump \(enabled ? "enabled" : "disabled").")
        case let .disconnect(all):
            let controllers = all ? Self.openControllers : [self]
            for controller in controllers { controller.disconnect() }
        case let .reconnect(all):
            let controllers = all ? Self.openControllers : [self]
            for controller in controllers {
                guard let session = controller.session else { controller.appendError("No previous connection to reconnect."); continue }
                Task { await session.reconnect() }
            }
        case let .connect(address, character):
            guard character == nil else {
                appendError("Named character lookup requires a loaded Config.txt profile.")
                return
            }
            guard let endpoint = Self.endpoint(address) else {
                appendError("Missing port; address must be host:port.")
                return
            }
            startSession(.init(name: address, host: endpoint.host, port: endpoint.port))
        case let .repeatCommand(count, command):
            for _ in 0..<count { processInput(command) }
        case let .delay(action):
            switch action {
            case .list:
                Task {
                    let entries = await delayScheduler.entries()
                    if entries.isEmpty { appendClient("No pending delay actions.") }
                    for entry in entries {
                        appendClient("Delay ID \(entry.id): \(entry.command) in \(entry.seconds)s\(entry.repeating ? " (repeating)" : "")")
                    }
                }
            case .killAll:
                Task { await delayScheduler.killAll(); appendClient("All pending timers erased.") }
            case let .kill(id):
                Task {
                    let killed = await delayScheduler.kill(id)
                    appendClient(killed ? "Timer killed." : "Timer ID not found.")
                }
            case let .schedule(id, repeating, seconds, command):
                Task {
                    let assigned = await delayScheduler.schedule(
                        id: id,
                        repeating: repeating,
                        seconds: seconds,
                        command: command
                    ) { [weak self] command in
                        await MainActor.run { self?.processInput(command) }
                    }
                    appendClient("Starting timer with ID: \(assigned) in \(seconds)s")
                }
            }
        case let .receive(value):
            guard let session else { appendError("Not connected."); return }
            Task { await session.receive(value) }
        case let .receiveGMCP(message):
            guard let session else { appendError("Not connected."); return }
            Task { await session.receiveGMCP(message) }
        case let .ping(value):
            guard let session else { appendError("Not connected."); return }
            Task { await session.ping(value) }
        case let .setInput(value):
            guard input.stringValue.isEmpty else { return }
            input.stringValue = value
            input.currentEditor()?.selectedRange = NSRange(location: 0, length: value.utf16.count)
        case let .idle(minutes, command):
            guard let session else { appendError("Must be connected to work."); return }
            if let minutes, let command {
                Task { await session.configureIdle(interval: TimeInterval(minutes) * 60, text: command) }
                appendClient("Idle timer activated: \(minutes) minute(s), sends \(command)")
            } else {
                Task { await session.configureIdle(interval: nil, text: nil) }
                appendClient("Idle timer removed.")
            }
        case .statistics:
            guard let session else { appendError("Not connected."); return }
            Task {
                let stats = await session.statistics()
                appendClient("Connections: \(stats.connectionCount)  Sent: \(stats.bytesSent) bytes  Received: \(stats.bytesReceived) bytes  Online: \(Int(stats.secondsConnected))s")
            }
        case .connectionInfo:
            guard let server = currentServer else { appendError("No connection information available."); return }
            appendClient("\(server.host):\(server.port) — \(server.usesTLS ? (server.verifiesCertificate ? "TLS, verified" : "TLS, unverified") : "plain TCP")")
        case .close: window?.performClose(nil)
        case .exit: NSApplication.shared.terminate(nil)
        case .newWindow, .newTab:
            NSApplication.shared.sendAction(#selector(ApplicationDelegate.newWindow(_:)), to: nil, from: nil)
        case .silence:
            appendClient("Stopped local sound playback.")
        case .removeLast: output.removeLastLine()
        case let .wall(value):
            for controller in Self.openControllers {
                guard let session = controller.session else { continue }
                Task { await session.send(value) }
            }
        case let .openDialog(dialog, _):
            switch dialog {
            case "worlds": showConnectDialog()
            case "about": NSApplication.shared.orderFrontStandardAboutPanel(nil)
            default: appendClient("The \(dialog) editor belongs to a later workspace milestone.")
            }
        case .listServers:
            if let server = currentServer { appendClient("\(server.name) — \(server.host):\(server.port)") }
            else { appendClient("No server profiles loaded.") }
        case .listCharacters: appendClient("No character profiles loaded in this window.")
        case .listPuppets: appendClient("No puppet profiles loaded in this window.")
        case let .connectPuppet(name): appendError("Puppet profile not found: \(name)")
        case .stopLogs: appendClient("No active logs.")
        case let .startLog(filename, _): appendClient("Logging command accepted for \(filename); logging is completed in Milestone 4.")
        case let .script(source):
            Task {
                let result = await scriptService.evaluate(source)
                if let error = result.error { appendError(error) }
                else if let value = result.value { appendClient(value) }
            }
        case let .scriptHelp(type):
            Task {
                if let type { appendClient("Scripting help requested for \(type). See Documentation/ScriptingAPI.md in the Windows reference.") }
                else { appendClient("Scripting types: " + (await ScriptRuntime().helpTypes()).joined(separator: ", ")) }
            }
        case let .openCommandHelp(topic):
            var components = URLComponents(string: "https://github.com/BeipDev/BeipMU/blob/master/Documentation/CommandLine.md")
            components?.fragment = topic
            if let url = components?.url { NSWorkspace.shared.open(url) }
        case .resetScript:
            Task { await scriptService.reset(); appendClient("Scripting runtime reset.") }
        case let .invoke(name, _, _):
            appendClient("/\(name) is registered; its target surface is completed in a later milestone.")
        case let .unimplemented(command): appendError("/\(command) is recognized but not implemented in this milestone.")
        }
    }

    private static var openControllers: [ClientWindowController] {
        NSApplication.shared.windows.compactMap { $0.windowController as? ClientWindowController }
    }

    private static func endpoint(_ address: String) -> (host: String, port: UInt16)? {
        if address.hasPrefix("["), let close = address.firstIndex(of: "]") {
            let host = String(address[address.index(after: address.startIndex)..<close])
            let suffix = address[address.index(after: close)...]
            guard suffix.first == ":", let port = UInt16(suffix.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = address.lastIndex(of: ":"),
              let port = UInt16(address[address.index(after: colon)...]) else { return nil }
        return (String(address[..<colon]), port)
    }

    private static func gmcpFrame(_ message: GMCPMessage) -> Data {
        let separator = message.payload.isEmpty ? "" : " "
        return Data([255, 250, 201]) + Data("\(message.package)\(separator)\(message.payload)".utf8) + Data([255, 240])
    }

    private func appendClient(_ text: String) { output.append(.init(text: text, source: .client)) }
    private func appendError(_ text: String) {
        let style = TextStyle(foreground: .init(red: 255, green: 80, blue: 80))
        output.append(.init(text: text, runs: [.init(range: 0..<text.utf16.count, style: style)], source: .client))
    }
}
