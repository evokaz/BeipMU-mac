import AppKit

@MainActor
final class InputWindowSettingsEditorView: NSView {
    typealias Scope = TextWindowSettingsEditorView.Scope

    struct State {
        var label: String
        var override: InputWindowSettingsOverride
    }

    private(set) var states: [Scope: State]
    private let availableScopes: [Scope]
    private var selectedScope: Scope
    private let scope = NSPopUpButton()
    private let useGlobal = NSButton(checkboxWithTitle: "Inherit default settings", target: nil, action: nil)
    private let font = NSPopUpButton()
    private let fontSize = NSTextField()
    private let foreground = NSColorWell()
    private let background = NSColorWell()
    private let resizeToFit = NSButton(checkboxWithTitle: "Resize to fit contents", target: nil, action: nil)
    private let minimumLines = NSTextField()
    private let maximumLines = NSTextField()
    private let marginLeft = NSTextField()
    private let marginTop = NSTextField()
    private let marginRight = NSTextField()
    private let marginBottom = NSTextField()
    private let keepText = NSButton(checkboxWithTitle: "Don’t clear input on Enter", target: nil, action: nil)
    private let localEcho = NSButton(checkboxWithTitle: "Local echo", target: nil, action: nil)
    private let localEchoColor = NSColorWell()
    private var settingsControls: [NSControl] = []

    init(states: [Scope: State], initialScope: Scope) {
        self.states = states
        availableScopes = Scope.allCases.filter { states[$0] != nil }
        selectedScope = states[initialScope] == nil ? .global : initialScope
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 500))

        scope.addItems(withTitles: availableScopes.compactMap { states[$0]?.label })
        scope.selectItem(at: availableScopes.firstIndex(of: selectedScope) ?? 0)
        scope.target = self
        scope.action = #selector(scopeChanged(_:))
        scope.setAccessibilityIdentifier("inputSettingsScope")
        useGlobal.target = self
        useGlobal.action = #selector(optionChanged(_:))
        useGlobal.setAccessibilityIdentifier("inputSettingsUseGlobal")
        resizeToFit.target = self
        resizeToFit.action = #selector(optionChanged(_:))
        localEcho.target = self
        localEcho.action = #selector(optionChanged(_:))

        font.addItems(withTitles: NSFontManager.shared.availableFontFamilies.sorted())
        font.setAccessibilityIdentifier("inputSettingsFont")
        fontSize.setAccessibilityIdentifier("inputSettingsFontSize")
        foreground.setAccessibilityIdentifier("inputSettingsForeground")
        background.setAccessibilityIdentifier("inputSettingsBackground")
        resizeToFit.setAccessibilityIdentifier("inputSettingsResizeToFit")
        minimumLines.setAccessibilityIdentifier("inputSettingsMinimumLines")
        maximumLines.setAccessibilityIdentifier("inputSettingsMaximumLines")
        marginLeft.setAccessibilityIdentifier("inputSettingsMarginLeft")
        marginTop.setAccessibilityIdentifier("inputSettingsMarginTop")
        marginRight.setAccessibilityIdentifier("inputSettingsMarginRight")
        marginBottom.setAccessibilityIdentifier("inputSettingsMarginBottom")
        keepText.setAccessibilityIdentifier("inputSettingsKeepText")
        localEcho.setAccessibilityIdentifier("inputSettingsLocalEcho")
        localEchoColor.setAccessibilityIdentifier("inputSettingsLocalEchoColor")
        [fontSize, minimumLines, maximumLines, marginLeft, marginTop, marginRight, marginBottom].forEach {
            $0.alignment = .right
        }

        let copy = NSButton(title: "Copy Settings", target: self, action: #selector(copySettings(_:)))
        let paste = NSButton(title: "Paste Settings", target: self, action: #selector(pasteSettings(_:)))
        let copyPaste = NSStackView(views: [copy, paste])
        copyPaste.orientation = .horizontal
        copyPaste.distribution = .fillEqually
        copyPaste.spacing = 8

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Scope:"), scope],
            [NSView(), useGlobal],
            [NSTextField(labelWithString: "Font:"), font],
            [NSTextField(labelWithString: "Font size:"), fontSize],
            [NSTextField(labelWithString: "Foreground:"), foreground],
            [NSTextField(labelWithString: "Background:"), background],
            [NSView(), resizeToFit],
            [NSTextField(labelWithString: "Minimum lines:"), minimumLines],
            [NSTextField(labelWithString: "Maximum lines:"), maximumLines],
            [NSTextField(labelWithString: "Left margin:"), marginLeft],
            [NSTextField(labelWithString: "Top margin:"), marginTop],
            [NSTextField(labelWithString: "Right margin:"), marginRight],
            [NSTextField(labelWithString: "Bottom margin:"), marginBottom],
            [NSView(), keepText],
            [NSView(), localEcho],
            [NSTextField(labelWithString: "Local echo color:"), localEchoColor],
            [NSTextField(labelWithString: "Settings:"), copyPaste],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 155
        grid.column(at: 1).width = 300
        grid.rowSpacing = 7
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])

        settingsControls = [
            font, fontSize, foreground, background, resizeToFit, minimumLines, maximumLines,
            marginLeft, marginTop, marginRight, marginBottom, keepText, localEcho, localEchoColor,
            copy, paste,
        ]
        loadSelectedScope()
    }

    required init?(coder: NSCoder) { nil }

    func commit() { saveSelectedScope() }

    @objc private func scopeChanged(_ sender: Any?) {
        saveSelectedScope()
        selectedScope = availableScopes[max(0, scope.indexOfSelectedItem)]
        loadSelectedScope()
    }

    @objc private func optionChanged(_ sender: Any?) { updateEnabledState() }

    @objc private func copySettings(_ sender: Any?) {
        saveSelectedScope()
        guard let settings = states[selectedScope]?.override.settings,
              let data = try? JSONEncoder().encode(settings),
              let string = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    @objc private func pasteSettings(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string),
              let data = string.data(using: .utf8),
              let settings = try? JSONDecoder().decode(InputWindowSettings.self, from: data),
              var state = states[selectedScope] else { NSSound.beep(); return }
        state.override.settings = settings.normalized
        states[selectedScope] = state
        loadSelectedScope()
    }

    private func loadSelectedScope() {
        guard let state = states[selectedScope] else { return }
        let value = state.override.settings.normalized
        useGlobal.state = state.override.usesGlobalSettings ? .on : .off
        font.selectItem(withTitle: value.fontName)
        fontSize.doubleValue = value.fontSize
        foreground.color = NSColor(hexString: value.foregroundHex) ?? .textColor
        background.color = NSColor(hexString: value.backgroundHex) ?? .textBackgroundColor
        resizeToFit.state = value.resizesToFitContents ? .on : .off
        minimumLines.integerValue = value.minimumLines
        maximumLines.integerValue = value.maximumLines
        marginLeft.integerValue = value.marginLeft
        marginTop.integerValue = value.marginTop
        marginRight.integerValue = value.marginRight
        marginBottom.integerValue = value.marginBottom
        keepText.state = value.keepsTextOnSubmit ? .on : .off
        localEcho.state = value.localEcho ? .on : .off
        localEchoColor.color = NSColor(hexString: value.localEchoHex) ?? .cyan
        updateEnabledState()
    }

    private func saveSelectedScope() {
        guard var state = states[selectedScope] else { return }
        state.override.usesGlobalSettings = selectedScope == .global ? false : useGlobal.state == .on
        state.override.settings = InputWindowSettings(
            fontName: font.titleOfSelectedItem ?? "Menlo",
            fontSize: fontSize.doubleValue,
            foregroundHex: foreground.color.hexString,
            backgroundHex: background.color.hexString,
            resizesToFitContents: resizeToFit.state == .on,
            minimumLines: minimumLines.integerValue,
            maximumLines: maximumLines.integerValue,
            marginLeft: marginLeft.integerValue,
            marginTop: marginTop.integerValue,
            marginRight: marginRight.integerValue,
            marginBottom: marginBottom.integerValue,
            keepsTextOnSubmit: keepText.state == .on,
            localEcho: localEcho.state == .on,
            localEchoHex: localEchoColor.color.hexString
        ).normalized
        states[selectedScope] = state
    }

    private func updateEnabledState() {
        let inherits = selectedScope != .global && useGlobal.state == .on
        useGlobal.isHidden = selectedScope == .global
        settingsControls.forEach { $0.isEnabled = !inherits }
        minimumLines.isEnabled = !inherits && resizeToFit.state == .on
        maximumLines.isEnabled = !inherits && resizeToFit.state == .on
        localEchoColor.isEnabled = !inherits && localEcho.state == .on
    }
}
