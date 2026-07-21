import AppKit
import BeipAutomation
import BeipCore
import BeipPersistence
import BeipProtocols
import BeipScriptRuntime
import Darwin

@MainActor
final class ClientWindowController: NSWindowController, NSWindowDelegate {
    private let profileLibrary: ProfileLibrary
    private let output = OutputTextView()
    private let input = CommandInputView()
    private let stateLabel = NSTextField(labelWithString: "Disconnected")
    private let activityLabel = NSTextField(labelWithString: "")
    private let tabButton = NSButton(title: "New Tab", target: nil, action: nil)
    private let commandRegistry = CommandRegistry()
    private let delayScheduler = DelayScheduler()
    private let scriptService = ScriptServiceClient()
    private var dockController: WorkspaceDockController!
    private var variables: [String: String] = [:]
    private var session: SessionActor?
    private var sessionTask: Task<Void, Never>?
    private var currentServer: ServerProfile?
    private var currentCharacter: CharacterProfile?
    private var secondaryInputWindows: [SecondaryInputWindowController] = []
    private var editWindows: [EditWindowController] = []
    private var statisticsWindow: SessionStatisticsWindowController?
    private var statisticsTask: Task<Void, Never>?
    private var logWriters: [URL: SessionLogWriter] = [:]
    private var localEcho = true
    private var terminalType = "Beip"
    private var gmcpDumpEnabled = false
    private var hasPendingPrompt = false
    private var unreadCount = 0
    private var lastFindQuery = ""
    private var preferences = WorkspacePreferencesStore.load()
    private var baseWindowTitle = "Untitled"
    private var isMuted = false
    private var connectionStateText = "Disconnected"
    private weak var taskbarView: NSStackView?
    var onClose: (() -> Void)?
    var onThemeChange: ((WorkspaceThemeSettings) -> Void)?
    var timestampsEnabled: Bool { preferences.showsTimestamps }
    var fanFoldEnabled: Bool { preferences.usesFanFoldBackgrounds }
    var stickyInputEnabled: Bool { preferences.stickyInput }
    var spellCheckingEnabled: Bool { preferences.checksSpelling }
    var outputSplitEnabled: Bool { output.isSplit }
    var muted: Bool { isMuted }
    var dockPlacement: WorkspaceDockPlacement { dockController?.placement ?? preferences.dockPlacement }
    var legacyDockPlacement: WorkspaceDockPlacement? { dockController?.legacyPlacement }
    var activeLogCount: Int { logWriters.count }

    func usesWorkspaceLayout(_ layout: WorkspaceLayoutNode) -> Bool {
        dockController?.currentLayout.hasSameTopology(as: layout) == true
    }

    init(profileLibrary: ProfileLibrary) {
        self.profileLibrary = profileLibrary
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BeipMU"
        window.setAccessibilityIdentifier("mainWindow")
        window.minSize = NSSize(width: 520, height: 360)
        super.init(window: window)
        window.delegate = self
        configureUI(in: window)
        if ProcessInfo.processInfo.environment["BEIPMU_UI_TESTING"] == "1" {
            window.center()
        } else {
            if !window.setFrameUsingName("BeipMUClientWindow") { window.center() }
            window.setFrameAutosaveName("BeipMUClientWindow")
        }
        appendClient("Welcome to BeipMU for Mac. Choose Connection → Connect… to begin.")
        loadWindowsGoldenSessionFixtureIfRequested()
        updateWindowTitle()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        dockController?.prepareForOwnerClose()
        secondaryInputWindows.forEach { $0.close() }
        editWindows.forEach { $0.close() }
        statisticsTask?.cancel()
        statisticsWindow?.close()
        stopAllLogs(announcing: false)
        sessionTask?.cancel()
        if let session { Task { await session.disconnect() } }
        onClose?()
    }

    func windowDidResize(_ notification: Notification) {
        guard let session else { return }
        let size = output.terminalSize
        Task { await session.updateWindowSize(columns: size.columns, rows: size.rows) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        unreadCount = 0
        activityLabel.stringValue = ""
        updateWindowTitle()
        Self.updateDockBadge()
    }

    func showConnectDialog() {
        let alert = NSAlert()
        alert.messageText = "Connect to a MU*"
        alert.informativeText = "Choose a saved profile or enter a host and port."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Manage Profiles…")
        alert.addButton(withTitle: "Cancel")

        let choices = profileLibrary.workspace.servers.flatMap { server in
            [(server.profile, Optional<CharacterProfile>.none)]
                + server.characters.map { (server.profile, Optional($0)) }
        }
        let profile = NSPopUpButton()
        profile.addItem(withTitle: "Manual Address")
        profile.addItems(withTitles: choices.map { server, character in
            character.map { "\(server.name) — \($0.name)" } ?? server.name
        })
        profile.setAccessibilityIdentifier("connectionProfile")

        let host = NSTextField(string: currentServer?.host ?? "lambda.moo.mud.org")
        let port = NSTextField(string: currentServer.map { String($0.port) } ?? "8888")
        let tls = NSButton(checkboxWithTitle: "Use TLS", target: nil, action: nil)
        tls.state = currentServer?.usesTLS == true ? .on : .off
        let verify = NSButton(checkboxWithTitle: "Verify TLS certificate", target: nil, action: nil)
        verify.state = currentServer?.verifiesCertificate == true ? .on : .off
        let resizeNAWS = NSButton(checkboxWithTitle: "Send window size updates", target: nil, action: nil)
        resizeNAWS.state = currentServer?.sendNAWSOnResize == true ? .on : .off

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Profile:"), profile],
            [NSTextField(labelWithString: "Host:"), host],
            [NSTextField(labelWithString: "Port:"), port],
            [NSView(), tls],
            [NSView(), verify],
            [NSView(), resizeNAWS],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 260
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 350, height: 170)
        alert.accessoryView = grid

        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                NSApplication.shared.sendAction(#selector(ApplicationDelegate.manageProfiles(_:)), to: nil, from: nil)
                return
            }
            guard response == .alertFirstButtonReturn else { return }
            if profile.indexOfSelectedItem > 0 {
                let choice = choices[profile.indexOfSelectedItem - 1]
                self.startSession(
                    choice.0,
                    character: choice.1,
                    policy: self.profileLibrary.workspace.projection.connectionPolicy
                )
                return
            }
            guard let rawPort = UInt16(port.stringValue), !host.stringValue.isEmpty else { return }
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

    func toggleOutputPause() { output.togglePaused() }
    func toggleTimestamps() {
        preferences.showsTimestamps.toggle()
        output.showsTimestamps = preferences.showsTimestamps
        savePreferences()
    }
    func toggleFanFold() {
        preferences.usesFanFoldBackgrounds.toggle()
        output.usesFanFoldBackgrounds = preferences.usesFanFoldBackgrounds
        savePreferences()
    }
    func copyOutputAsPlainText() { output.copySelectionAsPlainText() }
    func copyOutputAsHTML() { output.copySelectionAsHTML() }
    func toggleOutputMarker() { output.toggleMarkerForSelectedLine() }
    func toggleOutputSplit() {
        output.toggleSplit()
        preferences.outputSplit = output.isSplit
        savePreferences()
    }
    func toggleStickyInput() {
        preferences.stickyInput.toggle()
        input.behavior.isSticky = preferences.stickyInput
        savePreferences()
    }
    func toggleSpellChecking() {
        preferences.checksSpelling.toggle()
        input.isContinuousSpellCheckingEnabled = preferences.checksSpelling
        savePreferences()
    }

    func toggleMute() {
        isMuted.toggle()
        updateWindowTitle()
        appendClient(isMuted ? "This tab is muted." : "This tab is unmuted.")
    }

    func setDockPlacement(_ placement: WorkspaceDockPlacement) {
        dockController.setPlacement(placement)
    }

    func setWorkspaceLayout(_ layout: WorkspaceLayoutNode) {
        dockController.setLayout(layout)
    }

    func prepareForApplicationTermination() {
        dockController?.prepareForOwnerClose()
        stopAllLogs(announcing: false)
    }

    func startPerformanceSoakIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BEIPMU_PERFORMANCE_SOAK"] == "1" else { return }
        let requestedLines = Int(environment["BEIPMU_PERFORMANCE_SOAK_LINES"] ?? "") ?? 100_000
        let requestedHold = Double(environment["BEIPMU_PERFORMANCE_SOAK_HOLD_SECONDS"] ?? "") ?? 15
        let requestedDelay = Double(environment["BEIPMU_PERFORMANCE_SOAK_START_DELAY_SECONDS"] ?? "") ?? 0
        let requestedLimit = Int(environment["BEIPMU_PERFORMANCE_SOAK_HISTORY_LIMIT"] ?? "") ?? 10_000
        let lineCount = max(10_000, requestedLines)
        let holdSeconds = max(1, requestedHold)
        let startDelaySeconds = max(0, requestedDelay)
        let historyLimit = max(1_000, requestedLimit)

        preferences.outputHistoryLimit = historyLimit
        preferences.workspaceLayout = .splitSidebars
        output.historyLimit = historyLimit
        if !output.isSplit { output.toggleSplit() }
        dockController.setLayout(.splitSidebars)

        Task { [weak self] in
            guard let self else { return }
            if startDelaySeconds > 0 {
                try? await Task.sleep(for: .seconds(startDelaySeconds))
            }
            let started = Date()
            var appended = 0
            let batchSize = 250
            while appended < lineCount, !Task.isCancelled {
                let end = min(lineCount, appended + batchSize)
                for index in appended..<end {
                    output.append(Self.performanceSoakLine(index))
                }
                appended = end
                if appended == lineCount / 2 { dockController.setLayout(.stackedRight) }
                await Task.yield()
            }

            let holdTicks = max(1, Int((holdSeconds * 4).rounded(.up)))
            for tick in 0..<holdTicks where !Task.isCancelled {
                if tick == holdTicks / 2 { dockController.setLayout(.stackedBottom) }
                output.append(Self.performanceSoakLine(lineCount + tick))
                appended += 1
                try? await Task.sleep(for: .milliseconds(250))
            }

            dockController.setLayout(.splitSidebars)
            refreshDiagnostics()
            window?.displayIfNeeded()
            let report = [
                "lines=\(appended)",
                "retained=\(output.visibleLineCount)",
                "rendered=\(output.renderedLineCount)",
                "paintCandidates=\(output.visiblePaintCandidateCount)",
                "rssBytes=\(Self.currentResidentSize())",
                "elapsedSeconds=\(String(format: "%.3f", Date().timeIntervalSince(started)))",
            ].joined(separator: " ")
            FileHandle.standardOutput.write(Data("BEIPMU_SOAK_COMPLETE \(report)\n".utf8))
            NSApplication.shared.terminate(nil)
        }
    }

    func showCharacterNotes() {
        if dockController.placement == .hidden {
            dockController.setPlacement(preferences.lastDockedPlacement)
        }
        dockController.selectNotes()
    }

    func showSessionDiagnostics() {
        refreshDiagnostics()
        if dockController.placement == .hidden {
            dockController.setPlacement(preferences.lastDockedPlacement)
        }
        dockController.selectDiagnostics()
    }

    func showConnectionStatistics() {
        if let statisticsWindow {
            statisticsWindow.showWindow(nil)
            statisticsWindow.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = SessionStatisticsWindowController()
        controller.onClose = { [weak self] in
            self?.statisticsTask?.cancel()
            self?.statisticsTask = nil
            self?.statisticsWindow = nil
        }
        statisticsWindow = controller
        controller.showWindow(nil)
        if let owner = window, let panel = controller.window {
            owner.addChildWindow(panel, ordered: .above)
            panel.center()
        }

        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshConnectionStatistics()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func showWorkspaceSettings() {
        let alert = NSAlert()
        alert.messageText = "Workspace Settings"
        alert.informativeText = "These Mac-native text workspace settings are saved automatically."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        let historyLimit = NSTextField(string: String(preferences.outputHistoryLimit))
        historyLimit.alignment = .right
        let timestamps = NSButton(checkboxWithTitle: "Show timestamps", target: nil, action: nil)
        timestamps.state = preferences.showsTimestamps ? .on : .off
        let fanFold = NSButton(checkboxWithTitle: "Fan-fold backgrounds", target: nil, action: nil)
        fanFold.state = preferences.usesFanFoldBackgrounds ? .on : .off
        let sticky = NSButton(checkboxWithTitle: "Sticky input", target: nil, action: nil)
        sticky.state = preferences.stickyInput ? .on : .off
        let spelling = NSButton(checkboxWithTitle: "Check spelling", target: nil, action: nil)
        spelling.state = preferences.checksSpelling ? .on : .off
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "History lines:"), historyLimit],
            [NSView(), timestamps],
            [NSView(), fanFold],
            [NSView(), sticky],
            [NSView(), spelling],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 230
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 330, height: 130)
        alert.accessoryView = grid
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.preferences.outputHistoryLimit = max(100, historyLimit.integerValue)
            self.preferences.showsTimestamps = timestamps.state == .on
            self.preferences.usesFanFoldBackgrounds = fanFold.state == .on
            self.preferences.stickyInput = sticky.state == .on
            self.preferences.checksSpelling = spelling.state == .on
            self.applyPreferences()
            self.savePreferences()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    func showThemeSettings() {
        let alert = NSAlert()
        alert.messageText = "Workspace Theme"
        alert.informativeText = "Choose a native appearance or customize the text workspace palette."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        let mode = NSPopUpButton()
        mode.addItems(withTitles: WorkspaceThemeMode.allCases.map(\.title))
        mode.selectItem(at: WorkspaceThemeMode.allCases.firstIndex(of: preferences.theme.mode) ?? 0)
        mode.setAccessibilityIdentifier("themeMode")
        let foreground = NSColorWell()
        foreground.color = NSColor(hexString: preferences.theme.foregroundHex) ?? .textColor
        foreground.setAccessibilityIdentifier("themeForeground")
        let background = NSColorWell()
        background.color = NSColor(hexString: preferences.theme.backgroundHex) ?? .textBackgroundColor
        background.setAccessibilityIdentifier("themeBackground")
        let accent = NSColorWell()
        accent.color = NSColor(hexString: preferences.theme.accentHex) ?? .controlAccentColor
        accent.setAccessibilityIdentifier("themeAccent")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Appearance:"), mode],
            [NSTextField(labelWithString: "Text:"), foreground],
            [NSTextField(labelWithString: "Background:"), background],
            [NSTextField(labelWithString: "Accent:"), accent],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 230
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 340, height: 125)
        alert.accessoryView = grid
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let selectedMode = WorkspaceThemeMode.allCases[mode.indexOfSelectedItem]
            let settings = WorkspaceThemeSettings(
                mode: selectedMode,
                foregroundHex: foreground.color.hexString,
                backgroundHex: background.color.hexString,
                accentHex: accent.color.hexString
            )
            self.preferences.theme = settings
            self.applyThemeSettings(settings)
            self.savePreferences()
            self.onThemeChange?(settings)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    func showLoggingControls() {
        let alert = NSAlert()
        alert.messageText = "Session Logging"
        alert.informativeText = logWriters.isEmpty
            ? "Start a plain-text or HTML log for this session."
            : "\(logWriters.count) active log\(logWriters.count == 1 ? "" : "s"). Starting another log keeps existing logs running."
        alert.addButton(withTitle: "Start Log…")
        alert.addButton(withTitle: "Stop All")
        alert.addButton(withTitle: "Cancel")

        let history = NSPopUpButton()
        history.addItems(withTitles: ["From Now", "From Beginning", "From Visible Window"])
        history.setAccessibilityIdentifier("loggingHistory")
        let logTyped = NSButton(checkboxWithTitle: "Log typed input", target: nil, action: nil)
        logTyped.state = preferences.logging.logsTypedText ? .on : .off
        let typedPrefix = NSTextField(string: preferences.logging.typedPrefix)
        let logSent = NSButton(checkboxWithTitle: "Log sent text", target: nil, action: nil)
        logSent.state = preferences.logging.logsSentText ? .on : .off
        let sentPrefix = NSTextField(string: preferences.logging.sentPrefix)
        let time = NSButton(checkboxWithTitle: "Time", target: nil, action: nil)
        time.state = preferences.logging.includesTime ? .on : .off
        let date = NSButton(checkboxWithTitle: "Date", target: nil, action: nil)
        date.state = preferences.logging.includesDate ? .on : .off
        let hour24 = NSButton(checkboxWithTitle: "24-hour", target: nil, action: nil)
        hour24.state = preferences.logging.uses24HourTime ? .on : .off
        let timestampOptions = NSStackView(views: [time, date, hour24])
        timestampOptions.orientation = .horizontal
        timestampOptions.spacing = 8
        let wrap = NSButton(checkboxWithTitle: "Wrap", target: nil, action: nil)
        wrap.state = preferences.logging.wrapWidth == nil ? .off : .on
        let wrapWidth = NSTextField(string: String(preferences.logging.wrapWidth ?? 80))
        wrapWidth.alignment = .right
        let hangingIndent = NSTextField(string: String(preferences.logging.hangingIndent))
        hangingIndent.alignment = .right
        let nearestWord = NSButton(checkboxWithTitle: "Wrap at words", target: nil, action: nil)
        nearestWord.state = preferences.logging.wrapsAtWords ? .on : .off
        let doubleSpace = NSButton(checkboxWithTitle: "Double-space lines", target: nil, action: nil)
        doubleSpace.state = preferences.logging.doubleSpaces ? .on : .off
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "History:"), history],
            [logTyped, typedPrefix],
            [logSent, sentPrefix],
            [NSTextField(labelWithString: "Timestamps:"), timestampOptions],
            [wrap, wrapWidth],
            [NSTextField(labelWithString: "Hanging indent:"), hangingIndent],
            [NSView(), nearestWord],
            [NSView(), doubleSpace],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 240
        grid.rowSpacing = 7
        grid.frame = NSRect(x: 0, y: 0, width: 390, height: 240)
        alert.accessoryView = grid

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                self.stopAllLogs()
                return
            }
            guard response == .alertFirstButtonReturn else { return }
            self.preferences.logging = SessionLogOptions(
                logsSentText: logSent.state == .on,
                sentPrefix: sentPrefix.stringValue,
                logsTypedText: logTyped.state == .on,
                typedPrefix: typedPrefix.stringValue,
                includesTime: time.state == .on,
                includesDate: date.state == .on,
                uses24HourTime: hour24.state == .on,
                wrapWidth: wrap.state == .on ? max(2, wrapWidth.integerValue) : nil,
                hangingIndent: max(0, hangingIndent.integerValue),
                wrapsAtWords: nearestWord.state == .on,
                doubleSpaces: doubleSpace.state == .on
            )
            self.savePreferences()
            let panel = NSSavePanel()
            panel.title = "Start Session Log"
            panel.nameFieldStringValue = "\(Self.logDateFormatter.string(from: Date()))-\(self.baseWindowTitle.safeFilename).txt"
            let selectedHistory: CommandOutcome.LogHistory = switch history.indexOfSelectedItem {
            case 1: .all
            case 2: .window
            default: .none
            }
            let start: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard response == .OK, let self, let url = panel.url else { return }
                self.startLog(at: url, history: selectedHistory)
            }
            if let window = self.window { panel.beginSheetModal(for: window, completionHandler: start) }
            else { start(panel.runModal()) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    func applyThemeSettings(_ settings: WorkspaceThemeSettings) {
        preferences.theme = settings
        let palette = settings.palette
        window?.appearance = palette.appearance
        window?.backgroundColor = palette.chrome
        taskbarView?.layer?.backgroundColor = palette.chrome.cgColor
        output.applyTheme(palette)
        input.applyTheme(palette)
        dockController?.applyTheme(palette)
        secondaryInputWindows.forEach { $0.applyTheme(palette) }
        editWindows.forEach { $0.applyTheme(palette) }
    }

    func showInputPrefixDialog() {
        let alert = NSAlert()
        alert.messageText = "Input Prefix"
        alert.informativeText = "This text is prepended to every submitted command. Leave it empty to disable the prefix."
        alert.addButton(withTitle: "Set Prefix")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: input.behavior.prefix)
        field.placeholderString = "For example: say "
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.preferences.inputPrefix = field.stringValue
            self?.input.behavior.prefix = field.stringValue
            self?.savePreferences()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    func showNewInputWindow(prefix: String = "", unique: Bool = false) {
        if unique, let existing = secondaryInputWindows.first(where: { $0.prefix == prefix }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SecondaryInputWindowController(
            prefix: prefix,
            checksSpelling: preferences.checksSpelling
        ) { [weak self] value in
            self?.submitInput(value)
        }
        controller.input.completionCandidates = CommandRegistry.knownCommands.map { "/" + $0 }.sorted()
        controller.input.onSmartPaste = { [weak self] lines in self?.handleSmartPaste(lines) ?? false }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.secondaryInputWindows.removeAll { $0 === controller }
        }
        secondaryInputWindows.append(controller)
        controller.applyTheme(preferences.theme.palette)
        controller.showWindow(nil)
        if let owner = window, let child = controller.window {
            owner.addChildWindow(child, ordered: .above)
        }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func showNewEditWindow(options: EditWindowOptions = .init()) {
        let capturedLines = options.captureLineCount > 0
            ? output.capturedText(lineCount: options.captureLineCount, skipping: options.captureSkipCount)
            : ""
        let captured = capturedLines.isEmpty ? "" : options.prepend + capturedLines + options.append
        if !options.title.isEmpty, let existing = editWindows.first(where: { $0.logicalTitle == options.title }) {
            if !captured.isEmpty { existing.setText(captured) }
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = EditWindowController(
            title: options.title,
            text: captured,
            checksSpelling: options.checksSpelling
        ) { [weak self] value in
            self?.sendToSession(value)
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.editWindows.removeAll { $0 === controller }
        }
        editWindows.append(controller)
        controller.applyTheme(preferences.theme.palette)
        controller.showWindow(nil)
        if let owner = window, let child = controller.window {
            owner.addChildWindow(child, ordered: .above)
        }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func applyInputConversion(_ conversion: InputConversion) {
        if let keyWindow = NSApplication.shared.keyWindow,
           let secondary = secondaryInputWindows.first(where: { $0.window === keyWindow }) {
            secondary.input.apply(conversion)
        } else if let keyWindow = NSApplication.shared.keyWindow,
                  let editor = editWindows.first(where: { $0.window === keyWindow })?.editor {
            editor.string = conversion.apply(to: editor.string)
        } else {
            input.apply(conversion)
        }
    }

    func showFindDialog() {
        let alert = NSAlert()
        alert.messageText = "Find in Output"
        alert.addButton(withTitle: "Find Next")
        alert.addButton(withTitle: "Cancel")
        let query = NSTextField(string: lastFindQuery)
        query.placeholderString = "Text or regular expression"
        let regex = NSButton(checkboxWithTitle: "Regular expression", target: nil, action: nil)
        let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
        let wholeWord = NSButton(checkboxWithTitle: "Whole words", target: nil, action: nil)
        let controls = NSStackView(views: [query, regex, matchCase, wholeWord])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 7
        query.widthAnchor.constraint(equalToConstant: 340).isActive = true
        controls.frame = NSRect(x: 0, y: 0, width: 340, height: 100)
        alert.accessoryView = controls
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.lastFindQuery = query.stringValue
            do {
                _ = try self.output.find(query.stringValue, options: .init(
                    isRegularExpression: regex.state == .on,
                    isCaseSensitive: matchCase.state == .on,
                    wholeWord: wholeWord.state == .on
                ))
            } catch {
                self.appendError("Invalid regular expression: \(error.localizedDescription)")
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    private func configureUI(in window: NSWindow) {
        let root = NSStackView()
        root.orientation = .vertical
        root.distribution = .fill
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        let taskbar = NSStackView()
        taskbarView = taskbar
        taskbar.orientation = .horizontal
        taskbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        taskbar.spacing = 8
        taskbar.wantsLayer = true
        taskbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        stateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stateLabel.setAccessibilityIdentifier("connectionState")
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        activityLabel.textColor = .secondaryLabelColor
        tabButton.bezelStyle = .recessed
        tabButton.setAccessibilityIdentifier("sessionTaskButton")
        tabButton.target = self
        tabButton.action = #selector(toggleMuteFromTaskbar(_:))
        tabButton.toolTip = "Toggle audio for this tab"
        taskbar.addArrangedSubview(stateLabel)
        taskbar.addArrangedSubview(NSView())
        taskbar.addArrangedSubview(activityLabel)
        taskbar.addArrangedSubview(tabButton)

        input.completionCandidates = CommandRegistry.knownCommands.map { "/" + $0 }.sorted()
        input.onSubmit = { [weak self] text in self?.submitInput(text) }
        input.onSmartPaste = { [weak self] lines in self?.handleSmartPaste(lines) ?? false }
        output.onAction = { [weak self] action in self?.perform(action) }
        output.onPauseChange = { [weak self] paused, pending in
            guard let self else { return }
            self.activityLabel.stringValue = paused ? "Paused\(pending > 0 ? " — \(pending) new" : "")" : ""
        }
        applyPreferences()

        let inputContainer = NSView()
        inputContainer.addSubview(input.containerScrollView)
        NSLayoutConstraint.activate([
            input.containerScrollView.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 8),
            input.containerScrollView.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -8),
            input.containerScrollView.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 7),
            input.containerScrollView.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor, constant: -7),
            inputContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            inputContainer.heightAnchor.constraint(lessThanOrEqualToConstant: 150),
        ])

        root.addArrangedSubview(taskbar)
        root.addArrangedSubview(output.containerView)
        root.addArrangedSubview(inputContainer)
        let dockController = WorkspaceDockController(mainView: root, ownerWindow: window)
        self.dockController = dockController
        dockController.onPlacementChange = { [weak self] placement, thickness in
            guard let self else { return }
            self.preferences.dockPlacement = placement
            if [.left, .right, .top, .bottom].contains(placement) {
                self.preferences.lastDockedPlacement = placement
            }
            self.preferences.dockThickness = thickness
            self.savePreferences()
        }
        dockController.onLayoutChange = { [weak self] layout in
            guard let self else { return }
            self.preferences.workspaceLayout = layout
            self.savePreferences()
        }
        dockController.onNotesChange = { [weak self] notes in
            guard let self else { return }
            self.preferences.characterNotes[self.notesKey] = notes
            self.savePreferences()
        }
        dockController.setNotes(preferences.characterNotes[notesKey] ?? "")
        dockController.applyTheme(preferences.theme.palette)
        window.contentView = dockController.hostView
        NSLayoutConstraint.activate([
            taskbar.heightAnchor.constraint(equalToConstant: 34),
            output.containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        if preferences.dockPlacement == .floating {
            dockController.apply(placement: .floating, thickness: preferences.dockThickness)
        } else if let layout = preferences.workspaceLayout {
            dockController.apply(layout: layout)
        } else {
            dockController.apply(placement: preferences.dockPlacement, thickness: preferences.dockThickness)
        }
        refreshDiagnostics()
        window.makeFirstResponder(input)
    }

    private func startSession(
        _ server: ServerProfile,
        character: CharacterProfile? = nil,
        policy: ConnectionPolicy = .init()
    ) {
        sessionTask?.cancel()
        if let session { Task { await session.disconnect() } }
        currentServer = server
        currentCharacter = character
        variables = character?.variables ?? [:]
        baseWindowTitle = character.map { "\($0.name) @ \(server.name)" } ?? server.name
        updateWindowTitle()
        dockController.setNotes(preferences.characterNotes[notesKey] ?? "")
        refreshDiagnostics()
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
            await next.connect(.init(server: server, character: character, policy: policy))
        }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case let .state(state):
            switch state {
            case .disconnected: connectionStateText = "Disconnected"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .secondaryLabelColor
            case .resolving: connectionStateText = "Resolving…"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .systemOrange
            case .connecting: connectionStateText = "Connecting…"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .systemOrange
            case .connected: connectionStateText = "Connected"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .systemGreen
            case .disconnecting: connectionStateText = "Disconnecting…"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .systemOrange
            case let .failed(message): connectionStateText = "Failed"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .systemRed; appendError(message)
            }
            refreshDiagnostics()
        case let .renderedLine(line):
            if hasPendingPrompt { output.removeLastLine(); hasPendingPrompt = false }
            output.append(line)
            if line.source != .localEcho { appendToLogs(line) }
        case let .prompt(line):
            if hasPendingPrompt { output.removeLastLine() }
            output.append(line, terminator: "")
            appendToLogs(line)
            hasPendingPrompt = true
        case let .gmcp(message): activityLabel.stringValue = "GMCP: \(message.package)"
        case let .mcp(message): activityLabel.stringValue = "MCP: \(message)"
        case let .encoding(encoding): appendClient("Charset negotiated: \(encoding.rawValue)")
        case let .error(message): appendError(message)
        case let .log(message): appendClient(message)
        case let .activity(important):
            guard window?.isKeyWindow != true else { break }
            unreadCount += 1
            activityLabel.stringValue = important ? "Important — \(unreadCount) unread" : "\(unreadCount) unread"
            updateWindowTitle()
            if important { NSApplication.shared.requestUserAttention(.informationalRequest) }
            Self.updateDockBadge()
        case .received, .sent: break
        }
    }

    private func submitInput(_ value: String) {
        let lines = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines where !line.isEmpty { submitLine(String(line)) }
    }

    private func submitLine(_ line: String) {
        appendTypedToLogs(line)
        processInput(line)
    }

    private func sendToSession(_ text: String) {
        guard let session else { appendError("Not connected."); return }
        appendSentToLogs(text)
        Task { await session.send(text) }
    }

    private func appendToLogs(_ line: RenderedLine) {
        var failed: [(URL, Error)] = []
        for (url, writer) in logWriters {
            do { try writer.append(line) }
            catch { failed.append((url, error)) }
        }
        removeFailedLogs(failed)
    }

    private func appendTypedToLogs(_ text: String) {
        var failed: [(URL, Error)] = []
        for (url, writer) in logWriters {
            do { try writer.appendTyped(text) }
            catch { failed.append((url, error)) }
        }
        removeFailedLogs(failed)
    }

    private func appendSentToLogs(_ text: String) {
        var failed: [(URL, Error)] = []
        for (url, writer) in logWriters {
            do { try writer.appendSent(text) }
            catch { failed.append((url, error)) }
        }
        removeFailedLogs(failed)
    }

    private func removeFailedLogs(_ failures: [(URL, Error)]) {
        for (url, error) in failures {
            if let writer = logWriters.removeValue(forKey: url) { try? writer.stop() }
            appendError("Logging stopped for \(url.lastPathComponent): \(error.localizedDescription)")
        }
        if !failures.isEmpty { updateWindowTitle(); refreshDiagnostics() }
    }

    private func startLog(at requestedURL: URL, history: CommandOutcome.LogHistory) {
        var url = requestedURL.standardizedFileURL
        if url.pathExtension.isEmpty { url.appendPathExtension("txt") }
        guard logWriters[url] == nil else {
            appendError("Already logging to \(url.path).")
            return
        }
        let initialLines: [RenderedLine] = switch history {
        case .none: []
        case .all: output.retainedLines
        case .window: output.visibleWindowLines
        }
        let palette = preferences.theme.palette
        do {
            let writer = try SessionLogWriter(
                url: url,
                options: preferences.logging,
                title: baseWindowTitle,
                foregroundHex: palette.foreground.hexString,
                backgroundHex: palette.background.hexString,
                history: initialLines
            )
            logWriters[url] = writer
            appendClient("Logging to \(url.path) started.")
            updateWindowTitle()
            refreshDiagnostics()
        } catch {
            appendError("Cannot create log \(url.path): \(error.localizedDescription)")
        }
    }

    private func stopAllLogs(announcing: Bool = true) {
        guard !logWriters.isEmpty else {
            if announcing { appendClient("No active logs.") }
            return
        }
        let writers = logWriters
        logWriters.removeAll()
        var errors: [String] = []
        for (url, writer) in writers {
            do { try writer.stop() }
            catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if announcing { appendClient("Stopped \(writers.count) log\(writers.count == 1 ? "" : "s").") }
        errors.forEach { appendError("Could not finish log \($0)") }
        updateWindowTitle()
        refreshDiagnostics()
    }

    private func resolvedLogURL(_ filename: String) -> URL {
        var value = filename
        let replacements = [
            "%date%": Self.logDateFormatter.string(from: Date()),
            "%server%": currentServer?.name ?? "Server",
            "%character%": currentCharacter?.name ?? "Character",
            "%userprofile%": FileManager.default.homeDirectoryForCurrentUser.path,
        ]
        for (placeholder, replacement) in replacements {
            value = value.replacingOccurrences(of: placeholder, with: replacement, options: .caseInsensitive)
        }
        value = (value as NSString).expandingTildeInPath
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        let base = profileLibrary.workspace.sourceURL?.deletingLastPathComponent().appendingPathComponent("Logs", isDirectory: true)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BeipMU Logs", isDirectory: true)
        return base.appendingPathComponent(value)
    }

    private func handleSmartPaste(_ lines: [String]) -> Bool {
        let nonempty = lines.filter { !$0.isEmpty }
        let alert = NSAlert()
        alert.messageText = "Paste \(nonempty.count) lines?"
        alert.informativeText = "You can send each line as a separate command, or insert the text into the multiline editor."
        alert.addButton(withTitle: "Send Lines")
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for line in nonempty { submitLine(line) }
            return true
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func perform(_ action: LinkAction) {
        switch action {
        case let .url(value):
            guard let url = URL(string: value) else { appendError("Invalid link: \(value)"); return }
            NSWorkspace.shared.open(url)
        case let .send(value, _):
            sendToSession(value)
        case let .command(value): processInput(value)
        }
    }

    private func processInput(_ text: String) {
        switch commandRegistry.parse(text, variables: variables) {
        case .notACommand:
            sendToSession(text)
        case let .send(value):
            sendToSession(value)
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
            if let saved = profileLibrary.workspace.servers.first(where: {
                $0.profile.name.caseInsensitiveCompare(address) == .orderedSame
            }) {
                let selectedCharacter = character.flatMap { requested in
                    saved.characters.first { $0.name.caseInsensitiveCompare(requested) == .orderedSame }
                }
                if character != nil, selectedCharacter == nil {
                    appendError("Character not found in \(saved.profile.name): \(character!)")
                    return
                }
                startSession(
                    saved.profile,
                    character: selectedCharacter,
                    policy: profileLibrary.workspace.projection.connectionPolicy
                )
                return
            }
            guard character == nil else {
                appendError("World profile not found: \(address)")
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
            appendSentToLogs(value)
            Task { await session.ping(value) }
        case let .setInput(value):
            let target = secondaryInputWindows.first(where: { $0.window?.isKeyWindow == true })?.input ?? input
            guard target.text.isEmpty else { return }
            target.text = value
            target.setSelectedRange(NSRange(location: 0, length: value.utf16.count))
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
        case .newWindow:
            NSApplication.shared.sendAction(#selector(ApplicationDelegate.newWindow(_:)), to: nil, from: nil)
        case .newTab:
            NSApplication.shared.sendAction(#selector(ApplicationDelegate.newTab(_:)), to: nil, from: nil)
        case let .newInput(prefix, unique): showNewInputWindow(prefix: prefix, unique: unique)
        case let .newEdit(options): showNewEditWindow(options: options)
        case .silence:
            appendClient("Stopped local sound playback.")
        case .removeLast: output.removeLastLine()
        case let .wall(value):
            for controller in Self.openControllers {
                guard controller.session != nil else { continue }
                controller.sendToSession(value)
            }
        case let .openDialog(dialog, _):
            switch dialog {
            case "worlds", "characters", "puppets":
                NSApplication.shared.sendAction(#selector(ApplicationDelegate.manageProfiles(_:)), to: nil, from: nil)
            case "settings": showWorkspaceSettings()
            case "about": NSApplication.shared.orderFrontStandardAboutPanel(nil)
            default: appendClient("The \(dialog) editor belongs to a later workspace milestone.")
            }
        case .listServers:
            let servers = profileLibrary.workspace.servers
            if servers.isEmpty { appendClient("No server profiles loaded.") }
            for server in servers {
                appendClient("\(server.profile.name) — \(server.profile.host):\(server.profile.port)")
            }
        case .listCharacters:
            let entries = profileLibrary.workspace.servers.flatMap { server in
                server.characters.map { "\(server.profile.name) — \($0.name)" }
            }
            if entries.isEmpty { appendClient("No character profiles loaded.") }
            entries.forEach(appendClient)
        case .listPuppets:
            let entries = profileLibrary.workspace.servers.flatMap { server in
                server.characters.flatMap { character in
                    character.puppets.map { "\(server.profile.name) — \(character.name) — \($0.name)" }
                }
            }
            if entries.isEmpty { appendClient("No puppet profiles loaded.") }
            entries.forEach(appendClient)
        case let .connectPuppet(name):
            let match = currentCharacter?.puppets.first {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }
            if let match { appendClient("Puppet routing profile selected: \(match.name)") }
            else { appendError("Puppet profile not found: \(name)") }
        case .stopLogs: stopAllLogs()
        case let .startLog(filename, history): startLog(at: resolvedLogURL(filename), history: history)
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
        case let .invoke(name, arguments, _):
            switch name {
            case "tabcolor": setTabColor(arguments.first)
            case "switchtab": switchSessionTab(named: arguments.last)
            default: appendClient("/\(name) is registered; its target surface is completed in a later milestone.")
            }
        case let .unimplemented(command): appendError("/\(command) is recognized but not implemented in this milestone.")
        }
    }

    private static var openControllers: [ClientWindowController] {
        NSApplication.shared.windows.compactMap { $0.windowController as? ClientWindowController }
    }

    private static func updateDockBadge() {
        let total = openControllers.reduce(0) { $0 + $1.unreadCount }
        NSApplication.shared.dockTile.badgeLabel = total > 0 ? String(total) : nil
    }

    @objc private func toggleMuteFromTaskbar(_ sender: Any?) { toggleMute() }

    private func updateWindowTitle() {
        let activity = unreadCount > 0 ? "● " : ""
        let mute = isMuted ? " 🔇" : ""
        let logging = logWriters.isEmpty ? "" : " 📝"
        window?.title = activity + baseWindowTitle + mute + logging
        tabButton.title = (isMuted ? "Muted" : baseWindowTitle) + logging
    }

    private func setTabColor(_ value: String?) {
        guard let value, let color = NSColor(htmlColor: value) else {
            tabButton.bezelColor = nil
            appendClient("Tab color reset.")
            return
        }
        tabButton.bezelColor = color
        appendClient("Tab color set to \(value).")
    }

    private func switchSessionTab(named name: String?) {
        guard let name, let window,
              let match = window.tabbedWindows?.first(where: {
                  $0.title.localizedCaseInsensitiveContains(name)
              }) else {
            appendError("Tab not found: \(name ?? "")")
            return
        }
        match.makeKeyAndOrderFront(nil)
    }

    private func applyPreferences() {
        output.historyLimit = preferences.outputHistoryLimit
        output.showsTimestamps = preferences.showsTimestamps
        output.usesFanFoldBackgrounds = preferences.usesFanFoldBackgrounds
        if output.isSplit != preferences.outputSplit { output.toggleSplit() }
        input.behavior = .init(prefix: preferences.inputPrefix, isSticky: preferences.stickyInput)
        input.isContinuousSpellCheckingEnabled = preferences.checksSpelling
        applyThemeSettings(preferences.theme)
    }

    private func savePreferences() { WorkspacePreferencesStore.save(preferences) }

    private var notesKey: String {
        ([currentServer?.name, currentCharacter?.name].compactMap { $0 }.joined(separator: "/").isEmpty
            ? "Untitled"
            : [currentServer?.name, currentCharacter?.name].compactMap { $0 }.joined(separator: "/"))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func refreshDiagnostics() {
        let serverDescription = currentServer.map {
            "\($0.host):\($0.port)\($0.usesTLS ? " (TLS)" : "")"
        } ?? "None"
        let base = """
        Window: \(baseWindowTitle)
        State: \(connectionStateText)
        Server: \(serverDescription)
        Encoding: \(currentServer?.encoding.rawValue ?? "—")
        Output lines: \(output.visibleLineCount)
        Buffered while paused: \(output.pendingLineCount)
        Muted: \(isMuted ? "Yes" : "No")
        Active logs: \(logWriters.count)
        """
        dockController?.setDiagnostics(base)
        guard let session else { return }
        Task { [weak self] in
            let stats = await session.statistics()
            await MainActor.run {
                self?.dockController?.setDiagnostics(base + """

                Connections: \(stats.connectionCount)
                Sent: \(stats.bytesSent) bytes
                Received: \(stats.bytesReceived) bytes
                Online: \(Int(stats.secondsConnected)) seconds
                """)
            }
        }
    }

    private func refreshConnectionStatistics() async {
        let statistics: ConnectionStatistics
        if let session { statistics = await session.statistics() }
        else { statistics = ConnectionStatistics() }
        statisticsWindow?.update(
            statistics: statistics,
            server: currentServer.map { "\($0.host):\($0.port)" } ?? "None",
            state: connectionStateText
        )
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

    private static func performanceSoakLine(_ index: Int) -> RenderedLine {
        let text = "[\(index)] The quick brown fox crosses a virtualized MU* viewport with wrapped text, Unicode café, and command links."
        let prefixLength = min(text.utf16.count, String("[\(index)]").utf16.count)
        let foreground = RGBColor(
            red: UInt8(96 + index % 128),
            green: UInt8(128 + index % 96),
            blue: UInt8(160 + index % 64)
        )
        let style = TextStyle(
            foreground: foreground,
            bold: index.isMultiple(of: 7),
            italic: index.isMultiple(of: 11),
            underline: index.isMultiple(of: 13),
            blink: index.isMultiple(of: 997) ? .slow : .none,
            link: index.isMultiple(of: 17) ? .command("/statistics") : nil
        )
        return RenderedLine(
            text: text,
            runs: [StyleRun(range: 0..<prefixLength, style: style)],
            paragraph: ParagraphStyle(
                leftIndent: Double(index % 4) * 4,
                wrappedIndent: Double(index % 3) * 8,
                topPadding: index.isMultiple(of: 19) ? 2 : 0,
                bottomPadding: index.isMultiple(of: 23) ? 2 : 0
            ),
            source: index.isMultiple(of: 5) ? .localEcho : .server
        )
    }

    private static func currentResidentSize() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private static let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Deterministic UI-only projection of the normalized v331 golden byte
    /// trace. Protocol parsing remains covered by TelnetParserTests; this path
    /// proves that the resulting prompt and ANSI line reach the native output
    /// surface with the same text and color semantics.
    private func loadWindowsGoldenSessionFixtureIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BEIPMU_UI_TESTING"] == "1",
              environment["BEIPMU_UI_GOLDEN_SESSION"] == "1" else { return }
        output.clear()
        let text = "Golden prompt> Golden room"
        let roomStart = "Golden prompt> ".utf16.count
        let green = TextStyle(foreground: .init(red: 0, green: 205, blue: 0))
        output.append(.init(
            text: text,
            runs: [.init(range: roomStart..<text.utf16.count, style: green)],
            source: .server
        ))
        appendError("Remote connection closed.")
    }

    private func appendClient(_ text: String) { output.append(.init(text: text, source: .client)) }
    private func appendError(_ text: String) {
        let style = TextStyle(foreground: .init(red: 255, green: 80, blue: 80))
        output.append(.init(text: text, runs: [.init(range: 0..<text.utf16.count, style: style)], source: .client))
    }
}

private extension String {
    var safeFilename: String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let value = components(separatedBy: forbidden).filter { !$0.isEmpty }.joined(separator: "-")
        return value.isEmpty ? "Session" : value
    }
}

private extension NSColor {
    convenience init?(htmlColor value: String) {
        let named: [String: NSColor] = [
            "black": .black, "white": .white, "red": .systemRed, "green": .systemGreen,
            "blue": .systemBlue, "yellow": .systemYellow, "orange": .systemOrange,
            "purple": .systemPurple, "pink": .systemPink, "gray": .systemGray,
            "grey": .systemGray, "cyan": .systemCyan, "teal": .systemTeal,
        ]
        if let color = named[value.lowercased()] {
            self.init(cgColor: color.cgColor)
            return
        }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((number >> 16) & 0xff) / 255,
            green: CGFloat((number >> 8) & 0xff) / 255,
            blue: CGFloat(number & 0xff) / 255,
            alpha: 1
        )
    }
}
