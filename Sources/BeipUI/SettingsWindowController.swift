import AVFoundation
import AppKit
import BeipCore
import BeipPersistence
import UniformTypeIdentifiers

/// The destinations in the retained Settings window. This is intentionally a
/// small internal routing type: menu commands should describe where to go,
/// not own another settings surface.
enum SettingsSection: String, CaseIterable, Hashable {
    case appearance
    case ansiColors
    case output
    case input
    case restoreLogs
    case scripting
    case shortcuts
    case advanced

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .ansiColors: "ANSI Colors"
        case .output: "Output"
        case .input: "Input"
        case .restoreLogs: "Restore Logs"
        case .scripting: "Scripting"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        }
    }

    var accessibilityIdentifier: String { "settings.section.\(rawValue)" }
}

struct SettingsPresentationContext: Equatable {
    var section: SettingsSection
    var initialScope: TextWindowSettingsEditorView.Scope?
    var identity: TextWindowSettingsIdentity
}

private final class SettingsDocumentView: NSView {
    var onLayout: (() -> Void)?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

@MainActor
private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

@MainActor
private final class SettingsScrollCueView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.height > 0, bounds.width > 0 else { return }

        let fadeRect = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: min(46, bounds.height)
        )
        let background = NSColor.windowBackgroundColor
        NSGradient(
            colors: [
                background.withAlphaComponent(0),
                background.withAlphaComponent(0.9),
            ]
        )?.draw(in: fadeRect, angle: 90)

        let chevron = NSBezierPath()
        let center = NSPoint(x: bounds.midX, y: bounds.maxY - 14)
        chevron.move(to: NSPoint(x: center.x - 5, y: center.y - 2))
        chevron.line(to: center)
        chevron.line(to: NSPoint(x: center.x + 5, y: center.y - 2))
        chevron.lineWidth = 1.5
        NSColor.secondaryLabelColor.setStroke()
        chevron.stroke()
    }
}

@MainActor
private final class ShortcutCaptureField: NSTextField {
    var onCapture: ((KeyboardShortcut?) -> Void)?
    private(set) var isCapturing = false

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            isCapturing = true
            needsDisplay = true
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder {
            isCapturing = false
            needsDisplay = true
        }
        return resignedFirstResponder
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturing else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else {
            super.keyDown(with: event)
            return
        }
        capture(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isCapturing, isEnabled else { return }

        let ring = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
            xRadius: 4,
            yRadius: 4
        )
        ring.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        ring.stroke()
    }

    private func capture(_ event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            onCapture?(.unbound)
        default:
            guard let shortcut = KeyboardShortcut.capture(from: event) else {
                NSSound.beep()
                return
            }
            onCapture?(shortcut)
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    typealias Scope = TextWindowSettingsEditorView.Scope

    private let profileLibrary: ProfileLibrary
    private let preferencesProvider: () -> WorkspacePreferences
    private let shortcutsProvider: () -> [ShortcutAction: KeyboardShortcut]
    private let onPreferencesMutation: () -> Void
    private let onShortcutsMutation: ([ShortcutAction: KeyboardShortcut]) -> Void
    private let nativeShortcutConflict: ([ShortcutAction: KeyboardShortcut]) -> String?
    private let presentShortcutConflict: @MainActor (String) -> Void
    var onFactoryResetRequest: (() -> Void)?
    var onImportConfigurationRequest: (() -> Void)?
    var onExportConfigurationRequest: (() -> Void)?

    private var context: SettingsPresentationContext
    private(set) var selectedSection: SettingsSection = .appearance
    private var selectedScopes: [SettingsSection: Scope] = [:]
    private var preferencesSnapshot: WorkspacePreferences?
    private var applyingExternalChange = false
    private var profileLibraryObserverID: UUID?

    private let sidebar = NSTableView()
    private let sidebarScroll = NSScrollView()
    private let contentScroll = NSScrollView()
    private let contentDocument = SettingsDocumentView()
    private let contentScrollCue = SettingsScrollCueView()
    private let contentStack = NSStackView()
    private var contentIsOverflowing = false
    private var updatingContentScrollCue = false
    private var cachedSectionViews: [SettingsSection: [NSView]] = [:]
    private var contentWidthConstraints: [ObjectIdentifier: NSLayoutConstraint] = [:]
    private var errorLabels: [ObjectIdentifier: NSTextField] = [:]
    private var shortcutFields: [ShortcutAction: NSTextField] = [:]
    private var shortcutErrors: [ShortcutAction: NSTextField] = [:]

    private lazy var fontFamilyNames: [String] = NSFontManager.shared.availableFontFamilies.sorted()
    private lazy var speechVoiceOptions: [(title: String, identifier: String?)] = {
        let voices = AVSpeechSynthesisVoice.speechVoices().sorted {
            $0.language == $1.language
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.language < $1.language
        }
        return [(title: "System Default", identifier: nil)] + voices.map {
            (title: "\($0.name) — \($0.language)", identifier: $0.identifier)
        }
    }()

    private var appearanceMode: NSPopUpButton!
    private var menuStripPosition: NSPopUpButton!
    private var appearanceForeground: NSColorWell!
    private var appearanceBackground: NSColorWell!
    private var appearanceAccent: NSColorWell!

    private var ansiColorTable: NSTableView!
    private var ansiSelectedColor: NSColorWell!
    private var ansiSelectedColorIndex = 0
    private var ansiPreventInvisible: NSButton!
    private var ansiResetOnNewLine: NSButton!
    private var ansiFontBold: NSButton!
    private var ansiParseBlinking: NSButton!
    private var ansiBeepEnabled: NSButton!
    private var ansiSystemBeep: NSButton!
    private var ansiCustomBeep: NSButton!
    private var ansiBeepPath: NSTextField!
    private var ansiBeepChange: NSButton!
    private var ansiBeepPlay: NSButton!
    private var ansiParseCodes: NSButton!

    private var outputScope: NSPopUpButton!
    private var outputInherit: NSButton!
    private var outputFont: NSPopUpButton!
    private var outputFontSize: NSTextField!
    private var outputForeground: NSColorWell!
    private var outputBackground: NSColorWell!
    private var outputLink: NSColorWell!
    private var outputInvert: NSButton!
    private var outputFanFold: NSButton!
    private var outputFanFoldFirst: NSColorWell!
    private var outputFanFoldSecond: NSColorWell!
    private var outputHistory: NSTextField!
    private var outputWrappedIndent: NSTextField!
    private var outputParagraphSpacing: NSTextField!
    private var outputFixedWidth: NSButton!
    private var outputFixedWidthCharacters: NSTextField!
    private var outputSmoothScrolling: NSButton!
    private var outputScrollToBottom: NSButton!
    private var outputSplitOnPageUp: NSButton!
    private var outputMarginLeft: NSTextField!
    private var outputMarginRight: NSTextField!
    private var outputMarginTop: NSTextField!
    private var outputMarginBottom: NSTextField!
    private var outputShowTime: NSButton!
    private var output24Hour: NSButton!
    private var outputShowDate: NSButton!
    private var outputTooltip: NSButton!
    private var outputCopiedPopup: NSButton!
    private var outputNewMarkers: NSButton!
    private var outputInlineImages: NSButton!
    private var outputSpeechVoice: NSPopUpButton!
    private var outputSplit: NSButton!

    private var inputScope: NSPopUpButton!
    private var inputInherit: NSButton!
    private var inputFont: NSPopUpButton!
    private var inputFontSize: NSTextField!
    private var inputForeground: NSColorWell!
    private var inputBackground: NSColorWell!
    private var inputResizeToFit: NSButton!
    private var inputMinimumLines: NSTextField!
    private var inputMaximumLines: NSTextField!
    private var inputMarginLeft: NSTextField!
    private var inputMarginTop: NSTextField!
    private var inputMarginRight: NSTextField!
    private var inputMarginBottom: NSTextField!
    private var inputKeepText: NSButton!
    private var inputLocalEcho: NSButton!
    private var inputLocalEchoColor: NSColorWell!
    private var inputSpelling: NSButton!

    private var scriptStartupPath: NSTextField!
    private var scriptDebug: NSButton!
    private var restoreLogsEnabled: NSButton!
    private var restoreBufferSize: NSTextField!
    private var restoreLogsStatus: NSTextField!
    private let recoveryStore: SessionRecoveryStore?
    private var recoveryStatisticsObserverID: UUID?

    private enum FieldTag: Int {
        case outputFontSize = 1
        case outputHistory
        case outputWrappedIndent
        case outputParagraphSpacing
        case outputFixedWidthCharacters
        case outputMarginLeft
        case outputMarginRight
        case outputMarginTop
        case outputMarginBottom
        case inputFontSize
        case inputMinimumLines
        case inputMaximumLines
        case inputMarginLeft
        case inputMarginTop
        case inputMarginRight
        case inputMarginBottom
        case restoreBufferSize
    }

    init(
        profileLibrary: ProfileLibrary,
        recoveryStore: SessionRecoveryStore? = nil,
        preferencesProvider: @escaping () -> WorkspacePreferences = { WorkspacePreferencesStore.load() },
        shortcutsProvider: @escaping () -> [ShortcutAction: KeyboardShortcut],
        context: SettingsPresentationContext,
        onPreferencesMutation: @escaping () -> Void,
        onShortcutsMutation: @escaping ([ShortcutAction: KeyboardShortcut]) -> Void,
        nativeShortcutConflict: @escaping ([ShortcutAction: KeyboardShortcut]) -> String? = { _ in nil },
        presentShortcutConflict: @escaping @MainActor (String) -> Void = SettingsWindowController.showShortcutConflict,
        onFactoryResetRequest: (() -> Void)? = nil,
        onImportConfigurationRequest: (() -> Void)? = nil,
        onExportConfigurationRequest: (() -> Void)? = nil
    ) {
        self.profileLibrary = profileLibrary
        self.recoveryStore = recoveryStore
        self.preferencesProvider = preferencesProvider
        self.shortcutsProvider = shortcutsProvider
        self.context = context
        self.selectedSection = context.section
        self.onPreferencesMutation = onPreferencesMutation
        self.onShortcutsMutation = onShortcutsMutation
        self.nativeShortcutConflict = nativeShortcutConflict
        self.presentShortcutConflict = presentShortcutConflict
        self.onFactoryResetRequest = onFactoryResetRequest
        self.onImportConfigurationRequest = onImportConfigurationRequest
        self.onExportConfigurationRequest = onExportConfigurationRequest

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.minSize = NSSize(width: 760, height: 560)
        window.setAccessibilityIdentifier("settingsWindow")
        super.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        RuntimeStateContext.setFrameAutosaveName("BeipMUSettingsWindow", for: window)
        profileLibraryObserverID = profileLibrary.addChangeObserver { [weak self] in
            self?.refreshFromExternalChange()
        }
        recoveryStatisticsObserverID = recoveryStore?.addStatisticsObserver { [weak self] statistics in
            DispatchQueue.main.async {
                self?.updateRestoreLogsStatus(statistics)
            }
        }
        configureWindow()
        present(context: context)
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Public routing and test surface

    func present(context: SettingsPresentationContext) {
        guard commitCurrentFieldsIfNeeded() else { return }
        self.context = context
        selectedSection = context.section
        preferencesSnapshot = nil
        if let initialScope = context.initialScope {
            selectedScopes[context.section] = initialScope
        }
        refreshSidebarSelection()
        reloadContent()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        updateContentScrollCue()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func refreshFromExternalChange() {
        guard !applyingExternalChange else { return }
        preferencesSnapshot = nil
        reloadContent()
    }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        window?.appearance = palette.appearance
        window?.backgroundColor = palette.chrome
        window?.contentView?.appearance = palette.appearance
        window?.contentView?.needsDisplay = true
        window?.contentView?.needsLayout = true
    }

    var selectedSectionForTesting: SettingsSection { selectedSection }
    var presentationContextForTesting: SettingsPresentationContext { context }
    var sidebarTitlesForTesting: [String] { SettingsSection.allCases.map(\.title) }
    var contentIsOverflowingForTesting: Bool { contentIsOverflowing }
    var contentScrollShowsVerticalScrollerForTesting: Bool { contentScroll.hasVerticalScroller }
    var contentScrollCueIsVisibleForTesting: Bool { !contentScrollCue.isHidden }

    func setShortcutValueForTesting(_ value: String, for action: ShortcutAction) {
        shortcutFields[action]?.stringValue = value
        commitShortcut(action)
    }

    // MARK: - Window shell

    private func configureWindow() {
        guard let contentView = window?.contentView else { return }

        sidebar.headerView = nil
        sidebar.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settingsSidebarColumn")))
        sidebar.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        sidebar.rowHeight = 30
        sidebar.intercellSpacing = NSSize(width: 0, height: 1)
        sidebar.style = .sourceList
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.setAccessibilityIdentifier("settingsSidebar")
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = false
        sidebarScroll.hasHorizontalScroller = false
        sidebarScroll.drawsBackground = true
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        contentDocument.translatesAutoresizingMaskIntoConstraints = false
        contentDocument.onLayout = { [weak self] in self?.updateContentScrollCue() }
        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.distribution = .gravityAreas
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setContentHuggingPriority(.required, for: .vertical)
        contentStack.setContentCompressionResistancePriority(.required, for: .vertical)
        contentStack.setAccessibilityIdentifier("settingsContent")
        contentDocument.addSubview(contentStack)
        contentScroll.documentView = contentDocument
        contentScroll.hasVerticalScroller = false
        contentScroll.autohidesScrollers = true
        contentScroll.drawsBackground = false
        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.setAccessibilityIdentifier("settingsContentScroll")
        contentScroll.setAccessibilityLabel("Settings content")
        contentScroll.setAccessibilityRole(.scrollArea)
        contentScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: contentScroll.contentView
        )

        contentScrollCue.setAccessibilityIdentifier("settingsContentOverflowCue")
        contentScrollCue.setAccessibilityElement(false)
        contentScrollCue.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.addSubview(contentScrollCue)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(sidebarScroll)
        split.addArrangedSubview(contentScroll)
        contentView.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            split.topAnchor.constraint(equalTo: contentView.topAnchor),
            split.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 170),
            contentDocument.widthAnchor.constraint(equalTo: contentScroll.contentView.widthAnchor),
            contentStack.leadingAnchor.constraint(equalTo: contentDocument.leadingAnchor, constant: 22),
            contentStack.trailingAnchor.constraint(equalTo: contentDocument.trailingAnchor, constant: -22),
            contentStack.topAnchor.constraint(equalTo: contentDocument.topAnchor, constant: 22),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: contentDocument.bottomAnchor, constant: -22),
            contentScrollCue.leadingAnchor.constraint(equalTo: contentScroll.contentView.leadingAnchor),
            contentScrollCue.trailingAnchor.constraint(equalTo: contentScroll.contentView.trailingAnchor),
            contentScrollCue.bottomAnchor.constraint(equalTo: contentScroll.contentView.bottomAnchor),
            contentScrollCue.heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    private func refreshSidebarSelection() {
        sidebar.reloadData()
        guard let index = SettingsSection.allCases.firstIndex(of: selectedSection) else { return }
        sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        sidebar.scrollRowToVisible(index)
    }

    private func reloadContent() {
        applyingExternalChange = true
        defer { applyingExternalChange = false }
        contentStack.arrangedSubviews.forEach { contentStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        if let cachedViews = cachedSectionViews[selectedSection] {
            cachedViews.forEach { contentStack.addArrangedSubview($0) }
            refreshControls(for: selectedSection)
        } else {
            switch selectedSection {
            case .appearance: buildAppearance()
            case .ansiColors: buildANSIColors()
            case .output: buildOutput()
            case .input: buildInput()
            case .restoreLogs: buildRestoreLogs()
            case .scripting: buildScripting()
            case .shortcuts: buildShortcuts()
            case .advanced: buildAdvanced()
            }
            cachedSectionViews[selectedSection] = contentStack.arrangedSubviews
        }
        constrainContentViewsToStack()
        contentStack.needsLayout = true
        contentDocument.needsLayout = true
        contentDocument.layoutSubtreeIfNeeded()
        updateContentScrollCue()
    }

    private func updateContentScrollCue() {
        guard !updatingContentScrollCue else { return }
        guard contentScroll.contentView.bounds.height > 1 else { return }

        updatingContentScrollCue = true
        defer { updatingContentScrollCue = false }

        contentDocument.layoutSubtreeIfNeeded()
        let viewportHeight = contentScroll.contentView.bounds.height
        let documentHeight = contentDocument.bounds.height
        let overflowing = documentHeight > viewportHeight + 1

        if contentIsOverflowing != overflowing {
            contentIsOverflowing = overflowing
            contentScroll.hasVerticalScroller = overflowing
            contentScroll.autohidesScrollers = !overflowing
        }

        let hasMoreBelow = contentScroll.contentView.bounds.maxY < contentDocument.bounds.maxY - 1
        contentScrollCue.isHidden = !overflowing || !hasMoreBelow
        contentScrollCue.needsDisplay = true
    }

    @objc private func contentBoundsChanged(_ notification: Notification) {
        updateContentScrollCue()
    }

    private func refreshControls(for section: SettingsSection) {
        switch section {
        case .appearance: loadAppearanceControls()
        case .ansiColors: loadANSIControls()
        case .output: loadOutputControls()
        case .input: loadInputControls()
        case .restoreLogs: loadRestoreLogsControls()
        case .scripting: loadScriptingControls()
        case .shortcuts: loadShortcutControls()
        case .advanced: break
        }
    }

    private func constrainContentViewsToStack() {
        contentStack.arrangedSubviews.forEach { view in
            let identifier = ObjectIdentifier(view)
            if let constraint = contentWidthConstraints[identifier] {
                constraint.isActive = true
            } else {
                let constraint = view.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
                contentWidthConstraints[identifier] = constraint
                constraint.isActive = true
            }
        }
    }

    // MARK: - Sidebar

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === ansiColorTable { return ANSIColorName.allCases.count }
        return SettingsSection.allCases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === ansiColorTable {
            let name = ANSIColorName.allCases[row]
            let identifier = NSUserInterfaceItemIdentifier("ANSIColorRow")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? NSTableCellView()
            cell.identifier = identifier
            cell.setAccessibilityIdentifier("ansiColorRow.\(name.rawValue)")
            cell.setAccessibilityLabel(name.displayName)
            cell.textField = nil
            cell.subviews.forEach { $0.removeFromSuperview() }
            let label = NSTextField(labelWithString: name.displayName)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setAccessibilityIdentifier("ansiColorName.\(name.rawValue)")
            let swatch = NSColorWell()
            swatch.color = nsColor(for: profileLibrary.workspace.projection.ansi.color(for: name))
            swatch.isEnabled = false
            swatch.translatesAutoresizingMaskIntoConstraints = false
            swatch.widthAnchor.constraint(equalToConstant: 44).isActive = true
            swatch.setAccessibilityIdentifier("ansiColorSwatch.\(name.rawValue)")
            cell.addSubview(label)
            cell.addSubview(swatch)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                swatch.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                swatch.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("SettingsSidebarCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.textField = label
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let section = SettingsSection.allCases[row]
        cell.textField?.stringValue = section.title
        cell.textField?.setAccessibilityIdentifier(section.accessibilityIdentifier)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if let table = notification.object as? NSTableView, table === ansiColorTable {
            guard table.selectedRow >= 0, ANSIColorName.allCases.indices.contains(table.selectedRow) else { return }
            ansiSelectedColorIndex = table.selectedRow
            ansiSelectedColor.color = nsColor(for: profileLibrary.workspace.projection.ansi.colors[ansiSelectedColorIndex])
            return
        }
        let row = sidebar.selectedRow
        guard SettingsSection.allCases.indices.contains(row), SettingsSection.allCases[row] != selectedSection else { return }
        guard commitCurrentFieldsIfNeeded() else {
            refreshSidebarSelection()
            return
        }
        selectedSection = SettingsSection.allCases[row]
        reloadContent()
    }

    // MARK: - Common view helpers

    private func group(_ title: String, _ rows: [NSView], identifier: String? = nil) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let rowsStack = NSStackView(views: rows)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.distribution = .fill
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        let groupStack = NSStackView(views: [heading, rowsStack])
        groupStack.orientation = .vertical
        groupStack.alignment = .leading
        groupStack.distribution = .fill
        groupStack.spacing = 8
        groupStack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        groupStack.translatesAutoresizingMaskIntoConstraints = false
        if let identifier { groupStack.setAccessibilityIdentifier(identifier) }
        return groupStack
    }

    private func row(_ title: String, _ view: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 185).isActive = true
        let stack = NSStackView(views: [label, view])
        stack.orientation = .horizontal
        stack.distribution = .fill
        stack.spacing = 10
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func checkboxRow(_ button: NSButton) -> NSView {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return button
    }

    private func fieldRow(_ title: String, _ field: NSTextField) -> NSView {
        let error = NSTextField(labelWithString: "")
        error.textColor = .systemRed
        error.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        error.isHidden = true
        error.lineBreakMode = .byWordWrapping
        error.maximumNumberOfLines = 2
        errorLabels[ObjectIdentifier(field)] = error
        let fields = NSStackView(views: [field, error])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 2
        fields.translatesAutoresizingMaskIntoConstraints = false
        fields.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return row(title, fields)
    }

    private func globalOnly(_ title: String) -> String { "\(title) (Defaults only)" }

    private func makeNumberField(_ tag: FieldTag) -> NSTextField {
        let field = NSTextField()
        field.tag = tag.rawValue
        field.alignment = .right
        field.controlSize = .small
        field.target = self
        field.action = #selector(textFieldAction(_:))
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 110).isActive = true
        return field
    }

    private func makeCheckbox(_ title: String, identifier: String? = nil) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(controlChanged(_:)))
        if let identifier { button.setAccessibilityIdentifier(identifier) }
        return button
    }

    private func makeColorWell(_ identifier: String) -> NSColorWell {
        let well = NSColorWell()
        well.target = self
        well.action = #selector(controlChanged(_:))
        well.setAccessibilityIdentifier(identifier)
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: 90).isActive = true
        return well
    }

    private func makeFontPopup(_ identifier: String) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.addItems(withTitles: fontFamilyNames)
        popup.target = self
        popup.action = #selector(controlChanged(_:))
        popup.setAccessibilityIdentifier(identifier)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return popup
    }

    private func makeTextField(_ identifier: String) -> NSTextField {
        let field = NSTextField()
        field.target = self
        field.action = #selector(textFieldAction(_:))
        field.delegate = self
        field.setAccessibilityIdentifier(identifier)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        return field
    }

    // MARK: - Appearance

    private func buildAppearance() {
        appearanceMode = NSPopUpButton()
        appearanceMode.addItems(withTitles: WorkspaceThemeMode.allCases.map(\.title))
        appearanceMode.target = self
        appearanceMode.action = #selector(controlChanged(_:))
        appearanceMode.setAccessibilityIdentifier("themeMode")
        appearanceForeground = makeColorWell("themeForeground")
        appearanceBackground = makeColorWell("themeBackground")
        appearanceAccent = makeColorWell("themeAccent")
        menuStripPosition = NSPopUpButton()
        menuStripPosition.addItems(withTitles: MenuStripPosition.allCases.map(\.title))
        menuStripPosition.target = self
        menuStripPosition.action = #selector(controlChanged(_:))
        menuStripPosition.setAccessibilityIdentifier("menuStripPosition")
        menuStripPosition.translatesAutoresizingMaskIntoConstraints = false
        menuStripPosition.widthAnchor.constraint(equalToConstant: 220).isActive = true
        contentStack.addArrangedSubview(group("Window and chrome appearance", [
            row("Mode:", appearanceMode),
            row("Menu strip position:", menuStripPosition),
            row("Workspace text:", appearanceForeground),
            row("Workspace background:", appearanceBackground),
            row("Accent:", appearanceAccent),
        ], identifier: "settings.appearance.group"))
        loadAppearanceControls()
    }

    private func loadAppearanceControls() {
        guard appearanceMode != nil else { return }
        let preferences = currentPreferences()
        let theme = preferences.theme
        appearanceMode.selectItem(at: WorkspaceThemeMode.allCases.firstIndex(of: theme.mode) ?? 0)
        let position: MenuStripPosition = profileLibrary.workspace.projection.taskbarOnTop ? .top : .bottom
        menuStripPosition.selectItem(at: MenuStripPosition.allCases.firstIndex(of: position) ?? 0)
        appearanceForeground.color = NSColor(hexString: theme.foregroundHex) ?? .textColor
        appearanceBackground.color = NSColor(hexString: theme.backgroundHex) ?? .textBackgroundColor
        appearanceAccent.color = NSColor(hexString: theme.accentHex) ?? .controlAccentColor
        updateAppearanceEnabledState()
    }

    @objc private func controlChanged(_ sender: Any?) {
        guard !applyingExternalChange else { return }
        switch selectedSection {
        case .appearance: appearanceChanged(sender)
        case .ansiColors: ansiColorsChanged(sender)
        case .output: outputChanged(sender)
        case .input: inputChanged(sender)
        case .restoreLogs: restoreLogsChanged(sender)
        case .scripting: scriptingChanged(sender)
        case .shortcuts: break
        case .advanced: break
        }
    }

    private func appearanceChanged(_ sender: Any?) {
        if (sender as? NSPopUpButton) === menuStripPosition {
            let position = MenuStripPosition.allCases[menuStripPosition.indexOfSelectedItem]
            do {
                try profileLibrary.mutate { workspace in
                    workspace.setTaskbarOnTop(position == .top)
                }
                onPreferencesMutation()
            } catch {
                showInlineError("Unable to save menu strip position: \(error.localizedDescription)")
            }
            return
        }
        let theme = WorkspaceThemeSettings(
            mode: WorkspaceThemeMode.allCases[appearanceMode.indexOfSelectedItem],
            foregroundHex: appearanceForeground.color.hexString,
            backgroundHex: appearanceBackground.color.hexString,
            accentHex: appearanceAccent.color.hexString
        )
        mutatePreferences { $0.theme = theme }
        updateAppearanceEnabledState()
    }

    // MARK: - ANSI Colors

    private func buildANSIColors() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ansiColorColumn"))
        column.title = "Color"
        ansiColorTable = NSTableView()
        ansiColorTable.headerView = nil
        ansiColorTable.addTableColumn(column)
        ansiColorTable.rowHeight = 28
        ansiColorTable.intercellSpacing = NSSize(width: 0, height: 1)
        ansiColorTable.usesAlternatingRowBackgroundColors = true
        ansiColorTable.dataSource = self
        ansiColorTable.delegate = self
        ansiColorTable.setAccessibilityIdentifier("ansiColorTable")

        let colorScroll = NSScrollView()
        colorScroll.documentView = ansiColorTable
        colorScroll.hasVerticalScroller = true
        colorScroll.hasHorizontalScroller = false
        colorScroll.drawsBackground = false
        colorScroll.translatesAutoresizingMaskIntoConstraints = false
        colorScroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        colorScroll.widthAnchor.constraint(equalToConstant: 500).isActive = true
        colorScroll.setAccessibilityIdentifier("ansiColorsTableScroll")

        ansiSelectedColor = NSColorWell()
        ansiSelectedColor.target = self
        ansiSelectedColor.action = #selector(controlChanged(_:))
        ansiSelectedColor.setAccessibilityIdentifier("ansiSelectedColor")
        ansiSelectedColor.translatesAutoresizingMaskIntoConstraints = false
        ansiSelectedColor.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let change = NSButton(title: "Change…", target: self, action: #selector(ansiChangeColor(_:)))
        change.bezelStyle = .rounded
        change.setAccessibilityIdentifier("ansiColorChange")
        let `default` = NSButton(title: "Default", target: self, action: #selector(ansiDefaultColor(_:)))
        `default`.bezelStyle = .rounded
        `default`.setAccessibilityIdentifier("ansiColorDefault")
        let selectedControls = NSStackView(views: [ansiSelectedColor, change, `default`])
        selectedControls.orientation = .horizontal
        selectedControls.alignment = .centerY
        selectedControls.spacing = 8

        let presetButtons = ANSIPalettePreset.allCases.map { preset -> NSButton in
            let button = NSButton(title: preset.rawValue, target: self, action: #selector(ansiPresetChanged(_:)))
            button.bezelStyle = .rounded
            button.setAccessibilityIdentifier("ansiPreset.\(preset.rawValue.lowercased())")
            return button
        }
        let presets = NSStackView(views: presetButtons)
        presets.orientation = .horizontal
        presets.alignment = .centerY
        presets.spacing = 8
        presets.setAccessibilityIdentifier("ansiPresets")

        ansiPreventInvisible = makeCheckbox("Prevent invisible text", identifier: "ansiPreventInvisible")
        ansiResetOnNewLine = makeCheckbox("Reset formatting on new line", identifier: "ansiResetOnNewLine")
        ansiFontBold = makeCheckbox("Use font bold", identifier: "ansiFontBold")
        ansiParseBlinking = makeCheckbox("Parse blinking", identifier: "ansiParseBlinking")

        ansiBeepEnabled = makeCheckbox("Enable beep", identifier: "ansiBeepEnabled")
        ansiSystemBeep = NSButton(radioButtonWithTitle: "Use system beep", target: self, action: #selector(controlChanged(_:)))
        ansiSystemBeep.setAccessibilityIdentifier("ansiSystemBeep")
        ansiCustomBeep = NSButton(radioButtonWithTitle: "Use custom sound", target: self, action: #selector(controlChanged(_:)))
        ansiCustomBeep.setAccessibilityIdentifier("ansiCustomBeep")
        ansiBeepPath = makeTextField("ansiBeepPath")
        ansiBeepPath.placeholderString = "Path to a sound file"
        ansiBeepChange = NSButton(title: "Change…", target: self, action: #selector(ansiChooseBeep(_:)))
        ansiBeepChange.bezelStyle = .rounded
        ansiBeepChange.setAccessibilityIdentifier("ansiBeepChange")
        ansiBeepPlay = NSButton(title: "Play preview", target: self, action: #selector(ansiPlayBeep(_:)))
        ansiBeepPlay.bezelStyle = .rounded
        ansiBeepPlay.setAccessibilityIdentifier("ansiBeepPlay")
        let beepPath = NSStackView(views: [ansiBeepPath, ansiBeepChange, ansiBeepPlay])
        beepPath.orientation = .horizontal
        beepPath.alignment = .centerY
        beepPath.spacing = 8

        ansiParseCodes = makeCheckbox("Parse ANSI Codes", identifier: "ansiParseCodes")

        contentStack.addArrangedSubview(group("Text colors", [
            colorScroll,
            row("Selected color:", selectedControls),
            row("Presets:", presets),
        ], identifier: "ansiColorsSection"))
        contentStack.addArrangedSubview(group("Appearance", [
            checkboxRow(ansiPreventInvisible), checkboxRow(ansiResetOnNewLine),
            checkboxRow(ansiFontBold), checkboxRow(ansiParseBlinking),
        ], identifier: "settings.ansiColors.appearance"))
        contentStack.addArrangedSubview(group("Beep", [
            checkboxRow(ansiBeepEnabled), checkboxRow(ansiSystemBeep),
            checkboxRow(ansiCustomBeep), row("Sound file:", beepPath),
        ], identifier: "settings.ansiColors.beep"))
        contentStack.addArrangedSubview(group("Miscellaneous", [
            checkboxRow(ansiParseCodes),
        ], identifier: "settings.ansiColors.misc"))
        loadANSIControls()
    }

    private func loadANSIControls() {
        guard ansiColorTable != nil else { return }
        let settings = profileLibrary.workspace.projection.ansi
        ansiColorTable.reloadData()
        ansiColorTable.selectRowIndexes(IndexSet(integer: ansiSelectedColorIndex), byExtendingSelection: false)
        ansiSelectedColor.color = nsColor(for: settings.colors[ansiSelectedColorIndex])
        ansiPreventInvisible.state = settings.preventInvisible ? .on : .off
        ansiResetOnNewLine.state = settings.resetOnNewLine ? .on : .off
        ansiFontBold.state = settings.fontBold ? .on : .off
        ansiParseBlinking.state = settings.parseBlinking ? .on : .off
        ansiBeepEnabled.state = settings.beep ? .on : .off
        ansiSystemBeep.state = settings.beepSystem ? .on : .off
        ansiCustomBeep.state = settings.beepSystem ? .off : .on
        ansiBeepPath.stringValue = settings.beepFileName
        ansiParseCodes.state = settings.parse ? .on : .off
        updateANSIEnabledState()
    }

    private func updateANSIEnabledState() {
        guard ansiBeepEnabled != nil else { return }
        let beepEnabled = ansiBeepEnabled.state == .on
        let custom = ansiCustomBeep.state == .on
        ansiSystemBeep.isEnabled = beepEnabled
        ansiCustomBeep.isEnabled = beepEnabled
        ansiBeepPath.isEnabled = beepEnabled && custom
        ansiBeepChange.isEnabled = beepEnabled && custom
        ansiBeepPlay.isEnabled = beepEnabled
    }

    private func mutateANSI(_ mutation: @escaping (inout ANSISettings) -> Void) {
        do {
            try profileLibrary.mutate { workspace in
                workspace.updateANSISettings(mutation)
            }
            onPreferencesMutation()
            loadANSIControls()
        } catch {
            showInlineError("Unable to save ANSI settings: \(error.localizedDescription)")
        }
    }

    private func nsColor(for color: BeipCore.RGBColor) -> NSColor {
        NSColor(calibratedRed: CGFloat(color.red) / 255,
                green: CGFloat(color.green) / 255,
                blue: CGFloat(color.blue) / 255,
                alpha: 1)
    }

    private func rgbColor(from color: NSColor) -> BeipCore.RGBColor {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return BeipCore.RGBColor(
            red: UInt8(clamping: Int((converted.redComponent * 255).rounded())),
            green: UInt8(clamping: Int((converted.greenComponent * 255).rounded())),
            blue: UInt8(clamping: Int((converted.blueComponent * 255).rounded()))
        )
    }

    private func ansiColorsChanged(_ sender: Any?) {
        if let control = sender as? NSColorWell, control === ansiSelectedColor {
            let index = ansiSelectedColorIndex
            let color = rgbColor(from: ansiSelectedColor.color)
            mutateANSI { $0.colors[index] = color }
        } else if let control = sender as? NSButton {
            if control === ansiPreventInvisible { mutateANSI { $0.preventInvisible = self.ansiPreventInvisible.state == .on } }
            else if control === ansiResetOnNewLine { mutateANSI { $0.resetOnNewLine = self.ansiResetOnNewLine.state == .on } }
            else if control === ansiFontBold { mutateANSI { $0.fontBold = self.ansiFontBold.state == .on } }
            else if control === ansiParseBlinking { mutateANSI { $0.parseBlinking = self.ansiParseBlinking.state == .on } }
            else if control === ansiBeepEnabled { mutateANSI { $0.beep = self.ansiBeepEnabled.state == .on } }
            else if control === ansiSystemBeep { mutateANSI { $0.beepSystem = true } }
            else if control === ansiCustomBeep { mutateANSI { $0.beepSystem = false } }
            else if control === ansiParseCodes { mutateANSI { $0.parse = self.ansiParseCodes.state == .on } }
        }
        updateANSIEnabledState()
    }

    @objc private func ansiChangeColor(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.color = ansiSelectedColor.color
        panel.setTarget(self)
        panel.setAction(#selector(ansiColorPanelChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func ansiColorPanelChanged(_ sender: Any?) {
        guard let panel = sender as? NSColorPanel else { return }
        ansiSelectedColor.color = panel.color
        ansiColorsChanged(ansiSelectedColor)
    }

    @objc private func ansiDefaultColor(_ sender: Any?) {
        let index = ansiSelectedColorIndex
        mutateANSI { $0.colors[index] = ANSIPalettePreset.xTerm.colors[index] }
    }

    @objc private func ansiPresetChanged(_ sender: Any?) {
        guard let button = sender as? NSButton,
              let preset = ANSIPalettePreset.allCases.first(where: { $0.rawValue == button.title }) else { return }
        mutateANSI { $0.colors = preset.colors }
    }

    @objc private func ansiChooseBeep(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.ansiBeepPath.stringValue = url.path
            self.mutateANSI { $0.beepFileName = url.path }
        }
    }

    @objc private func ansiPlayBeep(_ sender: Any?) {
        if ansiSystemBeep.state == .on {
            NSSound.beep()
        } else if let path = ansiBeepPath?.stringValue, !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            NSSound(contentsOfFile: expanded, byReference: true)?.play()
        }
    }

    private func updateAppearanceEnabledState() {
        guard appearanceMode != nil else { return }
        let enabled = WorkspaceThemeMode.allCases[appearanceMode.indexOfSelectedItem] == .custom
        appearanceForeground.isEnabled = enabled
        appearanceBackground.isEnabled = enabled
        appearanceAccent.isEnabled = enabled
    }

    // MARK: - Output

    private func buildOutput() {
        outputScope = NSPopUpButton()
        outputScope.target = self
        outputScope.action = #selector(outputScopeChanged(_:))
        outputScope.setAccessibilityIdentifier("outputSettingsScope")
        outputInherit = makeCheckbox("Inherit default settings", identifier: "outputSettingsInheritDefault")
        outputInherit.target = self
        outputInherit.action = #selector(outputInheritanceChanged(_:))
        outputFont = makeFontPopup("outputSettingsFont")
        outputFontSize = makeNumberField(.outputFontSize); outputFontSize.setAccessibilityIdentifier("outputSettingsFontSize")
        outputForeground = makeColorWell("outputSettingsForeground")
        outputBackground = makeColorWell("outputSettingsBackground")
        outputLink = makeColorWell("outputSettingsWebLink")
        outputInvert = makeCheckbox("Invert brightness", identifier: "outputSettingsInvert")
        outputFanFold = makeCheckbox("Fan-fold backgrounds", identifier: "outputSettingsFanFold")
        outputFanFoldFirst = makeColorWell("outputSettingsFanFoldFirst")
        outputFanFoldSecond = makeColorWell("outputSettingsFanFoldSecond")
        outputHistory = makeNumberField(.outputHistory); outputHistory.setAccessibilityIdentifier("outputSettingsHistory")
        outputWrappedIndent = makeNumberField(.outputWrappedIndent); outputWrappedIndent.setAccessibilityIdentifier("outputSettingsWrappedIndent")
        outputParagraphSpacing = makeNumberField(.outputParagraphSpacing); outputParagraphSpacing.setAccessibilityIdentifier("outputSettingsParagraphSpacing")
        outputFixedWidth = makeCheckbox("Fixed width", identifier: "outputSettingsFixedWidth")
        outputFixedWidthCharacters = makeNumberField(.outputFixedWidthCharacters); outputFixedWidthCharacters.setAccessibilityIdentifier("outputSettingsFixedWidthCharacters")
        outputSmoothScrolling = makeCheckbox("Smooth scrolling", identifier: "outputSettingsSmoothScrolling")
        outputScrollToBottom = makeCheckbox("Scroll to bottom on new text", identifier: "outputSettingsScrollToBottom")
        outputSplitOnPageUp = makeCheckbox("Split on Page Up", identifier: "outputSettingsSplitOnPageUp")
        outputMarginLeft = makeNumberField(.outputMarginLeft); outputMarginLeft.setAccessibilityIdentifier("outputSettingsMarginLeft")
        outputMarginRight = makeNumberField(.outputMarginRight); outputMarginRight.setAccessibilityIdentifier("outputSettingsMarginRight")
        outputMarginTop = makeNumberField(.outputMarginTop); outputMarginTop.setAccessibilityIdentifier("outputSettingsMarginTop")
        outputMarginBottom = makeNumberField(.outputMarginBottom); outputMarginBottom.setAccessibilityIdentifier("outputSettingsMarginBottom")
        outputShowTime = makeCheckbox("Time", identifier: "outputSettingsShowTime")
        output24Hour = makeCheckbox("24-hour time", identifier: "outputSettings24Hour")
        outputShowDate = makeCheckbox("Date", identifier: "outputSettingsShowDate")
        outputTooltip = makeCheckbox(globalOnly("Show date and time tooltip"), identifier: "outputSettingsTooltip")
        outputCopiedPopup = makeCheckbox(globalOnly("Show selection copied popup"), identifier: "outputSettingsCopiedPopup")
        outputNewMarkers = makeCheckbox(globalOnly("New content markers"), identifier: "outputSettingsNewMarkers")
        outputInlineImages = makeCheckbox("Show inline image previews (Workspace-wide)", identifier: "showInlineImagePreviews")
        outputSpeechVoice = makeVoicePopup("speechVoice")
        outputSplit = makeCheckbox("Split output view (Workspace-wide)", identifier: "outputSplit")

        let scopes = scopeRow(outputScope, outputInherit)
        contentStack.addArrangedSubview(group("Scope", [scopes], identifier: "settings.output.scope"))
        contentStack.addArrangedSubview(group("Text", [
            row("Font:", outputFont), fieldRow("Font size:", outputFontSize),
            row("Foreground:", outputForeground), row("Background:", outputBackground),
            row("Web link:", outputLink), checkboxRow(outputInvert),
        ], identifier: "settings.output.text"))
        contentStack.addArrangedSubview(group("Layout", [
            checkboxRow(outputFanFold), row("Fan-fold color 1:", outputFanFoldFirst),
            row("Fan-fold color 2:", outputFanFoldSecond), fieldRow("Wrapped-line indent:", outputWrappedIndent),
            fieldRow("Paragraph spacing:", outputParagraphSpacing), checkboxRow(outputFixedWidth),
            fieldRow("Width in characters:", outputFixedWidthCharacters),
            fieldRow("Left margin:", outputMarginLeft), fieldRow("Right margin:", outputMarginRight),
            fieldRow("Top margin:", outputMarginTop), fieldRow("Bottom margin:", outputMarginBottom),
        ], identifier: "settings.output.layout"))
        contentStack.addArrangedSubview(group("Scrolling and history", [
            fieldRow("History lines:", outputHistory), checkboxRow(outputSmoothScrolling),
            checkboxRow(outputScrollToBottom), checkboxRow(outputSplitOnPageUp), checkboxRow(outputSplit),
        ], identifier: "settings.output.scrolling"))
        contentStack.addArrangedSubview(group("Timestamps", [
            checkboxRow(outputShowTime), checkboxRow(output24Hour), checkboxRow(outputShowDate),
        ], identifier: "settings.output.timestamps"))
        contentStack.addArrangedSubview(group("Feedback and media", [
            checkboxRow(outputTooltip), checkboxRow(outputCopiedPopup), checkboxRow(outputNewMarkers),
            checkboxRow(outputInlineImages), row("Speech voice (Workspace-wide):", outputSpeechVoice),
        ], identifier: "settings.output.feedback"))
        loadOutputControls()
    }

    private func scopeRow(_ scope: NSPopUpButton, _ inherit: NSButton) -> NSView {
        let stack = NSStackView(views: [scope, inherit])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return row("Scope:", stack)
    }

    private func makeVoicePopup(_ identifier: String) -> NSPopUpButton {
        let popup = NSPopUpButton()
        speechVoiceOptions.forEach { option in
            popup.addItem(withTitle: option.title)
            popup.lastItem?.representedObject = option.identifier
        }
        popup.target = self
        popup.action = #selector(controlChanged(_:))
        popup.setAccessibilityIdentifier(identifier)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        return popup
    }

    private func availableScopes(for identity: TextWindowSettingsIdentity) -> [Scope] {
        var result: [Scope] = [.global]
        if identity.worldKey != nil { result.append(.world) }
        if identity.characterKey != nil { result.append(.character) }
        if identity.tabKey != nil { result.append(.tab) }
        return result
    }

    private func scopeLabel(_ scope: Scope) -> String {
        switch scope {
        case .global: "Defaults"
        case .world: "World — \(context.identity.world ?? "")"
        case .character: "Character — \(context.identity.character ?? "")"
        case .tab: "Tab — \(context.identity.tab ?? "")"
        }
    }

    private func configureScopePopup(_ popup: NSPopUpButton, section: SettingsSection) {
        let available = availableScopes(for: context.identity)
        popup.removeAllItems()
        popup.addItems(withTitles: available.map(scopeLabel))
        let requested = selectedScopes[section] ?? context.initialScope ?? .global
        let selected = available.contains(requested) ? requested : .global
        selectedScopes[section] = selected
        popup.selectItem(at: available.firstIndex(of: selected) ?? 0)
    }

    private func selectedOutputScope() -> Scope { selectedScopes[.output] ?? .global }

    private func outputState(from preferences: WorkspacePreferences) -> (TextWindowSettings, Bool) {
        let scope = selectedOutputScope()
        switch scope {
        case .global: return (preferences.globalTextWindowSettings, false)
        case .world:
            guard let key = context.identity.worldKey else { return (preferences.globalTextWindowSettings, true) }
            let entry = preferences.worldTextWindowSettings[key]
            return (entry?.settings ?? preferences.globalTextWindowSettings, entry?.usesGlobalSettings ?? true)
        case .character:
            guard let key = context.identity.characterKey else { return (preferences.globalTextWindowSettings, true) }
            let entry = preferences.characterTextWindowSettings[key]
            return (entry?.settings ?? preferences.globalTextWindowSettings, entry?.usesGlobalSettings ?? true)
        case .tab:
            guard let key = context.identity.tabKey else { return (preferences.globalTextWindowSettings, true) }
            let entry = preferences.tabTextWindowSettings[key]
            return (entry?.settings ?? preferences.globalTextWindowSettings, entry?.usesGlobalSettings ?? true)
        }
    }

    private func loadOutputControls() {
        configureScopePopup(outputScope, section: .output)
        let preferences = currentPreferences()
        let (value, inherits) = outputState(from: preferences)
        outputInherit.state = inherits ? .on : .off
        setPopup(outputFont, title: value.fontName)
        outputFontSize.doubleValue = value.fontSize
        outputForeground.color = NSColor(hexString: value.foregroundHex) ?? .textColor
        outputBackground.color = NSColor(hexString: value.backgroundHex) ?? .textBackgroundColor
        outputLink.color = NSColor(hexString: value.webLinkHex) ?? .linkColor
        outputInvert.state = value.invertBrightness ? .on : .off
        outputFanFold.state = value.usesFanFoldBackgrounds ? .on : .off
        outputFanFoldFirst.color = NSColor(hexString: value.fanFoldFirstHex) ?? .textBackgroundColor
        outputFanFoldSecond.color = NSColor(hexString: value.fanFoldSecondHex) ?? .underPageBackgroundColor
        outputHistory.integerValue = value.historyLimit
        outputWrappedIndent.integerValue = value.wrappedLineIndent
        outputParagraphSpacing.integerValue = value.paragraphSpacing
        outputFixedWidth.state = value.usesFixedWidth ? .on : .off
        outputFixedWidthCharacters.integerValue = value.fixedWidthCharacters
        outputSmoothScrolling.state = value.smoothScrolling ? .on : .off
        outputScrollToBottom.state = value.scrollsToBottomOnNewText ? .on : .off
        outputSplitOnPageUp.state = value.splitsOnPageUp ? .on : .off
        outputMarginLeft.integerValue = value.marginLeft
        outputMarginRight.integerValue = value.marginRight
        outputMarginTop.integerValue = value.marginTop
        outputMarginBottom.integerValue = value.marginBottom
        outputShowTime.state = value.showsTime ? .on : .off
        output24Hour.state = value.uses24HourTime ? .on : .off
        outputShowDate.state = value.showsDate ? .on : .off
        let defaults = preferences.globalTextWindowSettings
        outputTooltip.state = defaults.showsDateTimeToolTip ? .on : .off
        outputCopiedPopup.state = defaults.showsSelectionCopiedPopup ? .on : .off
        outputNewMarkers.state = defaults.showsNewContentMarkers ? .on : .off
        outputInlineImages.state = preferences.showsInlineImagePreviews ? .on : .off
        outputSplit.state = preferences.outputSplit ? .on : .off
        setVoicePopup(outputSpeechVoice, identifier: preferences.speechVoiceIdentifier)
        updateOutputEnabledState()
    }

    private func setPopup(_ popup: NSPopUpButton, title: String) {
        if popup.itemTitles.contains(title) { popup.selectItem(withTitle: title) }
        else { popup.addItem(withTitle: title); popup.selectItem(withTitle: title) }
    }

    private func setVoicePopup(_ popup: NSPopUpButton, identifier: String?) {
        if let identifier, let index = popup.itemArray.firstIndex(where: { $0.representedObject as? String == identifier }) {
            popup.selectItem(at: index)
        } else { popup.selectItem(at: 0) }
    }

    private func outputChanged(_ sender: Any?) {
        guard let control = sender as? NSControl else { return }
        if control === outputFont {
            mutateOutput { [self] in $0.fontName = self.outputFont.titleOfSelectedItem ?? $0.fontName }
        } else if control === outputForeground {
            mutateOutput { [self] in $0.foregroundHex = self.outputForeground.color.hexString }
        } else if control === outputBackground {
            mutateOutput { [self] in $0.backgroundHex = self.outputBackground.color.hexString }
        } else if control === outputLink {
            mutateOutput { [self] in $0.webLinkHex = self.outputLink.color.hexString }
        } else if control === outputInvert {
            mutateOutput { [self] in $0.invertBrightness = self.outputInvert.state == .on }
        } else if control === outputFanFold {
            mutateOutput { [self] in $0.usesFanFoldBackgrounds = self.outputFanFold.state == .on }
        } else if control === outputFanFoldFirst {
            mutateOutput { [self] in $0.fanFoldFirstHex = self.outputFanFoldFirst.color.hexString }
        } else if control === outputFanFoldSecond {
            mutateOutput { [self] in $0.fanFoldSecondHex = self.outputFanFoldSecond.color.hexString }
        } else if control === outputFixedWidth {
            mutateOutput { [self] in $0.usesFixedWidth = self.outputFixedWidth.state == .on }
        } else if control === outputSmoothScrolling {
            mutateOutput { [self] in $0.smoothScrolling = self.outputSmoothScrolling.state == .on }
        } else if control === outputScrollToBottom {
            mutateOutput { [self] in $0.scrollsToBottomOnNewText = self.outputScrollToBottom.state == .on }
        } else if control === outputSplitOnPageUp {
            mutateOutput { [self] in $0.splitsOnPageUp = self.outputSplitOnPageUp.state == .on }
        } else if control === outputShowTime {
            mutateOutput { [self] in $0.showsTime = self.outputShowTime.state == .on }
        } else if control === output24Hour {
            mutateOutput { [self] in $0.uses24HourTime = self.output24Hour.state == .on }
        } else if control === outputShowDate {
            mutateOutput { [self] in $0.showsDate = self.outputShowDate.state == .on }
        } else if control === outputTooltip {
            mutatePreferences { [self] in $0.globalTextWindowSettings.showsDateTimeToolTip = self.outputTooltip.state == .on }
        } else if control === outputCopiedPopup {
            mutatePreferences { [self] in $0.globalTextWindowSettings.showsSelectionCopiedPopup = self.outputCopiedPopup.state == .on }
        } else if control === outputNewMarkers {
            mutatePreferences { [self] in $0.globalTextWindowSettings.showsNewContentMarkers = self.outputNewMarkers.state == .on }
        } else if control === outputInlineImages {
            mutatePreferences { [self] in $0.showsInlineImagePreviews = self.outputInlineImages.state == .on }
        } else if control === outputSpeechVoice {
            mutatePreferences { [self] in $0.speechVoiceIdentifier = self.outputSpeechVoice.selectedItem?.representedObject as? String }
        } else if control === outputSplit {
            mutatePreferences { [self] in $0.outputSplit = self.outputSplit.state == .on }
        }
        updateOutputEnabledState()
    }

    private func mutateOutput(_ mutation: @escaping (inout TextWindowSettings) -> Void) {
        mutatePreferences { preferences in
            let scope = self.selectedOutputScope()
            if scope == .global {
                mutation(&preferences.globalTextWindowSettings)
                preferences.outputHistoryLimit = preferences.globalTextWindowSettings.historyLimit
                preferences.showsTimestamps = preferences.globalTextWindowSettings.showsTime
                    || preferences.globalTextWindowSettings.showsDate
                preferences.usesFanFoldBackgrounds = preferences.globalTextWindowSettings.usesFanFoldBackgrounds
                return
            }
            guard let key = self.scopeKey(scope) else { return }
            switch scope {
            case .world:
                var entry = preferences.worldTextWindowSettings[key]
                    ?? .init(usesGlobalSettings: false, settings: preferences.globalTextWindowSettings)
                guard !entry.usesGlobalSettings else { return }
                mutation(&entry.settings)
                preferences.worldTextWindowSettings[key] = entry
            case .character:
                var entry = preferences.characterTextWindowSettings[key]
                    ?? .init(usesGlobalSettings: false, settings: preferences.globalTextWindowSettings)
                guard !entry.usesGlobalSettings else { return }
                mutation(&entry.settings)
                preferences.characterTextWindowSettings[key] = entry
            case .tab:
                var entry = preferences.tabTextWindowSettings[key]
                    ?? .init(usesGlobalSettings: false, settings: preferences.globalTextWindowSettings)
                guard !entry.usesGlobalSettings else { return }
                mutation(&entry.settings)
                preferences.tabTextWindowSettings[key] = entry
            case .global: break
            }
        }
    }

    private func scopeKey(_ scope: Scope) -> String? {
        switch scope {
        case .global: nil
        case .world: context.identity.worldKey
        case .character: context.identity.characterKey
        case .tab: context.identity.tabKey
        }
    }

    private func updateOutputEnabledState() {
        guard outputScope != nil else { return }
        let inherits = selectedOutputScope() != .global && outputInherit.state == .on
        let controls: [NSControl] = [
            outputFont, outputFontSize, outputForeground, outputBackground, outputLink, outputInvert,
            outputFanFold, outputFanFoldFirst, outputFanFoldSecond, outputHistory, outputWrappedIndent,
            outputParagraphSpacing, outputFixedWidth, outputFixedWidthCharacters, outputSmoothScrolling,
            outputScrollToBottom, outputSplitOnPageUp, outputMarginLeft, outputMarginRight, outputMarginTop,
            outputMarginBottom, outputShowTime, output24Hour, outputShowDate,
        ]
        controls.forEach { $0.isEnabled = !inherits }
        outputFanFoldFirst.isEnabled = !inherits && outputFanFold.state == .on
        outputFanFoldSecond.isEnabled = !inherits && outputFanFold.state == .on
        outputFixedWidthCharacters.isEnabled = !inherits && outputFixedWidth.state == .on
        output24Hour.isEnabled = !inherits && outputShowTime.state == .on
        // These controls always edit Defaults, even while a local scope is selected.
        [outputTooltip, outputCopiedPopup, outputNewMarkers].forEach { $0.isEnabled = true }
        outputInherit.isHidden = selectedOutputScope() == .global
    }

    @objc private func outputScopeChanged(_ sender: Any?) {
        guard commitCurrentFieldsIfNeeded() else {
            configureScopePopup(outputScope, section: .output)
            return
        }
        let available = availableScopes(for: context.identity)
        selectedScopes[.output] = available[max(0, outputScope.indexOfSelectedItem)]
        reloadContent()
    }

    @objc private func outputInheritanceChanged(_ sender: Any?) {
        let scope = selectedOutputScope()
        guard scope != .global, let key = scopeKey(scope) else { return }
        mutatePreferences { [self] preferences in
            let inherited = self.outputInherit.state == .on
            switch scope {
            case .world:
                var entry = preferences.worldTextWindowSettings[key]
                    ?? .init(usesGlobalSettings: inherited, settings: preferences.globalTextWindowSettings)
                entry.usesGlobalSettings = inherited
                preferences.worldTextWindowSettings[key] = entry
            case .character:
                var entry = preferences.characterTextWindowSettings[key]
                    ?? .init(usesGlobalSettings: inherited, settings: preferences.globalTextWindowSettings)
                entry.usesGlobalSettings = inherited
                preferences.characterTextWindowSettings[key] = entry
            case .tab:
                var entry = preferences.tabTextWindowSettings[key]
                    ?? .init(usesGlobalSettings: inherited, settings: preferences.globalTextWindowSettings)
                entry.usesGlobalSettings = inherited
                preferences.tabTextWindowSettings[key] = entry
            case .global: break
            }
        }
        updateOutputEnabledState()
    }

    // MARK: - Input

    private func buildInput() {
        inputScope = NSPopUpButton()
        inputScope.target = self
        inputScope.action = #selector(inputScopeChanged(_:))
        inputScope.setAccessibilityIdentifier("inputSettingsScope")
        inputInherit = makeCheckbox("Inherit default settings", identifier: "inputSettingsInheritDefault")
        inputInherit.target = self
        inputInherit.action = #selector(inputInheritanceChanged(_:))
        inputFont = makeFontPopup("inputSettingsFont")
        inputFontSize = makeNumberField(.inputFontSize); inputFontSize.setAccessibilityIdentifier("inputSettingsFontSize")
        inputForeground = makeColorWell("inputSettingsForeground")
        inputBackground = makeColorWell("inputSettingsBackground")
        inputResizeToFit = makeCheckbox("Resize to fit contents", identifier: "inputSettingsResizeToFit")
        inputMinimumLines = makeNumberField(.inputMinimumLines); inputMinimumLines.setAccessibilityIdentifier("inputSettingsMinimumLines")
        inputMaximumLines = makeNumberField(.inputMaximumLines); inputMaximumLines.setAccessibilityIdentifier("inputSettingsMaximumLines")
        inputMarginLeft = makeNumberField(.inputMarginLeft); inputMarginLeft.setAccessibilityIdentifier("inputSettingsMarginLeft")
        inputMarginTop = makeNumberField(.inputMarginTop); inputMarginTop.setAccessibilityIdentifier("inputSettingsMarginTop")
        inputMarginRight = makeNumberField(.inputMarginRight); inputMarginRight.setAccessibilityIdentifier("inputSettingsMarginRight")
        inputMarginBottom = makeNumberField(.inputMarginBottom); inputMarginBottom.setAccessibilityIdentifier("inputSettingsMarginBottom")
        inputKeepText = makeCheckbox("Don’t clear input on Enter", identifier: "inputSettingsKeepText")
        inputLocalEcho = makeCheckbox("Local echo", identifier: "inputSettingsLocalEcho")
        inputLocalEchoColor = makeColorWell("inputSettingsLocalEchoColor")
        inputSpelling = makeCheckbox("Check spelling (Workspace-wide)", identifier: "checkSpelling")

        contentStack.addArrangedSubview(group("Scope", [scopeRow(inputScope, inputInherit)], identifier: "settings.input.scope"))
        contentStack.addArrangedSubview(group("Text", [
            row("Font:", inputFont), fieldRow("Font size:", inputFontSize),
            row("Foreground:", inputForeground), row("Background:", inputBackground),
        ], identifier: "settings.input.text"))
        contentStack.addArrangedSubview(group("Size and spacing", [
            checkboxRow(inputResizeToFit), fieldRow("Minimum lines:", inputMinimumLines),
            fieldRow("Maximum lines:", inputMaximumLines), fieldRow("Left margin:", inputMarginLeft),
            fieldRow("Top margin:", inputMarginTop), fieldRow("Right margin:", inputMarginRight),
            fieldRow("Bottom margin:", inputMarginBottom),
        ], identifier: "settings.input.size"))
        contentStack.addArrangedSubview(group("Behavior", [
            checkboxRow(inputKeepText), checkboxRow(inputLocalEcho),
            row("Local echo color:", inputLocalEchoColor), checkboxRow(inputSpelling),
        ], identifier: "settings.input.behavior"))
        loadInputControls()
    }

    private func selectedInputScope() -> Scope { selectedScopes[.input] ?? .global }

    private func inputState(from preferences: WorkspacePreferences) -> (InputWindowSettings, Bool) {
        let scope = selectedInputScope()
        switch scope {
        case .global: return (preferences.globalInputWindowSettings, false)
        case .world:
            guard let key = context.identity.worldKey else { return (preferences.globalInputWindowSettings, true) }
            let entry = preferences.worldInputWindowSettings[key]
            return (entry?.settings ?? preferences.globalInputWindowSettings, entry?.usesGlobalSettings ?? true)
        case .character:
            guard let key = context.identity.characterKey else { return (preferences.globalInputWindowSettings, true) }
            let entry = preferences.characterInputWindowSettings[key]
            return (entry?.settings ?? preferences.globalInputWindowSettings, entry?.usesGlobalSettings ?? true)
        case .tab:
            guard let key = context.identity.tabKey else { return (preferences.globalInputWindowSettings, true) }
            let entry = preferences.tabInputWindowSettings[key]
            return (entry?.settings ?? preferences.globalInputWindowSettings, entry?.usesGlobalSettings ?? true)
        }
    }

    private func loadInputControls() {
        configureScopePopup(inputScope, section: .input)
        let preferences = currentPreferences()
        let (value, inherits) = inputState(from: preferences)
        inputInherit.state = inherits ? .on : .off
        setPopup(inputFont, title: value.fontName)
        inputFontSize.doubleValue = value.fontSize
        inputForeground.color = NSColor(hexString: value.foregroundHex) ?? .textColor
        inputBackground.color = NSColor(hexString: value.backgroundHex) ?? .textBackgroundColor
        inputResizeToFit.state = value.resizesToFitContents ? .on : .off
        inputMinimumLines.integerValue = value.minimumLines
        inputMaximumLines.integerValue = value.maximumLines
        inputMarginLeft.integerValue = value.marginLeft
        inputMarginTop.integerValue = value.marginTop
        inputMarginRight.integerValue = value.marginRight
        inputMarginBottom.integerValue = value.marginBottom
        inputKeepText.state = value.keepsTextOnSubmit ? .on : .off
        inputLocalEcho.state = value.localEcho ? .on : .off
        inputLocalEchoColor.color = NSColor(hexString: value.localEchoHex) ?? .cyan
        inputSpelling.state = preferences.checksSpelling ? .on : .off
        updateInputEnabledState()
    }

    private func inputChanged(_ sender: Any?) {
        guard let control = sender as? NSControl else { return }
        if control === inputFont {
            mutateInput { [self] in $0.fontName = self.inputFont.titleOfSelectedItem ?? $0.fontName }
        } else if control === inputForeground {
            mutateInput { [self] in $0.foregroundHex = self.inputForeground.color.hexString }
        } else if control === inputBackground {
            mutateInput { [self] in $0.backgroundHex = self.inputBackground.color.hexString }
        } else if control === inputResizeToFit {
            mutateInput { [self] in $0.resizesToFitContents = self.inputResizeToFit.state == .on }
        } else if control === inputKeepText {
            mutateInput { [self] in $0.keepsTextOnSubmit = self.inputKeepText.state == .on }
        } else if control === inputLocalEcho {
            mutateInput { [self] in $0.localEcho = self.inputLocalEcho.state == .on }
        } else if control === inputLocalEchoColor {
            mutateInput { [self] in $0.localEchoHex = self.inputLocalEchoColor.color.hexString }
        } else if control === inputSpelling {
            mutatePreferences { [self] in $0.checksSpelling = self.inputSpelling.state == .on }
        }
        updateInputEnabledState()
    }

    private func mutateInput(_ mutation: @escaping (inout InputWindowSettings) -> Void) {
        mutatePreferences { preferences in
            let scope = self.selectedInputScope()
            if scope == .global {
                mutation(&preferences.globalInputWindowSettings)
                preferences.stickyInput = preferences.globalInputWindowSettings.keepsTextOnSubmit
                return
            }
            guard let key = self.scopeKey(scope) else { return }
            switch scope {
            case .world:
                var entry = preferences.worldInputWindowSettings[key]
                    ?? .init(usesGlobalSettings: false, settings: preferences.globalInputWindowSettings)
                guard !entry.usesGlobalSettings else { return }
                mutation(&entry.settings); preferences.worldInputWindowSettings[key] = entry
            case .character:
                var entry = preferences.characterInputWindowSettings[key]
                    ?? .init(usesGlobalSettings: false, settings: preferences.globalInputWindowSettings)
                guard !entry.usesGlobalSettings else { return }
                mutation(&entry.settings); preferences.characterInputWindowSettings[key] = entry
            case .tab:
                var entry = preferences.tabInputWindowSettings[key]
                    ?? .init(usesGlobalSettings: false, settings: preferences.globalInputWindowSettings)
                guard !entry.usesGlobalSettings else { return }
                mutation(&entry.settings); preferences.tabInputWindowSettings[key] = entry
            case .global: break
            }
        }
    }

    private func updateInputEnabledState() {
        guard inputScope != nil else { return }
        let inherits = selectedInputScope() != .global && inputInherit.state == .on
        let controls: [NSControl] = [
            inputFont, inputFontSize, inputForeground, inputBackground, inputResizeToFit,
            inputMinimumLines, inputMaximumLines, inputMarginLeft, inputMarginTop, inputMarginRight,
            inputMarginBottom, inputKeepText, inputLocalEcho, inputLocalEchoColor,
        ]
        controls.forEach { $0.isEnabled = !inherits }
        inputMinimumLines.isEnabled = !inherits && inputResizeToFit.state == .on
        inputMaximumLines.isEnabled = !inherits && inputResizeToFit.state == .on
        inputLocalEchoColor.isEnabled = !inherits && inputLocalEcho.state == .on
        inputInherit.isHidden = selectedInputScope() == .global
    }

    @objc private func inputScopeChanged(_ sender: Any?) {
        guard commitCurrentFieldsIfNeeded() else {
            configureScopePopup(inputScope, section: .input)
            return
        }
        let available = availableScopes(for: context.identity)
        selectedScopes[.input] = available[max(0, inputScope.indexOfSelectedItem)]
        reloadContent()
    }

    @objc private func inputInheritanceChanged(_ sender: Any?) {
        let scope = selectedInputScope()
        guard scope != .global, let key = scopeKey(scope) else { return }
        mutatePreferences { [self] preferences in
            let inherited = self.inputInherit.state == .on
            switch scope {
            case .world:
                var entry = preferences.worldInputWindowSettings[key]
                    ?? .init(usesGlobalSettings: inherited, settings: preferences.globalInputWindowSettings)
                entry.usesGlobalSettings = inherited; preferences.worldInputWindowSettings[key] = entry
            case .character:
                var entry = preferences.characterInputWindowSettings[key]
                    ?? .init(usesGlobalSettings: inherited, settings: preferences.globalInputWindowSettings)
                entry.usesGlobalSettings = inherited; preferences.characterInputWindowSettings[key] = entry
            case .tab:
                var entry = preferences.tabInputWindowSettings[key]
                    ?? .init(usesGlobalSettings: inherited, settings: preferences.globalInputWindowSettings)
                entry.usesGlobalSettings = inherited; preferences.tabInputWindowSettings[key] = entry
            case .global: break
            }
        }
        updateInputEnabledState()
    }

    // MARK: - Restore Logs

    private func buildRestoreLogs() {
        restoreLogsEnabled = makeCheckbox("Enabled", identifier: "restoreLogsEnabled")
        restoreBufferSize = makeNumberField(.restoreBufferSize)
        restoreBufferSize.setAccessibilityIdentifier("restoreBufferSizeKB")
        restoreLogsStatus = NSTextField(labelWithString: "")
        restoreLogsStatus.setAccessibilityIdentifier("restoreLogsStatus")

        let explanation = NSTextField(wrappingLabelWithString:
            "Restore Logs keep recent output for individually selected characters and refill their tabs whenever they are opened. Select Restore Log for each character in Worlds & Characters.")
        explanation.maximumNumberOfLines = 0
        let rounding = NSTextField(wrappingLabelWithString:
            "Sizes are rounded up to the nearest 64 KB. Each character has its own buffer.")
        rounding.maximumNumberOfLines = 0

        contentStack.addArrangedSubview(group("Persistent character buffers", [
            explanation,
            checkboxRow(restoreLogsEnabled),
            fieldRow("Per-character size (KB):", restoreBufferSize),
            rounding,
            restoreLogsStatus,
        ], identifier: "settings.restoreLogs.group"))
        loadRestoreLogsControls()
    }

    private func loadRestoreLogsControls() {
        guard restoreLogsEnabled != nil else { return }
        let logging = profileLibrary.workspace.projection.logging
        restoreLogsEnabled.state = logging.restoreLogs ? .on : .off
        restoreBufferSize.integerValue = logging.restoreBufferSize / 1_024
        restoreBufferSize.isEnabled = logging.restoreLogs
        updateRestoreLogsStatus(recoveryStore?.statistics ?? .init(bufferCount: 0, fileSize: 0))
    }

    private func restoreLogsChanged(_ sender: Any?) {
        guard (sender as? NSButton) === restoreLogsEnabled else { return }
        saveRestoreLogSettings(
            enabled: restoreLogsEnabled.state == .on,
            bytes: profileLibrary.workspace.projection.logging.restoreBufferSize
        )
    }

    private func saveRestoreLogSettings(enabled: Bool, bytes: Int) {
        do {
            try profileLibrary.mutate { workspace in
                workspace.setRestoreLogSettings(enabled: enabled, perCharacterBytes: bytes)
            }
            try recoveryStore?.setPerCharacterCapacity(
                SessionLogOptions.normalizedRestoreBufferSize(bytes)
            )
            try recoveryStore?.setEnabled(enabled)
            onPreferencesMutation()
            loadRestoreLogsControls()
        } catch {
            showInlineError("Unable to save Restore Logs settings: \(error.localizedDescription)")
        }
    }

    private func updateRestoreLogsStatus(_ statistics: SessionRecoveryStatistics) {
        guard restoreLogsStatus != nil else { return }
        restoreLogsStatus.stringValue = "Currently using \(statistics.bufferCount) buffers for a file size of \(statistics.fileSize) B"
    }

    // MARK: - Scripting

    private func buildScripting() {
        scriptStartupPath = makeTextField("scriptStartupPath")
        scriptStartupPath.placeholderString = "Optional JavaScript file path"
        scriptDebug = makeCheckbox("Enable script debugging", identifier: "scriptDebugEnabled")
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseStartupScript(_:)))
        choose.setAccessibilityIdentifier("scriptChoose")
        let pathStack = NSStackView(views: [scriptStartupPath, choose])
        pathStack.orientation = .horizontal
        pathStack.spacing = 8
        pathStack.alignment = .centerY
        contentStack.addArrangedSubview(group("Startup and debugging", [
            row("Startup script:", pathStack), checkboxRow(scriptDebug),
            NSTextField(wrappingLabelWithString: "The path may be entered manually, left empty, or chosen from JavaScript files."),
        ], identifier: "settings.scripting.group"))
        loadScriptingControls()
    }

    private func buildAdvanced() {
        let importButton = NSButton(
            title: "Import Config.txt…",
            target: self,
            action: #selector(importConfigurationRequested(_:))
        )
        importButton.bezelStyle = .rounded
        importButton.setAccessibilityLabel("Import Config.txt")
        importButton.setAccessibilityIdentifier("importConfigurationButton")
        importButton.setAccessibilityHelp("Replace the active portable configuration with a Config.txt file.")

        let exportButton = NSButton(
            title: "Export Config.txt…",
            target: self,
            action: #selector(exportConfigurationRequested(_:))
        )
        exportButton.bezelStyle = .rounded
        exportButton.setAccessibilityLabel("Export Config.txt")
        exportButton.setAccessibilityIdentifier("exportConfigurationButton")
        exportButton.setAccessibilityHelp("Save the active portable configuration as a Config.txt file.")

        let configurationExplanation = NSTextField(wrappingLabelWithString:
            "Import replaces the active portable configuration after it is validated. Exported configurations can contain plaintext credentials and other private settings; store exported files securely."
        )
        configurationExplanation.setAccessibilityIdentifier("configurationFileExplanation")
        configurationExplanation.widthAnchor.constraint(equalToConstant: 476).isActive = true

        let configurationButtons = NSStackView(views: [importButton, exportButton])
        configurationButtons.orientation = .horizontal
        configurationButtons.alignment = .centerY
        configurationButtons.spacing = 8

        let configurationArea = NSStackView(views: [
            NSTextField(labelWithString: "Configuration file"),
            configurationExplanation,
            configurationButtons,
        ])
        configurationArea.orientation = .vertical
        configurationArea.alignment = .leading
        configurationArea.spacing = 10
        configurationArea.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        configurationArea.widthAnchor.constraint(equalToConstant: 500).isActive = true
        configurationArea.setAccessibilityIdentifier("settings.advanced.configuration")

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 500).isActive = true

        let reset = NSButton(
            title: "Reset Configuration…",
            target: self,
            action: #selector(factoryResetRequested(_:))
        )
        reset.bezelStyle = .rounded
        reset.contentTintColor = .systemRed
        reset.setAccessibilityLabel("Reset Configuration")
        reset.setAccessibilityIdentifier("resetConfigurationButton")
        reset.setAccessibilityHelp("Erase BeipMU-managed state while preserving logs, maps, scripts, and exported files.")

        let explanation = NSTextField(wrappingLabelWithString:
            "This erases profiles, automation, preferences, shortcuts, tabs, layouts, Restore Logs data, and the automatic Config.backup.txt. Logs, maps, scripts, and exported files are preserved."
        )
        explanation.setAccessibilityIdentifier("resetConfigurationExplanation")

        let destructiveArea = NSStackView(views: [
            NSTextField(labelWithString: "Destructive actions"),
            explanation,
            reset,
        ])
        destructiveArea.orientation = .vertical
        destructiveArea.alignment = .leading
        destructiveArea.spacing = 10
        destructiveArea.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        destructiveArea.widthAnchor.constraint(equalToConstant: 500).isActive = true
        destructiveArea.wantsLayer = true
        destructiveArea.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
        destructiveArea.layer?.cornerRadius = 8
        destructiveArea.setAccessibilityIdentifier("settings.advanced.destructive")

        contentStack.addArrangedSubview(group(
            "Advanced",
            [configurationArea, separator, destructiveArea],
            identifier: "settings.advanced.group"
        ))
    }

    @objc private func importConfigurationRequested(_ sender: Any?) {
        onImportConfigurationRequest?()
    }

    @objc private func exportConfigurationRequested(_ sender: Any?) {
        onExportConfigurationRequest?()
    }

    @objc private func factoryResetRequested(_ sender: Any?) {
        onFactoryResetRequest?()
    }

    private func loadScriptingControls() {
        guard scriptStartupPath != nil, scriptDebug != nil else { return }
        let scripting = profileLibrary.workspace.projection.scripting
        scriptStartupPath.stringValue = scripting.startupPath
        scriptDebug.state = scripting.debugEnabled ? .on : .off
    }

    private func scriptingChanged(_ sender: Any?) {
        guard sender as AnyObject? === scriptDebug else { return }
        saveScripting()
    }

    @objc private func chooseStartupScript(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Choose Startup JavaScript"
        panel.allowedContentTypes = [.javaScript]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window!) { [weak self, weak panel] response in
            guard response == .OK, let self, let url = panel?.url else { return }
            self.scriptStartupPath.stringValue = url.path
            self.saveScripting()
        }
    }

    private func saveScripting() {
        do {
            try profileLibrary.mutate {
                $0.updateScripting {
                    $0.startupPath = self.scriptStartupPath.stringValue
                    $0.debugEnabled = self.scriptDebug.state == .on
                }
            }
            onPreferencesMutation()
        } catch {
            showInlineError("Unable to save scripting settings: \(error.localizedDescription)")
        }
    }

    // MARK: - Shortcuts

    private func buildShortcuts() {
        shortcutFields.removeAll()
        shortcutErrors.removeAll()
        let rows = ShortcutAction.allCases.map { action -> NSView in
            let field = makeShortcutField("shortcut.\(action.rawValue)")
            field.widthAnchor.constraint(equalToConstant: 180).isActive = true
            field.tag = 10_000 + ShortcutAction.allCases.firstIndex(of: action)!
            field.onCapture = { [weak self, weak field] shortcut in
                guard let self, let field else { return }
                field.stringValue = shortcut?.displayString ?? ""
                self.commitShortcut(action)
            }
            shortcutFields[action] = field
            let error = NSTextField(labelWithString: "")
            error.textColor = .systemRed
            error.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            error.isHidden = true
            shortcutErrors[action] = error
            let value = NSStackView(views: [field, error])
            value.orientation = .vertical
            value.alignment = .leading
            value.spacing = 2
            return row("\(action.title):", value)
        }
        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreShortcutDefaults(_:)))
        restore.setAccessibilityIdentifier("shortcutRestoreDefaults")
        let note = NSTextField(wrappingLabelWithString: "Use ⌘N, Command+Shift+P, F1, or Shift+F2. Leave a field empty to disable that shortcut. Changes save as soon as each valid row is committed.")
        contentStack.addArrangedSubview(group("Keyboard shortcuts", rows + [restore, note], identifier: "settings.shortcuts.group"))
        loadShortcutControls()
    }

    private func makeShortcutField(_ identifier: String) -> ShortcutCaptureField {
        let field = ShortcutCaptureField()
        field.isEditable = false
        field.isSelectable = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(textFieldAction(_:))
        field.delegate = self
        field.setAccessibilityIdentifier(identifier)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 280).isActive = true
        return field
    }

    private func loadShortcutControls() {
        let values = shortcutsProvider()
        ShortcutAction.allCases.forEach { action in
            shortcutFields[action]?.stringValue = values[action]?.displayString ?? action.defaultShortcut.displayString
            setShortcutError(action, nil)
        }
    }

    @objc private func restoreShortcutDefaults(_ sender: Any?) {
        do {
            try profileLibrary.saveKeyEquivalents([:])
            onShortcutsMutation(KeyboardShortcutStore.load())
            reloadContent()
        } catch { showInlineError("Unable to restore shortcuts: \(error.localizedDescription)") }
    }

    private func commitShortcut(_ action: ShortcutAction) {
        guard let field = shortcutFields[action] else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: KeyboardShortcut
        if trimmed.isEmpty {
            parsed = .unbound
        } else if let value = KeyboardShortcut.parse(field.stringValue) {
            parsed = value
        } else {
            setShortcutError(action, "Enter a shortcut such as ⌘N or Shift+F2.")
            return
        }
        var values = shortcutsProvider()
        values[action] = parsed
        let duplicates = values.filter { $0.key != action && sameShortcut($0.value, parsed) }
        if let duplicate = duplicates.first {
            let message = "This shortcut is already assigned to \(duplicate.key.title)."
            setShortcutError(action, message)
            setShortcutError(duplicate.key, "This shortcut is also assigned to \(action.title).")
            presentShortcutConflict(message)
            return
        }
        if let conflict = nativeShortcutConflict(values) {
            setShortcutError(action, conflict)
            presentShortcutConflict(conflict)
            return
        }
        do {
            try profileLibrary.saveKeyEquivalents(KeyboardShortcutStore.serialized(values))
            onShortcutsMutation(values)
            field.stringValue = parsed.displayString
            shortcutErrors.keys.forEach { setShortcutError($0, nil) }
        } catch { setShortcutError(action, error.localizedDescription) }
    }

    private func sameShortcut(_ lhs: KeyboardShortcut, _ rhs: KeyboardShortcut) -> Bool {
        guard !lhs.keyEquivalent.isEmpty, !rhs.keyEquivalent.isEmpty else { return false }
        return lhs.keyEquivalent.lowercased() == rhs.keyEquivalent.lowercased()
            && lhs.modifierRawValue == rhs.modifierRawValue
    }

    private static func showShortcutConflict(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Shortcut Conflict"
        alert.informativeText = "\(message) Choose another shortcut, or leave the field empty to disable it."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func setShortcutError(_ action: ShortcutAction, _ message: String?) {
        guard let error = shortcutErrors[action] else { return }
        error.stringValue = message ?? ""
        error.isHidden = message == nil
    }

    // MARK: - Text committing and persistence

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        textFieldAction(field)
    }

    @objc private func textFieldAction(_ sender: Any?) {
        guard let field = sender as? NSTextField else { return }
        if let action = shortcutFields.first(where: { $0.value === field })?.key {
            commitShortcut(action)
            return
        }
        guard let tag = FieldTag(rawValue: field.tag) else {
            if field === scriptStartupPath { saveScripting() }
            else if field === ansiBeepPath { mutateANSI { $0.beepFileName = self.ansiBeepPath.stringValue } }
            return
        }
        let valid = commitNumericField(field, tag: tag)
        if !valid { window?.makeFirstResponder(field) }
    }

    private func commitNumericField(_ field: NSTextField, tag: FieldTag) -> Bool {
        func numberFormatter(allowsFloats: Bool) -> NumberFormatter {
            let formatter = NumberFormatter()
            formatter.locale = .current
            formatter.numberStyle = .decimal
            formatter.allowsFloats = allowsFloats
            formatter.isLenient = true
            formatter.usesGroupingSeparator = true
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = allowsFloats ? 16 : 0
            return formatter
        }

        func integer(_ minimum: Int, _ maximum: Int, _ apply: @escaping (Int) -> Void) -> Bool {
            let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let number = numberFormatter(allowsFloats: false).number(from: raw),
                  let value = Int(exactly: number.intValue),
                  (minimum...maximum).contains(value) else {
                setError(field, "Enter a value from \(minimum) to \(maximum).")
                return false
            }
            clearError(field); apply(value); return true
        }
        func decimal(_ minimum: Double, _ maximum: Double, _ apply: @escaping (Double) -> Void) -> Bool {
            let raw = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let number = numberFormatter(allowsFloats: true).number(from: raw),
                  let value = Double(exactly: number), value.isFinite,
                  (minimum...maximum).contains(value) else {
                setError(field, "Enter a value from \(minimum) to \(maximum).")
                return false
            }
            clearError(field); apply(value); return true
        }

        switch tag {
        case .outputFontSize: return decimal(6, 96) { value in self.mutateOutput { $0.fontSize = value } }
        case .outputHistory: return integer(100, 10_000_000) { value in self.mutateOutput { $0.historyLimit = value } }
        case .outputWrappedIndent: return integer(0, 500) { value in self.mutateOutput { $0.wrappedLineIndent = value } }
        case .outputParagraphSpacing: return integer(0, 100) { value in self.mutateOutput { $0.paragraphSpacing = value } }
        case .outputFixedWidthCharacters: return integer(20, 1_000) { value in self.mutateOutput { $0.fixedWidthCharacters = value } }
        case .outputMarginLeft: return integer(0, 500) { value in self.mutateOutput { $0.marginLeft = value } }
        case .outputMarginRight: return integer(0, 500) { value in self.mutateOutput { $0.marginRight = value } }
        case .outputMarginTop: return integer(0, 500) { value in self.mutateOutput { $0.marginTop = value } }
        case .outputMarginBottom: return integer(0, 500) { value in self.mutateOutput { $0.marginBottom = value } }
        case .inputFontSize: return decimal(6, 96) { value in self.mutateInput { $0.fontSize = value } }
        case .inputMinimumLines:
            let maxLines = inputMaximumLines?.integerValue ?? 100
            return integer(1, maxLines) { value in self.mutateInput { $0.minimumLines = value } }
        case .inputMaximumLines:
            let minLines = inputMinimumLines?.integerValue ?? 1
            return integer(minLines, 100) { value in self.mutateInput { $0.maximumLines = value } }
        case .inputMarginLeft: return integer(0, 500) { value in self.mutateInput { $0.marginLeft = value } }
        case .inputMarginTop: return integer(0, 500) { value in self.mutateInput { $0.marginTop = value } }
        case .inputMarginRight: return integer(0, 500) { value in self.mutateInput { $0.marginRight = value } }
        case .inputMarginBottom: return integer(0, 500) { value in self.mutateInput { $0.marginBottom = value } }
        case .restoreBufferSize:
            let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kilobytes = Int(raw), kilobytes > 0, kilobytes <= Int.max / 1_024 else {
                setError(field, "Enter a positive whole number of KB.")
                return false
            }
            let normalized = SessionLogOptions.normalizedRestoreBufferSize(kilobytes * 1_024)
            field.integerValue = normalized / 1_024
            clearError(field)
            saveRestoreLogSettings(
                enabled: restoreLogsEnabled.state == .on,
                bytes: normalized
            )
            return true
        }
    }

    private func commitCurrentFieldsIfNeeded() -> Bool {
        if selectedSection == .restoreLogs {
            guard let restoreBufferSize else { return true }
            let valid = commitNumericField(restoreBufferSize, tag: .restoreBufferSize)
            if !valid { window?.makeFirstResponder(restoreBufferSize) }
            return valid
        }
        guard selectedSection == .output || selectedSection == .input else { return true }
        let fields: [NSTextField]
        if selectedSection == .output {
            guard let outputFontSize, let outputHistory, let outputWrappedIndent,
                  let outputParagraphSpacing, let outputFixedWidthCharacters,
                  let outputMarginLeft, let outputMarginRight, let outputMarginTop,
                  let outputMarginBottom else { return true }
            fields = [outputFontSize, outputHistory, outputWrappedIndent, outputParagraphSpacing,
                      outputFixedWidthCharacters, outputMarginLeft, outputMarginRight, outputMarginTop, outputMarginBottom]
        } else {
            guard let inputFontSize, let inputMinimumLines, let inputMaximumLines,
                  let inputMarginLeft, let inputMarginTop, let inputMarginRight,
                  let inputMarginBottom else { return true }
            fields = [inputFontSize, inputMinimumLines, inputMaximumLines,
                      inputMarginLeft, inputMarginTop, inputMarginRight, inputMarginBottom]
        }
        for field in fields {
            guard commitNumericField(field, tag: FieldTag(rawValue: field.tag)!) else {
                window?.makeFirstResponder(field)
                return false
            }
        }
        return true
    }

    private func setError(_ field: NSTextField, _ message: String) {
        guard let error = errorLabels[ObjectIdentifier(field)] else { return }
        error.stringValue = message
        error.isHidden = false
    }

    private func clearError(_ field: NSTextField) {
        errorLabels[ObjectIdentifier(field)]?.isHidden = true
    }

    private func showInlineError(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .systemRed
        contentStack.insertArrangedSubview(label, at: 0)
    }

    private func mutatePreferences(_ mutation: @escaping (inout WorkspacePreferences) -> Void) {
        preferencesSnapshot = WorkspacePreferencesStore.update(mutation)
        onPreferencesMutation()
        if !applyingExternalChange { reloadContent() }
    }

    private func currentPreferences() -> WorkspacePreferences {
        if let preferencesSnapshot { return preferencesSnapshot }
        let loaded = preferencesProvider()
        preferencesSnapshot = loaded
        return loaded
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        window?.contentView?.layoutSubtreeIfNeeded()
        updateContentScrollCue()
    }

    func windowWillClose(_ notification: Notification) {
        // The delegate owns this controller. Closing hides the retained
        // window, allowing Settings… to reuse the same instance next time.
    }
}
