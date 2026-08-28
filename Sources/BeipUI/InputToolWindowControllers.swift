import AppKit
import BeipCore

@MainActor
final class InputHistoryPaneView: NSView {
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private enum ScrollPosition {
        case bottom
        case origin(NSPoint)
    }
    private var pendingScrollPosition: ScrollPosition?

    override init(frame frameRect: NSRect) {
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        scrollView = scroll
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        updateBorderColor()
        setAccessibilityIdentifier("inputHistoryPane")
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 2, height: 1)
        textView.setAccessibilityIdentifier("inputHistoryText")
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
        ])
        update([])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        let scrollPosition = pendingScrollPosition ?? currentScrollPosition()
        super.layout()
        scrollView.frame = bounds
        scrollView.layoutSubtreeIfNeeded()
        if let textContainer = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: textContainer)
        }
        apply(scrollPosition)
        pendingScrollPosition = nil
    }

    func update(_ entries: [String]) {
        pendingScrollPosition = currentScrollPosition()
        textView.string = entries.isEmpty ? "No input history." : entries.joined(separator: "\n")
        needsLayout = true
    }

    func show(_ entries: [String]) {
        pendingScrollPosition = .bottom
        textView.string = entries.isEmpty ? "No input history." : entries.joined(separator: "\n")
        needsLayout = true
    }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        layer?.backgroundColor = palette.chrome.cgColor
        updateBorderColor()
        textView.textColor = palette.foreground
        textView.backgroundColor = palette.background
        scrollView.backgroundColor = palette.background
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    private func currentScrollPosition() -> ScrollPosition {
        isAtBottom ? .bottom : .origin(scrollView.contentView.bounds.origin)
    }

    private var isAtBottom: Bool {
        let maximumY = max(0, textView.bounds.height - scrollView.contentSize.height)
        return maximumY - scrollView.contentView.bounds.origin.y <= 1
    }

    private func apply(_ scrollPosition: ScrollPosition) {
        let maximumY = max(0, textView.bounds.height - scrollView.contentSize.height)
        let origin: NSPoint
        switch scrollPosition {
        case .bottom:
            origin = NSPoint(x: scrollView.contentView.bounds.origin.x, y: maximumY)
        case let .origin(previousOrigin):
            origin = NSPoint(
                x: previousOrigin.x,
                y: min(max(0, previousOrigin.y), maximumY)
            )
        }
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

final class SecondaryInputWindowController: NSWindowController, NSWindowDelegate {
    private(set) var prefix: String
    let logicalTitle: String
    let input = CommandInputView()
    var onClose: (() -> Void)?

    init(prefix: String, checksSpelling: Bool, onSubmit: @escaping (String) -> Void) {
        self.prefix = prefix
        logicalTitle = prefix.isEmpty ? "Input" : "Input — \(prefix)"
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 120),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.title = prefix.isEmpty ? "Input" : "Input — \(prefix)"
        window.minSize = NSSize(width: 360, height: 110)
        input.behavior = .init(prefix: prefix)
        input.isContinuousSpellCheckingEnabled = checksSpelling
        input.onSubmit = onSubmit
        input.onPreferredHeightChange = { [weak self] height in self?.resizeInput(to: height) }
        input.setAccessibilityIdentifier("secondaryCommandInput")

        let prefixLabel = NSTextField(labelWithString: prefix.isEmpty ? "No prefix" : "Prefix: \(prefix)")
        prefixLabel.textColor = .secondaryLabelColor
        let content = NSStackView(views: [prefixLabel, input.containerScrollView])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        input.containerScrollView.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -20).isActive = true
        input.containerScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        window.contentView = content
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(input)
    }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        window?.appearance = palette.appearance
        window?.backgroundColor = palette.chrome
        input.applyTheme(palette)
    }

    func applyScript(action: String, value: String) {
        switch action {
        case "set": input.text = value
        case "prefix":
            prefix = value
            input.behavior = .init(prefix: value, isSticky: input.behavior.isSticky)
        case "title": window?.title = value
        default: break
        }
    }

    private func resizeInput(to height: CGFloat) {
        guard let window else { return }
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        window.setContentSize(NSSize(width: contentSize.width, height: max(110, height + 46)))
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

@MainActor
final class EditWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    let editor: NSTextView
    let logicalTitle: String
    var onClose: (() -> Void)?
    private let status = NSTextField(labelWithString: "Ln 1/1, Col 1")
    private let onSend: (String) -> Void

    init(title: String, text: String, checksSpelling: Bool, onSend: @escaping (String) -> Void) {
        logicalTitle = title
        self.onSend = onSend
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let scroll = NSScrollView()
        editor = NSTextView(frame: .zero)
        super.init(window: window)
        window.delegate = self
        window.title = title.isEmpty ? "Editor" : title
        window.minSize = NSSize(width: 440, height: 280)

        editor.string = text
        editor.delegate = self
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isContinuousSpellCheckingEnabled = checksSpelling
        editor.usesFindBar = true
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 7, height: 7)
        editor.setAccessibilityIdentifier("editWindowText")
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let send = NSButton(title: "Send", target: self, action: #selector(sendText(_:)))
        send.setAccessibilityIdentifier("sendEditWindow")

        let find = NSButton(title: "Find…", target: self, action: #selector(findText(_:)))
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearText(_:)))
        let spelling = NSButton(checkboxWithTitle: "Check spelling", target: self, action: #selector(toggleSpelling(_:)))
        spelling.state = checksSpelling ? .on : .off
        status.textColor = .secondaryLabelColor
        let controls = NSStackView(views: [status, NSView(), spelling, find, clear, send])
        controls.orientation = .horizontal
        controls.spacing = 8

        let content = NSStackView(views: [controls, scroll])
        content.orientation = .vertical
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -20).isActive = true
        window.contentView = content
        window.center()
        updateStatus()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(editor)
    }

    func setText(_ text: String) {
        editor.string = text
        editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        updateStatus()
    }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        window?.appearance = palette.appearance
        window?.backgroundColor = palette.chrome
        editor.textColor = palette.foreground
        editor.backgroundColor = palette.background
        editor.insertionPointColor = palette.accent
        editor.selectedTextAttributes = [
            .backgroundColor: palette.accent.withAlphaComponent(0.55),
            .foregroundColor: palette.foreground,
        ]
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
    func textViewDidChangeSelection(_ notification: Notification) { updateStatus() }

    @objc private func findText(_ sender: Any?) {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        editor.performFindPanelAction(item)
    }

    @objc private func sendText(_ sender: Any?) { onSend(editor.string) }
    @objc private func clearText(_ sender: Any?) { editor.string = ""; updateStatus() }
    @objc private func toggleSpelling(_ sender: NSButton) {
        editor.isContinuousSpellCheckingEnabled = sender.state == .on
    }

    private func updateStatus() {
        let source = editor.string as NSString
        let cursor = min(editor.selectedRange().location, source.length)
        let prefix = source.substring(to: cursor)
        let line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let allLines = max(1, editor.string.reduce(1) { $1 == "\n" ? $0 + 1 : $0 })
        let column = (prefix.split(separator: "\n", omittingEmptySubsequences: false).last?.utf16.count ?? 0) + 1
        status.stringValue = "Ln \(line)/\(allLines), Col \(column)"
    }
}
