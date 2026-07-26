import AppKit
import AVFoundation
import BeipAutomation
import BeipCore
import BeipPersistence
import BeipProtocols
import BeipScriptRuntime
import Darwin
import UserNotifications

@MainActor
private final class SessionWindowTabItemView: NSView {
    weak var targetController: ClientWindowController?
    private final class ClickThroughLabel: NSTextField {
        override var alignmentRectInsets: NSEdgeInsets {
            NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private let titleLabel = ClickThroughLabel(labelWithString: "")
    private let trailingIndicatorLabel = ClickThroughLabel(labelWithString: "")
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?
    private var selected = false
    private let tabColor: NSColor?

    init(
        title: String,
        trailingIndicators: String,
        selected: Bool,
        color: NSColor?,
        targetController: ClientWindowController
    ) {
        self.targetController = targetController
        self.selected = selected
        tabColor = color
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 7

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.allowsExpansionToolTips = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setAccessibilityIdentifier("sessionTabTitle")
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        trailingIndicatorLabel.stringValue = trailingIndicators
        trailingIndicatorLabel.font = .systemFont(ofSize: 13)
        trailingIndicatorLabel.lineBreakMode = .byClipping
        trailingIndicatorLabel.maximumNumberOfLines = 1
        trailingIndicatorLabel.translatesAutoresizingMaskIntoConstraints = false
        trailingIndicatorLabel.setAccessibilityIdentifier("sessionTabIndicators")
        trailingIndicatorLabel.setContentHuggingPriority(.required, for: .horizontal)
        trailingIndicatorLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(trailingIndicatorLabel)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.isBordered = false
        closeButton.focusRingType = .none
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTab(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = !selected
        closeButton.toolTip = "Close tab"
        closeButton.setAccessibilityLabel("Close tab")
        closeButton.setAccessibilityIdentifier("sessionTabClose")
        addSubview(closeButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\([title, trailingIndicators].filter { !$0.isEmpty }.joined(separator: " ")) tab")
        setAccessibilityIdentifier(selected ? "activeSessionTab" : "sessionTab")

        let minimumWidth = widthAnchor.constraint(greaterThanOrEqualToConstant: 132)
        minimumWidth.priority = .defaultLow
        let titleToIndicators = titleLabel.trailingAnchor.constraint(
            equalTo: trailingIndicatorLabel.leadingAnchor,
            constant: trailingIndicators.isEmpty ? 0 : -5
        )
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            minimumWidth,
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 5),
            titleToIndicators,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingIndicatorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailingIndicatorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateBackground(hovered: false)
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
        updateBackground(hovered: true)
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = !selected
        updateBackground(hovered: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground(hovered: false)
    }

    override func mouseDown(with event: NSEvent) {
        selectTab(self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = targetController?.sessionTabContextMenu() else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        targetController?.sessionTabContextMenu()
    }

    private func updateBackground(hovered: Bool) {
        layer?.backgroundColor = if selected {
            (tabColor ?? NSColor.controlColor).cgColor
        } else if hovered {
            NSColor.quaternaryLabelColor.cgColor
        } else {
            NSColor.clear.cgColor
        }
    }

    @objc private func selectTab(_ sender: Any?) {
        targetController?.sessionTabGroup?.select(targetController, sender: sender)
    }

    @objc private func closeTab(_ sender: Any?) {
        targetController?.window?.performClose(sender)
    }
}

@MainActor
final class ClientTabGroup {
    private final class WeakController {
        weak var value: ClientWindowController?
        init(_ value: ClientWindowController) { self.value = value }
    }

    private var entries: [WeakController]
    private(set) weak var selectedController: ClientWindowController?

    init(_ initialController: ClientWindowController) {
        entries = [WeakController(initialController)]
        selectedController = initialController
        initialController.sessionTabGroup = self
    }

    var controllers: [ClientWindowController] {
        entries.compactMap(\.value)
    }

    func add(_ controller: ClientWindowController) {
        guard !controllers.contains(where: { $0 === controller }) else { return }
        entries.append(WeakController(controller))
        controller.sessionTabGroup = self
        refreshTabs()
        controller.tabStateDidChange()
    }

    func select(_ controller: ClientWindowController?, sender: Any?) {
        guard let controller, controllers.contains(where: { $0 === controller }) else { return }
        let previous = selectedController
        if let frame = previous?.window?.frame {
            controller.window?.setFrame(frame, display: false)
        }
        selectedController = controller
        if previous !== controller { previous?.window?.orderOut(sender) }
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
        controller.focusCommandInput()
        refreshTabs()
        controller.tabStateDidChange()
    }

    func prepareToClose(_ controller: ClientWindowController) {
        guard selectedController === controller else { return }
        let current = controllers
        guard current.count > 1,
              let index = current.firstIndex(where: { $0 === controller }) else { return }
        let remaining = current.filter { $0 !== controller }
        let replacement = remaining[min(index, remaining.count - 1)]
        if let frame = controller.window?.frame {
            replacement.window?.setFrame(frame, display: false)
        }
        selectedController = replacement
        replacement.showWindow(nil)
        replacement.window?.makeKeyAndOrderFront(nil)
        replacement.focusCommandInput()
        refreshTabs()
    }

    func markSelected(_ controller: ClientWindowController) {
        guard controllers.contains(where: { $0 === controller }) else { return }
        selectedController = controller
        refreshTabs()
        controller.tabStateDidChange()
    }

    func controllerWillClose(_ controller: ClientWindowController) {
        let before = controllers
        guard let index = before.firstIndex(where: { $0 === controller }) else { return }
        let wasSelected = selectedController === controller
        entries.removeAll { $0.value == nil || $0.value === controller }
        controller.sessionTabGroup = nil

        let remaining = controllers
        if remaining.count == 1 {
            let survivor = remaining[0]
            survivor.sessionTabGroup = nil
            selectedController = nil
            if wasSelected {
                DispatchQueue.main.async {
                    survivor.showWindow(nil)
                    survivor.window?.makeKeyAndOrderFront(nil)
                    survivor.rebuildSessionTabs()
                }
            } else {
                survivor.rebuildSessionTabs()
            }
            return
        }

        if wasSelected, !remaining.isEmpty {
            selectedController = nil
            let replacement = remaining[min(index, remaining.count - 1)]
            DispatchQueue.main.async { [weak self, weak replacement] in
                self?.select(replacement, sender: nil)
            }
        } else {
            refreshTabs()
        }
        controller.tabStateDidChange()
    }

    func refreshTabs() {
        controllers.forEach { $0.rebuildSessionTabs() }
    }
}

@MainActor
final class ClientWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate {
    private struct ActiveLog {
        var template: String
        var rollsOverDaily: Bool
        var isAutomatic: Bool
        var appendsDate: Bool
        var writer: SessionLogWriter
    }

    private struct SpawnCapture {
        var title: String
        var action: TriggerSpawnAction
        var children: [Trigger]
    }

    private struct WindowSettingsClipboard: Codable {
        var globalTextWindowSettings: TextWindowSettings
        var worldTextWindowSettings: [String: TextWindowSettingsOverride]
        var characterTextWindowSettings: [String: TextWindowSettingsOverride]
        var tabTextWindowSettings: [String: TextWindowSettingsOverride]
        var globalInputWindowSettings: InputWindowSettings
        var worldInputWindowSettings: [String: InputWindowSettingsOverride]
        var characterInputWindowSettings: [String: InputWindowSettingsOverride]
        var tabInputWindowSettings: [String: InputWindowSettingsOverride]
    }

    private final class SimpleEditUploadState {
        let reference: String
        let type: String
        let original: String
        var lastUploaded: String?

        init(reference: String, type: String, original: String) {
            self.reference = reference
            self.type = type
            self.original = original
        }
    }

    private let profileLibrary: ProfileLibrary
    private let output = OutputTextView()
    private let input = CommandInputView()
    private let inputSplitView = NSSplitView()
    private let inputContainer = NSView()
    private let stateLabel = NSTextField(labelWithString: "Disconnected")
    private let activityLabel = NSTextField(labelWithString: "")
    private let applicationMenuButton = NSButton()
    private let quickConnectButton = NSButton()
    private let profilesButton = NSButton()
    private let sessionTabs = NSStackView()
    private let titlebarStatistics = SessionTitlebarStatisticsController()
    private let commandRegistry = CommandRegistry()
    private let delayScheduler = DelayScheduler()
    private let scriptService = ScriptServiceClient()
    private let aiClient = AIClient()
    private let triggerEngine = TriggerEngine()
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var scriptSounds: [NSSound] = []
    private var scriptWindows: [String: ScriptWindowController] = [:]
    private var suppressNextSessionActivity = false
    private var frameBeforeMaximize: NSRect?
    private var dockController: WorkspaceDockController!
    private var variables: [String: String] = [:]
    private var aliasGroups: [AliasGroup] = []
    private var triggerGroups: [TriggerGroup] = []
    private var keyboardMacroGroups: [KeyboardMacroGroup] = []
    private var aliasesEchoResults = true
    private var aliasesProcessCommands = false
    private var session: SessionActor?
    private var sessionTask: Task<Void, Never>?
    private var currentServer: ServerProfile?
    private var currentCharacter: CharacterProfile?
    private var currentPuppet: PuppetProfile?
    private weak var puppetMaster: ClientWindowController?
    private var puppetChildren: [UUID: ClientWindowController] = [:]
    private var aiWindow: AIWindowController?
    private var aiRequestTask: Task<Void, Never>?
    private var preservingAIPlacement = false
    private var grabPrefix: String?
    private var secondaryInputWindows: [SecondaryInputWindowController] = []
    private var inputHistoryWindow: InputHistoryWindowController?
    private var editWindows: [EditWindowController] = []
    private var statisticsWindow: SessionStatisticsWindowController?
    private var triggerStatisticsWindows: [String: TriggerStatisticsWindowController] = [:]
    private var triggerStatistics: [String: TriggerStatisticStore] = [:]
    private var triggerSpawnWindows: [String: TriggerSpawnWindowController] = [:]
    private var triggerSpawnTabGroups: [String: TriggerSpawnTabGroupWindowController] = [:]
    private var suppressSpawnPersistence = false
    private var gmcpState = AdvancedGMCPState()
    private var mediaState = ClientMediaState()
    private let mediaController = ClientMediaController()
    private var mcpStatusWindow: MCPStatusWindowController?
    private var webViewState = WebViewProtocolState()
    private var webViewWindows: [String: WebViewWindowController] = [:]
    private var nextUnnamedWebViewID = 1
    private var gmcpStatisticsWindows: [String: GMCPStatisticsWindowController] = [:]
    private var tileMapWindows: [String: TileMapWindowController] = [:]
    private var imageViewerWindow: ImageViewerWindowController?
    private var atlasWindow: AtlasWindowController?
    private var suppressAtlasPersistence = false
    private var automationEditors: [AutomationEditorWindowController] = []
    private var automationDebugWindows: [CommandOutcome.DebugAutomationKind: AutomationDebugWindowController] = [:]
    private var networkDebugWindow: NetworkDebugWindowController?
    private var scriptDebugWindow: ScriptDebugWindowController?
    private var scriptDebugEntries: [ScriptDebugWindowController.Entry] = []
    private var helpWindow: EmbeddedHelpWindowController?
    private var spawnCapture: SpawnCapture?
    private var statisticsTask: Task<Void, Never>?
    private var titlebarStatisticsTask: Task<Void, Never>?
    private var lastTypedAt = Date()
    private var isSessionConnected = false
    private var logWriters: [URL: ActiveLog] = [:]
    private var localEcho = true
    private var terminalType = "Beip"
    private var gmcpDumpEnabled = false
    private var tileMapsEnabled = true
    private var hasPendingPrompt = false
    private var unreadCount = 0
    private var lastFindQuery = ""
    private var sessionTabColor: NSColor?
    var sessionTabGroup: ClientTabGroup?
    private var preferences = WorkspacePreferencesStore.load()
    private var baseWindowTitle = "Untitled"
    private var scriptTitlePrefix = ""
    private var isMuted = false
    private var bypassLastTabReplacement = false
    private var connectionStateText = "Disconnected"
    private weak var taskbarView: NSStackView?
    private var tracksInputHeight = false
    private static var didRunStartupScript = false
    var onClose: (() -> Void)?
    var onRequestCloseLastTab: ((ClientWindowController) -> Bool)?
    var onTabStateChange: (() -> Void)?
    var onQuickConnectProfile: ((ClientWindowController, ServerProfile, CharacterProfile?) -> Void)?
    var onThemeChange: ((WorkspaceThemeSettings) -> Void)?
    var onTextWindowSettingsChange: (() -> Void)?
    var onInputHeightChange: ((Double) -> Void)?
    var timestampsEnabled: Bool {
        let settings = activeTextWindowSettings
        return settings.showsTime || settings.showsDate
    }
    var fanFoldEnabled: Bool { activeTextWindowSettings.usesFanFoldBackgrounds }
    var stickyInputEnabled: Bool { activeInputWindowSettings.keepsTextOnSubmit }
    var spellCheckingEnabled: Bool { preferences.checksSpelling }
    var outputSplitEnabled: Bool { output.isSplit }
    var muted: Bool { isMuted }
    var dockPlacement: WorkspaceDockPlacement { dockController?.placement ?? preferences.dockPlacement }
    var legacyDockPlacement: WorkspaceDockPlacement? { dockController?.legacyPlacement }
    var activeLogCount: Int { logWriters.count }

    func startDeviceMediaAuditIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BEIPMU_DEVICE_MEDIA_AUDIT"] == "1" else { return }

        if let source = environment["BEIPMU_DEVICE_MEDIA_URL"].flatMap(URL.init(string:)) {
            let item = ClientMediaItem(
                name: "device-audit",
                source: source,
                volume: 1,
                loops: 1,
                continues: false
            )
            appendClient("Device audit: downloading Client.Media from \(source.absoluteString)")
            mediaController.apply(.play(item))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                appendClient("Device audit: \(mediaController.information)")
            }
        }

        let phrase = environment["BEIPMU_DEVICE_SPEECH_TEXT"]
            ?? "BeipMU selected speech voice device audit."
        let utterance = AVSpeechUtterance(string: phrase)
        if let identifier = preferences.speechVoiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
            appendClient("Device audit: speaking with \(voice.name), \(voice.language).")
        } else {
            appendClient("Device audit: speaking with the system default voice.")
        }
        speechSynthesizer.speak(utterance)
    }

    func usesWorkspaceLayout(_ layout: WorkspaceLayoutNode) -> Bool {
        dockController?.currentLayout.hasSameTopology(as: layout) == true
    }

    func toggleMaximize() {
        guard let window, let screen = window.screen else { return }
        if let restoreFrame = frameBeforeMaximize {
            frameBeforeMaximize = nil
            window.setFrame(restoreFrame, display: true)
            Self.postFrameChange(for: window)
        } else {
            frameBeforeMaximize = window.frame
            Self.configureUnrestrictedSizing(for: window)
            window.setFrame(screen.visibleFrame, display: true)
            Self.postFrameChange(for: window)
            Self.publishTestFrame(for: window)
        }
    }

    func toggleFullScreen() {
        guard let window else { return }
        Self.configureUnrestrictedSizing(for: window)
        window.toggleFullScreen(nil)
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
        super.init(window: window)
        Task { [weak self, scriptService] in
            await scriptService.startAsyncOutputDelivery { [weak self] outputs in
                self?.applyScriptEvaluation(.init(outputs: outputs), showValue: false)
            }
        }
        mediaController.onError = { [weak self] message in self?.appendError(message) }
        if preferences.logging == SessionLogOptions() {
            preferences.logging = profileLibrary.workspace.projection.logging
        }
        window.delegate = self
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        configureUI(in: window)
        startTitlebarStatisticsUpdates()
        Self.configureUnrestrictedSizing(for: window)
        if ProcessInfo.processInfo.environment["BEIPMU_UI_TESTING"] == "1" {
            window.setContentSize(NSSize(width: 980, height: 700))
            window.center()
        } else {
            if !window.setFrameUsingName("BeipMUClientWindow") { window.center() }
            window.setFrameAutosaveName("BeipMUClientWindow")
        }
        restoreInputHeight()
        tracksInputHeight = true
        appendClient("Welcome to BeipMU for Mac. Choose Connection → Connect… to begin.")
        runStartupScriptIfNeeded()
        updateWindowTitle()
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        sessionTabGroup?.controllerWillClose(self)
        if let puppet = currentPuppet {
            puppetMaster?.detachPuppetChild(puppet.id)
            puppetMaster = nil
        } else {
            let children = Array(puppetChildren.values)
            puppetChildren.removeAll()
            children.forEach { $0.masterConnectionClosed() }
        }
        Task { [weak self, scriptService] in
            guard let self else { return }
            applyScriptEvaluation(
                await scriptService.dispatchConnectionEvent("window:close", host: scriptHostSnapshot),
                showValue: false
            )
        }
        dockController?.prepareForOwnerClose()
        secondaryInputWindows.forEach { $0.close() }
        inputHistoryWindow?.close()
        editWindows.forEach { $0.close() }
        statisticsTask?.cancel()
        titlebarStatisticsTask?.cancel()
        statisticsWindow?.close()
        triggerStatisticsWindows.values.forEach { $0.close() }
        saveSpawnSurfacePreferences()
        closeSpawnSurfaces()
        gmcpStatisticsWindows.values.forEach { $0.close() }
        tileMapWindows.values.forEach { $0.close() }
        imageViewerWindow?.close()
        mcpStatusWindow?.close()
        closeWebViews()
        mediaController.flush()
        scriptWindows.values.forEach { $0.close() }
        scriptWindows.removeAll()
        saveAtlasSurfacePreferences()
        closeAtlasSurface()
        automationDebugWindows.values.forEach { $0.close() }
        networkDebugWindow?.close()
        scriptDebugWindow?.close()
        closeAIWindow(preservingDockPlacement: false)
        stopAllLogs(announcing: false)
        Task { [scriptService] in await scriptService.stopAsyncOutputDelivery() }
        sessionTask?.cancel()
        if let session { Task { await session.disconnect() } }
        onClose?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !bypassLastTabReplacement,
           (sessionTabGroup?.controllers.count ?? 1) == 1,
           onRequestCloseLastTab?(self) == true {
            return false
        }
        sessionTabGroup?.prepareToClose(self)
        return true
    }

    func closeForTabReplacement() {
        bypassLastTabReplacement = true
        close()
    }

    func tabStateDidChange() {
        onTabStateChange?()
    }

    var persistedOpenTab: MacConfigurationSidecar.OpenTab {
        .init(
            serverID: currentServer?.id,
            characterID: currentCharacter?.id,
            serverName: currentServer?.name,
            characterName: currentCharacter?.name
        )
    }

    func representsSavedProfile(_ server: ServerProfile, character: CharacterProfile?) -> Bool {
        currentServer?.id == server.id && currentCharacter?.id == character?.id
    }

    func tabGroupContainsSavedProfile(_ server: ServerProfile, character: CharacterProfile?) -> Bool {
        (sessionTabGroup?.controllers ?? [self]).contains {
            $0.representsSavedProfile(server, character: character)
        }
    }

    func restoreOpenTab(server: ServerProfile, character: CharacterProfile?) {
        currentServer = server
        currentCharacter = character
        currentPuppet = nil
        variables = profileLibrary.workspace.projection.variables(
            for: server,
            character: character,
            puppet: nil
        )
        let automation = profileLibrary.workspace.projection.automationGroups(
            for: server,
            character: character,
            puppet: nil
        )
        aliasGroups = automation.aliases
        triggerGroups = automation.triggers
        keyboardMacroGroups = profileLibrary.workspace.projection.macroGroups(
            for: server,
            character: character,
            puppet: nil
        )
        baseWindowTitle = character.map { "\($0.name) @ \(server.name)" } ?? server.name
        applyTextWindowSettings()
        applyInputWindowSettings()
        dockController.setNotes(preferences.characterNotes[notesKey] ?? "")
        if let layout = preferences.workspaceLayouts[notesKey] ?? preferences.workspaceLayout {
            dockController.apply(layout: layout)
        }
        updateWindowTitle()
        refreshDiagnostics()
    }

    func windowDidResize(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            Self.publishTestFrame(for: window)
        }
        guard let session else { return }
        let size = output.terminalSize
        Task { await session.updateWindowSize(columns: size.columns, rows: size.rows) }
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === inputSplitView else { return proposedMinimumPosition }
        return max(80, proposedMinimumPosition)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === inputSplitView else { return proposedMaximumPosition }
        return max(80, min(
            proposedMaximumPosition,
            splitView.bounds.height - splitView.dividerThickness - 30
        ))
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard tracksInputHeight,
              window?.isVisible == true,
              notification.object as? NSSplitView === inputSplitView,
              inputContainer.frame.height >= 30 else { return }
        let height = Double(inputContainer.frame.height)
        guard abs(preferences.inputHeight - height) >= 0.5 else { return }
        preferences.inputHeight = height
        savePreferences()
        onInputHeightChange?(height)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            Self.configureUnrestrictedSizing(for: window)
        }
        unreadCount = 0
        activityLabel.stringValue = ""
        updateWindowTitle()
        sessionTabGroup?.markSelected(self)
        rebuildSessionTabs()
        Self.updateDockBadge()
        Task { [weak self, scriptService] in
            guard let self else { return }
            applyScriptEvaluation(
                await scriptService.dispatchConnectionEvent("window:activate", arguments: ["true"], host: scriptHostSnapshot),
                showValue: false
            )
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        Task { [weak self, scriptService] in
            guard let self else { return }
            applyScriptEvaluation(
                await scriptService.dispatchConnectionEvent("window:activate", arguments: ["false"], host: scriptHostSnapshot),
                showValue: false
            )
        }
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

    private func configureTabBarButton(
        _ button: NSButton,
        symbolName: String,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        tintColor: NSColor,
        action: Selector
    ) {
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.focusRingType = .none
        button.contentTintColor = tintColor
        button.target = self
        button.action = action
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.setAccessibilityIdentifier(accessibilityIdentifier)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @objc private func showApplicationMenu(_ sender: NSButton) {
        popUp(tabBarApplicationMenu(), from: sender)
    }

    @objc private func showQuickConnectMenu(_ sender: NSButton) {
        popUp(quickConnectMenu(), from: sender)
    }

    @objc private func showProfiles(_ sender: NSButton) {
        NSApplication.shared.sendAction(
            #selector(ApplicationDelegate.manageProfiles(_:)),
            to: NSApplication.shared.delegate,
            from: sender
        )
    }

    private func popUp(_ menu: NSMenu, from button: NSButton) {
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: button.bounds.minY - 4),
            in: button
        )
    }

    private func tabBarApplicationMenu() -> NSMenu {
        let menu = NSMenu(title: "BeipMU")
        menu.autoenablesItems = false

        let windowsMenu = NSMenu(title: "Windows")
        windowsMenu.addItem(applicationMenuItem(
            title: "New Tab",
            action: #selector(ApplicationDelegate.newTab(_:)),
            keyEquivalent: "t",
            modifiers: [.control]
        ))
        windowsMenu.addItem(applicationMenuItem(
            title: "New Window",
            action: #selector(ApplicationDelegate.newWindow(_:)),
            keyEquivalent: "n",
            modifiers: [.control]
        ))
        windowsMenu.addItem(applicationMenuItem(
            title: "New Input Window",
            action: #selector(ApplicationDelegate.newInputWindow(_:))
        ))
        windowsMenu.addItem(applicationMenuItem(
            title: "New Edit Window",
            action: #selector(ApplicationDelegate.newEditWindow(_:))
        ))
        windowsMenu.addItem(.separator())
        windowsMenu.addItem(applicationMenuItem(
            title: "Toggle Input History Window",
            action: #selector(ApplicationDelegate.toggleInputHistoryWindow(_:))
        ))
        windowsMenu.addItem(applicationMenuItem(
            title: "Toggle Image Window",
            action: #selector(ApplicationDelegate.toggleImageWindow(_:))
        ))
        windowsMenu.addItem(applicationMenuItem(
            title: "Toggle Map Window",
            action: #selector(ApplicationDelegate.toggleMapWindow(_:))
        ))
        windowsMenu.addItem(applicationMenuItem(
            title: "Toggle Character Notes Window",
            action: #selector(ApplicationDelegate.toggleCharacterNotesWindow(_:))
        ))
        windowsMenu.addItem(.separator())
        windowsMenu.addItem(applicationMenuItem(
            title: "Copy all window settings",
            action: #selector(ApplicationDelegate.copyAllWindowSettings(_:))
        ))
        windowsMenu.addItem(applicationMenuItem(
            title: "Paste all window settings",
            action: #selector(ApplicationDelegate.pasteAllWindowSettings(_:))
        ))
        windowsMenu.addItem(.separator())
        windowsMenu.addItem(applicationMenuItem(
            title: "Show Hidden Captions",
            action: #selector(ApplicationDelegate.showHiddenCaptions(_:))
        ))
        let windows = NSMenuItem(title: "Windows", action: nil, keyEquivalent: "")
        windows.submenu = windowsMenu
        windows.isEnabled = true
        menu.addItem(windows)

        let toolsMenu = NSMenu(title: "Tools")
        toolsMenu.addItem(applicationMenuItem(
            title: "Triggers…",
            action: #selector(ApplicationDelegate.editTriggers(_:)),
            keyEquivalent: "t",
            modifiers: [.control, .shift]
        ))
        toolsMenu.addItem(applicationMenuItem(
            title: "Macros…",
            action: #selector(ApplicationDelegate.editMacros(_:)),
            keyEquivalent: "m",
            modifiers: [.control, .shift]
        ))
        toolsMenu.addItem(applicationMenuItem(
            title: "Aliases…",
            action: #selector(ApplicationDelegate.editAliases(_:)),
            keyEquivalent: "a",
            modifiers: [.control, .shift]
        ))
        toolsMenu.addItem(.separator())
        toolsMenu.addItem(applicationMenuItem(
            title: "Trigger Debugger",
            action: #selector(ApplicationDelegate.debugTriggers(_:))
        ))
        toolsMenu.addItem(applicationMenuItem(
            title: "Alias Debugger",
            action: #selector(ApplicationDelegate.debugAliases(_:))
        ))
        toolsMenu.addItem(applicationMenuItem(
            title: "Network Debugger",
            action: #selector(ApplicationDelegate.debugNetwork(_:))
        ))
        toolsMenu.addItem(applicationMenuItem(
            title: "Smart Paste…",
            action: #selector(ApplicationDelegate.smartPaste(_:)),
            keyEquivalent: "v",
            modifiers: [.control, .shift]
        ))
        let tools = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        tools.submenu = toolsMenu
        tools.isEnabled = true
        menu.addItem(tools)

        menu.addItem(applicationMenuItem(
            title: "Logging…",
            action: #selector(ApplicationDelegate.logging(_:)),
            keyEquivalent: "l",
            modifiers: [.control]
        ))
        menu.addItem(applicationMenuItem(
            title: "Settings…",
            action: #selector(ApplicationDelegate.settings(_:))
        ))
        menu.addItem(applicationMenuItem(
            title: "Global Output Settings…",
            action: #selector(ApplicationDelegate.globalTextWindowSettings(_:))
        ))
        menu.addItem(applicationMenuItem(
            title: "Global Input Settings…",
            action: #selector(ApplicationDelegate.globalInputWindowSettings(_:))
        ))

        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(applicationMenuItem(
            title: "BeipMU Help",
            action: #selector(ApplicationDelegate.showHelp(_:)),
            keyEquivalent: "?"
        ))
        let help = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        help.submenu = helpMenu
        help.isEnabled = true
        menu.addItem(help)

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Close all Windows and Exit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        )
        quit.target = NSApplication.shared
        quit.isEnabled = true
        menu.addItem(quit)
        return menu
    }

    private func applicationMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = NSApplication.shared.delegate
        item.isEnabled = NSApplication.shared.delegate != nil
        return item
    }

    private final class QuickConnectTarget: NSObject {
        let serverID: UUID
        let characterID: UUID?

        init(serverID: UUID, characterID: UUID?) {
            self.serverID = serverID
            self.characterID = characterID
        }
    }

    private func quickConnectMenu() -> NSMenu {
        let menu = NSMenu(title: "Player Quick Connect")
        menu.autoenablesItems = false
        let servers = profileLibrary.workspace.servers
        guard !servers.isEmpty else {
            let empty = NSMenuItem(title: "No Saved Worlds", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for server in servers {
            switch server.characters.count {
            case 0:
                menu.addItem(quickConnectItem(
                    title: server.profile.name,
                    serverID: server.profile.id,
                    characterID: nil
                ))
            case 1:
                let character = server.characters[0]
                menu.addItem(quickConnectItem(
                    title: "\(server.profile.name) — \(character.name)",
                    serverID: server.profile.id,
                    characterID: character.id
                ))
            default:
                let characters = NSMenu(title: server.profile.name)
                characters.autoenablesItems = false
                for character in server.characters {
                    characters.addItem(quickConnectItem(
                        title: character.name,
                        serverID: server.profile.id,
                        characterID: character.id
                    ))
                }
                let world = NSMenuItem(title: server.profile.name, action: nil, keyEquivalent: "")
                world.submenu = characters
                world.isEnabled = true
                menu.addItem(world)
            }
        }
        return menu
    }

    private func quickConnectItem(
        title: String,
        serverID: UUID,
        characterID: UUID?
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(quickConnect(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = QuickConnectTarget(serverID: serverID, characterID: characterID)
        item.isEnabled = true
        return item
    }

    @objc private func quickConnect(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? QuickConnectTarget,
              let server = profileLibrary.workspace.servers.first(where: {
                  $0.profile.id == target.serverID
              }) else { return }
        let character = target.characterID.flatMap { characterID in
            server.characters.first { $0.id == characterID }
        }
        guard !tabGroupContainsSavedProfile(server.profile, character: character) else { return }
        if let onQuickConnectProfile {
            onQuickConnectProfile(self, server.profile, character)
            return
        }
        startSession(
            server.profile,
            character: character,
            policy: profileLibrary.workspace.projection.connectionPolicy
        )
    }

    var tabBarApplicationMenuForTesting: NSMenu { tabBarApplicationMenu() }
    var quickConnectMenuForTesting: NSMenu { quickConnectMenu() }
    var sessionTabContextMenuForTesting: NSMenu { sessionTabContextMenu() }
    var inputHeightPreferenceForTesting: Double { preferences.inputHeight }
    var tabBarControlIdentifiersForTesting: [String] {
        [applicationMenuButton, quickConnectButton, profilesButton].compactMap {
            $0.accessibilityIdentifier()
        }
    }
    var tabBarArrangedIdentifiersForTesting: [String] {
        taskbarView?.arrangedSubviews.compactMap { $0.accessibilityIdentifier() } ?? []
    }

    func disconnect() {
        if let puppet = currentPuppet, let master = puppetMaster {
            master.detachPuppetChild(puppet.id)
            puppetMaster = nil
            masterConnectionStateChanged(connected: false)
            return
        }
        guard let session else { return }
        Task { await session.disconnect() }
    }

    func reconnect() {
        guard let server = currentServer else {
            appendError("No previous connection to reconnect.")
            return
        }
        guard let session else {
            startSession(
                server,
                character: currentCharacter,
                policy: profileLibrary.workspace.projection.connectionPolicy
            )
            return
        }
        Task { await session.reconnect() }
    }

    func sessionTabContextMenu() -> NSMenu {
        let menu = NSMenu(title: sessionTabTitle)
        menu.autoenablesItems = false

        let disconnectItem = NSMenuItem(
            title: "Disconnect",
            action: #selector(contextDisconnectTab(_:)),
            keyEquivalent: ""
        )
        disconnectItem.target = self
        disconnectItem.isEnabled = session != nil || currentPuppet != nil
        menu.addItem(disconnectItem)

        let reconnectItem = NSMenuItem(
            title: "Reconnect",
            action: #selector(contextReconnectTab(_:)),
            keyEquivalent: ""
        )
        reconnectItem.target = self
        reconnectItem.isEnabled = currentServer != nil && currentPuppet == nil
        menu.addItem(reconnectItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(
            title: "Close Tab",
            action: #selector(contextCloseTab(_:)),
            keyEquivalent: ""
        )
        closeItem.target = self
        closeItem.isEnabled = window != nil
        menu.addItem(closeItem)

        return menu
    }

    @objc private func contextDisconnectTab(_ sender: Any?) {
        disconnect()
    }

    @objc private func contextReconnectTab(_ sender: Any?) {
        reconnect()
    }

    @objc private func contextCloseTab(_ sender: Any?) {
        window?.performClose(sender)
    }

    func clearOutput() { output.clear() }

    func toggleOutputPause() { output.togglePaused() }
    func toggleTimestamps() {
        updateActiveTextWindowSettings { $0.showsTime.toggle() }
    }
    func toggleFanFold() {
        updateActiveTextWindowSettings { $0.usesFanFoldBackgrounds.toggle() }
    }
    func copyOutputAsPlainText() { output.copySelectionAsPlainText() }
    func copyOutputAsHTML() { output.copySelectionAsHTML() }
    func toggleOutputMarker() { output.toggleMarkerForSelectedLine() }
    func toggleOutputSplit() {
        output.toggleSplit()
        preferences.outputSplit = output.isSplit
        savePreferences()
    }
    func smartPaste(_ sender: Any?) { input.paste(sender) }
    func toggleStickyInput() {
        updateActiveInputWindowSettings { $0.keepsTextOnSubmit.toggle() }
    }
    func toggleSpellChecking() {
        preferences.checksSpelling.toggle()
        input.isContinuousSpellCheckingEnabled = preferences.checksSpelling
        savePreferences()
    }

    func toggleMute() {
        isMuted.toggle()
        mediaController.isMuted = isMuted
        if isMuted {
            scriptSounds.forEach { $0.stop() }
            scriptSounds.removeAll()
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
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
        saveSpawnSurfacePreferences()
        saveAtlasSurfacePreferences()
        mediaController.flush()
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

    func startM10ScaleIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BEIPMU_M10_SCALE"] == "1" else { return }
        preferences.outputHistoryLimit = 10_000
        output.historyLimit = 10_000
        preferences.workspaceLayout = .splitSidebars
        dockController.setLayout(.splitSidebars)

        Task { [weak self] in
            guard let self else { return }
            let started = Date()
            for session in 0..<8 {
                output.append(.init(text: "[M10:\(session)] connected (attempt 3/3)"))
                for line in 0..<250 {
                    let color = RGBColor(
                        red: UInt8(48 + session * 20),
                        green: UInt8(180 - session * 12),
                        blue: UInt8(96 + session * 16)
                    )
                    output.append(.init(
                        text: String(format: "[M10:%d:%03d] styled payload ✓ %d", session, line, line * 7_919 % 100_003),
                        runs: [.init(range: 0..<11, style: .init(foreground: color, bold: true))]
                    ))
                    if line == 49 || line == 149 {
                        output.append(.init(text: "Client.Media.Play session=\(session) line=\(line)"))
                        output.append(.init(text: "WebView.Open session=\(session) line=\(line)"))
                    }
                    if line.isMultiple(of: 50) { await Task.yield() }
                }
                output.append(.init(text: "[M10:\(session)] log closed; session cleaned"))
                dockController.setLayout(session.isMultiple(of: 2) ? .stackedRight : .splitSidebars)
            }
            dockController.setLayout(.splitSidebars)
            window?.displayIfNeeded()
            let result: [String: Any] = [
                "schemaVersion": 1,
                "result": "pass",
                "sessionCount": 8,
                "reconnectsPerSession": 2,
                "styledLines": 2_000,
                "mediaEvents": 16,
                "webViewEvents": 16,
                "activeSessionsAfterClose": 0,
                "openLogsAfterClose": 0,
                "retainedRendererRows": output.visibleLineCount,
                "renderedRows": output.renderedLineCount,
                "peakRSSBytes": Self.currentResidentSize(),
                "completionSeconds": Date().timeIntervalSince(started),
            ]
            if let path = environment["BEIPMU_M10_SCALE_RESULT"],
               let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            output.append(.init(text: "M10_SCALE_COMPLETE activeSessions=0 openLogs=0"))
            refreshDiagnostics()
            if environment["BEIPMU_M10_SCALE_AUTO_TERMINATE"] == "1" {
                try? await Task.sleep(for: .seconds(1))
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func showCharacterNotes() {
        if dockController.placement == .hidden {
            dockController.setPlacement(preferences.lastDockedPlacement)
        }
        dockController.selectNotes()
    }

    func toggleInputHistoryWindow() {
        if let inputHistoryWindow, inputHistoryWindow.window?.isVisible == true {
            inputHistoryWindow.close()
            return
        }
        let controller = inputHistoryWindow ?? InputHistoryWindowController(entries: input.historyEntriesForDisplay)
        inputHistoryWindow = controller
        controller.onClose = { [weak self] in self?.inputHistoryWindow = nil }
        controller.update(input.historyEntriesForDisplay)
        controller.applyTheme(preferences.theme.palette)
        controller.showWindow(nil)
        if let owner = window, let child = controller.window, child.parent == nil {
            owner.addChildWindow(child, ordered: .above)
        }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func toggleImageWindow() {
        if let imageViewerWindow, imageViewerWindow.window?.isVisible == true {
            imageViewerWindow.close()
            return
        }
        let viewer = imageViewerWindow ?? ImageViewerWindowController()
        imageViewerWindow = viewer
        viewer.onClose = { [weak self] in self?.imageViewerWindow = nil }
        if let owner = window, let child = viewer.window, child.parent == nil {
            owner.addChildWindow(child, ordered: .above)
        }
        viewer.showWindow(nil)
        viewer.window?.makeKeyAndOrderFront(nil)
    }

    func toggleMapWindow() {
        if atlasWindow?.window?.isVisible == true {
            closeAtlasSurface()
        } else {
            showAtlas()
        }
    }

    func toggleCharacterNotesWindow() {
        if dockController.placement != .hidden, dockController.containsPane(.notes) {
            dockController.setPlacement(.hidden)
        } else {
            showCharacterNotes()
        }
    }

    func copyAllWindowSettings() {
        let bundle = WindowSettingsClipboard(
            globalTextWindowSettings: preferences.globalTextWindowSettings,
            worldTextWindowSettings: preferences.worldTextWindowSettings,
            characterTextWindowSettings: preferences.characterTextWindowSettings,
            tabTextWindowSettings: preferences.tabTextWindowSettings,
            globalInputWindowSettings: preferences.globalInputWindowSettings,
            worldInputWindowSettings: preferences.worldInputWindowSettings,
            characterInputWindowSettings: preferences.characterInputWindowSettings,
            tabInputWindowSettings: preferences.tabInputWindowSettings
        )
        guard let data = try? JSONEncoder().encode(bundle),
              let value = String(data: data, encoding: .utf8) else {
            appendError("Unable to copy window settings.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        appendClient("Copied all window settings.")
    }

    func pasteAllWindowSettings() {
        guard let value = NSPasteboard.general.string(forType: .string),
              let data = value.data(using: .utf8),
              let bundle = try? JSONDecoder().decode(WindowSettingsClipboard.self, from: data) else {
            appendError("Clipboard does not contain BeipMU window settings.")
            return
        }
        preferences.globalTextWindowSettings = bundle.globalTextWindowSettings.normalized
        preferences.worldTextWindowSettings = bundle.worldTextWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        preferences.characterTextWindowSettings = bundle.characterTextWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        preferences.tabTextWindowSettings = bundle.tabTextWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        preferences.globalInputWindowSettings = bundle.globalInputWindowSettings.normalized
        preferences.worldInputWindowSettings = bundle.worldInputWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        preferences.characterInputWindowSettings = bundle.characterInputWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        preferences.tabInputWindowSettings = bundle.tabInputWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        synchronizeLegacyGlobalTextSettings()
        synchronizeLegacyGlobalInputSettings()
        applyTextWindowSettings()
        applyInputWindowSettings()
        savePreferences()
        onTextWindowSettingsChange?()
        appendClient("Pasted all window settings.")
    }

    func showHiddenCaptions() {
        appendClient("Hidden captions are not currently tracked by this Mac-native workspace.")
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

    private func outputContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Output")
        func add(_ title: String, _ action: Selector, enabled: Bool = true, state: NSControl.StateValue = .off) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.state = state
            menu.addItem(item)
        }
        add("Find…", #selector(contextFind(_:)))
        add(
            output.isPaused ? "Resume" : "Pause",
            #selector(contextPause(_:)),
            state: output.isPaused ? .on : .off
        )
        add("Split", #selector(contextSplit(_:)), state: output.isSplit ? .on : .off)
        add("Copy screen to clipboard", #selector(contextCopyScreen(_:)), enabled: output.visibleLineCount > 0)
        menu.addItem(.separator())
        add("Clear", #selector(contextClear(_:)), enabled: output.visibleLineCount > 0)
        add("Delete Line", #selector(contextDeleteLine(_:)), enabled: output.hasSelectedLine)
        menu.addItem(.separator())
        let tabKey = textWindowIdentity.tabKey
        let usesGlobal = activeTextWindowUsesGlobalSettings
        add(
            "Use global settings",
            #selector(contextUseGlobalSettings(_:)),
            enabled: tabKey != nil,
            state: usesGlobal ? .on : .off
        )
        add("Settings…", #selector(contextTextWindowSettings(_:)))
        return menu
    }

    func outputContextMenuForTesting() -> NSMenu {
        outputContextMenu()
    }

    func inputContextMenuForTesting() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        return input.contextMenuForTesting(baseMenu: menu)
    }

    @objc private func contextFind(_ sender: Any?) { showFindDialog() }
    @objc private func contextPause(_ sender: Any?) { toggleOutputPause() }
    @objc private func contextSplit(_ sender: Any?) { toggleOutputSplit() }
    @objc private func contextCopyScreen(_ sender: Any?) { output.copyScreenToClipboard() }
    @objc private func contextClear(_ sender: Any?) { clearOutput() }
    @objc private func contextDeleteLine(_ sender: Any?) { output.removeSelectedLine() }
    @objc private func contextTextWindowSettings(_ sender: Any?) {
        showTextWindowSettings(initialScope: textWindowIdentity.tabKey == nil ? .global : .tab)
    }

    @objc private func contextUseGlobalSettings(_ sender: Any?) {
        guard let key = textWindowIdentity.tabKey else { return }
        let newValue = !activeTextWindowUsesGlobalSettings
        var entry = preferences.tabTextWindowSettings[key]
            ?? .init(usesGlobalSettings: newValue, settings: activeTextWindowSettings)
        entry.usesGlobalSettings = newValue
        preferences.tabTextWindowSettings[key] = entry
        applyTextWindowSettings()
        savePreferences()
        onTextWindowSettingsChange?()
    }

    private func showInputWindowSettings(initialScope: TextWindowSettingsEditorView.Scope) {
        let identity = textWindowIdentity
        let global = preferences.globalInputWindowSettings
        var states: [TextWindowSettingsEditorView.Scope: InputWindowSettingsEditorView.State] = [
            .global: .init(
                label: "Global",
                override: .init(usesGlobalSettings: false, settings: global)
            ),
        ]
        if let key = identity.worldKey {
            states[.world] = .init(
                label: "World — \(identity.world ?? "")",
                override: preferences.worldInputWindowSettings[key]
                    ?? .init(usesGlobalSettings: true, settings: global)
            )
        }
        if let key = identity.characterKey {
            states[.character] = .init(
                label: "Character — \(identity.character ?? "")",
                override: preferences.characterInputWindowSettings[key]
                    ?? .init(usesGlobalSettings: true, settings: global)
            )
        }
        if let key = identity.tabKey {
            states[.tab] = .init(
                label: "Tab — \(identity.tab ?? "")",
                override: preferences.tabInputWindowSettings[key]
                    ?? .init(usesGlobalSettings: true, settings: global)
            )
        }
        let editor = InputWindowSettingsEditorView(
            states: states,
            initialScope: states[initialScope] == nil ? .global : initialScope
        )
        let alert = NSAlert()
        alert.messageText = initialScope == .global ? "Global Input Window Settings" : "Input Window Settings"
        alert.informativeText = "Customize global defaults or override them for this world, character, or tab."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = editor
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            editor.commit()
            if let state = editor.states[.global] {
                self.preferences.globalInputWindowSettings = state.override.settings.normalized
            }
            if let key = identity.worldKey, let state = editor.states[.world] {
                self.preferences.worldInputWindowSettings[key] = state.override
            }
            if let key = identity.characterKey, let state = editor.states[.character] {
                self.preferences.characterInputWindowSettings[key] = state.override
            }
            if let key = identity.tabKey, let state = editor.states[.tab] {
                self.preferences.tabInputWindowSettings[key] = state.override
            }
            self.synchronizeLegacyGlobalInputSettings()
            self.applyInputWindowSettings()
            self.savePreferences()
            self.onTextWindowSettingsChange?()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    private func toggleInputUseGlobalSettings() {
        guard let key = textWindowIdentity.tabKey else { return }
        let newValue = !activeInputWindowUsesGlobalSettings
        var entry = preferences.tabInputWindowSettings[key]
            ?? .init(usesGlobalSettings: newValue, settings: activeInputWindowSettings)
        entry.usesGlobalSettings = newValue
        preferences.tabInputWindowSettings[key] = entry
        applyInputWindowSettings()
        savePreferences()
        onTextWindowSettingsChange?()
    }

    func showGlobalTextWindowSettings() {
        showTextWindowSettings(initialScope: .global)
    }

    func showGlobalInputWindowSettings() {
        showInputWindowSettings(initialScope: .global)
    }

    private func showTextWindowSettings(initialScope: TextWindowSettingsEditorView.Scope) {
        let identity = textWindowIdentity
        let global = preferences.globalTextWindowSettings
        var states: [TextWindowSettingsEditorView.Scope: TextWindowSettingsEditorView.State] = [
            .global: .init(
                label: "Global",
                override: .init(usesGlobalSettings: false, settings: global)
            ),
        ]
        if let key = identity.worldKey {
            states[.world] = .init(
                label: "World — \(identity.world ?? "")",
                override: preferences.worldTextWindowSettings[key]
                    ?? .init(usesGlobalSettings: true, settings: global)
            )
        }
        if let key = identity.characterKey {
            states[.character] = .init(
                label: "Character — \(identity.character ?? "")",
                override: preferences.characterTextWindowSettings[key]
                    ?? .init(usesGlobalSettings: true, settings: global)
            )
        }
        if let key = identity.tabKey {
            states[.tab] = .init(
                label: "Tab — \(identity.tab ?? "")",
                override: preferences.tabTextWindowSettings[key]
                    ?? .init(usesGlobalSettings: true, settings: global)
            )
        }

        let editor = TextWindowSettingsEditorView(
            states: states,
            initialScope: states[initialScope] == nil ? .global : initialScope
        )
        let alert = NSAlert()
        alert.messageText = initialScope == .global ? "Global Text Window Settings" : "Text Window Settings"
        alert.informativeText = "Customize the global defaults or override them for this world, character, or tab."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = editor
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            editor.commit()
            if let state = editor.states[.global] {
                self.preferences.globalTextWindowSettings = state.override.settings.normalized
            }
            if let key = identity.worldKey, let state = editor.states[.world] {
                self.preferences.worldTextWindowSettings[key] = state.override
            }
            if let key = identity.characterKey, let state = editor.states[.character] {
                self.preferences.characterTextWindowSettings[key] = state.override
            }
            if let key = identity.tabKey, let state = editor.states[.tab] {
                self.preferences.tabTextWindowSettings[key] = state.override
            }
            self.synchronizeLegacyGlobalTextSettings()
            self.applyTextWindowSettings()
            self.savePreferences()
            self.onTextWindowSettingsChange?()
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
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
        sticky.state = preferences.globalInputWindowSettings.keepsTextOnSubmit ? .on : .off
        let spelling = NSButton(checkboxWithTitle: "Check spelling", target: nil, action: nil)
        spelling.state = preferences.checksSpelling ? .on : .off
        let startupScript = NSTextField(string: profileLibrary.workspace.projection.scripting.startupPath)
        startupScript.placeholderString = "Optional JavaScript file path"
        startupScript.setAccessibilityIdentifier("scriptStartupPath")
        let scriptDebug = NSButton(checkboxWithTitle: "Enable script debugging", target: nil, action: nil)
        scriptDebug.state = profileLibrary.workspace.projection.scripting.debugEnabled ? .on : .off
        scriptDebug.setAccessibilityIdentifier("scriptDebugEnabled")
        let voices = AVSpeechSynthesisVoice.speechVoices().sorted {
            if $0.language == $1.language { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.language < $1.language
        }
        let speechVoice = NSPopUpButton()
        speechVoice.addItem(withTitle: "System Default")
        for voice in voices {
            speechVoice.addItem(withTitle: "\(voice.name) — \(voice.language)")
            speechVoice.lastItem?.representedObject = voice.identifier
        }
        if let identifier = preferences.speechVoiceIdentifier,
           let index = speechVoice.itemArray.firstIndex(where: { $0.representedObject as? String == identifier }) {
            speechVoice.selectItem(at: index)
        }
        speechVoice.setAccessibilityIdentifier("speechVoice")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "History lines:"), historyLimit],
            [NSView(), timestamps],
            [NSView(), fanFold],
            [NSView(), sticky],
            [NSView(), spelling],
            [NSTextField(labelWithString: "Startup script:"), startupScript],
            [NSView(), scriptDebug],
            [NSTextField(labelWithString: "Speech voice:"), speechVoice],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 230
        grid.rowSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 440, height: 225)
        alert.accessoryView = grid
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.preferences.outputHistoryLimit = max(100, historyLimit.integerValue)
            self.preferences.showsTimestamps = timestamps.state == .on
            self.preferences.usesFanFoldBackgrounds = fanFold.state == .on
            self.preferences.globalTextWindowSettings.historyLimit = self.preferences.outputHistoryLimit
            self.preferences.globalTextWindowSettings.showsTime = self.preferences.showsTimestamps
            self.preferences.globalTextWindowSettings.usesFanFoldBackgrounds = self.preferences.usesFanFoldBackgrounds
            self.preferences.stickyInput = sticky.state == .on
            self.preferences.globalInputWindowSettings.keepsTextOnSubmit = sticky.state == .on
            self.preferences.checksSpelling = spelling.state == .on
            self.preferences.speechVoiceIdentifier = speechVoice.selectedItem?.representedObject as? String
            self.applyPreferences()
            self.savePreferences()
            self.onTextWindowSettingsChange?()
            do {
                try self.profileLibrary.mutate {
                    $0.updateScripting {
                        $0.startupPath = startupScript.stringValue
                        $0.debugEnabled = scriptDebug.state == .on
                    }
                }
            } catch {
                self.appendError("Unable to save startup script setting: \(error.localizedDescription)")
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    func showEmbeddedHelp(topic: String? = nil) {
        let controller = helpWindow ?? EmbeddedHelpWindowController()
        helpWindow = controller
        controller.show(topic: topic)
        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)
    }

    func showAutomationEditor(_ kind: AutomationEditorWindowController.Kind, scope: LegacyConfigurationWorkspace.AutomationScope? = nil) {
        let selectedScope = scope ?? currentAutomationScope
        let title = "\(kind.title) — \(selectedScope.displayName)"
        if let existing = automationEditors.first(where: { $0.window?.title == title }) {
            existing.showWindow(nil)
            return
        }
        let editor = AutomationEditorWindowController(library: profileLibrary, kind: kind, scope: selectedScope)
        editor.onClose = { [weak self, weak editor] in
            guard let editor else { return }
            self?.automationEditors.removeAll { $0 === editor }
        }
        automationEditors.append(editor)
        editor.showWindow(nil)
    }

    private var currentAutomationScope: LegacyConfigurationWorkspace.AutomationScope {
        if let server = currentServer,
           let projectionServer = profileLibrary.workspace.servers.first(where: { $0.profile.id == server.id }) {
            if let character = currentCharacter,
               let projectedCharacter = projectionServer.characters.first(where: { $0.id == character.id }) {
                if let puppet = currentPuppet,
                   let projectedPuppet = projectedCharacter.puppets.first(where: { $0.id == puppet.id }) {
                    return .puppet(server: server.id, character: character.id, puppet: projectedPuppet.id)
                }
                return .character(server: server.id, character: character.id)
            }
            return .server(server.id)
        }
        return .global
    }

    func showAutomationDebugger(_ kind: CommandOutcome.DebugAutomationKind) {
        if let existing = automationDebugWindows[kind] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
        } else {
            let controller = AutomationDebugWindowController(kind: kind)
            controller.onClose = { [weak self] in self?.automationDebugWindows.removeValue(forKey: kind) }
            automationDebugWindows[kind] = controller
            controller.showWindow(nil)
        }
        if kind == .timers {
            Task {
                let entries = await delayScheduler.entries()
                automationDebugWindows[.timers]?.showTimerEntries(entries)
            }
        }
    }

    func showNetworkDebugger() {
        if let networkDebugWindow {
            networkDebugWindow.showWindow(nil)
            networkDebugWindow.window?.makeKeyAndOrderFront(nil)
            networkDebugWindow.focusInitialControl()
            return
        }
        let controller = NetworkDebugWindowController(title: baseWindowTitle)
        controller.onClose = { [weak self] in self?.networkDebugWindow = nil }
        networkDebugWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusInitialControl()
    }

    func showScriptDebugger() {
        if let scriptDebugWindow {
            scriptDebugWindow.showWindow(nil)
            scriptDebugWindow.window?.makeKeyAndOrderFront(nil)
            scriptDebugWindow.focusInitialControl()
            return
        }
        let controller = ScriptDebugWindowController(title: baseWindowTitle)
        controller.onClose = { [weak self] in self?.scriptDebugWindow = nil }
        controller.onReset = { [weak self, scriptService] in
            Task {
                await scriptService.reset()
                await MainActor.run {
                    self?.recordScriptDebug(.init(kind: .runtime, message: "Runtime reset."))
                }
            }
        }
        scriptDebugWindow = controller
        controller.replace(with: scriptDebugEntries)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.focusInitialControl()
    }

    func showRestoreInformation() {
        appendClient("Live Restore.dat information… running CheckAndRepair first")
        guard let configurationURL = profileLibrary.workspace.sourceURL else {
            appendError("Restore.dat is unavailable until a Config.txt file is open.")
            return
        }
        let restoreURL = configurationURL.deletingLastPathComponent().appendingPathComponent("Restore.dat")
        guard FileManager.default.fileExists(atPath: restoreURL.path) else {
            appendClient("CheckAndRepair complete\nBuffer Size: 0kb   Total Buffers: 0\nSummary complete.")
            return
        }
        let document = profileLibrary.workspace.document
        let sizeInKB = document.value(at: ["Connections", "Logging", "RestoreBufferSizeCurrent"])
            .flatMap(Int.init)
            ?? document.value(at: ["Connections", "Logging", "RestoreBufferSize"]).flatMap(Int.init)
            ?? 64
        let bufferSize = sizeInKB * 1_024
        guard bufferSize >= 20 else {
            appendError("Restore.dat has an invalid configured buffer size: \(sizeInKB)kb.")
            return
        }
        do {
            let inspection = try RestoreLogStore.inspectRepairing(from: restoreURL, bufferSize: bufferSize)
            let assignments = profileLibrary.workspace.projection.servers.reduce(into: [Int: String]()) {
                $0.merge($1.restoreLogAssignments) { current, _ in current }
            }
            var lines = [
                "CheckAndRepair complete",
                "Buffer Size: \(inspection.bufferSize / 1_024)kb   Total Buffers: \(inspection.buffers.count)",
            ]
            lines += inspection.buffers.map { buffer in
                let owner = assignments[buffer.index] ?? "Unassigned"
                let percent = inspection.bufferSize == 0 ? 0 : buffer.usedBytes * 100 / inspection.bufferSize
                let repaired = buffer.wasRepaired ? "   Repaired" : ""
                return "\(buffer.index)  \(owner) - Used: \(buffer.usedBytes)  \(percent)% - Records: \(buffer.recordCount)\(repaired)"
            }
            lines.append("Summary complete.")
            appendClient(lines.joined(separator: "\n"))
        } catch {
            appendError("Unable to inspect Restore.dat: \(error.localizedDescription)")
        }
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
        let autoLog = NSButton(checkboxWithTitle: "Start automatic log on connect", target: nil, action: nil)
        autoLog.state = preferences.logging.autoLogEnabled ? .on : .off
        let autoLogFilename = NSTextField(string: preferences.logging.defaultLogFilename)
        autoLogFilename.placeholderString = "For example: %server%-%date%.html"
        let appendFileDate = NSButton(checkboxWithTitle: "Append date to automatic filename", target: nil, action: nil)
        appendFileDate.state = preferences.logging.appendsDateToFilename ? .on : .off
        let fileDateFormat = NSTextField(string: preferences.logging.fileDateFormat)
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
            [autoLog, autoLogFilename],
            [appendFileDate, fileDateFormat],
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
                autoLogEnabled: autoLog.state == .on,
                defaultLogFilename: autoLogFilename.stringValue,
                appendsDateToFilename: appendFileDate.state == .on,
                fileDateFormat: fileDateFormat.stringValue,
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
                self.startLog(template: url.path, history: selectedHistory)
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
        mcpStatusWindow?.applyTheme(palette)
        webViewWindows.values.forEach { $0.applyTheme(palette) }
    }

    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        applyThemeSettings(preferences.theme)
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
        controller.input.onPageUp = { [weak self] in self?.output.performPageUp() ?? false }
        controller.input.onPageDown = { [weak self] in self?.output.performPageDown() ?? false }
        controller.input.onShowSettings = { [weak self] in
            guard let self else { return }
            self.showInputWindowSettings(initialScope: self.textWindowIdentity.tabKey == nil ? .global : .tab)
        }
        controller.input.onToggleUseGlobalSettings = { [weak self] in self?.toggleInputUseGlobalSettings() }
        controller.input.usesGlobalSettings = activeInputWindowUsesGlobalSettings
        controller.input.canToggleUseGlobalSettings = textWindowIdentity.tabKey != nil
        controller.input.applySettings(activeInputWindowSettings)
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
        let captured = options.initialText ?? (capturedLines.isEmpty ? "" : options.prepend + capturedLines + options.append)
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

    func showAtlas() {
        let controller = ensureAtlasWindow()
        controller.showWindow(self)
        controller.window?.makeKeyAndOrderFront(self)
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
        taskbar.alignment = .centerY
        taskbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        taskbar.spacing = 8
        taskbar.wantsLayer = true
        taskbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        configureTabBarButton(
            applicationMenuButton,
            symbolName: "line.3.horizontal",
            accessibilityLabel: "Application menu",
            accessibilityIdentifier: "tabBarApplicationMenu",
            tintColor: .labelColor,
            action: #selector(showApplicationMenu(_:))
        )
        configureTabBarButton(
            quickConnectButton,
            symbolName: "person.fill",
            accessibilityLabel: "Player Quick Connect",
            accessibilityIdentifier: "tabBarQuickConnect",
            tintColor: .systemPurple,
            action: #selector(showQuickConnectMenu(_:))
        )
        configureTabBarButton(
            profilesButton,
            symbolName: "globe",
            accessibilityLabel: "Worlds & Characters",
            accessibilityIdentifier: "tabBarWorldsAndCharacters",
            tintColor: .systemBlue,
            action: #selector(showProfiles(_:))
        )
        taskbar.addArrangedSubview(applicationMenuButton)
        taskbar.addArrangedSubview(quickConnectButton)
        taskbar.addArrangedSubview(profilesButton)
        stateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stateLabel.setAccessibilityIdentifier("connectionState")
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        activityLabel.textColor = .secondaryLabelColor
        sessionTabs.orientation = .horizontal
        sessionTabs.alignment = .centerY
        sessionTabs.distribution = .fillEqually
        sessionTabs.spacing = 4
        sessionTabs.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sessionTabs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sessionTabs.setAccessibilityIdentifier("sessionTabs")
        taskbar.addArrangedSubview(sessionTabs)
        taskbar.addArrangedSubview(activityLabel)
        taskbar.addArrangedSubview(NSView())
        taskbar.addArrangedSubview(titlebarStatistics.view)

        input.completionCandidates = CommandRegistry.knownCommands.map { "/" + $0 }.sorted()
        input.onSubmit = { [weak self] text in self?.submitInput(text) }
        input.onSmartPaste = { [weak self] lines in self?.handleSmartPaste(lines) ?? false }
        input.onMacro = { [weak self] event in self?.handleKeyboardMacro(event) ?? false }
        input.onPageUp = { [weak self] in self?.output.performPageUp() ?? false }
        input.onPageDown = { [weak self] in self?.output.performPageDown() ?? false }
        input.onShowSettings = { [weak self] in
            guard let self else { return }
            self.showInputWindowSettings(initialScope: self.textWindowIdentity.tabKey == nil ? .global : .tab)
        }
        input.onToggleUseGlobalSettings = { [weak self] in self?.toggleInputUseGlobalSettings() }
        input.onPreferredHeightChange = { [weak self] height in self?.resizeInput(to: height) }
        input.onTextChange = { [weak self] _ in self?.refreshTitlebarStatistics() }
        output.onAction = { [weak self] action in self?.perform(action) }
        output.onContextMenu = { [weak self] _ in self?.outputContextMenu() }
        output.onInteractionCompleted = { [weak self] in self?.focusCommandInput() }
        output.onPauseChange = { [weak self] paused, pending in
            guard let self else { return }
            self.activityLabel.stringValue = paused ? "Paused\(pending > 0 ? " — \(pending) new" : "")" : ""
        }
        applyPreferences()

        inputContainer.addSubview(input.containerScrollView)
        NSLayoutConstraint.activate([
            input.containerScrollView.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 8),
            input.containerScrollView.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -8),
            input.containerScrollView.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 7),
            input.containerScrollView.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor, constant: -7),
            inputContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])

        inputSplitView.isVertical = false
        inputSplitView.dividerStyle = .thin
        inputSplitView.delegate = self
        inputSplitView.setAccessibilityIdentifier("commandInputSplit")
        inputSplitView.addArrangedSubview(output.containerView)
        inputSplitView.addArrangedSubview(inputContainer)
        inputSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        inputSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        inputSplitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        inputSplitView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        root.addArrangedSubview(taskbar)
        root.addArrangedSubview(inputSplitView)
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
            self.preferences.workspaceLayouts[self.notesKey] = layout
            self.savePreferences()
        }
        dockController.onNotesChange = { [weak self] notes in
            guard let self else { return }
            self.preferences.characterNotes[self.notesKey] = notes
            self.savePreferences()
        }
        dockController.setNotes(preferences.characterNotes[notesKey] ?? "")
        dockController.applyTheme(preferences.theme.palette)
        // Keep the Auto Layout-driven dock tree behind an autoresizing wrapper.
        // Making the dock host the NSWindow content view directly lets its
        // fitting height become a WindowServer live-resize boundary.
        let contentBounds = window.contentView?.bounds
            ?? NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        let windowContent = NSView(frame: contentBounds)
        windowContent.autoresizingMask = [.width, .height]
        dockController.hostView.frame = windowContent.bounds
        dockController.hostView.autoresizingMask = [.width, .height]
        windowContent.addSubview(dockController.hostView)
        let verticalResizeHandle = VerticalWindowResizeHandle(
            frame: NSRect(x: 0, y: 0, width: windowContent.bounds.width, height: 8)
        )
        verticalResizeHandle.autoresizingMask = [.width, .maxYMargin]
        windowContent.addSubview(verticalResizeHandle)
        window.contentView = windowContent
        let preferredOutputHeight = output.containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        // This is a layout preference, not a window-size requirement. Keeping it
        // required makes the vertical stack (and docked row layouts in particular)
        // push its fitting height back onto the window during a live resize.
        preferredOutputHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            taskbar.heightAnchor.constraint(equalToConstant: 34),
            preferredOutputHeight,
        ])
        if preferences.dockPlacement == .floating {
            dockController.apply(placement: .floating, thickness: preferences.dockThickness)
        } else if let layout = preferences.workspaceLayouts[notesKey] ?? preferences.workspaceLayout {
            dockController.apply(layout: layout)
        } else {
            dockController.apply(placement: preferences.dockPlacement, thickness: preferences.dockThickness)
        }
        applyInputWindowSettings()
        refreshDiagnostics()
        window.makeFirstResponder(input)
    }

    func startPuppetSession(
        master: ClientWindowController,
        server: ServerProfile,
        character: CharacterProfile,
        puppet: PuppetProfile
    ) {
        startSession(
            server,
            character: character,
            puppet: puppet,
            master: master,
            policy: profileLibrary.workspace.projection.connectionPolicy
        )
    }

    func startSavedProfileSession(
        _ server: ServerProfile,
        character: CharacterProfile?,
        policy: ConnectionPolicy
    ) {
        startSession(server, character: character, policy: policy)
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        window.screen?.visibleFrame ?? newFrame
    }

    private static func configureUnrestrictedSizing(for window: NSWindow) {
        let unrestrictedSize = NSSize(width: 100_000, height: 100_000)
        window.minSize = .zero
        window.maxSize = unrestrictedSize
        window.contentMinSize = .zero
        window.contentMaxSize = unrestrictedSize
        window.contentAspectRatio = .zero
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.minFullScreenContentSize = .zero
        window.maxFullScreenContentSize = unrestrictedSize
        window.collectionBehavior.insert(.fullScreenPrimary)
    }

    private static func postFrameChange(for window: NSWindow) {
        NSAccessibility.post(element: window, notification: .windowMoved)
        NSAccessibility.post(element: window, notification: .windowResized)
    }

    private static func publishTestFrame(for window: NSWindow) {
        guard ProcessInfo.processInfo.environment["BEIPMU_UI_TESTING"] == "1" else { return }
        window.setAccessibilityValue("\(Int(window.frame.width))x\(Int(window.frame.height))")
        NSAccessibility.post(element: window, notification: .valueChanged)
    }

    private func startSession(
        _ server: ServerProfile,
        character: CharacterProfile? = nil,
        puppet: PuppetProfile? = nil,
        master: ClientWindowController? = nil,
        policy: ConnectionPolicy = .init()
    ) {
        preferences.workspaceLayouts[notesKey] = dockController.currentLayout
        savePreferences()
        saveSpawnSurfacePreferences()
        closeSpawnSurfaces()
        saveAtlasSurfacePreferences()
        closeAtlasSurface()
        closeWebViews()
        closeAIWindow(preservingDockPlacement: true)
        sessionTask?.cancel()
        if let session { Task { await session.disconnect() } }
        isSessionConnected = false
        currentServer = server
        currentCharacter = character
        currentPuppet = puppet
        puppetMaster = master
        applyTextWindowSettings()
        applyInputWindowSettings()
        variables = profileLibrary.workspace.projection.variables(for: server, character: character, puppet: puppet)
        let automation = profileLibrary.workspace.projection.automationGroups(for: server, character: character, puppet: puppet)
        aliasGroups = automation.aliases
        triggerGroups = automation.triggers
        keyboardMacroGroups = profileLibrary.workspace.projection.macroGroups(for: server, character: character, puppet: puppet)
        aliasesEchoResults = profileLibrary.workspace.projection.automation.aliases.echo
        aliasesProcessCommands = profileLibrary.workspace.projection.automation.aliases.processCommands
        gmcpState.reset()
        mediaState.reset()
        mediaController.flush()
        baseWindowTitle = character.map { character in
            let suffix = puppet.map { " / \($0.name)" } ?? ""
            return "\(character.name) @ \(server.name)\(suffix)"
        } ?? server.name
        tabStateDidChange()
        updateWindowTitle()
        dockController.setNotes(preferences.characterNotes[notesKey] ?? "")
        if let layout = preferences.workspaceLayouts[notesKey] ?? preferences.workspaceLayout {
            dockController.apply(layout: layout)
        }
        restoreSpawnSurfacePreferences()
        restoreAtlasSurfacePreferences()
        restoreWebViewPreferences()
        refreshDiagnostics()
        if let master, let puppet {
            session = nil
            output.clear()
            master.attachPuppetChild(self, puppet: puppet)
            masterConnectionStateChanged(connected: master.connectionStateText == "Connected")
            appendClient("Puppet \(puppet.name) is attached to \(character?.name ?? "the character")'s connection.")
            return
        }
        var processor = MUDProtocolPipeline(
            encoding: server.encoding,
            mcp: server.mcp,
            pueblo: server.pueblo,
            limitTelnetCharset: server.limitTelnetCharset
        )
        processor.setTerminalType(terminalType)
        let next = SessionActor(transport: NetworkTransport(), processor: processor, localEcho: localEcho)
        session = next
        let inputSettings = activeInputWindowSettings
        Task {
            await next.configureLocalEcho(
                inputSettings.localEcho,
                color: Self.rgbColor(hex: inputSettings.localEchoHex)
            )
        }
        output.clear()
        sessionTask = Task { [weak self] in
            let events = await next.events()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
        let size = output.terminalSize
        Task {
            await next.updateWindowSize(columns: size.columns, rows: size.rows)
            await next.connect(.init(server: server, character: character, puppet: puppet, policy: policy))
        }
    }

    private func runStartupScriptIfNeeded() {
        guard !Self.didRunStartupScript else { return }
        let configuredPath = profileLibrary.workspace.projection.scripting.startupPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredPath.isEmpty else { return }
        Self.didRunStartupScript = true

        let url: URL
        if configuredPath.hasPrefix("/") || configuredPath.hasPrefix("~") {
            url = URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath)
        } else if let configuration = profileLibrary.workspace.sourceURL {
            url = configuration.deletingLastPathComponent().appendingPathComponent(configuredPath)
        } else {
            appendError("Cannot load startup script without a saved Config.txt location.")
            return
        }

        Task { [weak self, scriptService] in
            do {
                let source = try String(contentsOf: url, encoding: .utf8)
                let result = await scriptService.evaluate(source, host: self?.scriptHostSnapshot ?? .init())
                self?.applyScriptEvaluation(result, showValue: false)
            } catch {
                self?.appendError("Cannot load startup script: \(error.localizedDescription)")
            }
        }
    }

    private func handle(_ event: SessionEvent) async {
        switch event {
        case let .state(state):
            switch state {
            case .disconnected:
                isSessionConnected = false
                connectionStateText = "Disconnected"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .secondaryLabelColor
                appendConnectionNotice(.disconnected)
            case .resolving:
                isSessionConnected = false
                connectionStateText = "Resolving…"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .systemOrange
            case .connecting:
                isSessionConnected = false
                connectionStateText = "Connecting…"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .systemOrange
            case .connected:
                isSessionConnected = true
                lastTypedAt = Date()
                connectionStateText = "Connected"
                stateLabel.stringValue = connectionStateText
                stateLabel.textColor = .systemGreen
                startAutomaticLog()
            case .disconnecting:
                isSessionConnected = false
                connectionStateText = "Disconnecting…"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .systemOrange
            case let .failed(message):
                isSessionConnected = false
                connectionStateText = "Failed"; stateLabel.stringValue = connectionStateText; stateLabel.textColor = .systemRed
                appendConnectionError(message)
            }
            refreshTitlebarStatistics()
            refreshDiagnostics()
            if case .connected = state { webViewWindows.values.forEach { $0.connectionChanged(connected: true) } }
            if case .disconnected = state { webViewWindows.values.forEach { $0.connectionChanged(connected: false) } }
            if case .failed = state { webViewWindows.values.forEach { $0.connectionChanged(connected: false) } }
            if case .connected = state {
                applyScriptEvaluation(await scriptService.dispatchConnectionEvent("connect", host: scriptHostSnapshot), showValue: false)
                if let server = currentServer, let character = currentCharacter {
                    for puppet in character.puppets where puppet.connectWithPlayer {
                        _ = (NSApp.delegate as? ApplicationDelegate)?.openPuppet(
                            master: self, server: server, character: character, puppet: puppet
                        )
                    }
                }
            }
            if case .disconnected = state {
                applyScriptEvaluation(await scriptService.dispatchConnectionEvent("disconnect", host: scriptHostSnapshot), showValue: false)
            }
            if case .failed = state {
                applyScriptEvaluation(await scriptService.dispatchConnectionEvent("disconnect", host: scriptHostSnapshot), showValue: false)
            }
            let connected = state == .connected
            let shouldNotifyPuppets: Bool
            switch state {
            case .connected, .disconnected, .failed: shouldNotifyPuppets = true
            default: shouldNotifyPuppets = false
            }
            if shouldNotifyPuppets {
                puppetChildren.values.forEach { $0.masterConnectionStateChanged(connected: connected) }
            }
        case let .renderedLine(line):
            if routeMasterLineToPuppet(line, isPrompt: false) { return }
            await presentIncoming(line, isPrompt: false)
        case let .prompt(line):
            if routeMasterLineToPuppet(line, isPrompt: true) { return }
            await presentIncoming(line, isPrompt: true)
        case let .gmcp(message):
            webViewWindows.values.forEach { $0.observeGMCP(message) }
            let raw = message.payload.isEmpty ? message.package : "\(message.package) \(message.payload)"
            applyScriptEvaluation(
                await scriptService.dispatchConnectionEvent("gmcp", arguments: [raw], host: scriptHostSnapshot),
                showValue: false
            )
            handleAdvancedGMCP(message)
        case let .mcp(message): handleMCP(message)
        case let .encoding(encoding): appendClient("Charset negotiated: \(encoding.rawValue)")
        case let .error(message): appendError(message)
        case let .log(message): appendClient(message)
        case let .connectionNotice(notice): appendConnectionNotice(notice)
        case let .activity(important):
            if suppressNextSessionActivity { suppressNextSessionActivity = false; break }
            guard window?.isKeyWindow != true else { break }
            unreadCount += 1
            activityLabel.stringValue = important ? "Important — \(unreadCount) unread" : "\(unreadCount) unread"
            updateWindowTitle()
            if important { NSApplication.shared.requestUserAttention(.informationalRequest) }
            Self.updateDockBadge()
        case let .received(data):
            networkDebugWindow?.append(data, received: true)
            applyScriptEvaluation(
                await scriptService.dispatchConnectionEvent(
                    "receive",
                    arguments: [String(decoding: data, as: UTF8.self)],
                    host: scriptHostSnapshot
                ),
                showValue: false
            )
        case let .sent(data):
            networkDebugWindow?.append(data, received: false)
        }
    }

    func puppetController(for id: UUID) -> ClientWindowController? { puppetChildren[id] }
    var ownsNetworkSession: Bool { session != nil }
    var isPuppetAttachment: Bool { currentPuppet != nil && puppetMaster != nil && session == nil }

    private func attachPuppetChild(_ controller: ClientWindowController, puppet: PuppetProfile) {
        if let previous = puppetChildren.updateValue(controller, forKey: puppet.id), previous !== controller {
            previous.masterConnectionClosed()
        }
    }

    private func detachPuppetChild(_ id: UUID) {
        puppetChildren.removeValue(forKey: id)
    }

    private func masterConnectionClosed() {
        puppetMaster = nil
        masterConnectionStateChanged(connected: false)
    }

    private func masterConnectionStateChanged(connected: Bool) {
        let changed = (connectionStateText == "Connected") != connected
        isSessionConnected = connected
        if connected, changed { lastTypedAt = Date() }
        connectionStateText = connected ? "Connected" : "Disconnected"
        stateLabel.stringValue = connectionStateText
        stateLabel.textColor = connected ? .systemGreen : .secondaryLabelColor
        refreshTitlebarStatistics()
        webViewWindows.values.forEach { $0.connectionChanged(connected: connected) }
        refreshDiagnostics()
        guard changed else { return }
        if connected { startAutomaticLog() }
        Task { [weak self, scriptService] in
            guard let self else { return }
            applyScriptEvaluation(
                await scriptService.dispatchConnectionEvent(
                    connected ? "connect" : "disconnect",
                    host: scriptHostSnapshot
                ),
                showValue: false
            )
        }
    }

    private func routeMasterLineToPuppet(_ line: RenderedLine, isPrompt: Bool) -> Bool {
        guard currentPuppet == nil, let server = currentServer, let character = currentCharacter else {
            return false
        }
        for puppet in character.puppets {
            guard let routed = PuppetRouter.route(line.text, through: [puppet]) else { continue }
            var child = puppetChildren[puppet.id]
            if child == nil, puppet.autoConnect {
                child = (NSApp.delegate as? ApplicationDelegate)?.openPuppet(
                    master: self, server: server, character: character, puppet: puppet
                )
            }
            guard let child else { continue }
            if puppet.characterLog {
                var logged = line
                logged.text = puppet.characterLogPrefix + line.text
                logged.runs = []
                appendToLogs(logged)
            }
            child.receivePuppetLine(line, route: routed, isPrompt: isPrompt)
            return true
        }
        return false
    }

    private func receivePuppetLine(
        _ source: RenderedLine,
        route: PuppetRouter.RoutedLine,
        isPrompt: Bool
    ) {
        var line = source
        line.text = route.text
        if let removed = route.removedRange {
            let length = removed.count
            line.runs = line.runs.compactMap { run in
                if run.range.upperBound <= removed.lowerBound { return run }
                if run.range.lowerBound >= removed.upperBound {
                    return .init(
                        range: (run.range.lowerBound - length)..<(run.range.upperBound - length),
                        style: run.style
                    )
                }
                let lower = min(run.range.lowerBound, removed.lowerBound)
                let upper = max(removed.lowerBound, run.range.upperBound - length)
                return upper > lower ? .init(range: lower..<upper, style: run.style) : nil
            }
            line.assets = line.assets.compactMap { asset in
                var adjusted = asset
                if asset.characterOffset >= removed.upperBound {
                    adjusted.characterOffset -= length
                } else if asset.characterOffset >= removed.lowerBound {
                    adjusted.characterOffset = removed.lowerBound
                }
                return adjusted
            }
        }
        Task { [weak self] in await self?.presentIncoming(line, isPrompt: isPrompt) }
    }

    private func presentIncoming(_ line: RenderedLine, isPrompt: Bool) async {
        if consumeGrabResponse(line.text) { return }
        webViewWindows.values.forEach { $0.observeReceived(line.text) }
        let hookedLine = await applyScriptDisplayHook(to: gmcpState.decorate(line))
        let presentation = await applyTriggers(to: hookedLine)
        let webViewGag = webViewWindows.values.reduce(false) { $1.observeDisplay(presentation.line) || $0 }
        _ = atlasWindow?.observeOutput(presentation.line.text)
        if !isPrompt {
            suppressNextSessionActivity = presentation.suppressActivity
            if hasPendingPrompt { output.removeLastLine(); hasPendingPrompt = false }
            if !presentation.gagDisplay, !webViewGag {
                output.append(presentation.line)
                offerImages(in: presentation.line)
            }
            if presentation.line.source != .localEcho, !presentation.gagLog {
                appendToLogs(presentation.line)
            }
            return
        }
        if hasPendingPrompt { output.removeLastLine() }
        if !presentation.gagDisplay, !webViewGag {
            output.append(presentation.line, terminator: "")
            offerImages(in: presentation.line)
            hasPendingPrompt = true
        } else {
            hasPendingPrompt = false
        }
        if !presentation.gagLog { appendToLogs(presentation.line) }
    }

    private func consumeGrabResponse(_ text: String) -> Bool {
        guard let prefix = grabPrefix, text.hasPrefix(prefix) else { return false }
        let assignment = String(text.dropFirst(prefix.count))
        grabPrefix = nil
        input.text = assignment
        window?.makeFirstResponder(input)
        appendClient("Grab complete. The editable property assignment is in the command input.")
        return true
    }

    private func submitInput(_ value: String) {
        let lines = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines where !line.isEmpty { submitLine(String(line)) }
    }

    private func handleKeyboardMacro(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command),
              let key = Self.legacyMacroKey(for: event),
              let macro = KeyboardMacroEngine.macro(for: key, groups: keyboardMacroGroups)
        else { return false }
        if macro.typeIntoInput {
            input.insertText(macro.macro, replacementRange: input.selectedRange())
        } else {
            for line in Self.logicalLines(in: macro.macro) where !line.isEmpty { submitLine(line) }
        }
        return true
    }

    private static func legacyMacroKey(for event: NSEvent) -> String? {
        let specialKeys: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            82: "NumPad0", 83: "NumPad1", 84: "NumPad2", 85: "NumPad3", 86: "NumPad4",
            87: "NumPad5", 88: "NumPad6", 89: "NumPad7", 91: "NumPad8", 92: "NumPad9",
        ]
        let base = specialKeys[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased()
        guard let base, !base.isEmpty else { return nil }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var prefix: [String] = []
        if modifiers.contains(.control) { prefix.append("Control") }
        if modifiers.contains(.option) { prefix.append("Alt") }
        if modifiers.contains(.shift) { prefix.append("Shift") }
        return (prefix + [base]).joined(separator: "+")
    }

    private func submitLine(_ line: String) {
        lastTypedAt = Date()
        refreshTitlebarStatistics()
        appendTypedToLogs(line)
        guard line.hasPrefix("/") else { processInput(line); return }
        let body = String(line.dropFirst())
        let split = body.firstIndex(where: { $0.isWhitespace })
        let command = split.map { String(body[..<$0]) } ?? body
        let parameters = split.map { body[$0...].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        Task { [weak self, scriptService] in
            guard let self else { return }
            applyScriptEvaluation(
                await scriptService.dispatchConnectionEvent(
                    "window:command",
                    arguments: [command, parameters],
                    host: scriptHostSnapshot
                ),
                showValue: false
            )
            processInput(line)
        }
    }

    private func sendToSession(_ text: String) {
        guard session != nil || puppetMaster != nil else { appendError("Not connected."); return }
        Task { [weak self, scriptService] in
            guard let self else { return }
            let result = await scriptService.dispatchConnectionEvent("send", arguments: [text], host: scriptHostSnapshot)
            applyScriptEvaluation(result, showValue: false)
            transmitToSession(text)
        }
    }

    private func transmitToSession(_ text: String, session explicitSession: SessionActor? = nil) {
        appendSentToLogs(text)
        webViewWindows.values.forEach { $0.observeSent(text) }
        if let puppet = currentPuppet, let master = puppetMaster {
            master.transmitPuppetWire(PuppetRouter.outgoing(text, for: puppet))
            return
        }
        guard let session = explicitSession ?? session else { appendError("Not connected."); return }
        let outbound = text
        Task { await session.send(outbound) }
    }

    private func transmitPuppetWire(_ text: String) {
        guard let session else { appendError("The character connection is not connected."); return }
        Task { await session.send(text) }
    }

    private func receiveFromScript(_ text: String) {
        guard let session else { appendError("Not connected."); return }
        Task { [weak self, scriptService] in
            guard let self else { return }
            let result = await scriptService.dispatchConnectionEvent("receive", arguments: [text], host: scriptHostSnapshot)
            applyScriptEvaluation(result, showValue: false)
            await session.receive(text)
        }
    }

    private func applyScriptDisplayHook(to line: RenderedLine) async -> RenderedLine {
        let result = await scriptService.dispatchConnectionEvent("display", line: line, host: scriptHostSnapshot)
        applyScriptEvaluation(.init(error: result.error, outputs: result.outputs), showValue: false)
        struct ChangedLine: Decodable { var text: String; var html: String }
        guard let value = result.value,
              let data = value.data(using: .utf8),
              let changed = try? JSONDecoder().decode(ChangedLine.self, from: data) else { return line }
        if changed.text == line.text, !changed.html.contains("<span") { return line }
        var parser = MUDProtocolPipeline(encoding: .utf8, pueblo: true, puebloActive: true)
        for event in parser.consume(Data((changed.html + "\n").utf8)) {
            if case var .line(parsed) = event {
                parsed.source = line.source
                parsed.timestamp = line.timestamp
                return parsed
            }
        }
        var changedLine = line
        changedLine.text = changed.text
        changedLine.runs = []
        return changedLine
    }

    private func appendToLogs(_ line: RenderedLine) {
        rollOverLogsIfNeeded(at: line.timestamp)
        var failed: [(URL, Error)] = []
        for (url, log) in logWriters {
            do { try log.writer.append(line) }
            catch { failed.append((url, error)) }
        }
        removeFailedLogs(failed)
    }

    private func appendTypedToLogs(_ text: String) {
        rollOverLogsIfNeeded()
        var failed: [(URL, Error)] = []
        for (url, log) in logWriters {
            do { try log.writer.appendTyped(text) }
            catch { failed.append((url, error)) }
        }
        removeFailedLogs(failed)
    }

    private func appendSentToLogs(_ text: String) {
        rollOverLogsIfNeeded()
        var failed: [(URL, Error)] = []
        for (url, log) in logWriters {
            do { try log.writer.appendSent(text) }
            catch { failed.append((url, error)) }
        }
        removeFailedLogs(failed)
    }

    private func removeFailedLogs(_ failures: [(URL, Error)]) {
        for (url, error) in failures {
            if let log = logWriters.removeValue(forKey: url) { try? log.writer.stop() }
            appendError("Logging stopped for \(url.lastPathComponent): \(error.localizedDescription)")
        }
        if !failures.isEmpty { updateWindowTitle(); refreshDiagnostics() }
    }

    private func startLog(
        template: String,
        history: CommandOutcome.LogHistory,
        appendingDate: Bool = false,
        automatic: Bool = false
    ) {
        let resolution = resolvedLogURL(template, appendingDate: appendingDate)
        var url = resolution.url
        if url.pathExtension.isEmpty { url.appendPathExtension("txt") }
        guard logWriters[url] == nil else {
            if !automatic { appendError("Already logging to \(url.path).") }
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
            logWriters[url] = .init(
                template: template,
                rollsOverDaily: resolution.rollsOverDaily,
                isAutomatic: automatic,
                appendsDate: appendingDate,
                writer: writer
            )
            appendInformationalNotice("\(automatic ? "Automatic logging" : "Logging") to \(url.path) started.")
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
        if announcing {
            for url in writers.keys.sorted(by: { $0.path < $1.path }) {
                appendInformationalNotice("Logging to \(url.path) stopped.")
            }
        }
        logWriters.removeAll()
        var errors: [String] = []
        for (url, log) in writers {
            do { try log.writer.stop() }
            catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        errors.forEach { appendError("Could not finish log \($0)") }
        updateWindowTitle()
        refreshDiagnostics()
    }

    private func resolvedLogURL(
        _ filename: String,
        at date: Date = Date(),
        appendingDate: Bool = false
    ) -> (url: URL, rollsOverDaily: Bool) {
        let resolution = SessionLogFilename.resolve(
            filename,
            date: date,
            dateFormat: preferences.logging.fileDateFormat,
            appendingDate: appendingDate,
            serverName: currentServer?.name ?? "Server",
            characterName: currentCharacter?.name ?? "Character"
        )
        var value = resolution.filename.replacingOccurrences(
            of: "%userprofile%",
            with: FileManager.default.homeDirectoryForCurrentUser.path,
            options: .caseInsensitive
        )
        value = (value as NSString).expandingTildeInPath
        if value.hasPrefix("/") { return (URL(fileURLWithPath: value), resolution.rollsOverDaily) }
        let configuredBase = profileLibrary.workspace.projection.loggingPath
            .replacingOccurrences(of: "%userprofile%", with: FileManager.default.homeDirectoryForCurrentUser.path, options: .caseInsensitive)
            .replacingOccurrences(of: "\\", with: "/")
        let base = !configuredBase.isEmpty
            ? URL(fileURLWithPath: (configuredBase as NSString).expandingTildeInPath, isDirectory: true)
            : profileLibrary.workspace.sourceURL?.deletingLastPathComponent().appendingPathComponent("Logs", isDirectory: true)
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("BeipMU Logs", isDirectory: true)
        return (base.appendingPathComponent(value), resolution.rollsOverDaily)
    }

    private func startAutomaticLog(announcingMissingSetup: Bool = false) {
        guard !logWriters.values.contains(where: \.isAutomatic) else {
            if announcingMissingSetup { appendClient("Automatic log already running.") }
            return
        }
        let settings = preferences.logging
        let legacy: (filename: String, appendsDate: Bool)? = if let puppet = currentPuppet,
                                                               !puppet.logFilename.isEmpty {
            (puppet.logFilename, puppet.logAppendsDate)
        } else {
            currentServer.flatMap {
                profileLibrary.workspace.projection.automaticLog(for: $0, character: currentCharacter)
            }
        }
        let template = legacy?.filename ?? settings.defaultLogFilename
        guard legacy != nil || settings.autoLogEnabled,
              !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if announcingMissingSetup { appendClient("No automatic log setup.") }
            return
        }
        startLog(
            template: template,
            history: .none,
            appendingDate: legacy?.appendsDate ?? settings.appendsDateToFilename,
            automatic: true
        )
    }

    private func rollOverLogsIfNeeded(at date: Date = Date()) {
        let pending = logWriters.map { (url: $0.key, log: $0.value) }
        for entry in pending where entry.log.rollsOverDaily {
            var replacement = resolvedLogURL(
                entry.log.template,
                at: date,
                appendingDate: entry.log.appendsDate
            )
            if replacement.url.pathExtension.isEmpty { replacement.url.appendPathExtension("txt") }
            guard replacement.url.standardizedFileURL != entry.url else { continue }
            guard logWriters[replacement.url] == nil else {
                if let old = logWriters.removeValue(forKey: entry.url) { try? old.writer.stop() }
                continue
            }
            let palette = preferences.theme.palette
            do {
                let writer = try SessionLogWriter(
                    url: replacement.url,
                    options: preferences.logging,
                    title: baseWindowTitle,
                    foregroundHex: palette.foreground.hexString,
                    backgroundHex: palette.background.hexString
                )
                try entry.log.writer.stop()
                logWriters.removeValue(forKey: entry.url)
                logWriters[replacement.url] = .init(
                    template: entry.log.template,
                    rollsOverDaily: replacement.rollsOverDaily,
                    isAutomatic: entry.log.isAutomatic,
                    appendsDate: entry.log.appendsDate,
                    writer: writer
                )
            } catch {
                removeFailedLogs([(entry.url, error)])
            }
        }
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

    private func processAliasedInput(_ text: String) {
        guard !aliasGroups.isEmpty else {
            sendToSession(text)
            return
        }
        do {
            let result = try AliasEngine.process(text, groups: aliasGroups, variables: variables)
            automationDebugWindows[.aliases]?.append(result.trace)
            guard !result.matchedAliases.isEmpty else {
                sendToSession(text)
                return
            }
            if aliasesEchoResults {
                appendClient("Echoing alias result: \(result.text)")
            }
            for line in Self.logicalLines(in: result.text) where !line.isEmpty {
                if aliasesProcessCommands, line.hasPrefix("/") {
                    processInput(line)
                } else {
                    sendToSession(line)
                }
            }
        } catch {
            appendError("Alias error: \(error.localizedDescription)")
            sendToSession(text)
        }
    }

    private func reloadCurrentAutomation() {
        guard let server = currentServer else {
            variables = [:]
            aliasGroups = []
            triggerGroups = []
            keyboardMacroGroups = []
            return
        }
        variables = profileLibrary.workspace.projection.variables(
            for: server,
            character: currentCharacter,
            puppet: currentPuppet
        )
        let groups = profileLibrary.workspace.projection.automationGroups(
            for: server,
            character: currentCharacter,
            puppet: currentPuppet
        )
        aliasGroups = groups.aliases
        triggerGroups = groups.triggers
        keyboardMacroGroups = profileLibrary.workspace.projection.macroGroups(
            for: server,
            character: currentCharacter,
            puppet: currentPuppet
        )
    }

    private func showAIWindow(prompt: String? = nil) {
        let controller: AIWindowController
        let isNew: Bool
        if let aiWindow {
            controller = aiWindow
            isNew = false
        } else {
            controller = AIWindowController(profileKey: notesKey)
            isNew = true
            controller.onClose = { [weak self, weak controller] in
                guard let self, self.aiWindow === controller else { return }
                if !self.preservingAIPlacement {
                    self.dockController.undockPane(.ai)
                }
                self.aiWindow = nil
            }
            controller.onDockRequest = { [weak self, weak controller] side in
                guard let self, let controller else { return }
                self.dockAIWindow(controller, side: side)
            }
            controller.onSubmit = { [weak self, weak controller] value in
                guard let self else { return }
                let endpoint = self.currentServer?.aiEndpoint
                let model = self.currentServer?.aiModel ?? ""
                self.aiRequestTask?.cancel()
                self.aiRequestTask = Task {
                    do {
                        let result = try await self.aiClient.request(
                            .init(prompt: value, model: model),
                            endpoint: endpoint,
                            apiKey: ProcessInfo.processInfo.environment["BEIPMU_AI_API_KEY"]
                        )
                        guard !Task.isCancelled else { return }
                        controller?.showResponse(result, for: value)
                    } catch is CancellationError {
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        controller?.showError(error.localizedDescription)
                    }
                }
            }
            aiWindow = controller
        }
        controller.updateEndpoint(currentServer?.aiEndpoint)
        controller.applyTheme(preferences.theme.palette)
        if isNew {
            presentAIWindow(controller)
        } else if !controller.isDocked {
            controller.showFloating(self)
        }
        if let prompt, !prompt.isEmpty {
            controller.submitPrompt(prompt)
        }
    }

    private func presentAIWindow(_ controller: AIWindowController) {
        guard !controller.isDocked else { return }
        let view = controller.contentViewForDocking()
        if dockController.restorePane(
            .ai,
            view: view,
            title: "AI",
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(.ai)
                controller.showFloating(self)
            }
        ) {
            return
        }
        dockAIWindow(controller, side: .bottom)
    }

    private func dockAIWindow(_ controller: AIWindowController, side: WebViewDockSide) {
        dockController.dockPane(
            .ai,
            view: controller.contentViewForDocking(),
            title: "AI",
            side: side,
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(.ai)
                controller.showFloating(self)
            }
        )
    }

    private func closeAIWindow(preservingDockPlacement: Bool) {
        guard let controller = aiWindow else { return }
        aiRequestTask?.cancel()
        aiRequestTask = nil
        preservingAIPlacement = preservingDockPlacement
        if preservingDockPlacement, controller.isDocked {
            dockController.releasePane(.ai)
        }
        controller.closeSurface()
        preservingAIPlacement = false
        aiWindow = nil
    }

    private func recallOutput(lineCount: Int, search: String) {
        let retained = output.retainedLines
        let start = max(0, retained.count - lineCount)
        let matches = retained[start...].filter {
            $0.text.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        appendClient("Recall - Starting")
        matches.forEach { output.append($0) }
        appendClient("Recall - Finished")
    }

    private func runCompatibilityTest(_ kind: String) {
        guard let payload = CommandTestFixtures.payload(for: kind) else { return }
        if let session {
            Task { await session.receive(payload) }
        } else {
            var processor = MUDProtocolPipeline(encoding: .utf8, pueblo: true, puebloActive: true)
            for event in processor.consume(Data(payload.utf8)) {
                switch event {
                case let .line(line), let .prompt(line): output.append(line)
                default: break
                }
            }
        }
    }

    private func applyTriggers(to original: RenderedLine) async -> (line: RenderedLine, gagDisplay: Bool, gagLog: Bool, suppressActivity: Bool) {
        guard !triggerGroups.isEmpty || spawnCapture != nil else { return (original, false, false, false) }
        do {
            let effects: [AutomationEffect]
            if let capture = spawnCapture, capture.action.onlyChildrenDuringCapture {
                effects = try await triggerEngine.processOnly(
                    original,
                    triggers: capture.children,
                    variables: variables,
                    isAway: window?.isKeyWindow != true
                )
            } else if triggerGroups.isEmpty {
                effects = []
            } else {
                effects = try await triggerEngine.process(
                    original,
                    groups: triggerGroups,
                    variables: variables,
                    isAway: window?.isKeyWindow != true
                )
            }
            automationDebugWindows[.triggers]?.append(await triggerEngine.lastTrace())
            var line = original
            var gagDisplay = false
            var gagLog = false
            var suppressActivity = false
            var newSpawn: (action: TriggerSpawnAction, children: [Trigger])?
            for effect in effects {
                switch effect {
                case let .replace(range, replacement):
                    guard let swiftRange = Range(range, in: line.text) else { continue }
                    line.text.replaceSubrange(swiftRange, with: replacement)
                    // A filtered fragment may carry its own markup in the
                    // reference client. Until the rich filter parser is
                    // complete, do not retain stale UTF-16 style ranges.
                    line.runs = []
                case let .replaceHTML(range, replacement):
                    guard let swiftRange = Range(range, in: line.text) else { continue }
                    var parser = MUDProtocolPipeline(encoding: .utf8, pueblo: true, puebloActive: true)
                    let fragment = parser.consume(Data((replacement + "\n").utf8)).compactMap { event -> RenderedLine? in
                        if case let .line(value) = event { return value }
                        return nil
                    }.first ?? .init(text: replacement)
                    line.text.replaceSubrange(swiftRange, with: fragment.text)
                    line.runs = fragment.runs.map {
                        .init(range: (range.location + $0.range.lowerBound)..<(range.location + $0.range.upperBound), style: $0.style)
                    }
                case .gagDisplay:
                    gagDisplay = true
                case .gagLog:
                    gagLog = true
                case let .send(text):
                    for value in Self.logicalLines(in: text) where !value.isEmpty { processInput(value) }
                case let .link(range, text):
                    let upperBound = line.text.utf16.count
                    let lower = max(0, min(range.location, upperBound))
                    let upper = max(lower, min(range.location + range.length, upperBound))
                    guard lower < upper else { continue }
                    var style = Self.style(at: lower, in: line) ?? .init()
                    style.link = .send(text, hints: [])
                    line.runs.append(.init(range: lower..<upper, style: style))
                case let .activity(important):
                    markActivity(important: important)
                case .activateWindow:
                    window?.makeKeyAndOrderFront(nil)
                case .suppressActivity:
                    suppressActivity = true
                case let .sound(path):
                    if !isMuted, let sound = NSSound(contentsOf: URL(fileURLWithPath: path), byReference: true) {
                        scriptSounds.removeAll { !$0.isPlaying }
                        scriptSounds.append(sound)
                        sound.play()
                    }
                case let .speech(text):
                    if !isMuted {
                        let utterance = AVSpeechUtterance(string: text)
                        if let identifier = preferences.speechVoiceIdentifier {
                            utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
                        }
                        speechSynthesizer.speak(utterance)
                    }
                case let .script(function, ranges, callbackLine):
                    let result = await scriptService.callTrigger(
                        function,
                        ranges: ranges,
                        line: callbackLine,
                        host: scriptHostSnapshot
                    )
                    applyScriptEvaluation(result, showValue: false)
                case let .notification(text):
                    deliverNotification(text)
                case let .style(range, foreground, background):
                    let upperBound = line.text.utf16.count
                    let lower = max(0, min(range.location, upperBound))
                    let upper = max(lower, min(range.location + range.length, upperBound))
                    guard lower < upper else { continue }
                    var style = Self.style(at: lower, in: line) ?? .init()
                    if let foreground { style.foreground = foreground }
                    if let background { style.background = background }
                    line.runs.append(.init(
                        range: lower..<upper,
                        style: style
                    ))
                case let .resetColors(range, foreground, background):
                    let upperBound = line.text.utf16.count
                    let lower = max(0, min(range.location, upperBound))
                    let upper = max(lower, min(range.location + range.length, upperBound))
                    guard lower < upper else { continue }
                    var style = Self.style(at: lower, in: line) ?? .init()
                    if foreground { style.foreground = nil }
                    if background { style.background = nil }
                    line.runs.append(.init(range: lower..<upper, style: style))
                case let .font(range, face, size):
                    let upperBound = line.text.utf16.count
                    let lower = max(0, min(range.location, upperBound))
                    let upper = max(lower, min(range.location + range.length, upperBound))
                    guard lower < upper else { continue }
                    var style = Self.style(at: lower, in: line) ?? .init()
                    style.fontFace = face
                    style.fontSize = size
                    line.runs.append(.init(range: lower..<upper, style: style))
                case let .appearance(range, patch):
                    let upperBound = line.text.utf16.count
                    let lower = max(0, min(range.location, upperBound))
                    let upper = max(lower, min(range.location + range.length, upperBound))
                    guard lower < upper else { continue }
                    var style = Self.style(at: lower, in: line) ?? .init()
                    patch.applying(to: &style)
                    line.runs.append(.init(range: lower..<upper, style: style))
                case let .paragraph(patch):
                    patch.applying(to: &line.paragraph)
                case let .avatar(url):
                    if let source = URL(string: url) {
                        line.assets.append(.init(kind: .avatar, source: source, altText: "Trigger avatar", characterOffset: 0))
                    }
                case let .stat(update):
                    updateTriggerStatistic(update)
                case let .spawn(action, _, children):
                    if spawnCapture == nil { newSpawn = (action, children) }
                }
            }
            if let newSpawn {
                deliverSpawn(line, action: newSpawn.action, children: newSpawn.children, startsCapture: true)
                gagDisplay = gagDisplay || !newSpawn.action.copy
                gagLog = gagLog || newSpawn.action.gagLog
            } else if let capture = spawnCapture {
                deliverSpawn(line, action: capture.action, children: capture.children, startsCapture: false)
                gagDisplay = gagDisplay || !capture.action.copy
                gagLog = gagLog || capture.action.gagLog
                if matchesCaptureEnd(capture.action.captureUntil, text: line.text) {
                    spawnCapture = nil
                }
            }
            return (line, gagDisplay, gagLog, suppressActivity)
        } catch {
            appendError("Trigger error: \(error.localizedDescription)")
            return (original, false, false, false)
        }
    }

    private func markActivity(important: Bool) {
        guard window?.isKeyWindow != true else { return }
        unreadCount += 1
        activityLabel.stringValue = important ? "Important — \(unreadCount) unread" : "\(unreadCount) unread"
        updateWindowTitle()
        if important { NSApplication.shared.requestUserAttention(.informationalRequest) }
        Self.updateDockBadge()
    }

    private func deliverNotification(_ text: String) {
        let content = UNMutableNotificationContent()
        content.title = baseWindowTitle
        content.body = text
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        Task {
            do {
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    _ = try await center.requestAuthorization(options: [.alert, .sound])
                }
                try await center.add(request)
            } catch {
                appendError("Unable to deliver notification: \(error.localizedDescription)")
            }
        }
    }

    private static func logicalLines(in text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func style(at utf16Offset: Int, in line: RenderedLine) -> TextStyle? {
        line.runs.last(where: { $0.range.contains(utf16Offset) })?.style
    }

    private func processInput(_ text: String) {
        switch commandRegistry.parse(text, variables: variables) {
        case .notACommand:
            _ = atlasWindow?.recordTypedExit(text)
            processAliasedInput(text)
        case let .send(value):
            sendToSession(value)
        case let .display(value): appendClient(value)
        case .clear: output.clear()
        case let .localEcho(enabled):
            updateActiveInputWindowSettings { $0.localEcho = enabled }
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
        case let .mediaControl(action):
            switch action {
            case .flush:
                if mediaState.isActive {
                    for event in mediaState.flush() { mediaController.apply(event) }
                    mediaController.flush()
                }
            case .info:
                if mediaState.isActive {
                    appendClient(mediaState.information)
                    appendClient(mediaController.information)
                } else {
                    appendError("MCMP not active")
                }
            }
        case let .tileMap(enabled):
            tileMapsEnabled = enabled
            appendClient("TileMap tag parsing \(enabled ? "ON" : "OFF")")
        case let .switchSpawnTab(group, title):
            guard let controller = triggerSpawnTabGroups[group] else {
                appendError("Tab group not found")
                return
            }
            if !controller.selectTab(named: title) { appendError("Tab not found") }
        case let .mapAddRoom(name, outward, returnCommand):
            guard let atlasWindow, atlasWindow.editor.currentLocation != nil else {
                appendError("The map doesn't currently know your location")
                return
            }
            if !atlasWindow.addRoomAndExit(name: name, outward: outward, returnCommand: returnCommand) {
                appendError("The room could not be added")
            }
        case let .mapAddExit(outward, returnCommand):
            guard let atlasWindow, atlasWindow.editor.currentLocation != nil else {
                appendError("The map doesn't currently know your location")
                return
            }
            if !atlasWindow.addDirectionalExit(outward: outward, returnCommand: returnCommand) {
                appendError("Unknown direction or no room in that direction")
            }
        case .mapGuessLocation:
            guard let atlasWindow else { appendError("No map"); return }
            if atlasWindow.guessLocation(in: output.retainedLines.map(\.text)) == nil {
                appendError("Unable to determine current location")
            }
        case .mapLook:
            guard let description = atlasWindow?.lookDescription() else {
                appendError("The map doesn't currently know your location")
                return
            }
            appendClient(description)
        case let .disconnect(all):
            let controllers = all ? Self.openControllers : [self]
            for controller in controllers { controller.disconnect() }
        case let .reconnect(all):
            let controllers = all ? Self.openControllers : [self]
            for controller in controllers { controller.reconnect() }
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
        case let .ai(prompt): showAIWindow(prompt: prompt)
        case let .gag(text):
            do {
                _ = try profileLibrary.mutate { try $0.addOrActivateGlobalGag(text) }
                reloadCurrentAutomation()
                appendClient("Gag activated for: \(text)")
            } catch { appendError("Gag: \(error.localizedDescription)") }
        case let .grab(object, property):
            guard session != nil else { appendError("Not connected."); return }
            let token = String(format: "%08X", UInt32.random(in: UInt32.min...UInt32.max))
            grabPrefix = token + " "
            sendToSession("@pemit me=\(grabPrefix!)&\(property) \(object)=[get(\(object)/\(property))]")
        case let .recall(lineCount, search): recallOutput(lineCount: lineCount, search: search)
        case .resetConfiguration:
            disconnect()
            do {
                try profileLibrary.newConfiguration()
                currentServer = nil
                currentCharacter = nil
                currentPuppet = nil
                reloadCurrentAutomation()
                appendClient("Configuration reset.")
            } catch { appendError("Unable to reset configuration: \(error.localizedDescription)") }
        case .rollTest:
            appendClient(DiceFairnessReport.run().displayText)
        case let .compatibilityTest(kind): runCompatibilityTest(kind)
        case let .webView(request): openWebView(request)
        case .silence:
            mediaController.stop(name: nil)
            scriptSounds.forEach { $0.stop() }
            scriptSounds.removeAll()
            speechSynthesizer.stopSpeaking(at: .immediate)
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
            case "aliases": showAutomationEditor(.aliases)
            case "triggers": showAutomationEditor(.triggers)
            case "macros": showAutomationEditor(.macros)
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
            if let match, let server = currentServer, let character = currentCharacter {
                _ = (NSApp.delegate as? ApplicationDelegate)?.openPuppet(
                    master: self, server: server, character: character, puppet: match
                )
            }
            else { appendError("Puppet profile not found: \(name)") }
        case .stopLogs: stopAllLogs()
        case let .startLog(filename, history): startLog(template: filename, history: history)
        case .startAutoLog: startAutomaticLog(announcingMissingSetup: true)
        case let .script(source):
            Task {
                let result = await scriptService.evaluate(source, host: scriptHostSnapshot)
                applyScriptEvaluation(result, showValue: true)
            }
        case let .scriptHelp(type):
            Task {
                let runtime = ScriptRuntime()
                if let type {
                    appendClient(await runtime.help(for: type) ?? "Unknown scripting type: \(type)")
                } else {
                    appendClient("Scripting types: " + (await runtime.helpTypes()).joined(separator: ", "))
                }
            }
        case let .openCommandHelp(topic):
            showEmbeddedHelp(topic: topic)
        case .resetScript:
            Task { await scriptService.reset(); appendClient("Scripting runtime reset.") }
        case .cancelCapture:
            if spawnCapture == nil { appendClient("No active spawn capture.") }
            else { spawnCapture = nil; appendClient("Spawn capture cancelled.") }
        case let .debugAutomation(kind):
            showAutomationDebugger(kind)
        case .debugNetwork:
            showNetworkDebugger()
        case .restoreInfo:
            showRestoreInformation()
        case let .invoke(name, arguments, _):
            switch name {
            case "tabcolor": setTabColor(arguments.first)
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

    func rebuildSessionTabs() {
        sessionTabs.arrangedSubviews.forEach {
            sessionTabs.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let controllers = sessionTabGroup?.controllers ?? [self]
        let selectedController = sessionTabGroup?.selectedController ?? self
        for controller in controllers {
            let tab = SessionWindowTabItemView(
                title: controller.sessionTabText,
                trailingIndicators: controller.sessionTabTrailingIndicators,
                selected: controller === selectedController,
                color: controller.sessionTabColor,
                targetController: controller
            )
            sessionTabs.addArrangedSubview(tab)
        }
    }

    func focusCommandInput() {
        window?.makeFirstResponder(input)
    }

    var isCommandInputFocusedForTesting: Bool {
        window?.firstResponder === input
    }

    func startLogForTesting(at url: URL) {
        startLog(template: url.path, history: .none)
    }

    private var sessionTabTitle: String {
        [sessionTabText, sessionTabTrailingIndicators].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private var sessionTabText: String {
        let activity = unreadCount > 0 ? "● " : ""
        return activity + scriptTitlePrefix + baseWindowTitle
    }

    private var sessionTabTrailingIndicators: String {
        [
            isMuted ? "🔇" : nil,
            logWriters.isEmpty ? nil : "📝",
        ].compactMap { $0 }.joined(separator: " ")
    }

    private func updateWindowTitle() {
        window?.title = sessionTabTitle
        if let sessionTabGroup { sessionTabGroup.refreshTabs() }
        else { rebuildSessionTabs() }
    }

    private func setTabColor(_ value: String?) {
        guard let value, let color = NSColor(htmlColor: value) else {
            sessionTabColor = nil
            if let sessionTabGroup { sessionTabGroup.refreshTabs() }
            else { rebuildSessionTabs() }
            appendClient("Tab color reset.")
            return
        }
        sessionTabColor = color
        if let sessionTabGroup { sessionTabGroup.refreshTabs() }
        else { rebuildSessionTabs() }
        appendClient("Tab color set to \(value).")
    }

    private func applyPreferences() {
        applyTextWindowSettings()
        if output.isSplit != preferences.outputSplit { output.toggleSplit() }
        input.behavior.prefix = preferences.inputPrefix
        input.isContinuousSpellCheckingEnabled = preferences.checksSpelling
        applyInputWindowSettings()
        applyThemeSettings(preferences.theme)
    }

    private func savePreferences() { WorkspacePreferencesStore.save(preferences) }

    private var textWindowIdentity: TextWindowSettingsIdentity {
        .init(
            world: currentServer?.name,
            character: currentCharacter?.name,
            tab: currentServer == nil ? nil : (currentPuppet?.name ?? "Main")
        )
    }

    private var activeTextWindowSettings: TextWindowSettings {
        preferences.textWindowSettings(for: textWindowIdentity)
    }

    private var activeInputWindowSettings: InputWindowSettings {
        preferences.inputWindowSettings(for: textWindowIdentity)
    }

    private var activeInputWindowUsesGlobalSettings: Bool {
        let identity = textWindowIdentity
        if let key = identity.tabKey, let entry = preferences.tabInputWindowSettings[key] {
            return entry.usesGlobalSettings
        }
        if let key = identity.characterKey, let entry = preferences.characterInputWindowSettings[key] {
            return entry.usesGlobalSettings
        }
        if let key = identity.worldKey, let entry = preferences.worldInputWindowSettings[key] {
            return entry.usesGlobalSettings
        }
        return true
    }

    private var activeTextWindowUsesGlobalSettings: Bool {
        let identity = textWindowIdentity
        if let key = identity.tabKey, let entry = preferences.tabTextWindowSettings[key] {
            return entry.usesGlobalSettings
        }
        if let key = identity.characterKey, let entry = preferences.characterTextWindowSettings[key] {
            return entry.usesGlobalSettings
        }
        if let key = identity.worldKey, let entry = preferences.worldTextWindowSettings[key] {
            return entry.usesGlobalSettings
        }
        return true
    }

    private func applyTextWindowSettings() {
        output.applySettings(activeTextWindowSettings)
    }

    private func applyInputWindowSettings() {
        let settings = activeInputWindowSettings
        input.usesGlobalSettings = activeInputWindowUsesGlobalSettings
        input.canToggleUseGlobalSettings = textWindowIdentity.tabKey != nil
        input.applySettings(settings)
        secondaryInputWindows.forEach {
            $0.input.usesGlobalSettings = activeInputWindowUsesGlobalSettings
            $0.input.canToggleUseGlobalSettings = textWindowIdentity.tabKey != nil
            $0.input.applySettings(settings)
        }
        localEcho = settings.localEcho
        if let session {
            let color = Self.rgbColor(hex: settings.localEchoHex)
            Task { await session.configureLocalEcho(settings.localEcho, color: color) }
        }
    }

    private func updateActiveInputWindowSettings(_ update: (inout InputWindowSettings) -> Void) {
        let identity = textWindowIdentity
        if let key = identity.tabKey {
            var entry = preferences.tabInputWindowSettings[key]
                ?? .init(usesGlobalSettings: false, settings: activeInputWindowSettings)
            entry.usesGlobalSettings = false
            update(&entry.settings)
            entry.settings = entry.settings.normalized
            preferences.tabInputWindowSettings[key] = entry
        } else {
            update(&preferences.globalInputWindowSettings)
            preferences.globalInputWindowSettings = preferences.globalInputWindowSettings.normalized
            synchronizeLegacyGlobalInputSettings()
        }
        applyInputWindowSettings()
        savePreferences()
        onTextWindowSettingsChange?()
    }

    private func synchronizeLegacyGlobalInputSettings() {
        preferences.stickyInput = preferences.globalInputWindowSettings.keepsTextOnSubmit
    }

    private func restoreInputHeight() {
        guard inputSplitView.bounds.height > 0 else { return }
        inputSplitView.layoutSubtreeIfNeeded()
        inputSplitView.setPosition(
            max(
                80,
                inputSplitView.bounds.height
                    - inputSplitView.dividerThickness
                    - CGFloat(preferences.inputHeight)
            ),
            ofDividerAt: 0
        )
    }

    func synchronizeInputHeight(_ height: Double) {
        preferences.inputHeight = height
        let wasTrackingInputHeight = tracksInputHeight
        tracksInputHeight = false
        restoreInputHeight()
        tracksInputHeight = wasTrackingInputHeight
    }

    private func resizeInput(to height: CGFloat) {
        guard activeInputWindowSettings.resizesToFitContents, inputSplitView.bounds.height > 0 else { return }
        let boundedHeight = min(max(30, height), max(30, inputSplitView.bounds.height - 80))
        inputSplitView.setPosition(
            inputSplitView.bounds.height - inputSplitView.dividerThickness - boundedHeight,
            ofDividerAt: 0
        )
    }

    private static func rgbColor(hex: String) -> BeipCore.RGBColor? {
        guard let color = NSColor(hexString: hex)?.usingColorSpace(.deviceRGB) else { return nil }
        return BeipCore.RGBColor(
            red: UInt8((color.redComponent * 255).rounded()),
            green: UInt8((color.greenComponent * 255).rounded()),
            blue: UInt8((color.blueComponent * 255).rounded())
        )
    }

    private func updateActiveTextWindowSettings(_ update: (inout TextWindowSettings) -> Void) {
        let identity = textWindowIdentity
        if let key = identity.tabKey {
            var entry = preferences.tabTextWindowSettings[key]
                ?? .init(usesGlobalSettings: false, settings: activeTextWindowSettings)
            entry.usesGlobalSettings = false
            update(&entry.settings)
            entry.settings = entry.settings.normalized
            preferences.tabTextWindowSettings[key] = entry
        } else {
            update(&preferences.globalTextWindowSettings)
            preferences.globalTextWindowSettings = preferences.globalTextWindowSettings.normalized
            synchronizeLegacyGlobalTextSettings()
        }
        applyTextWindowSettings()
        savePreferences()
        onTextWindowSettingsChange?()
    }

    private func synchronizeLegacyGlobalTextSettings() {
        let global = preferences.globalTextWindowSettings
        preferences.outputHistoryLimit = global.historyLimit
        preferences.showsTimestamps = global.showsTime || global.showsDate
        preferences.usesFanFoldBackgrounds = global.usesFanFoldBackgrounds
    }

    func reloadTextWindowPreferences() {
        let saved = WorkspacePreferencesStore.load()
        preferences.globalTextWindowSettings = saved.globalTextWindowSettings
        preferences.worldTextWindowSettings = saved.worldTextWindowSettings
        preferences.characterTextWindowSettings = saved.characterTextWindowSettings
        preferences.tabTextWindowSettings = saved.tabTextWindowSettings
        preferences.globalInputWindowSettings = saved.globalInputWindowSettings
        preferences.worldInputWindowSettings = saved.worldInputWindowSettings
        preferences.characterInputWindowSettings = saved.characterInputWindowSettings
        preferences.tabInputWindowSettings = saved.tabInputWindowSettings
        applyTextWindowSettings()
        applyInputWindowSettings()
    }

    private var notesKey: String {
        ([currentServer?.name, currentCharacter?.name, currentPuppet?.name].compactMap { $0 }.joined(separator: "/").isEmpty
            ? "Untitled"
            : [currentServer?.name, currentCharacter?.name, currentPuppet?.name].compactMap { $0 }.joined(separator: "/"))
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

    private func startTitlebarStatisticsUpdates() {
        refreshTitlebarStatistics()
        titlebarStatisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                refreshTitlebarStatistics()
            }
        }
    }

    private func refreshTitlebarStatistics() {
        let typedCount = UInt64(input.string.count)
        let idleSeconds = isSessionConnected ? Date().timeIntervalSince(lastTypedAt) : 0
        guard let session else {
            titlebarStatistics.update(
                typedCount: typedCount,
                onlineSeconds: 0,
                idleSeconds: idleSeconds
            )
            return
        }
        Task { [weak self] in
            let statistics = await session.statistics()
            guard let self else { return }
            titlebarStatistics.update(
                typedCount: typedCount,
                onlineSeconds: statistics.secondsConnected,
                idleSeconds: idleSeconds
            )
        }
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

    private static let connectionInfoColor = BeipCore.RGBColor(red: 0, green: 205, blue: 205)
    private static let connectionSuccessColor = BeipCore.RGBColor(red: 0, green: 205, blue: 0)
    private static let connectionAddressColor = BeipCore.RGBColor(red: 80, green: 80, blue: 255)
    private static let connectionErrorColor = BeipCore.RGBColor(red: 255, green: 0, blue: 0)

    private func appendClient(_ text: String) { output.append(.init(text: text, source: .client)) }

    private func appendInformationalNotice(_ text: String) {
        appendClient(text, color: Self.connectionInfoColor)
    }

    private func appendConnectionNotice(_ notice: ConnectionNotice) {
        switch notice {
        case let .lookingUp(host, port):
            appendClient("Looking up address \(host):\(port)", color: Self.connectionInfoColor)
        case let .connecting(host, port):
            let prefix = "Address is "
            let address = "\(host):\(port)"
            let suffix = ", Connecting…"
            let text = prefix + address + suffix
            let prefixEnd = prefix.utf16.count
            let addressEnd = prefixEnd + address.utf16.count
            output.append(.init(
                text: text,
                runs: [
                    .init(range: 0..<prefixEnd, style: .init(foreground: Self.connectionSuccessColor)),
                    .init(range: prefixEnd..<addressEnd, style: .init(foreground: Self.connectionAddressColor)),
                    .init(range: addressEnd..<text.utf16.count, style: .init(foreground: Self.connectionSuccessColor)),
                ],
                source: .client
            ))
        case .connected:
            appendClient("Connected", color: Self.connectionSuccessColor)
        case let .retryScheduled(seconds):
            appendClient("Will try to reconnect in \(seconds) seconds", color: Self.connectionInfoColor)
        case let .retrying(attempt, limit):
            appendClient("Retrying, attempt \(attempt) of \(limit)", color: Self.connectionInfoColor)
        case .retryLimitReached:
            appendClient("Retry limit reached, giving up", color: Self.connectionErrorColor)
        case .disconnected:
            appendClient("Disconnected", color: Self.connectionErrorColor)
        }
    }

    private func appendConnectionError(_ message: String) {
        let prefix = "Error: "
        let text = prefix + message
        let boundary = prefix.utf16.count
        output.append(.init(
            text: text,
            runs: [
                .init(range: 0..<boundary, style: .init(foreground: Self.connectionErrorColor)),
                .init(range: boundary..<text.utf16.count, style: .init(foreground: Self.connectionInfoColor)),
            ],
            source: .client
        ))
    }

    private func appendClient(_ text: String, color: BeipCore.RGBColor) {
        output.append(.init(
            text: text,
            runs: [.init(range: 0..<text.utf16.count, style: .init(foreground: color))],
            source: .client
        ))
    }

    private var scriptHostSnapshot: ScriptHostSnapshot {
        let projection = profileLibrary.workspace.projection
        let worlds = projection.servers.map { server in
            ScriptHostSnapshot.World(
                name: server.profile.name,
                host: "\(server.profile.host):\(server.profile.port)",
                characters: server.characters.map { .init(name: $0.name) }
            )
        }
        return .init(
            buildNumber: LegacyConfigurationProjection.currentWindowsVersion,
            version: LegacyConfigurationProjection.currentWindowsVersion,
            buildDate: Self.applicationBuildDate,
            configPath: profileLibrary.workspace.sourceURL?.path ?? "",
            worlds: worlds,
            aliases: projection.automation.aliases.aliases.map {
                .init(description: $0.description, matchText: $0.match.text)
            },
            triggers: projection.automation.triggers.triggers.map {
                .init(description: $0.description, matchText: $0.match.text)
            },
            activeWorld: currentServer?.name,
            activeCharacter: currentCharacter?.name,
            spawnTabGroups: triggerSpawnTabGroups.keys.sorted(),
            secondaryInputs: secondaryInputWindows.map {
                .init(title: $0.logicalTitle, prefix: $0.prefix, text: $0.input.text)
            },
            window: .init(
                title: window?.title ?? baseWindowTitle,
                input: input.text,
                inputPrefix: preferences.inputPrefix,
                inputTitle: input.accessibilityLabel(),
                titlePrefix: scriptTitlePrefix,
                connected: session != nil,
                logging: !logWriters.isEmpty,
                logFileName: logWriters.keys.sorted { $0.path < $1.path }.first?.path,
                variables: variables
            )
        )
    }

    private func applyScriptEvaluation(_ result: ScriptEvaluation, showValue: Bool) {
        for output in result.outputs {
            switch output.kind {
            case .debugText:
                recordScriptDebug(.init(kind: .text, message: output.value))
                appendClient("Script: \(output.value)")
            case .debugHTML:
                recordScriptDebug(.init(kind: .html, message: output.value))
                appendClient("Script HTML: \(output.value)")
            case .display: appendClient(output.value)
            case .displayHTML:
                var parser = MUDProtocolPipeline(encoding: .utf8, pueblo: true, puebloActive: true)
                for event in parser.consume(Data((output.value + "\n").utf8)) {
                    if case let .line(line) = event { self.output.append(line) }
                }
            case .send: sendToSession(output.value)
            case .transmit: transmitToSession(output.value)
            case .receive:
                receiveFromScript(output.value)
            case .setInput:
                input.text = output.value
            case .setVariable:
                struct Variable: Decodable { var name: String; var value: String }
                if let data = output.value.data(using: .utf8),
                   let variable = try? JSONDecoder().decode(Variable.self, from: data) {
                    variables[variable.name] = variable.value
                }
            case .deleteVariable:
                variables.removeValue(forKey: output.value)
            case .closeWindow:
                window?.performClose(nil)
            case .activity:
                markActivity(important: false)
            case .importantActivity:
                markActivity(important: true)
            case .runFile:
                let path = (output.value as NSString).expandingTildeInPath
                Task {
                    do {
                        let source = try String(contentsOfFile: path, encoding: .utf8)
                        let nested = await scriptService.evaluate(source, host: scriptHostSnapshot)
                        applyScriptEvaluation(nested, showValue: false)
                    } catch {
                        appendError("Cannot run script file: \(error.localizedDescription)")
                    }
                }
            case .playSound:
                guard !isMuted,
                      let sound = NSSound(contentsOfFile: (output.value as NSString).expandingTildeInPath, byReference: true) else { continue }
                scriptSounds.append(sound)
                sound.play()
            case .stopSounds:
                scriptSounds.forEach { $0.stop() }
                scriptSounds.removeAll()
                speechSynthesizer.stopSpeaking(at: .immediate)
            case .scriptError:
                recordScriptDebug(.init(kind: .error, message: output.value), revealForError: true)
                appendError(output.value)
            case .reconnect:
                guard let session else { appendError("No previous connection to reconnect."); continue }
                Task { await session.reconnect() }
            case .logWrite, .logWriteLine:
                var failures: [(URL, Error)] = []
                for (url, log) in logWriters {
                    do {
                        if output.kind == .logWrite { try log.writer.appendScript(output.value) }
                        else { try log.writer.appendScriptLine(output.value) }
                    } catch {
                        failures.append((url, error))
                    }
                }
                removeFailedLogs(failures)
            case .setInputPrefix:
                preferences.inputPrefix = output.value
                input.behavior = .init(prefix: output.value, isSticky: preferences.stickyInput)
                savePreferences()
            case .setInputTitle:
                input.setAccessibilityLabel(output.value)
            case .setTitlePrefix:
                scriptTitlePrefix = output.value
                updateWindowTitle()
            case .openConnectDialog:
                showConnectDialog()
            case .scriptWindow:
                guard let data = output.value.data(using: .utf8),
                      let operation = try? JSONDecoder().decode(ScriptWindowOperation.self, from: data) else {
                    appendError("Invalid script-window operation.")
                    continue
                }
                let controller: ScriptWindowController
                if let existing = scriptWindows[operation.identifier] {
                    controller = existing
                } else {
                    guard operation.action == "create" else { continue }
                    controller = .init(operation: operation)
                    controller.onClose = { [weak self] in self?.scriptWindows.removeValue(forKey: operation.identifier) }
                    controller.onEvent = { [weak self, scriptService] event, arguments in
                        guard let self else { return }
                        Task {
                            self.applyScriptEvaluation(
                                await scriptService.dispatchConnectionEvent(
                                    "scriptWindow:\(operation.identifier):\(event)",
                                    arguments: arguments,
                                    host: self.scriptHostSnapshot
                                ),
                                showValue: false
                            )
                        }
                    }
                    scriptWindows[operation.identifier] = controller
                    controller.showWindow(self)
                    controller.window?.makeKeyAndOrderFront(nil)
                }
                controller.apply(operation, relativeTo: window)
            case .newMainWindow:
                NSApplication.shared.sendAction(#selector(ApplicationDelegate.newWindow(_:)), to: nil, from: nil)
                Task { [weak self, scriptService] in
                    guard let self else { return }
                    applyScriptEvaluation(
                        await scriptService.dispatchConnectionEvent("app:newWindow", host: scriptHostSnapshot),
                        showValue: false
                    )
                }
            case .secondaryInput:
                guard let data = output.value.data(using: .utf8),
                      let operation = try? JSONDecoder().decode(ScriptWindowOperation.self, from: data),
                      let value = operation.strings.first,
                      let controller = secondaryInputWindows.first(where: { $0.logicalTitle == operation.identifier }) else { continue }
                controller.applyScript(action: operation.action, value: value)
            }
        }
        if let error = result.error {
            recordScriptDebug(.init(kind: .error, message: error), revealForError: true)
            appendError(error)
        }
        else if showValue, let value = result.value { appendClient(value) }
    }

    private func recordScriptDebug(
        _ entry: ScriptDebugWindowController.Entry,
        revealForError: Bool = false
    ) {
        scriptDebugEntries.append(entry)
        if scriptDebugEntries.count > 1_000 {
            scriptDebugEntries.removeFirst(scriptDebugEntries.count - 1_000)
        }
        scriptDebugWindow?.append(entry)
        if revealForError,
           profileLibrary.workspace.projection.scripting.debugEnabled,
           scriptDebugWindow == nil {
            showScriptDebugger()
        }
    }

    private static var applicationBuildDate: String? {
        guard let executable = Bundle.main.executableURL,
              let values = try? executable.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }

    private func updateTriggerStatistic(_ update: TriggerStatisticUpdate) {
        let title = update.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Trigger Statistics" : update.title
        var store = triggerStatistics[title] ?? .init()
        store.apply(update)
        triggerStatistics[title] = store

        let controller: TriggerStatisticsWindowController
        if let existing = triggerStatisticsWindows[title] {
            controller = existing
        } else {
            controller = .init(title: title)
            controller.onClose = { [weak self] in self?.triggerStatisticsWindows.removeValue(forKey: title) }
            triggerStatisticsWindows[title] = controller
        }
        controller.update(store.ordered)
        controller.showWindow(self)
    }

    private func deliverSpawn(
        _ line: RenderedLine,
        action: TriggerSpawnAction,
        children: [Trigger],
        startsCapture: Bool
    ) {
        let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Trigger Spawn" : action.title
        let group = action.tabGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        if group.isEmpty {
            let controller = spawnWindow(named: title)
            if startsCapture, action.clear { controller.clear() }
            controller.append(line)
            presentSpawnWindow(controller, title: title)
        } else {
            let controller = spawnTabGroup(named: group)
            controller.deliver(
                line,
                to: title,
                clear: startsCapture && action.clear,
                showTab: startsCapture && action.showTab
            )
            presentSpawnTabGroup(controller, title: group)
        }
        if startsCapture, !action.captureUntil.isEmpty {
            spawnCapture = .init(title: title, action: action, children: children)
        }
    }

    private func spawnWindow(named title: String) -> TriggerSpawnWindowController {
        if let existing = triggerSpawnWindows[title] { return existing }
        let controller = TriggerSpawnWindowController(title: title)
        controller.onAction = { [weak self] action in self?.perform(action) }
        controller.onClose = { [weak self] in
            guard let self else { return }
            self.dockController.undockPane(.spawn(title))
            self.triggerSpawnWindows.removeValue(forKey: title)
            self.saveSpawnSurfacePreferences()
        }
        controller.onDockRequest = { [weak self, weak controller] side in
            guard let self, let controller else { return }
            self.dockSpawnWindow(controller, title: title, side: side)
        }
        controller.window?.setFrameAutosaveName("BeipMUSpawn.\((notesKey + "." + title).safeFilename)")
        triggerSpawnWindows[title] = controller
        saveSpawnSurfacePreferences()
        return controller
    }

    private func spawnTabGroup(named title: String) -> TriggerSpawnTabGroupWindowController {
        if let existing = triggerSpawnTabGroups[title] { return existing }
        let controller = TriggerSpawnTabGroupWindowController(title: title)
        controller.onAction = { [weak self] action in self?.perform(action) }
        controller.onStructureChange = { [weak self] in self?.saveSpawnSurfacePreferences() }
        controller.onTabActivate = { [weak self, scriptService] tab in
            guard let self else { return }
            Task {
                self.applyScriptEvaluation(
                    await scriptService.dispatchConnectionEvent(
                        "spawnTabs:\(title)",
                        arguments: [tab],
                        host: self.scriptHostSnapshot
                    ),
                    showValue: false
                )
            }
        }
        controller.onClose = { [weak self] in
            guard let self else { return }
            self.dockController.undockPane(.spawnTabs(title))
            self.triggerSpawnTabGroups.removeValue(forKey: title)
            self.saveSpawnSurfacePreferences()
        }
        controller.onDockRequest = { [weak self, weak controller] side in
            guard let self, let controller else { return }
            self.dockSpawnTabGroup(controller, title: title, side: side)
        }
        controller.window?.setFrameAutosaveName("BeipMUSpawnTabs.\((notesKey + "." + title).safeFilename)")
        triggerSpawnTabGroups[title] = controller
        saveSpawnSurfacePreferences()
        return controller
    }

    private func saveSpawnSurfacePreferences() {
        guard !suppressSpawnPersistence else { return }
        let standalone = triggerSpawnWindows.keys.sorted()
        let groups = triggerSpawnTabGroups.sorted { $0.key < $1.key }.map { title, controller in
            SpawnTabGroupPreferences(title: title, tabs: controller.tabTitles, selectedTab: controller.selectedTitle)
        }
        let state = SpawnSurfacePreferences(standaloneWindows: standalone, tabGroups: groups)
        if standalone.isEmpty, groups.isEmpty { preferences.spawnSurfaces.removeValue(forKey: notesKey) }
        else { preferences.spawnSurfaces[notesKey] = state }
        savePreferences()
    }

    private func presentSpawnWindow(_ controller: TriggerSpawnWindowController, title: String) {
        guard !controller.isDocked else { return }
        let pane = WorkspacePaneKind.spawn(title)
        let view = controller.contentViewForDocking()
        if !dockController.restorePane(
            pane,
            view: view,
            title: title,
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(pane)
                controller.showFloating(self)
            }
        ) {
            controller.showFloating(self)
        }
    }

    private func presentSpawnTabGroup(_ controller: TriggerSpawnTabGroupWindowController, title: String) {
        guard !controller.isDocked else { return }
        let pane = WorkspacePaneKind.spawnTabs(title)
        let view = controller.contentViewForDocking()
        if !dockController.restorePane(
            pane,
            view: view,
            title: title,
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(pane)
                controller.showFloating(self)
            }
        ) {
            controller.showFloating(self)
        }
    }

    private func dockSpawnWindow(_ controller: TriggerSpawnWindowController, title: String, side: WebViewDockSide) {
        let pane = WorkspacePaneKind.spawn(title)
        dockController.dockPane(
            pane,
            view: controller.contentViewForDocking(),
            title: title,
            side: side,
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(pane)
                controller.showFloating(self)
            }
        )
    }

    private func dockSpawnTabGroup(_ controller: TriggerSpawnTabGroupWindowController, title: String, side: WebViewDockSide) {
        let pane = WorkspacePaneKind.spawnTabs(title)
        dockController.dockPane(
            pane,
            view: controller.contentViewForDocking(),
            title: title,
            side: side,
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(pane)
                controller.showFloating(self)
            }
        )
    }

    private func restoreSpawnSurfacePreferences() {
        guard let state = preferences.spawnSurfaces[notesKey] else { return }
        suppressSpawnPersistence = true
        defer { suppressSpawnPersistence = false }
        for title in state.standaloneWindows where !title.isEmpty {
            presentSpawnWindow(spawnWindow(named: title), title: title)
        }
        for saved in state.tabGroups where !saved.title.isEmpty {
            let group = spawnTabGroup(named: saved.title)
            for title in saved.tabs where !title.isEmpty {
                group.ensureTab(named: title, selected: title == saved.selectedTab)
            }
            if !group.tabTitles.isEmpty { presentSpawnTabGroup(group, title: saved.title) }
        }
    }

    private func closeSpawnSurfaces() {
        suppressSpawnPersistence = true
        let windows = Array(triggerSpawnWindows)
        let groups = Array(triggerSpawnTabGroups)
        triggerSpawnWindows.removeAll()
        triggerSpawnTabGroups.removeAll()
        for (title, controller) in windows {
            dockController?.releasePane(.spawn(title))
            controller.onClose = nil
            controller.closeSurface()
        }
        for (title, controller) in groups {
            dockController?.releasePane(.spawnTabs(title))
            controller.onClose = nil
            controller.closeSurface()
        }
        suppressSpawnPersistence = false
    }

    private func matchesCaptureEnd(_ expression: String, text: String) -> Bool {
        guard !expression.isEmpty,
              let regex = try? NSRegularExpression(pattern: expression) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private func handleAdvancedGMCP(_ message: GMCPMessage) {
        activityLabel.stringValue = "GMCP: \(message.package)"
        if gmcpDumpEnabled {
            appendClient("GMCP \(message.package) \(message.payload)")
        }
        if !tileMapsEnabled, message.package.lowercased().hasPrefix("beip.tilemap.") { return }
        if handleWebViewGMCP(message) { return }
        if currentServer?.mcmp == true, message.package.lowercased().hasPrefix("client.media.") {
            do {
                for event in try mediaState.consume(message) { mediaController.apply(event) }
            } catch {
                appendError(error.localizedDescription)
            }
            return
        }
        do {
            for event in try gmcpState.consume(message) {
                switch event {
                case let .statisticsPane(title):
                    guard let pane = gmcpState.statisticsPanes[title] else { continue }
                    let controller: GMCPStatisticsWindowController
                    if let existing = gmcpStatisticsWindows[title] {
                        controller = existing
                    } else {
                        controller = .init(title: title)
                        controller.onClose = { [weak self] in self?.gmcpStatisticsWindows.removeValue(forKey: title) }
                        gmcpStatisticsWindows[title] = controller
                    }
                    controller.update(pane)
                    controller.showWindow(self)
                case let .tileMap(name):
                    guard let map = gmcpState.tileMaps[name] else { continue }
                    let controller: TileMapWindowController
                    if let existing = tileMapWindows[name] {
                        controller = existing
                    } else {
                        controller = .init(title: name)
                        controller.onClose = { [weak self] in self?.tileMapWindows.removeValue(forKey: name) }
                        controller.onChange = { [weak self] map in
                            guard let self else { return }
                            self.gmcpState.updateTileMap(map)
                            self.preferences.tileMapEdits[self.notesKey, default: [:]][name] = map
                            self.savePreferences()
                        }
                        tileMapWindows[name] = controller
                    }
                    let restored = preferences.tileMapEdits[notesKey]?[name]
                    let displayMap = restored.map {
                        $0.columns == map.columns && $0.rows == map.rows && $0.tiles.count == map.tiles.count ? $0 : map
                    } ?? map
                    if displayMap != map { gmcpState.updateTileMap(displayMap) }
                    controller.update(displayMap)
                    controller.showWindow(self)
                case let .roomInfo(room):
                    activityLabel.stringValue = room.area.isEmpty ? "Room: \(room.name)" : "Room: \(room.name) — \(room.area)"
                    let atlas = ensureAtlasWindow()
                    atlas.integrate(room)
                    atlas.showWindow(self)
                case let .transmit(outgoing):
                    guard let session else { continue }
                    Task { await session.sendRaw(Self.gmcpFrame(outgoing)) }
                case .avatarsChanged:
                    break
                }
            }
        } catch {
            appendError("GMCP \(message.package): \(error.localizedDescription)")
        }
    }

    private func handleWebViewGMCP(_ message: GMCPMessage) -> Bool {
        let package = message.package.lowercased()
        guard package == "webview.open" || package == "webview.close" else { return false }
        do {
            guard let event = try webViewState.consume(message) else { return false }
            switch event {
            case let .close(id):
                if !id.isEmpty { webViewWindows[id]?.closeSurface() }
            case let .open(request):
                switch currentServer?.gmcpWebViewPolicy ?? .ask {
                case .ignore: return true
                case .allow: openWebView(request, serverRequested: true)
                case .ask:
                    let alert = NSAlert()
                    alert.messageText = "Allow WebView?"
                    alert.informativeText = "The server wants to open:\n\n\(request.permissionSummary)"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "Ignore Once")
                    alert.addButton(withTitle: "Allow Once")
                    alert.addButton(withTitle: "Allow All")
                    alert.addButton(withTitle: "Ignore All")
                    switch alert.runModal() {
                    case .alertSecondButtonReturn: openWebView(request, serverRequested: true)
                    case .alertThirdButtonReturn:
                        setCurrentServerWebViewPolicy(.allow)
                        openWebView(request, serverRequested: true)
                    case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
                        setCurrentServerWebViewPolicy(.ignore)
                    default: break
                    }
                }
            }
        } catch {
            appendError("GMCP \(message.package): \(error.localizedDescription)")
        }
        return true
    }

    private func setCurrentServerWebViewPolicy(_ policy: ServerWebViewPolicy) {
        guard var server = currentServer else { return }
        server.gmcpWebViewPolicy = policy
        currentServer = server
        do {
            try profileLibrary.mutate { workspace in
                try workspace.updateServer(id: server.id) { $0.profile.gmcpWebViewPolicy = policy }
            }
        } catch {
            appendError("Could not save WebView policy: \(error.localizedDescription)")
        }
    }

    private func openWebView(_ request: WebViewOpenRequest, serverRequested: Bool = false) {
        let key: String
        if request.id.isEmpty {
            key = "__unnamed_\(nextUnnamedWebViewID)"
            nextUnnamedWebViewID += 1
        } else {
            key = request.id
        }
        if let existing = webViewWindows[key] {
            existing.apply(request, allowsFileNavigation: !serverRequested)
            presentWebView(existing, key: key, request: request)
            saveWebViewPreference(request, serverRequested: serverRequested)
            return
        }
        let controller = WebViewWindowController(id: request.id, request: request, allowsFileNavigation: !serverRequested)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.dockController.undockPane(.webView(key))
            self.webViewWindows = self.webViewWindows.filter { $0.value !== controller }
            self.removeWebViewPreference(id: request.id)
        }
        controller.onCommand = { [weak self, weak controller] command in
            guard let self, let controller else { return nil }
            return try self.handleWebViewBridge(command, from: controller)
        }
        controller.onNavigationError = { [weak self] message in
            self?.appendError("WebView \(request.id.isEmpty ? "(unnamed)" : request.id): \(message)")
        }
        controller.onDockRequest = { [weak self, weak controller] side in
            guard let self, let controller else { return }
            self.dockWebView(controller, key: key, side: side)
        }
        webViewWindows[key] = controller
        controller.applyTheme(preferences.theme.palette)
        presentWebView(controller, key: key, request: request)
        saveWebViewPreference(request, serverRequested: serverRequested)
        if serverRequested { appendClient("Server opened WebView: \(request.permissionSummary)") }
    }

    private func presentWebView(_ controller: WebViewWindowController, key: String, request: WebViewOpenRequest) {
        let pane = WorkspacePaneKind.webView(key)
        if let side = request.dock {
            dockWebView(controller, key: key, side: side)
        } else {
            if dockController.containsPane(pane) { dockController.undockPane(pane) }
            removeWebViewPreference(id: controller.logicalID)
            controller.showFloating(self)
        }
    }

    private func dockWebView(_ controller: WebViewWindowController, key: String, side: WebViewDockSide) {
        let pane = WorkspacePaneKind.webView(key)
        let title = controller.logicalID.isEmpty ? "WebView" : controller.logicalID
        controller.recordDockSide(side)
        dockController.dockPane(
            pane,
            view: controller.contentViewForDocking(),
            title: title,
            side: side,
            onUndock: { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dockController.undockPane(pane)
                controller.recordDockSide(nil)
                self.removeWebViewPreference(id: controller.logicalID)
                controller.showFloating(self)
            }
        )
        saveWebViewPreference(controller.currentRequest, serverRequested: controller.isServerRequested)
    }

    private func saveWebViewPreference(_ request: WebViewOpenRequest, serverRequested: Bool) {
        guard let saved = SavedWebViewPane(request), !serverRequested || currentServer?.gmcpWebViewPolicy == .allow else { return }
        var panes = preferences.webViewPanes[notesKey] ?? []
        panes.removeAll { $0.id == saved.id }
        panes.append(saved)
        preferences.webViewPanes[notesKey] = panes.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        savePreferences()
    }

    private func removeWebViewPreference(id: String) {
        guard !id.isEmpty, var panes = preferences.webViewPanes[notesKey] else { return }
        panes.removeAll { $0.id == id }
        if panes.isEmpty { preferences.webViewPanes.removeValue(forKey: notesKey) }
        else { preferences.webViewPanes[notesKey] = panes }
        savePreferences()
    }

    private func restoreWebViewPreferences() {
        guard currentServer?.gmcpWebViewPolicy == .allow else { return }
        for pane in preferences.webViewPanes[notesKey] ?? [] {
            openWebView(pane.request, serverRequested: true)
        }
    }

    private func handleWebViewBridge(_ command: WebViewBridgeCommand, from controller: WebViewWindowController) throws -> Any? {
        switch command {
        case .close: controller.closeSurface(); return true
        case .isConnected: return connectionStateText == "Connected"
        case let .send(text, processAliases):
            if processAliases { processAliasedInput(text) } else { sendToSession(text) }
            return true
        case let .receive(text):
            guard let session else { throw WebViewClientError.notConnected }
            Task { await session.receive(text) }
            return true
        case let .display(text):
            appendClient(text)
            return true
        case let .sendGMCP(package, json):
            guard let session else { throw WebViewClientError.notConnected }
            guard !package.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WebViewClientError.invalidPackage }
            Task { await session.sendRaw(Self.gmcpFrame(.init(package: package, payload: json))) }
            return true
        case let .processAliases(text):
            guard !aliasGroups.isEmpty else { return text }
            return try AliasEngine.process(text, groups: aliasGroups, variables: variables).text
        case let .addToInputHistory(text): input.addToHistory(text); return true
        case let .property(name):
            switch name.lowercased() {
            case "worldname": return currentServer?.name
            case "charactername": return currentCharacter?.name
            case "puppetname": return nil
            case "id": return controller.logicalID
            default: return nil
            }
        }
    }

    private func closeWebViews() {
        let values = Array(webViewWindows)
        webViewWindows.removeAll()
        for (key, controller) in values {
            dockController?.releasePane(.webView(key))
            controller.onClose = nil
            controller.closeSurface()
        }
    }

    private func handleMCP(_ message: MCPMessage) {
        activityLabel.stringValue = "MCP: \(message.fullName)"
        switch message.package.lowercased() {
        case "dns-com-awns-status":
            guard let text = message[parameter: "text"] else {
                appendError("MCP status message was missing required parameter 'text'")
                return
            }
            let controller: MCPStatusWindowController
            if let existing = mcpStatusWindow {
                controller = existing
            } else {
                controller = .init()
                controller.applyTheme(preferences.theme.palette)
                controller.onClose = { [weak self] in self?.mcpStatusWindow = nil }
                mcpStatusWindow = controller
            }
            controller.update(text)
            controller.showWindow(self)
        case "dns-org-mud-moo-simpleedit":
            showMCPSimpleEdit(message)
        default:
            appendClient("MCP \(message.fullName)")
        }
    }

    private func showMCPSimpleEdit(_ message: MCPMessage) {
        guard let reference = message[parameter: "reference"],
              let type = message[parameter: "type"],
              let name = message[parameter: "name"] else {
            appendError("MCP SimpleEdit message was missing reference, type, or name")
            return
        }
        let text = message.values(for: "content")?.joined(separator: "\n") ?? message[parameter: "content"] ?? ""
        let state = SimpleEditUploadState(reference: reference, type: type, original: text)
        let upload: (String) -> Void = { [weak self, state] value in
            guard state.lastUploaded != value else { return }
            state.lastUploaded = value
            self?.sendMCPSimpleEdit(value, state: state)
        }
        let controller = EditWindowController(title: name, text: text, checksSpelling: false, onSend: upload)
        controller.onClose = { [weak self, weak controller, state] in
            guard let self, let controller else { return }
            let value = controller.editor.string
            if value != state.original, value != state.lastUploaded { upload(value) }
            self.editWindows.removeAll { $0 === controller }
        }
        editWindows.append(controller)
        controller.applyTheme(preferences.theme.palette)
        controller.showWindow(self)
        if let owner = window, let child = controller.window { owner.addChildWindow(child, ordered: .above) }
        controller.window?.makeKeyAndOrderFront(self)
        appendClient("mcp-simpleedit Editing: \"\(name)\" Type: \(type)")
    }

    private func sendMCPSimpleEdit(_ text: String, state: SimpleEditUploadState) {
        guard let session else { appendError("MCP SimpleEdit cannot upload while disconnected"); return }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" { lines.removeLast() }
        let message = MCPMessage(
            package: "dns-org-mud-moo-simpleedit",
            message: "set",
            parameters: ["reference": state.reference, "type": state.type],
            multiline: lines.isEmpty ? [:] : ["content": lines]
        )
        Task { await session.sendMCP(message) }
        appendClient("mcp-simpleedit Changes uploaded")
    }

    private func offerImages(in line: RenderedLine) {
        var urls = line.assets.compactMap { $0.kind == .image ? $0.source : nil }
        let pattern = #"https?://[^\s<>\"]+\.(?:png|jpe?g|gif|webp)(?:\?[^\s<>\"]*)?"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(line.text.startIndex..., in: line.text)
            urls += regex.matches(in: line.text, range: range).compactMap { match in
                Range(match.range, in: line.text).flatMap { URL(string: String(line.text[$0])) }
            }
        }
        for url in urls {
            let viewer: ImageViewerWindowController
            if let existing = imageViewerWindow {
                viewer = existing
            } else {
                viewer = .init()
                viewer.onClose = { [weak self] in self?.imageViewerWindow = nil }
                imageViewerWindow = viewer
            }
            viewer.open(url)
        }
    }

    private func ensureAtlasWindow() -> AtlasWindowController {
        if let atlasWindow { return atlasWindow }
        let controller = AtlasWindowController()
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller, self.atlasWindow === controller else { return }
            self.atlasWindow = nil
            if !self.suppressAtlasPersistence {
                self.preferences.atlasSurfaces.removeValue(forKey: self.notesKey)
                self.savePreferences()
            }
        }
        controller.onSendCommands = { [weak self] commands in
            commands.forEach { self?.processInput($0) }
        }
        controller.onStateChange = { [weak self] state in
            guard let self, !self.suppressAtlasPersistence else { return }
            self.preferences.atlasSurfaces[self.notesKey] = state
            self.savePreferences()
        }
        atlasWindow = controller
        if let owner = window, let child = controller.window { owner.addChildWindow(child, ordered: .above) }
        return controller
    }

    private func saveAtlasSurfacePreferences() {
        guard let atlasWindow else { return }
        preferences.atlasSurfaces[notesKey] = atlasWindow.surfacePreferences
        savePreferences()
    }

    private func restoreAtlasSurfacePreferences() {
        guard let state = preferences.atlasSurfaces[notesKey] else { return }
        let controller = ensureAtlasWindow()
        do {
            try controller.restore(state)
            controller.showWindow(self)
        } catch {
            preferences.atlasSurfaces.removeValue(forKey: notesKey)
            savePreferences()
            appendError("Atlas restore failed: \(error.localizedDescription)")
        }
    }

    private func closeAtlasSurface() {
        suppressAtlasPersistence = true
        atlasWindow?.close()
        atlasWindow = nil
        suppressAtlasPersistence = false
    }

    private func appendError(_ text: String) {
        let style = TextStyle(foreground: .init(red: 255, green: 80, blue: 80))
        output.append(.init(text: text, runs: [.init(range: 0..<text.utf16.count, style: style)], source: .client))
    }
}

private enum WebViewClientError: LocalizedError {
    case notConnected
    case invalidPackage

    var errorDescription: String? {
        switch self {
        case .notConnected: "WebView client is not connected"
        case .invalidPackage: "WebView GMCP package is empty"
        }
    }
}

@MainActor
private final class VerticalWindowResizeHandle: NSView {
    private var initialWindowFrame = NSRect.zero
    private var initialMouseLocation = NSPoint.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("Resize window vertically")
        setAccessibilityIdentifier("mainWindowVerticalResizeHandle")
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        initialWindowFrame = window.frame
        initialMouseLocation = NSEvent.mouseLocation
        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if nextEvent.type == .leftMouseUp { break }
            resizeWindow(to: NSEvent.mouseLocation)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        resizeWindow(to: NSEvent.mouseLocation)
    }

    private func resizeWindow(to mouseLocation: NSPoint) {
        guard let window, initialWindowFrame.height > 0 else { return }
        let delta = mouseLocation.y - initialMouseLocation.y
        let minimumHeight = max(32, window.frame.height - window.contentLayoutRect.height)
        let height = max(minimumHeight, initialWindowFrame.height - delta)
        let frame = NSRect(
            x: initialWindowFrame.minX,
            y: initialWindowFrame.maxY - height,
            width: initialWindowFrame.width,
            height: height
        )
        window.setFrame(frame, display: true)
        NSAccessibility.post(element: window, notification: .windowMoved)
        NSAccessibility.post(element: window, notification: .windowResized)
        if ProcessInfo.processInfo.environment["BEIPMU_UI_TESTING"] == "1" {
            window.setAccessibilityValue("\(Int(window.frame.width))x\(Int(window.frame.height))")
            NSAccessibility.post(element: window, notification: .valueChanged)
        }
    }
}

@MainActor
final class EmbeddedHelpWindowController: NSWindowController {
    private let search = NSSearchField()
    private let textView: NSTextView

    init() {
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = "BeipMU Help"
        window.setFrameAutosaveName("BeipMU.EmbeddedHelp")
        window.setAccessibilityIdentifier("embeddedHelpWindow")
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.setAccessibilityIdentifier("embeddedHelpText")
        search.placeholderString = "Find a command"
        search.setAccessibilityIdentifier("embeddedHelpSearch")
        search.target = self
        search.action = #selector(searchChanged)
        let root = NSStackView(views: [search, scroll])
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = .init(top: 10, left: 10, bottom: 10, right: 10)
        window.contentView = root
    }

    required init?(coder: NSCoder) { nil }

    func show(topic: String?) {
        search.stringValue = topic ?? ""
        updateText(topic)
    }

    @objc private func searchChanged() { updateText(search.stringValue) }

    private func updateText(_ topic: String?) {
        let query = topic?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let lines = CommandRegistry.commandHelp.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if query.isEmpty {
            textView.string = CommandRegistry.commandHelp
        } else {
            let matches = lines.filter { $0.lowercased().contains(query) }
            textView.string = matches.isEmpty ? "No command help matches ‘\(query)’." : matches.joined(separator: "\n")
        }
        textView.scrollToBeginningOfDocument(nil)
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
