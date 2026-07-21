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
    private let scriptService = ScriptServiceClient()
    private var variables: [String: String] = [:]
    private var session: SessionActor?
    private var sessionTask: Task<Void, Never>?
    private var currentServer: ServerProfile?
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
        let next = SessionActor(transport: NetworkTransport(), processor: MUDProtocolPipeline(encoding: server.encoding))
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
        case let .renderedLine(line): output.append(line)
        case let .prompt(line): output.append(line, terminator: "")
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
        switch commandRegistry.parse(text, variables: variables) {
        case .notACommand:
            guard let session else { appendError("Not connected."); return }
            appendLocalEcho(text)
            Task { await session.send(text) }
        case let .send(value):
            guard let session else { appendError("Not connected."); return }
            Task { await session.send(value) }
        case let .display(value): appendClient(value)
        case .clear: output.clear()
        case let .setVariable(name, value): variables[name] = value; appendClient("Set %\(name)%")
        case let .unsetVariable(name): variables.removeValue(forKey: name); appendClient("Unset %\(name)%")
        case let .gmcp(message):
            guard let session else { appendError("Not connected."); return }
            Task { await session.sendRaw(Self.gmcpFrame(message)) }
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
        case .resetScript:
            Task { await scriptService.reset(); appendClient("Scripting runtime reset.") }
        case let .unimplemented(command): appendError("/\(command) is recognized but not implemented in this milestone.")
        }
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
    private func appendLocalEcho(_ text: String) {
        let style = TextStyle(foreground: .init(red: 0, green: 205, blue: 205))
        output.append(.init(text: text, runs: [.init(range: 0..<text.utf16.count, style: style)], source: .localEcho))
    }
}
