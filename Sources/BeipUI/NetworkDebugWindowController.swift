import AppKit
import BeipProtocols

@MainActor
final class NetworkDebugWindowController: NSWindowController, NSWindowDelegate {
    private struct PendingEntry {
        let data: Data
        let received: Bool
    }

    private let textView = NSTextView()
    private let hexButton = KeyboardFocusableButton(checkboxWithTitle: "Show Hex", target: nil, action: nil)
    private let telnetButton = KeyboardFocusableButton(checkboxWithTitle: "Show Telnet + ASCII", target: nil, action: nil)
    private let pauseButton = KeyboardFocusableButton(title: "Pause", target: nil, action: nil)
    private var formatter = NetworkDebugFormatter()
    private var pendingEntries: [PendingEntry] = []
    private var isPaused = false
    private let maximumTextLength = 1_000_000
    var onClose: (() -> Void)?

    init(title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Network Debugger - \(title)"
        panel.setAccessibilityIdentifier("networkDebugger")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = .init(width: 12, height: 12)
        textView.setAccessibilityIdentifier("networkDebuggerLog")
        textView.setAccessibilityLabel("Network activity")

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hexButton.state = .off
        hexButton.target = self
        hexButton.action = #selector(optionsChanged(_:))
        hexButton.setAccessibilityIdentifier("networkDebuggerShowHex")
        telnetButton.state = .on
        telnetButton.target = self
        telnetButton.action = #selector(optionsChanged(_:))
        telnetButton.setAccessibilityIdentifier("networkDebuggerShowTelnet")
        pauseButton.target = self
        pauseButton.action = #selector(togglePause(_:))
        pauseButton.setAccessibilityIdentifier("networkDebuggerPause")

        let copyButton = KeyboardFocusableButton(title: "Copy", target: self, action: #selector(copyLog(_:)))
        copyButton.setAccessibilityIdentifier("networkDebuggerCopy")
        let clearButton = KeyboardFocusableButton(title: "Clear", target: self, action: #selector(clearLog(_:)))
        clearButton.setAccessibilityIdentifier("networkDebuggerClear")
        hexButton.nextKeyView = telnetButton
        telnetButton.nextKeyView = pauseButton
        pauseButton.nextKeyView = copyButton
        copyButton.nextKeyView = clearButton
        clearButton.nextKeyView = textView
        textView.nextKeyView = hexButton
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [hexButton, telnetButton, spacer, pauseButton, copyButton, clearButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        panel.contentView = content
        content.addSubview(controls)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.initialFirstResponder = hexButton

        appendMessage("Showing network activity. Use the controls to change the view.\n", color: .secondaryLabelColor)
    }

    required init?(coder: NSCoder) { nil }

    var displayedText: String { textView.string }
    var paused: Bool { isPaused }
    var pendingEntryCount: Int { pendingEntries.count }

    func focusInitialControl() { window?.makeFirstResponder(hexButton) }

    func append(_ data: Data, received: Bool) {
        guard !data.isEmpty else { return }
        if isPaused {
            pendingEntries.append(PendingEntry(data: data, received: received))
            return
        }
        appendImmediately(data, received: received)
    }

    func setShowHex(_ enabled: Bool) {
        hexButton.state = enabled ? .on : .off
        formatter.showHex = enabled
    }

    func setShowTelnet(_ enabled: Bool) {
        telnetButton.state = enabled ? .on : .off
        formatter.showTelnet = enabled
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        pauseButton.title = paused ? "Resume" : "Pause"
        pauseButton.setAccessibilityLabel(paused ? "Resume network activity" : "Pause network activity")
        if !paused {
            let entries = pendingEntries
            pendingEntries.removeAll(keepingCapacity: true)
            entries.forEach { appendImmediately($0.data, received: $0.received) }
        }
    }

    func clear() {
        textView.textStorage?.setAttributedString(NSAttributedString())
        pendingEntries.removeAll(keepingCapacity: true)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    @objc private func optionsChanged(_ sender: NSButton) {
        formatter.showHex = hexButton.state == .on
        formatter.showTelnet = telnetButton.state == .on
    }

    @objc private func togglePause(_ sender: NSButton) { setPaused(!isPaused) }

    @objc private func copyLog(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func clearLog(_ sender: NSButton) { clear() }

    private func appendImmediately(_ data: Data, received: Bool) {
        let direction = received ? "Received" : "Sent"
        let suffix = data.count == 1 ? "byte" : "bytes"
        appendMessage("\n\(direction) \(data.count) \(suffix)\n", color: received ? .systemBlue : .systemGreen)
        appendFormatted(formatter.format(data, received: received))
        appendMessage("\n", color: .textColor)
        trimIfNeeded()
        textView.scrollToEndOfDocument(nil)
    }

    private func appendMessage(_ string: String, color: NSColor) {
        textView.textStorage?.append(NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
            ]
        ))
    }

    private func appendFormatted(_ markup: String) {
        guard !markup.isEmpty else { return }
        let storage = NSMutableAttributedString()
        var remainder = markup[...]
        var color = NSColor.textColor

        while !remainder.isEmpty {
            if remainder.hasPrefix("<font color='") {
                guard let close = remainder.firstIndex(of: ">") else { break }
                let tag = remainder[remainder.startIndex...close]
                if let hash = tag.firstIndex(of: "#") {
                    let start = tag.index(after: hash)
                    let end = tag.index(start, offsetBy: 6, limitedBy: tag.endIndex) ?? tag.endIndex
                    color = Self.color(for: String(tag[start..<end]))
                }
                remainder = remainder[remainder.index(after: close)...]
                continue
            }

            let nextTag = remainder.range(of: "<font color='")?.lowerBound ?? remainder.endIndex
            var text = String(remainder[..<nextTag])
            text = text.replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\r\n", with: "\n")
            storage.append(NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: color,
                ]
            ))
            remainder = remainder[nextTag...]
        }
        textView.textStorage?.append(storage)
    }

    private static func color(for hex: String) -> NSColor {
        switch hex.lowercased() {
        case "ff00ff": return .systemPurple
        case "8080ff": return .systemBlue
        case "008000": return .systemGreen
        case "ff0000": return .systemRed
        default: return .textColor
        }
    }

    private func trimIfNeeded() {
        guard let storage = textView.textStorage, storage.length > maximumTextLength else { return }
        storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - maximumTextLength))
    }
}
