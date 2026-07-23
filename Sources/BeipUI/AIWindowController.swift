import AppKit
import BeipCore

@MainActor
final class AIWindowController: NSWindowController, NSWindowDelegate {
    private let prompt = NSTextView()
    private let response = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let endpoint = NSTextField(labelWithString: "")
    private let send = NSButton(title: "Send", target: nil, action: nil)
    private let content = NSStackView()
    private let dockingAccessory = DockSurfaceAccessoryViewController()
    private var history: [String] = []
    private(set) var isDocked = false
    var onSubmit: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onDockRequest: ((WebViewDockSide) -> Void)? {
        didSet { dockingAccessory.onDockRequest = onDockRequest }
    }

    init(profileKey: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "AI"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let safeKey = profileKey.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        panel.setFrameAutosaveName("BeipMU.AI.\(safeKey.isEmpty ? "Session" : safeKey)")
        super.init(window: panel)
        panel.delegate = self
        panel.addTitlebarAccessoryViewController(dockingAccessory)
        configure(in: panel)
    }

    required init?(coder: NSCoder) { nil }

    func updateEndpoint(_ value: URL?) {
        endpoint.stringValue = value?.absoluteString ?? "No endpoint configured for this world"
        endpoint.textColor = value == nil ? .systemOrange : .secondaryLabelColor
        send.isEnabled = value != nil
    }

    func showResponse(_ value: String, for promptText: String) {
        if !promptText.isEmpty { history.append(promptText) }
        response.string = value
        status.stringValue = "Completed"
        status.textColor = .systemGreen
        window?.makeFirstResponder(prompt)
    }

    func submitPrompt(_ value: String) {
        prompt.string = value
        submit(nil)
    }

    func contentViewForDocking() -> NSView {
        window?.orderOut(nil)
        if window?.contentView === content { window?.contentView = nil }
        content.removeFromSuperview()
        isDocked = true
        return content
    }

    func showFloating(_ sender: Any?) {
        if isDocked {
            content.removeFromSuperview()
            window?.contentView = content
            isDocked = false
        }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func closeSurface() {
        if isDocked {
            content.removeFromSuperview()
            window?.contentView = content
            isDocked = false
        }
        close()
    }

    func showError(_ value: String) {
        response.string = value
        status.stringValue = "Request failed"
        status.textColor = .systemRed
    }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        window?.appearance = palette.appearance
        window?.backgroundColor = palette.chrome
        for editor in [prompt, response] {
            editor.textColor = palette.foreground
            editor.backgroundColor = palette.background
            editor.insertionPointColor = palette.accent
        }
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private func configure(in panel: NSPanel) {
        prompt.isRichText = false
        prompt.font = .systemFont(ofSize: 14)
        prompt.isVerticallyResizable = true
        prompt.isHorizontallyResizable = false
        prompt.textContainer?.widthTracksTextView = true
        prompt.setAccessibilityIdentifier("aiPrompt")
        prompt.setAccessibilityLabel("AI prompt")

        response.isRichText = false
        response.isEditable = false
        response.isSelectable = true
        response.font = .systemFont(ofSize: 14)
        response.setAccessibilityIdentifier("aiResponse")
        response.setAccessibilityLabel("AI response")

        let promptScroll = scrollView(for: prompt)
        let responseScroll = scrollView(for: response)
        let heading = NSTextField(labelWithString: "Prompt")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let responseHeading = NSTextField(labelWithString: "Response")
        responseHeading.font = .systemFont(ofSize: 13, weight: .semibold)
        endpoint.lineBreakMode = .byTruncatingMiddle
        endpoint.setAccessibilityIdentifier("aiEndpoint")
        endpoint.setAccessibilityLabel("AI endpoint")
        status.setAccessibilityIdentifier("aiStatus")
        status.setAccessibilityLabel("AI request status")
        send.target = self
        send.action = #selector(submit(_:))
        send.keyEquivalent = "\r"
        send.setAccessibilityIdentifier("aiSend")
        let clear = NSButton(title: "Clear", target: self, action: #selector(clear(_:)))
        clear.setAccessibilityIdentifier("aiClear")
        let controls = NSStackView(views: [endpoint, NSView(), status, clear, send])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.setCustomSpacing(14, after: endpoint)

        content.setViews([controls, heading, promptScroll, responseHeading, responseScroll], in: .leading)
        content.orientation = .vertical
        content.spacing = 8
        content.edgeInsets = .init(top: 12, left: 12, bottom: 12, right: 12)
        promptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        responseScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        panel.contentView = content
    }

    private func scrollView(for editor: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    @objc private func submit(_ sender: Any?) {
        let value = prompt.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { NSSound.beep(); return }
        status.stringValue = "Requesting…"
        status.textColor = .secondaryLabelColor
        onSubmit?(value)
    }

    @objc private func clear(_ sender: Any?) {
        prompt.string = ""
        response.string = ""
        status.stringValue = ""
    }
}
