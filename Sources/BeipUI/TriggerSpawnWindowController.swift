import AppKit
import BeipCore

@MainActor
final class TriggerSpawnWindowController: NSWindowController, NSWindowDelegate {
    private let textView = NSTextView()
    var onClose: (() -> Void)?

    init(title: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.setAccessibilityIdentifier("triggerSpawnWindow")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = .init(width: 16, height: 16)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
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

    func clear() { textView.string = "" }

    func append(_ line: RenderedLine) {
        textView.textStorage?.append(.init(string: line.text + "\n"))
        textView.scrollToEndOfDocument(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
