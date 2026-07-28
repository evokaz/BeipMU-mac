import AppKit
import BeipAutomation

@MainActor
final class AutomationDebugWindowController: NSWindowController, NSWindowDelegate {
    private let textView = NSTextView()
    var onClose: (() -> Void)?

    init(kind: CommandOutcome.DebugAutomationKind) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 360),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(kind.rawValue.capitalized) Debugger"
        panel.setAccessibilityIdentifier("\(kind.rawValue)Debugger")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = .init(width: 12, height: 12)
        textView.setAccessibilityIdentifier("\(kind.rawValue)DebuggerLog")
        textView.setAccessibilityLabel("\(kind.rawValue.capitalized) debugger log")
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func append(_ events: [AutomationTraceEvent]) {
        guard !events.isEmpty else { return }
        let lines = events.map { event in
            let name = event.description.isEmpty ? event.pattern : event.description
            let reason = event.reason.map { "\n  reason: \($0)" } ?? ""
            return "[\(event.engine.rawValue)] \(name) — \(event.matchCount) match\(event.matchCount == 1 ? "" : "es")\(reason)\n  input:  \(event.input)\n  output: \(event.output)\n"
        }.joined()
        textView.textStorage?.append(.init(string: lines))
        textView.scrollToEndOfDocument(nil)
    }

    func showTimerEntries(_ entries: [DelayScheduler.Entry]) {
        textView.string = entries.isEmpty
            ? "No pending timers.\n"
            : entries.map { "\($0.id): \($0.command) in \($0.seconds)s\($0.repeating ? " (repeating)" : "")" }.joined(separator: "\n") + "\n"
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
