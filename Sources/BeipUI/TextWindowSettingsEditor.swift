import AppKit

func historyLinesNumberFormatter(locale: Locale = .current) -> NumberFormatter {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.allowsFloats = false
    formatter.isLenient = true
    formatter.usesGroupingSeparator = true
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 0
    return formatter
}

@MainActor
final class TextWindowSettingsEditorView: NSView {
    enum Scope: String, CaseIterable, Hashable {
        case global = "Global"
        case world = "World"
        case character = "Character"
        case tab = "Tab"
    }

    struct State {
        var label: String
        var override: TextWindowSettingsOverride
    }

    private(set) var states: [Scope: State]
    private let availableScopes: [Scope]
    private var selectedScope: Scope
    private let scope = NSPopUpButton()
    private let useGlobal = NSButton(checkboxWithTitle: "Use global settings", target: nil, action: nil)
    private let font = NSPopUpButton()
    private let fontSize = NSTextField()
    private let foreground = NSColorWell()
    private let background = NSColorWell()
    private let webLink = NSColorWell()
    private let invert = NSButton(checkboxWithTitle: "Invert brightness", target: nil, action: nil)
    private let fanFold = NSButton(checkboxWithTitle: "Fan-fold backgrounds", target: nil, action: nil)
    private let fanFoldFirst = NSColorWell()
    private let fanFoldSecond = NSColorWell()
    private let history = NSTextField()
    private let wrappedIndent = NSTextField()
    private let paragraphSpacing = NSTextField()
    private let fixedWidth = NSButton(checkboxWithTitle: "Fixed width", target: nil, action: nil)
    private let fixedWidthCharacters = NSTextField()
    private let smoothScroll = NSButton(checkboxWithTitle: "Smooth scrolling", target: nil, action: nil)
    private let scrollToBottom = NSButton(
        checkboxWithTitle: "Scroll to bottom on new text",
        target: nil,
        action: nil
    )
    private let splitOnPageUp = NSButton(checkboxWithTitle: "Split on Page Up", target: nil, action: nil)
    private let marginLeft = NSTextField()
    private let marginRight = NSTextField()
    private let marginTop = NSTextField()
    private let marginBottom = NSTextField()
    private let showTime = NSButton(checkboxWithTitle: "Time", target: nil, action: nil)
    private let use24Hour = NSButton(checkboxWithTitle: "24-hour time", target: nil, action: nil)
    private let showDate = NSButton(checkboxWithTitle: "Date", target: nil, action: nil)
    private let showToolTip = NSButton(checkboxWithTitle: "Show date & time tooltip", target: nil, action: nil)
    private let copiedPopup = NSButton(checkboxWithTitle: "Show selection copied popup", target: nil, action: nil)
    private let newContentMarkers = NSButton(checkboxWithTitle: "New content markers", target: nil, action: nil)
    private var settingsControls: [NSControl] = []

    init(states: [Scope: State], initialScope: Scope, numberLocale: Locale = .current) {
        self.states = states
        availableScopes = Scope.allCases.filter { states[$0] != nil }
        selectedScope = states[initialScope] == nil ? .global : initialScope
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 580))

        scope.addItems(withTitles: availableScopes.compactMap { states[$0]?.label })
        scope.selectItem(at: availableScopes.firstIndex(of: selectedScope) ?? 0)
        scope.target = self
        scope.action = #selector(scopeChanged(_:))
        scope.setAccessibilityIdentifier("textSettingsScope")
        useGlobal.target = self
        useGlobal.action = #selector(useGlobalChanged(_:))
        useGlobal.setAccessibilityIdentifier("textSettingsUseGlobal")
        [fixedWidth, fanFold, showTime].forEach {
            $0.target = self
            $0.action = #selector(optionChanged(_:))
        }

        font.addItems(withTitles: NSFontManager.shared.availableFontFamilies.sorted())
        font.setAccessibilityIdentifier("textSettingsFont")
        fontSize.setAccessibilityIdentifier("textSettingsFontSize")
        foreground.setAccessibilityIdentifier("textSettingsForeground")
        background.setAccessibilityIdentifier("textSettingsBackground")
        webLink.setAccessibilityIdentifier("textSettingsWebLink")
        history.formatter = historyLinesNumberFormatter(locale: numberLocale)
        history.setAccessibilityIdentifier("textSettingsHistory")
        wrappedIndent.setAccessibilityIdentifier("textSettingsWrappedIndent")
        paragraphSpacing.setAccessibilityIdentifier("textSettingsParagraphSpacing")
        fixedWidthCharacters.setAccessibilityIdentifier("textSettingsFixedWidthCharacters")
        marginLeft.setAccessibilityIdentifier("textSettingsMarginLeft")
        marginRight.setAccessibilityIdentifier("textSettingsMarginRight")
        marginTop.setAccessibilityIdentifier("textSettingsMarginTop")
        marginBottom.setAccessibilityIdentifier("textSettingsMarginBottom")
        [fontSize, history, wrappedIndent, paragraphSpacing, fixedWidthCharacters,
         marginLeft, marginRight, marginTop, marginBottom].forEach {
            $0.alignment = .right
            $0.controlSize = .small
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
            [NSTextField(labelWithString: "Web link:"), webLink],
            [NSView(), invert],
            [NSView(), fanFold],
            [NSTextField(labelWithString: "Fan-fold color 1:"), fanFoldFirst],
            [NSTextField(labelWithString: "Fan-fold color 2:"), fanFoldSecond],
            [NSTextField(labelWithString: "History lines:"), history],
            [NSTextField(labelWithString: "Wrapped-line indent:"), wrappedIndent],
            [NSTextField(labelWithString: "Paragraph spacing:"), paragraphSpacing],
            [NSView(), fixedWidth],
            [NSTextField(labelWithString: "Width in characters:"), fixedWidthCharacters],
            [NSView(), smoothScroll],
            [NSView(), scrollToBottom],
            [NSView(), splitOnPageUp],
            [NSTextField(labelWithString: "Left margin:"), marginLeft],
            [NSTextField(labelWithString: "Right margin:"), marginRight],
            [NSTextField(labelWithString: "Top margin:"), marginTop],
            [NSTextField(labelWithString: "Bottom margin:"), marginBottom],
            [NSView(), showTime],
            [NSView(), use24Hour],
            [NSView(), showDate],
            [NSView(), showToolTip],
            [NSView(), copiedPopup],
            [NSView(), newContentMarkers],
            [NSTextField(labelWithString: "Settings:"), copyPaste],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 165
        grid.column(at: 1).width = 330
        grid.rowSpacing = 7
        grid.translatesAutoresizingMaskIntoConstraints = false

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            document.widthAnchor.constraint(equalToConstant: 540),
        ])
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        settingsControls = [
            font, fontSize, foreground, background, webLink, invert, fanFold, fanFoldFirst, fanFoldSecond, history,
            wrappedIndent, paragraphSpacing, fixedWidth, fixedWidthCharacters, smoothScroll,
            scrollToBottom, splitOnPageUp, marginLeft, marginRight, marginTop, marginBottom,
            showTime, use24Hour, showDate, showToolTip, copiedPopup, newContentMarkers,
            copy, paste,
        ]
        loadSelectedScope()
    }

    required init?(coder: NSCoder) { nil }

    func commit() {
        saveSelectedScope()
    }

    @objc private func scopeChanged(_ sender: Any?) {
        saveSelectedScope()
        selectedScope = availableScopes[max(0, scope.indexOfSelectedItem)]
        loadSelectedScope()
    }

    @objc private func useGlobalChanged(_ sender: Any?) {
        updateEnabledState()
    }

    @objc private func optionChanged(_ sender: Any?) {
        updateEnabledState()
    }

    @objc private func copySettings(_ sender: Any?) {
        saveSelectedScope()
        guard let state = states[selectedScope],
              let data = try? JSONEncoder().encode(state.override.settings),
              let value = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func pasteSettings(_ sender: Any?) {
        guard let value = NSPasteboard.general.string(forType: .string),
              let data = value.data(using: .utf8),
              let pasted = try? JSONDecoder().decode(TextWindowSettings.self, from: data),
              var state = states[selectedScope] else {
            NSSound.beep()
            return
        }
        state.override.settings = pasted.normalized
        state.override.usesGlobalSettings = false
        states[selectedScope] = state
        loadSelectedScope()
    }

    private func loadSelectedScope() {
        guard let state = states[selectedScope] else { return }
        let value = state.override.settings
        useGlobal.state = state.override.usesGlobalSettings ? .on : .off
        if font.itemTitles.contains(value.fontName) { font.selectItem(withTitle: value.fontName) }
        else {
            font.addItem(withTitle: value.fontName)
            font.selectItem(withTitle: value.fontName)
        }
        fontSize.doubleValue = value.fontSize
        foreground.color = NSColor(hexString: value.foregroundHex) ?? .textColor
        background.color = NSColor(hexString: value.backgroundHex) ?? .textBackgroundColor
        webLink.color = NSColor(hexString: value.webLinkHex) ?? .linkColor
        invert.state = value.invertBrightness ? .on : .off
        fanFold.state = value.usesFanFoldBackgrounds ? .on : .off
        fanFoldFirst.color = NSColor(hexString: value.fanFoldFirstHex) ?? .textBackgroundColor
        fanFoldSecond.color = NSColor(hexString: value.fanFoldSecondHex) ?? .underPageBackgroundColor
        history.integerValue = value.historyLimit
        wrappedIndent.integerValue = value.wrappedLineIndent
        paragraphSpacing.integerValue = value.paragraphSpacing
        fixedWidth.state = value.usesFixedWidth ? .on : .off
        fixedWidthCharacters.integerValue = value.fixedWidthCharacters
        smoothScroll.state = value.smoothScrolling ? .on : .off
        scrollToBottom.state = value.scrollsToBottomOnNewText ? .on : .off
        splitOnPageUp.state = value.splitsOnPageUp ? .on : .off
        marginLeft.integerValue = value.marginLeft
        marginRight.integerValue = value.marginRight
        marginTop.integerValue = value.marginTop
        marginBottom.integerValue = value.marginBottom
        showTime.state = value.showsTime ? .on : .off
        use24Hour.state = value.uses24HourTime ? .on : .off
        showDate.state = value.showsDate ? .on : .off
        let globalHelp = states[.global]?.override.settings ?? value
        showToolTip.state = globalHelp.showsDateTimeToolTip ? .on : .off
        copiedPopup.state = globalHelp.showsSelectionCopiedPopup ? .on : .off
        newContentMarkers.state = globalHelp.showsNewContentMarkers ? .on : .off
        useGlobal.isHidden = selectedScope == .global
        updateEnabledState()
    }

    private func saveSelectedScope() {
        guard var state = states[selectedScope] else { return }
        state.override.usesGlobalSettings = selectedScope == .global ? false : useGlobal.state == .on
        state.override.settings = TextWindowSettings(
            fontName: font.titleOfSelectedItem ?? "Menlo",
            fontSize: fontSize.doubleValue,
            foregroundHex: foreground.color.hexString,
            backgroundHex: background.color.hexString,
            webLinkHex: webLink.color.hexString,
            invertBrightness: invert.state == .on,
            usesFanFoldBackgrounds: fanFold.state == .on,
            fanFoldFirstHex: fanFoldFirst.color.hexString,
            fanFoldSecondHex: fanFoldSecond.color.hexString,
            historyLimit: history.integerValue,
            wrappedLineIndent: wrappedIndent.integerValue,
            paragraphSpacing: paragraphSpacing.integerValue,
            usesFixedWidth: fixedWidth.state == .on,
            fixedWidthCharacters: fixedWidthCharacters.integerValue,
            smoothScrolling: smoothScroll.state == .on,
            scrollsToBottomOnNewText: scrollToBottom.state == .on,
            splitsOnPageUp: splitOnPageUp.state == .on,
            marginLeft: marginLeft.integerValue,
            marginRight: marginRight.integerValue,
            marginTop: marginTop.integerValue,
            marginBottom: marginBottom.integerValue,
            showsTime: showTime.state == .on,
            uses24HourTime: use24Hour.state == .on,
            showsDate: showDate.state == .on,
            showsDateTimeToolTip: showToolTip.state == .on,
            showsSelectionCopiedPopup: copiedPopup.state == .on,
            showsNewContentMarkers: newContentMarkers.state == .on
        ).normalized
        states[selectedScope] = state
        if selectedScope == .global {
            // Help controls apply globally even when local output overrides exist.
            states[.global] = state
        }
    }

    private func updateEnabledState() {
        let enabled = selectedScope == .global || useGlobal.state == .off
        settingsControls.forEach { $0.isEnabled = enabled }
        fixedWidthCharacters.isEnabled = enabled && fixedWidth.state == .on
        use24Hour.isEnabled = enabled && showTime.state == .on
        fanFoldFirst.isEnabled = enabled && fanFold.state == .on
        fanFoldSecond.isEnabled = enabled && fanFold.state == .on
        let isGlobal = selectedScope == .global
        showToolTip.isEnabled = enabled && isGlobal
        copiedPopup.isEnabled = enabled && isGlobal
        newContentMarkers.isEnabled = enabled && isGlobal
    }
}
