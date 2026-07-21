import AppKit
import BeipCore

@MainActor
final class OutputTextView {
    let scrollView: NSScrollView
    private let textView: NSTextView
    private let defaultForeground = NSColor(calibratedWhite: 0.9, alpha: 1)
    private let defaultBackground = NSColor(calibratedWhite: 0.05, alpha: 1)

    init() {
        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isRichText = true
        textView.usesFindBar = true
        textView.usesFontPanel = false
        textView.backgroundColor = defaultBackground
        textView.textColor = defaultForeground
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.setAccessibilityLabel("MU star output")

        scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    func clear() { textView.textStorage?.setAttributedString(NSAttributedString()) }

    func removeLastLine() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let value = storage.string as NSString
        var end = value.length
        if end > 0, value.character(at: end - 1) == 10 { end -= 1 }
        let search = NSRange(location: 0, length: end)
        let newline = value.range(of: "\n", options: .backwards, range: search)
        let start = newline.location == NSNotFound ? 0 : newline.location + 1
        storage.deleteCharacters(in: NSRange(location: start, length: storage.length - start))
    }

    var terminalSize: (columns: UInt16, rows: UInt16) {
        let font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let cellWidth = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
        let cellHeight = max(1, textView.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize)
        let contentSize = scrollView.contentSize
        let horizontalInsets = textView.textContainerInset.width * 2
        let verticalInsets = textView.textContainerInset.height * 2
        let columns = max(1, min(Int(UInt16.max), Int((contentSize.width - horizontalInsets) / cellWidth)))
        let rows = max(1, min(Int(UInt16.max), Int((contentSize.height - verticalInsets) / cellHeight)))
        return (UInt16(columns), UInt16(rows))
    }

    func append(_ line: RenderedLine, terminator: String = "\n") {
        let value = NSMutableAttributedString(string: line.text + terminator, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: defaultForeground,
        ])
        for run in line.runs where run.range.lowerBound >= 0 && run.range.upperBound <= line.text.utf16.count {
            let range = NSRange(location: run.range.lowerBound, length: run.range.count)
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let color = run.style.foreground { attributes[.foregroundColor] = NSColor(color) }
            if let color = run.style.background { attributes[.backgroundColor] = NSColor(color) }
            var traits: NSFontTraitMask = []
            if run.style.bold { traits.insert(.boldFontMask) }
            if run.style.italic { traits.insert(.italicFontMask) }
            attributes[.font] = NSFontManager.shared.convert(
                NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), toHaveTrait: traits
            )
            if run.style.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.style.strikeout { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            value.addAttributes(attributes, range: range)
        }
        textView.textStorage?.append(value)
        textView.scrollToEndOfDocument(nil)
        NSAccessibility.post(element: textView, notification: .valueChanged)
    }
}

private extension NSColor {
    convenience init(_ color: BeipCore.RGBColor) {
        self.init(
            calibratedRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: CGFloat(color.alpha) / 255
        )
    }
}
