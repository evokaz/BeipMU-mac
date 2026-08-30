import AppKit
import BeipCore

@MainActor
final class CommandInputView: NSTextView {
    let containerScrollView: NSScrollView
    var onSubmit: ((String) -> Void)?
    var onSmartPaste: (([String]) -> Bool)?
    var onMacro: ((NSEvent) -> Bool)?
    var onPageUp: (() -> Bool)?
    var onPageDown: (() -> Bool)?
    var onShowSettings: (() -> Void)?
    var onToggleUseGlobalSettings: (() -> Void)?
    var onPreferredHeightChange: ((CGFloat) -> Void)?
    var onTextChange: ((String) -> Void)?
    var onHistoryChange: (([String]) -> Void)?
    var usesGlobalSettings = true
    var canToggleUseGlobalSettings = false
    var behavior = InputBehavior()
    var completionCandidates: [String] = []
    private var commandHistory = InputHistory()
    private var preservesHistoryNavigationDuringTextChange = false
    private var settings = InputWindowSettings()
    private var themePalette = WorkspaceThemeSettings().palette

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        containerScrollView = NSScrollView()
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 50), textContainer: container)

        containerScrollView.documentView = self
        containerScrollView.hasVerticalScroller = true
        containerScrollView.autohidesScrollers = true
        containerScrollView.borderType = .bezelBorder
        containerScrollView.translatesAutoresizingMaskIntoConstraints = false
        isRichText = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = true
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textContainerInset = NSSize(width: 5, height: 6)
        setAccessibilityLabel("Command input")
    }

    required init?(coder: NSCoder) { nil }

    var text: String {
        get { string }
        set {
            commandHistory.resetNavigation()
            string = newValue
            setSelectedRange(NSRange(location: newValue.utf16.count, length: 0))
            onTextChange?(newValue)
        }
    }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        themePalette = palette
        let foreground = NSColor(hexString: settings.foregroundHex) ?? palette.foreground
        let background = NSColor(hexString: settings.backgroundHex) ?? palette.background
        textColor = foreground
        backgroundColor = background
        containerScrollView.backgroundColor = background
        insertionPointColor = palette.accent
        selectedTextAttributes = [
            .backgroundColor: palette.accent.withAlphaComponent(0.55),
            .foregroundColor: foreground,
        ]
        needsDisplay = true
        containerScrollView.needsDisplay = true
    }

    func applySettings(_ suppliedSettings: InputWindowSettings) {
        settings = suppliedSettings.normalized
        font = NSFont(name: settings.fontName, size: settings.fontSize)
            ?? .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        textColor = NSColor(hexString: settings.foregroundHex) ?? themePalette.foreground
        backgroundColor = NSColor(hexString: settings.backgroundHex) ?? themePalette.background
        containerScrollView.backgroundColor = backgroundColor
        containerScrollView.contentInsets = NSEdgeInsets(
            top: CGFloat(settings.marginTop),
            left: CGFloat(settings.marginLeft),
            bottom: CGFloat(settings.marginBottom),
            right: CGFloat(settings.marginRight)
        )
        textContainerInset = .zero
        behavior.isSticky = settings.keepsTextOnSubmit
        notifyPreferredHeight()
    }

    var appliedSettingsForTesting: InputWindowSettings { settings }
    var historyEntriesForDisplay: [String] { commandHistory.entries }

    override func keyDown(with event: NSEvent) {
        if onMacro?(event) == true { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36 where !modifiers.contains(.shift) && !modifiers.contains(.option),
             76 where !modifiers.contains(.shift) && !modifiers.contains(.option):
            submit()
        case 126:
            if modifiers.isDisjoint(with: [.shift, .control, .command, .option]),
               shouldNavigateBackward,
               let previous = commandHistory.previous(currentText: string) {
                replaceTextFromHistory(previous)
            } else {
                // Moving within a recalled multiline entry must not discard the
                // history cursor. It will be used when the caret reaches an edge.
                if !modifiers.isDisjoint(with: [.shift, .control, .command, .option]) {
                    commandHistory.resetNavigation()
                }
                super.keyDown(with: event)
            }
        case 125:
            if modifiers.isDisjoint(with: [.shift, .control, .command, .option]),
               shouldNavigateForward,
               let next = commandHistory.next() {
                replaceTextFromHistory(next)
            } else {
                if !modifiers.isDisjoint(with: [.shift, .control, .command, .option]) {
                    commandHistory.resetNavigation()
                }
                super.keyDown(with: event)
            }
        case 48 where modifiers.isDisjoint(with: [.control, .command, .option]):
            completeCurrentWord()
        case 116 where modifiers.isDisjoint(with: [.control, .command, .option]) && onPageUp?() == true:
            break
        case 121 where modifiers.isDisjoint(with: [.control, .command, .option]) && onPageDown?() == true:
            break
        default:
            commandHistory.resetNavigation()
            super.keyDown(with: event)
        }
    }

    func apply(_ conversion: InputConversion) {
        text = conversion.apply(to: string)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        return addingConversionMenu(to: menu)
    }

    func contextMenuForTesting(baseMenu: NSMenu = NSMenu()) -> NSMenu {
        addingConversionMenu(to: baseMenu)
    }

    private func addingConversionMenu(to menu: NSMenu) -> NSMenu {
        guard menu.item(withTitle: "Conversion") == nil else { return menu }

        if onShowSettings != nil {
            let global = NSMenuItem(
                title: "Inherit default settings",
                action: #selector(toggleUseGlobalSettings(_:)),
                keyEquivalent: ""
            )
            global.target = self
            global.state = usesGlobalSettings ? .on : .off
            global.isEnabled = canToggleUseGlobalSettings && onToggleUseGlobalSettings != nil
            menu.insertItem(global, at: 0)
            let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: "")
            settings.target = self
            menu.insertItem(settings, at: 1)
            menu.insertItem(.separator(), at: 2)
        }

        let conversionMenu = NSMenu(title: "Conversion")
        func add(_ title: String, conversion: InputConversion, action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = conversion.rawValue
            conversionMenu.addItem(item)
        }
        add("Convert Returns to %R", conversion: .returns, action: #selector(convertReturns(_:)))
        add("Convert Tabs to %T", conversion: .tabs, action: #selector(convertTabs(_:)))
        add("Convert Spaces to %B", conversion: .spaces, action: #selector(convertSpaces(_:)))

        let conversionItem = NSMenuItem(title: "Conversion", action: nil, keyEquivalent: "")
        conversionItem.submenu = conversionMenu
        let insertionIndex = onShowSettings == nil ? 0 : 3
        menu.insertItem(conversionItem, at: insertionIndex)
        if menu.numberOfItems > insertionIndex + 1, !menu.items[insertionIndex + 1].isSeparatorItem {
            menu.insertItem(.separator(), at: insertionIndex + 1)
        }
        return menu
    }

    @objc private func toggleUseGlobalSettings(_ sender: Any?) { onToggleUseGlobalSettings?() }
    @objc private func showSettings(_ sender: Any?) { onShowSettings?() }
    @objc private func convertReturns(_ sender: Any?) { apply(.returns) }
    @objc private func convertTabs(_ sender: Any?) { apply(.tabs) }
    @objc private func convertSpaces(_ sender: Any?) { apply(.spaces) }

    func addToHistory(_ value: String) {
        commandHistory.record(value)
        onHistoryChange?(commandHistory.entries)
    }

    func restoreHistory(_ values: [String]) {
        commandHistory = InputHistory(limit: commandHistory.limit)
        values.forEach { commandHistory.record($0) }
        commandHistory.resetNavigation()
        onHistoryChange?(commandHistory.entries)
    }

    override func paste(_ sender: Any?) {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        let normalized = pasted.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 1, onSmartPaste?(lines) == true { return }
        insertText(normalized, replacementRange: selectedRange())
    }

    override func didChangeText() {
        super.didChangeText()
        if !preservesHistoryNavigationDuringTextChange {
            commandHistory.resetNavigation()
        }
        onTextChange?(string)
        notifyPreferredHeight()
    }

    private func replaceTextFromHistory(_ value: String) {
        preservesHistoryNavigationDuringTextChange = true
        string = value
        setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        preservesHistoryNavigationDuringTextChange = false
        onTextChange?(value)
    }

    private func notifyPreferredHeight() {
        guard settings.resizesToFitContents, bounds.width > 0, let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let lineHeight = max(1, layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: settings.fontSize)))
        let measuredLines = max(1, Int(ceil(layoutManager.usedRect(for: textContainer).height / lineHeight)))
        let lines = min(settings.maximumLines, max(settings.minimumLines, measuredLines))
        let height = CGFloat(lines) * lineHeight
            + CGFloat(settings.marginTop + settings.marginBottom)
            + 4
        onPreferredHeightChange?(max(30, height))
    }

    private var shouldNavigateBackward: Bool {
        let selection = selectedRange()
        return selection.length == 0 && isCaretOnVisualLine(.first, at: selection.location)
    }

    private var shouldNavigateForward: Bool {
        let selection = selectedRange()
        return selection.length == 0 && isCaretOnVisualLine(.last, at: selection.location)
    }

    private enum VisualLineBoundary {
        case first
        case last
    }

    /// Returns whether an insertion point is on the first or last rendered line.
    /// Line-fragment ranges account for both explicit newlines and soft wrapping.
    private func isCaretOnVisualLine(_ boundary: VisualLineBoundary, at location: Int) -> Bool {
        guard let layoutManager, let textContainer else { return false }
        layoutManager.ensureLayout(for: textContainer)

        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return true }

        var firstGlyphRange = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &firstGlyphRange)

        var lastGlyphRange = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyphCount - 1, effectiveRange: &lastGlyphRange)

        let hasTrailingEmptyLine = layoutManager.extraLineFragmentTextContainer != nil
        let hasSingleVisualLine = NSEqualRanges(firstGlyphRange, lastGlyphRange) && !hasTrailingEmptyLine
        if hasSingleVisualLine { return true }

        switch boundary {
        case .first:
            let characterRange = layoutManager.characterRange(
                forGlyphRange: firstGlyphRange,
                actualGlyphRange: nil
            )
            // The end of a wrapped fragment is the start of the next visual line.
            return location < NSMaxRange(characterRange)
        case .last:
            if hasTrailingEmptyLine {
                return location == (string as NSString).length
            }
            let characterRange = layoutManager.characterRange(
                forGlyphRange: lastGlyphRange,
                actualGlyphRange: nil
            )
            return location >= characterRange.location
        }
    }

    private func submit() {
        guard !string.isEmpty else { return }
        let original = string
        let submission = behavior.submission(for: original)
        commandHistory.record(original)
        onHistoryChange?(commandHistory.entries)
        text = submission.replacement
        onSubmit?(submission.outbound)
    }

    private func completeCurrentWord() {
        let value = string as NSString
        let cursor = selectedRange().location
        var start = cursor
        while start > 0, !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(value.character(at: start - 1))!) {
            start -= 1
        }
        let prefix = value.substring(with: NSRange(location: start, length: cursor - start))
        guard !prefix.isEmpty else { super.insertTab(nil); return }
        let matches = completionCandidates.filter {
            $0.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
        }
        guard let completion = matches.count == 1 ? matches[0] : matches.sorted().first else {
            NSSound.beep()
            return
        }
        insertText(completion, replacementRange: NSRange(location: start, length: cursor - start))
    }
}
