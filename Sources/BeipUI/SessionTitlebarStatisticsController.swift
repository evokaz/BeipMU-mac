import AppKit

@MainActor
final class SessionTitlebarStatisticsController: NSViewController {
    private let typedValue = NSTextField(labelWithString: "0")
    private let onlineValue = NSTextField(labelWithString: "0s")
    private let idleValue = NSTextField(labelWithString: "0s")

    convenience init() {
        self.init(nibName: nil, bundle: nil)
    }

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)

        let stack = NSStackView(views: [
            Self.metric(label: "Typed", value: typedValue),
            Self.metric(label: "Online", value: onlineValue),
            Self.metric(label: "Idle", value: idleValue),
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.setAccessibilityIdentifier("activeTabStatistics")

        view = stack
    }

    required init?(coder: NSCoder) { nil }

    func update(typedCount: UInt64, onlineSeconds: TimeInterval, idleSeconds: TimeInterval) {
        typedValue.stringValue = String(typedCount)
        onlineValue.stringValue = SessionTitlebarStatisticsFormatter.duration(onlineSeconds)
        idleValue.stringValue = SessionTitlebarStatisticsFormatter.duration(idleSeconds)
    }

    private static func metric(label: String, value: NSTextField) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.textColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 12)

        value.textColor = .labelColor
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        value.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [title, value])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 3
        return stack
    }
}

enum SessionTitlebarStatisticsFormatter {
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.down)))
        let days = total / 86_400
        let hours = total % 86_400 / 3_600
        let minutes = total % 3_600 / 60
        let seconds = total % 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}
