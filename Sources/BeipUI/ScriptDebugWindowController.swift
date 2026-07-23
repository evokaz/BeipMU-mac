import AppKit

@MainActor
final class ScriptDebugWindowController: NSWindowController, NSWindowDelegate {
    enum EntryKind: String, Sendable {
        case text = "Debug"
        case html = "Debug HTML"
        case error = "Error"
        case runtime = "Runtime"
    }

    struct Entry: Sendable, Equatable {
        var kind: EntryKind
        var message: String
    }

    private let textView = NSTextView()
    var onClose: (() -> Void)?
    var onReset: (() -> Void)?

    init(title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Script Debugger - \(title)"
        panel.setAccessibilityIdentifier("scriptDebugger")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = .init(width: 12, height: 12)
        textView.setAccessibilityIdentifier("scriptDebuggerLog")
        textView.setAccessibilityLabel("Script debug output")

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = KeyboardFocusableButton(title: "Clear", target: self, action: #selector(clearLog(_:)))
        clearButton.setAccessibilityIdentifier("scriptDebuggerClear")
        let resetButton = KeyboardFocusableButton(title: "Reset Runtime", target: self, action: #selector(resetRuntime(_:)))
        resetButton.setAccessibilityIdentifier("scriptDebuggerReset")
        resetButton.nextKeyView = clearButton
        clearButton.nextKeyView = textView
        textView.nextKeyView = resetButton
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [spacer, resetButton, clearButton])
        controls.orientation = .horizontal
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
        panel.initialFirstResponder = resetButton
    }

    required init?(coder: NSCoder) { nil }

    var displayedText: String { textView.string }

    func focusInitialControl() {
        guard let reset = window?.contentView?.subviews
            .flatMap({ [$0] + $0.subviews })
            .compactMap({ $0 as? NSButton })
            .first(where: { $0.accessibilityIdentifier() == "scriptDebuggerReset" }) else { return }
        window?.makeFirstResponder(reset)
    }

    func replace(with entries: [Entry]) {
        textView.textStorage?.setAttributedString(NSAttributedString())
        entries.forEach(append)
    }

    func append(_ entry: Entry) {
        let color: NSColor = switch entry.kind {
        case .text: .textColor
        case .html: .systemPurple
        case .error: .systemRed
        case .runtime: .systemBlue
        }
        let prefix = "[\(entry.kind.rawValue)] "
        textView.textStorage?.append(NSAttributedString(
            string: prefix + entry.message + "\n",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: color,
            ]
        ))
        trimIfNeeded()
        textView.scrollToEndOfDocument(nil)
    }

    func clear() { textView.textStorage?.setAttributedString(NSAttributedString()) }

    func windowWillClose(_ notification: Notification) { onClose?() }

    @objc private func clearLog(_ sender: NSButton) { clear() }
    @objc private func resetRuntime(_ sender: NSButton) { onReset?() }

    private func trimIfNeeded() {
        guard let storage = textView.textStorage, storage.length > 500_000 else { return }
        storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 500_000))
    }
}
