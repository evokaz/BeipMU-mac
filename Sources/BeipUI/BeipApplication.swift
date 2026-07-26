import AppKit
import BeipCore

@MainActor
public enum BeipApplication {
    private static var retainedDelegate: ApplicationDelegate?

    public static func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = ApplicationDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.run()
        fatalError("NSApplication.run unexpectedly returned")
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windows: [ClientWindowController] = []
    private let profileLibrary = ProfileLibrary()
    private var configurationManager: ConfigurationManagerWindowController?
    private var keyboardShortcuts = KeyboardShortcutStore.load()
    private var shortcutItems: [ShortcutAction: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        if ProcessInfo.processInfo.environment["BEIPMU_UI_TEST_RESET"] == "1" {
            WorkspacePreferencesStore.resetUITestDefaults()
        }
        keyboardShortcuts = KeyboardShortcutStore.load(from: profileLibrary.keyEquivalents)
        configureMenu()
        newWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        activeController?.startPerformanceSoakIfRequested()
        activeController?.startM10ScaleIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if profileLibrary.workspace.isDirty {
            let alert = NSAlert()
            alert.messageText = "Quit with unsaved configuration changes?"
            alert.informativeText = "Changes in the world and character manager have not been saved."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit Without Saving")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        windows.forEach { $0.prepareForApplicationTermination() }
        return .terminateNow
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = makeController()
        controller.showWindow(sender)
        controller.startDeviceMediaAuditIfRequested()
    }

    @discardableResult
    func openPuppet(
        master: ClientWindowController,
        server: ServerProfile,
        character: CharacterProfile,
        puppet: PuppetProfile
    ) -> ClientWindowController {
        if let existing = master.puppetController(for: puppet.id) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let controller = makeController()
        controller.showWindow(nil)
        controller.startPuppetSession(master: master, server: server, character: character, puppet: puppet)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    @objc func newTab(_ sender: Any?) {
        guard let parentWindow = activeController?.window else { newWindow(sender); return }
        let controller = makeController()
        guard let childWindow = controller.window else { return }
        parentWindow.tabbingMode = .preferred
        childWindow.tabbingMode = .preferred
        parentWindow.addTabbedWindow(childWindow, ordered: .above)
        controller.showWindow(sender)
        childWindow.makeKeyAndOrderFront(sender)
    }

    @objc func newInputWindow(_ sender: Any?) { activeController?.showNewInputWindow() }
    @objc func newEditWindow(_ sender: Any?) { activeController?.showNewEditWindow() }

    private func makeController() -> ClientWindowController {
        let controller = ClientWindowController(profileLibrary: profileLibrary)
        windows.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windows.removeAll { $0 === controller }
        }
        controller.onThemeChange = { [weak self] theme in
            self?.windows.forEach { $0.applyThemeSettings(theme) }
        }
        controller.onTextWindowSettingsChange = { [weak self] in
            self?.windows.forEach { $0.reloadTextWindowPreferences() }
        }
        return controller
    }

    @objc func connect(_ sender: Any?) { activeController?.showConnectDialog() }
    @objc func manageProfiles(_ sender: Any?) {
        if configurationManager == nil {
            let controller = ConfigurationManagerWindowController(library: profileLibrary)
            controller.onRequestSaveAs = { [weak self] in self?.saveConfigurationAs(nil) }
            configurationManager = controller
        }
        configurationManager?.showWindow(sender)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc func newConfiguration(_ sender: Any?) {
        guard confirmDiscardIfNeeded() else { return }
        do {
            try profileLibrary.newConfiguration()
            manageProfiles(sender)
        } catch { NSApplication.shared.presentError(error) }
    }

    @objc func openConfiguration(_ sender: Any?) {
        guard confirmDiscardIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Config.txt"
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await profileLibrary.open(url)
                manageProfiles(sender)
                if let recovery = profileLibrary.workspace.recoveredFrom {
                    let alert = NSAlert()
                    alert.messageText = "Recovered configuration from backup"
                    alert.informativeText = "The primary file could not be read. Loaded \(recovery.lastPathComponent) without overwriting Config.txt."
                    alert.runModal()
                }
            } catch { NSApplication.shared.presentError(error) }
        }
    }

    @objc func saveConfiguration(_ sender: Any?) {
        guard profileLibrary.workspace.sourceURL != nil else { saveConfigurationAs(sender); return }
        Task {
            do { try await profileLibrary.save() }
            catch { NSApplication.shared.presentError(error) }
        }
    }

    @objc func saveConfigurationAs(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "Save Configuration"
        panel.nameFieldStringValue = "Config.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { try await profileLibrary.save(as: url) }
            catch { NSApplication.shared.presentError(error) }
        }
    }

    @objc func exportConfiguration(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "Export Portable Config.txt"
        panel.nameFieldStringValue = "Config-export.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try profileLibrary.export(to: url) }
        catch { NSApplication.shared.presentError(error) }
    }
    @objc func disconnect(_ sender: Any?) { activeController?.disconnect() }
    @objc func logging(_ sender: Any?) { activeController?.showLoggingControls() }
    @objc func statistics(_ sender: Any?) { activeController?.showConnectionStatistics() }
    @objc func debugNetwork(_ sender: Any?) { activeController?.showNetworkDebugger() }
    @objc func debugAliases(_ sender: Any?) { activeController?.showAutomationDebugger(.aliases) }
    @objc func debugTriggers(_ sender: Any?) { activeController?.showAutomationDebugger(.triggers) }
    @objc func debugTimers(_ sender: Any?) { activeController?.showAutomationDebugger(.timers) }
    @objc func debugScripts(_ sender: Any?) { activeController?.showScriptDebugger() }
    @objc func inspectRestoreLog(_ sender: Any?) { activeController?.showRestoreInformation() }
    @objc func clear(_ sender: Any?) { activeController?.clearOutput() }
    @objc func find(_ sender: Any?) { activeController?.showFindDialog() }
    @objc func pauseOutput(_ sender: Any?) { activeController?.toggleOutputPause() }
    @objc func toggleTimestamps(_ sender: Any?) { activeController?.toggleTimestamps() }
    @objc func toggleFanFold(_ sender: Any?) { activeController?.toggleFanFold() }
    @objc func copyOutputPlain(_ sender: Any?) { activeController?.copyOutputAsPlainText() }
    @objc func copyOutputHTML(_ sender: Any?) { activeController?.copyOutputAsHTML() }
    @objc func toggleOutputMarker(_ sender: Any?) { activeController?.toggleOutputMarker() }
    @objc func toggleOutputSplit(_ sender: Any?) { activeController?.toggleOutputSplit() }
    @objc func toggleStickyInput(_ sender: Any?) { activeController?.toggleStickyInput() }
    @objc func toggleSpellChecking(_ sender: Any?) { activeController?.toggleSpellChecking() }
    @objc func setInputPrefix(_ sender: Any?) { activeController?.showInputPrefixDialog() }
    @objc func convertReturns(_ sender: Any?) { activeController?.applyInputConversion(.returns) }
    @objc func convertTabs(_ sender: Any?) { activeController?.applyInputConversion(.tabs) }
    @objc func convertSpaces(_ sender: Any?) { activeController?.applyInputConversion(.spaces) }
    @objc func settings(_ sender: Any?) { activeController?.showWorkspaceSettings() }
    @objc func globalTextWindowSettings(_ sender: Any?) { activeController?.showGlobalTextWindowSettings() }
    @objc func globalInputWindowSettings(_ sender: Any?) { activeController?.showGlobalInputWindowSettings() }
    @objc func themeSettings(_ sender: Any?) { activeController?.showThemeSettings() }
    @objc func toggleMute(_ sender: Any?) { activeController?.toggleMute() }
    @objc func showNotes(_ sender: Any?) { activeController?.showCharacterNotes() }
    @objc func showDiagnostics(_ sender: Any?) { activeController?.showSessionDiagnostics() }
    @objc func showAtlas(_ sender: Any?) { activeController?.showAtlas() }
    @objc func showHelp(_ sender: Any?) { activeController?.showEmbeddedHelp() }
    @objc func layoutTabbedRight(_ sender: Any?) { activeController?.setWorkspaceLayout(.tabbedRight) }
    @objc func layoutSplitSidebars(_ sender: Any?) { activeController?.setWorkspaceLayout(.splitSidebars) }
    @objc func layoutStackedRight(_ sender: Any?) { activeController?.setWorkspaceLayout(.stackedRight) }
    @objc func layoutStackedBottom(_ sender: Any?) { activeController?.setWorkspaceLayout(.stackedBottom) }
    @objc func layoutMainOnly(_ sender: Any?) { activeController?.setWorkspaceLayout(.mainOnly) }
    @objc func hideDock(_ sender: Any?) { activeController?.setDockPlacement(.hidden) }
    @objc func dockLeft(_ sender: Any?) { activeController?.setDockPlacement(.left) }
    @objc func dockRight(_ sender: Any?) { activeController?.setDockPlacement(.right) }
    @objc func dockTop(_ sender: Any?) { activeController?.setDockPlacement(.top) }
    @objc func dockBottom(_ sender: Any?) { activeController?.setDockPlacement(.bottom) }
    @objc func floatDock(_ sender: Any?) { activeController?.setDockPlacement(.floating) }
    @objc func maximizeWindow(_ sender: Any?) { activeController?.toggleMaximize() }
    @objc func toggleFullScreen(_ sender: Any?) { activeController?.toggleFullScreen() }

    @objc func configureKeyboardShortcuts(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = "Enter shortcuts such as ⌘N, Command+Shift+P, F1, or Shift+F2."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Restore Defaults")

        var fields: [ShortcutAction: NSTextField] = [:]
        let rows = ShortcutAction.allCases.map { action -> [NSView] in
            let field = NSTextField(string: keyboardShortcuts[action]?.displayString ?? action.defaultShortcut.displayString)
            field.setAccessibilityIdentifier("shortcut.\(action.rawValue)")
            fields[action] = field
            return [NSTextField(labelWithString: action.title + ":"), field]
        }
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 160
        grid.rowSpacing = 7
        grid.frame = NSRect(x: 0, y: 0, width: 380, height: CGFloat(rows.count * 31))
        alert.accessoryView = grid

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            var parsed: [ShortcutAction: KeyboardShortcut] = [:]
            for action in ShortcutAction.allCases {
                guard let value = fields[action]?.stringValue,
                      let shortcut = KeyboardShortcut.parse(value) else {
                    showShortcutError("Invalid shortcut for \(action.title).")
                    return
                }
                parsed[action] = shortcut
            }
            let collisions = Dictionary(grouping: parsed, by: { "\($0.value.keyEquivalent)|\($0.value.modifierRawValue)" })
                .values.first { $0.count > 1 }
            if let collisions {
                showShortcutError("The shortcut \(collisions[0].value.displayString) is assigned more than once.")
                return
            }
            do {
                try profileLibrary.saveKeyEquivalents(KeyboardShortcutStore.serialized(parsed))
                keyboardShortcuts = parsed
                applyKeyboardShortcuts()
            } catch { NSApplication.shared.presentError(error) }
        case .alertThirdButtonReturn:
            do {
                try profileLibrary.saveKeyEquivalents([:])
                keyboardShortcuts = KeyboardShortcutStore.load()
                applyKeyboardShortcuts()
            } catch { NSApplication.shared.presentError(error) }
        default: break
        }
    }

    private var activeController: ClientWindowController? {
        guard let keyWindow = NSApplication.shared.keyWindow else { return windows.last }
        if let controller = keyWindow.windowController as? ClientWindowController { return controller }
        if let owner = windows.first(where: { $0.window?.childWindows?.contains(keyWindow) == true }) {
            return owner
        }
        return windows.last
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard profileLibrary.workspace.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved configuration changes?"
        alert.informativeText = "This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showShortcutError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Shortcut Not Saved"
        alert.informativeText = message
        alert.runModal()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let controller = activeController else { return false }
        let action = menuItem.action
        switch action {
        case #selector(logging(_:)):
            menuItem.title = controller.activeLogCount == 0 ? "Logging…" : "Logging… (\(controller.activeLogCount) active)"
        case #selector(toggleTimestamps(_:)): menuItem.state = controller.timestampsEnabled ? .on : .off
        case #selector(toggleFanFold(_:)): menuItem.state = controller.fanFoldEnabled ? .on : .off
        case #selector(toggleOutputSplit(_:)): menuItem.state = controller.outputSplitEnabled ? .on : .off
        case #selector(toggleStickyInput(_:)): menuItem.state = controller.stickyInputEnabled ? .on : .off
        case #selector(toggleSpellChecking(_:)): menuItem.state = controller.spellCheckingEnabled ? .on : .off
        case #selector(toggleMute(_:)): menuItem.state = controller.muted ? .on : .off
        case #selector(layoutTabbedRight(_:)): menuItem.state = controller.usesWorkspaceLayout(.tabbedRight) ? .on : .off
        case #selector(layoutSplitSidebars(_:)): menuItem.state = controller.usesWorkspaceLayout(.splitSidebars) ? .on : .off
        case #selector(layoutStackedRight(_:)): menuItem.state = controller.usesWorkspaceLayout(.stackedRight) ? .on : .off
        case #selector(layoutStackedBottom(_:)): menuItem.state = controller.usesWorkspaceLayout(.stackedBottom) ? .on : .off
        case #selector(layoutMainOnly(_:)): menuItem.state = controller.usesWorkspaceLayout(.mainOnly) ? .on : .off
        case #selector(hideDock(_:)): menuItem.state = controller.legacyDockPlacement == .hidden ? .on : .off
        case #selector(dockLeft(_:)): menuItem.state = controller.legacyDockPlacement == .left ? .on : .off
        case #selector(dockRight(_:)): menuItem.state = controller.legacyDockPlacement == .right ? .on : .off
        case #selector(dockTop(_:)): menuItem.state = controller.legacyDockPlacement == .top ? .on : .off
        case #selector(dockBottom(_:)): menuItem.state = controller.legacyDockPlacement == .bottom ? .on : .off
        case #selector(floatDock(_:)): menuItem.state = controller.legacyDockPlacement == .floating ? .on : .off
        default: break
        }
        return true
    }

    private func configureMenu() {
        shortcutItems.removeAll()
        let main = NSMenu()
        NSApplication.shared.mainMenu = main

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About BeipMU", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(settings(_:)), keyEquivalent: ",")
        appMenu.addItem(
            withTitle: "Global Text Window Settings…",
            action: #selector(globalTextWindowSettings(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(
            withTitle: "Global Input Window Settings…",
            action: #selector(globalInputWindowSettings(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(withTitle: "Theme…", action: #selector(themeSettings(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Keyboard Shortcuts…", action: #selector(configureKeyboardShortcuts(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit BeipMU", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        addShortcutItem(to: fileMenu, action: .newWindow, selector: #selector(newWindow(_:)))
        addShortcutItem(to: fileMenu, action: .newTab, selector: #selector(newTab(_:)))
        fileMenu.addItem(withTitle: "New Input Window", action: #selector(newInputWindow(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "New Edit Window", action: #selector(newEditWindow(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "New Configuration", action: #selector(newConfiguration(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Open Config…", action: #selector(openConfiguration(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Save Config", action: #selector(saveConfiguration(_:)), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Save Config As…", action: #selector(saveConfigurationAs(_:)), keyEquivalent: "S")
        fileMenu.addItem(withTitle: "Export Config…", action: #selector(exportConfiguration(_:)), keyEquivalent: "e")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let connectionItem = NSMenuItem()
        main.addItem(connectionItem)
        let connectionMenu = NSMenu(title: "Connection")
        connectionItem.submenu = connectionMenu
        addShortcutItem(to: connectionMenu, action: .connect, selector: #selector(connect(_:)), title: "Connect…")
        addShortcutItem(to: connectionMenu, action: .disconnect, selector: #selector(disconnect(_:)))
        addShortcutItem(to: connectionMenu, action: .logging, selector: #selector(logging(_:)), title: "Logging…")
        connectionMenu.addItem(withTitle: "Statistics…", action: #selector(statistics(_:)), keyEquivalent: "")
        let debuggers = NSMenu(title: "Debuggers")
        debuggers.addItem(withTitle: "Network…", action: #selector(debugNetwork(_:)), keyEquivalent: "")
        debuggers.addItem(withTitle: "Aliases…", action: #selector(debugAliases(_:)), keyEquivalent: "")
        debuggers.addItem(withTitle: "Triggers…", action: #selector(debugTriggers(_:)), keyEquivalent: "")
        debuggers.addItem(withTitle: "Timers…", action: #selector(debugTimers(_:)), keyEquivalent: "")
        debuggers.addItem(withTitle: "Scripts…", action: #selector(debugScripts(_:)), keyEquivalent: "")
        debuggers.addItem(.separator())
        debuggers.addItem(withTitle: "Inspect Restore.dat", action: #selector(inspectRestoreLog(_:)), keyEquivalent: "")
        let debuggersItem = NSMenuItem(title: "Debuggers", action: nil, keyEquivalent: "")
        debuggersItem.submenu = debuggers
        connectionMenu.addItem(debuggersItem)
        connectionMenu.addItem(.separator())
        connectionMenu.addItem(withTitle: "Worlds & Characters…", action: #selector(manageProfiles(_:)), keyEquivalent: "")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        addShortcutItem(to: editMenu, action: .findOutput, selector: #selector(find(_:)), title: "Find in Output…")
        editMenu.addItem(withTitle: "Copy Output as Plain Text", action: #selector(copyOutputPlain(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Copy Output as HTML", action: #selector(copyOutputHTML(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        addShortcutItem(to: editMenu, action: .clearOutput, selector: #selector(clear(_:)))
        let conversionMenu = NSMenu(title: "Conversion")
        addShortcutItem(to: conversionMenu, action: .convertReturns, selector: #selector(convertReturns(_:)))
        addShortcutItem(to: conversionMenu, action: .convertTabs, selector: #selector(convertTabs(_:)))
        addShortcutItem(to: conversionMenu, action: .convertSpaces, selector: #selector(convertSpaces(_:)))
        let conversionItem = NSMenuItem(title: "Conversion", action: nil, keyEquivalent: "")
        conversionItem.submenu = conversionMenu
        editMenu.addItem(conversionItem)

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        addShortcutItem(to: viewMenu, action: .pauseOutput, selector: #selector(pauseOutput(_:)))
        viewMenu.addItem(withTitle: "Show Timestamps", action: #selector(toggleTimestamps(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Fan-fold Backgrounds", action: #selector(toggleFanFold(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Split Output View", action: #selector(toggleOutputSplit(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Toggle Marker on Selected Line", action: #selector(toggleOutputMarker(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Sticky Input", action: #selector(toggleStickyInput(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Input Prefix…", action: #selector(setInputPrefix(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Check Spelling", action: #selector(toggleSpellChecking(_:)), keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Mute Current Tab", action: #selector(toggleMute(_:)), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Atlas Map…", action: #selector(showAtlas(_:)), keyEquivalent: "")
        let panes = NSMenu(title: "Workspace Panes")
        panes.addItem(withTitle: "Character Notes", action: #selector(showNotes(_:)), keyEquivalent: "")
        panes.addItem(withTitle: "Session Diagnostics", action: #selector(showDiagnostics(_:)), keyEquivalent: "")
        panes.addItem(.separator())
        panes.addItem(withTitle: "Tabbed Right", action: #selector(layoutTabbedRight(_:)), keyEquivalent: "")
        panes.addItem(withTitle: "Split Sidebars", action: #selector(layoutSplitSidebars(_:)), keyEquivalent: "")
        panes.addItem(withTitle: "Stacked Right", action: #selector(layoutStackedRight(_:)), keyEquivalent: "")
        panes.addItem(withTitle: "Stacked Bottom", action: #selector(layoutStackedBottom(_:)), keyEquivalent: "")
        panes.addItem(withTitle: "Main Session Only", action: #selector(layoutMainOnly(_:)), keyEquivalent: "")
        panes.addItem(.separator())
        panes.addItem(withTitle: "Dock Left", action: #selector(dockLeft(_:)), keyEquivalent: "")
        panes.addItem(withTitle: "Dock Right", action: #selector(dockRight(_:)), keyEquivalent: "")
        panes.addItem(withTitle: "Dock Top", action: #selector(dockTop(_:)), keyEquivalent: "")
        panes.addItem(withTitle: "Dock Bottom", action: #selector(dockBottom(_:)), keyEquivalent: "")
        panes.addItem(withTitle: "Float", action: #selector(floatDock(_:)), keyEquivalent: "")
        panes.addItem(withTitle: "Hide", action: #selector(hideDock(_:)), keyEquivalent: "")
        let panesItem = NSMenuItem(title: "Workspace Panes", action: nil, keyEquivalent: "")
        panesItem.submenu = panes
        viewMenu.addItem(panesItem)

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        let zoomItem = windowMenu.addItem(withTitle: "Zoom", action: #selector(maximizeWindow(_:)), keyEquivalent: "")
        zoomItem.target = self
        let fullScreenItem = windowMenu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.target = self
        fullScreenItem.keyEquivalentModifierMask = [.control, .command]
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "{")
        windowMenu.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "}")
        windowMenu.addItem(withTitle: "Move Tab to New Window", action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApplication.shared.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        helpMenu.addItem(withTitle: "BeipMU Help", action: #selector(showHelp(_:)), keyEquivalent: "?")
        applyKeyboardShortcuts()
    }

    @discardableResult
    private func addShortcutItem(
        to menu: NSMenu,
        action: ShortcutAction,
        selector: Selector,
        title: String? = nil
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title ?? action.title, action: selector, keyEquivalent: "")
        shortcutItems[action] = item
        return item
    }

    private func applyKeyboardShortcuts() {
        for (action, item) in shortcutItems {
            let shortcut = keyboardShortcuts[action] ?? action.defaultShortcut
            item.keyEquivalent = shortcut.keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
    }
}
