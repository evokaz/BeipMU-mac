import AppKit
import BeipCore

@MainActor
final class SessionStatisticsWindowController: NSWindowController, NSWindowDelegate {
    private let serverValue = NSTextField(labelWithString: "None")
    private let stateValue = NSTextField(labelWithString: "Disconnected")
    private let connectionsValue = NSTextField(labelWithString: "0")
    private let sentValue = NSTextField(labelWithString: "0 bytes")
    private let receivedValue = NSTextField(labelWithString: "0 bytes")
    private let onlineValue = NSTextField(labelWithString: "00:00:00")

    var onClose: (() -> Void)?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 300),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Connection Statistics"
        panel.setAccessibilityIdentifier("statisticsWindow")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        configureContent(in: panel)
    }

    required init?(coder: NSCoder) { nil }

    func update(
        statistics: ConnectionStatistics,
        server: String,
        state: String
    ) {
        serverValue.stringValue = server
        stateValue.stringValue = state
        connectionsValue.stringValue = String(statistics.connectionCount)
        sentValue.stringValue = Self.byteDescription(statistics.bytesSent)
        receivedValue.stringValue = Self.byteDescription(statistics.bytesReceived)
        onlineValue.stringValue = Self.durationDescription(statistics.secondsConnected)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func configureContent(in panel: NSPanel) {
        let heading = NSTextField(labelWithString: "Session Statistics")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString: "Live totals for the active session. Values continue updating while this window is open.")
        detail.textColor = .secondaryLabelColor

        let rows = [
            row("Server:", value: serverValue, identifier: "statisticsServer"),
            row("State:", value: stateValue, identifier: "statisticsState"),
            row("Connections:", value: connectionsValue, identifier: "statisticsConnections"),
            row("Bytes sent:", value: sentValue, identifier: "statisticsBytesSent"),
            row("Bytes received:", value: receivedValue, identifier: "statisticsBytesReceived"),
            row("Time connected:", value: onlineValue, identifier: "statisticsOnlineTime"),
        ]
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 125
        grid.column(at: 1).width = 220
        grid.rowSpacing = 9

        let stack = NSStackView(views: [heading, detail, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -22),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func row(_ title: String, value: NSTextField, identifier: String) -> [NSView] {
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.setAccessibilityIdentifier(identifier)
        return [NSTextField(labelWithString: title), value]
    }

    private static func byteDescription(_ bytes: UInt64) -> String {
        "\(bytes) byte\(bytes == 1 ? "" : "s")"
    }

    private static func durationDescription(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = total % 3_600 / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
