import AppKit
import BeipAutomation

@MainActor
final class TriggerStatisticsWindowController: NSWindowController, NSWindowDelegate {
    private let textView = NSTextView()
    private let titleValue: String
    var onClose: (() -> Void)?

    init(title: String) {
        titleValue = title
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.setAccessibilityIdentifier("triggerStatisticsWindow")
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

    func update(_ statistics: [TriggerStatistic]) {
        let content = NSMutableAttributedString()
        for statistic in statistics {
            let line = "\(statistic.name): \(Self.valueDescription(statistic.value))\n"
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let color = statistic.color {
                attributes[.foregroundColor] = NSColor(
                    red: CGFloat(color.red) / 255,
                    green: CGFloat(color.green) / 255,
                    blue: CGFloat(color.blue) / 255,
                    alpha: 1
                )
            }
            if let font = statistic.font {
                var traits: NSFontTraitMask = []
                if font.bold { traits.insert(.boldFontMask) }
                if font.italic { traits.insert(.italicFontMask) }
                let base = NSFont(name: font.name, size: CGFloat(font.size))
                    ?? NSFont.monospacedSystemFont(ofSize: CGFloat(font.size), weight: .regular)
                attributes[.font] = NSFontManager.shared.convert(base, toHaveTrait: traits)
                if font.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if font.strikeout { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = switch statistic.nameAlignment {
            case .left: .left
            case .center: .center
            case .right: .right
            }
            attributes[.paragraphStyle] = paragraph
            content.append(.init(string: line, attributes: attributes))
        }
        textView.textStorage?.setAttributedString(content)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private static func valueDescription(_ value: TriggerStatisticValue) -> String {
        switch value {
        case let .integer(number): String(number)
        case let .string(text): text
        case let .range(value, lower, upper, _): "\(value) [\(lower)…\(upper)]"
        }
    }
}
