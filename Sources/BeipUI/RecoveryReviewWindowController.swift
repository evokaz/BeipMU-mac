import AppKit
import BeipPersistence

/// Startup review for passive session snapshots. Closing the review without a
/// decision is intentionally a skip: the underlying sessions remain in
/// Recovery.dat for the next launch.
@MainActor
final class RecoveryReviewWindowController: NSWindowController, NSWindowDelegate {
    private let candidates: [SessionRecoverySession]
    private let rows = NSStackView()
    private var checkboxes: [UUID: NSButton] = [:]
    private let restoreButton = NSButton(title: "Restore Selected", target: nil, action: nil)
    private let discardButton = NSButton(title: "Discard Selected", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip for Now", target: nil, action: nil)
    private var decisionMade = false

    var onRestore: (([UUID]) -> Void)?
    var onDiscard: (([UUID]) -> Void)?
    var onSkip: (() -> Void)?

    init(candidates: [SessionRecoverySession]) {
        self.candidates = candidates
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Recover Sessions"
        panel.setAccessibilityIdentifier("recoveryReviewWindow")
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        configure()
    }

    required init?(coder: NSCoder) { nil }

    var selectedSessionIDsForTesting: [UUID] {
        candidates.map(\.id).filter { checkboxes[$0]?.state == .on }
    }

    private func configure() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(wrappingLabelWithString: "BeipMU found disconnected session snapshots. Choose which sessions to restore; restoring never reconnects automatically.")
        title.translatesAutoresizingMaskIntoConstraints = false

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 8
        rows.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        rows.translatesAutoresizingMaskIntoConstraints = false

        for candidate in candidates {
            let checkbox = NSButton(checkboxWithTitle: Self.title(for: candidate), target: nil, action: nil)
            checkbox.state = .on
            checkbox.setAccessibilityIdentifier("recoverySessionRow")
            checkbox.setAccessibilityValue(candidate.id.uuidString)
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            checkbox.setContentCompressionResistancePriority(.required, for: .vertical)
            checkboxes[candidate.id] = checkbox
            rows.addArrangedSubview(checkbox)
        }

        let scroll = NSScrollView()
        scroll.documentView = rows
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        restoreButton.target = self
        restoreButton.action = #selector(restore(_:))
        restoreButton.keyEquivalent = "\r"
        restoreButton.setAccessibilityIdentifier("recoveryRestoreButton")
        discardButton.target = self
        discardButton.action = #selector(discard(_:))
        discardButton.setAccessibilityIdentifier("recoveryDiscardButton")
        skipButton.target = self
        skipButton.action = #selector(skip(_:))
        skipButton.setAccessibilityIdentifier("recoverySkipButton")

        let buttons = NSStackView(views: [skipButton, NSView(), discardButton, restoreButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            buttons.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @objc private func restore(_ sender: Any?) {
        let ids = selectedSessionIDsForTesting
        if !ids.isEmpty {
            decisionMade = true
            onRestore?(ids)
        }
        else { skip(nil) }
    }

    @objc private func discard(_ sender: Any?) {
        let ids = selectedSessionIDsForTesting
        if !ids.isEmpty {
            decisionMade = true
            onDiscard?(ids)
        }
        else { skip(nil) }
    }

    @objc private func skip(_ sender: Any?) {
        decisionMade = true
        onSkip?()
        close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !decisionMade else { return }
        decisionMade = true
        onSkip?()
    }

    private static func title(for session: SessionRecoverySession) -> String {
        let profile = [session.serverName, session.characterName].compactMap { $0 }.joined(separator: " — ")
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(profile) (last active \(formatter.string(from: session.updatedAt)))"
    }
}
