import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// The destinations in the retained Settings window. This is intentionally a
/// small internal routing type: menu commands should describe where to go,
/// not own another settings surface.
enum SettingsSection: String, CaseIterable, Hashable {
    case appearance
    case output
    case input
    case scripting
    case shortcuts
    case advanced

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .output: "Output"
        case .input: "Input"
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
    override var isFlipped: Bool { true }
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

    private var context: SettingsPresentationContext
    private(set) var selectedSection: SettingsSection = .appearance
    private var selectedScopes: [SettingsSection: Scope] = [:]
    private var preferencesSnapshot: WorkspacePreferences?
    private var applyingExternalChange = false

    private let sidebar = NSTableView()
    private let sidebarScroll = NSScrollView()
    private let contentScroll = NSScrollView()
    private let contentDocument = SettingsDocumentView()
    private let contentStack = NSStackView()
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
    private var appearanceForeground: NSColorWell!
    private var appearanceBackground: NSColorWell!
    private var appearanceAccent: NSColorWell!

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
    }

    init(
        profileLibrary: ProfileLibrary,
        preferencesProvider: @escaping () -> WorkspacePreferences = { WorkspacePreferencesStore.load() },
        shortcutsProvider: @escaping () -> [ShortcutAction: KeyboardShortcut],
        context: SettingsPresentationContext,
        onPreferencesMutation: @escaping () -> Void,
        onShortcutsMutation: @escaping ([ShortcutAction: KeyboardShortcut]) -> Void,
        nativeShortcutConflict: @escaping ([ShortcutAction: KeyboardShortcut]) -> String? = { _ in nil },
        presentShortcutConflict: @escaping @MainActor (String) -> Void = SettingsWindowController.showShortcutConflict,
        onFactoryResetRequest: (() -> Void)? = nil
    ) {
        self.profileLibrary = profileLibrary
        self.preferencesProvider = preferencesProvider
        self.shortcutsProvider = shortcutsProvider
        self.context = context
        self.selectedSection = context.section
        self.onPreferencesMutation = onPreferencesMutation
        self.onShortcutsMutation = onShortcutsMutation
        self.nativeShortcutConflict = nativeShortcutConflict
        self.presentShortcutConflict = presentShortcutConflict
        self.onFactoryResetRequest = onFactoryResetRequest

        let window = NSWindow(
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
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func refreshFromExternalChange() {
        guard !applyingExternalChange else { return }
        preferencesSnapshot = nil
        reloadContent()
    }

    var selectedSectionForTesting: SettingsSection { selectedSection }
    var presentationContextForTesting: SettingsPresentationContext { context }
    var sidebarTitlesForTesting: [String] { SettingsSection.allCases.map(\.title) }

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
        contentScroll.hasVerticalScroller = true
        contentScroll.autohidesScrollers = true
        contentScroll.drawsBackground = false
        contentScroll.translatesAutoresizingMaskIntoConstraints = false

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
            case .output: buildOutput()
            case .input: buildInput()
            case .scripting: buildScripting()
            case .shortcuts: buildShortcuts()
            case .advanced: buildAdvanced()
            }
            cachedSectionViews[selectedSection] = contentStack.arrangedSubviews
        }
        constrainContentViewsToStack()
        contentStack.needsLayout = true
        contentDocument.needsLayout = true
    }

    private func refreshControls(for section: SettingsSection) {
        switch section {
        case .appearance: loadAppearanceControls()
        case .output: loadOutputControls()
        case .input: loadInputControls()
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

    func numberOfRows(in tableView: NSTableView) -> Int { SettingsSection.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
        contentStack.addArrangedSubview(group("Window and chrome appearance", [
            row("Mode:", appearanceMode),
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
        appearanceForeground.color = NSColor(hexString: theme.foregroundHex) ?? .textColor
        appearanceBackground.color = NSColor(hexString: theme.backgroundHex) ?? .textBackgroundColor
        appearanceAccent.color = NSColor(hexString: theme.accentHex) ?? .controlAccentColor
        updateAppearanceEnabledState()
    }

    @objc private func controlChanged(_ sender: Any?) {
        guard !applyingExternalChange else { return }
        switch selectedSection {
        case .appearance: appearanceChanged(sender)
        case .output: outputChanged(sender)
        case .input: inputChanged(sender)
        case .scripting: scriptingChanged(sender)
        case .shortcuts: break
        case .advanced: break
        }
    }

    private func appearanceChanged(_ sender: Any?) {
        let theme = WorkspaceThemeSettings(
            mode: WorkspaceThemeMode.allCases[appearanceMode.indexOfSelectedItem],
            foregroundHex: appearanceForeground.color.hexString,
            backgroundHex: appearanceBackground.color.hexString,
            accentHex: appearanceAccent.color.hexString
        )
        mutatePreferences { $0.theme = theme }
        updateAppearanceEnabledState()
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
            "This erases profiles, automation, preferences, shortcuts, tabs, layouts, recovery data, and the automatic Config.backup.txt. Logs, maps, scripts, and exported files are preserved."
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
            [separator, destructiveArea],
            identifier: "settings.advanced.group"
        ))
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
        }
    }

    private func commitCurrentFieldsIfNeeded() -> Bool {
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

    func windowWillClose(_ notification: Notification) {
        // The delegate owns this controller. Closing hides the retained
        // window, allowing Settings… to reuse the same instance next time.
    }
}
