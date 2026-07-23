import AppKit
import BeipCore

@MainActor
final class CommandInputView: NSTextView {
    let containerScrollView: NSScrollView
    var onSubmit: ((String) -> Void)?
    var onSmartPaste: (([String]) -> Bool)?
    var onMacro: ((NSEvent) -> Bool)?
    var behavior = InputBehavior()
    var completionCandidates: [String] = []
    private var commandHistory = InputHistory()

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        containerScrollView = NSScrollView()
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 50), textContainer: container)

        containerScrollView.documentView = self
        containerScrollView.hasVerticalScroller = true
        containerScrollView.autohidesScrollers = true
        containerScrollView.borderType = .bezelBorder
        containerScrollView.translatesAutoresizingMaskIntoConstraints = false
        isRichText = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = true
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textContainerInset = NSSize(width: 5, height: 6)
        setAccessibilityLabel("Command input")
    }

    required init?(coder: NSCoder) { nil }

    var text: String {
        get { string }
        set { string = newValue; setSelectedRange(NSRange(location: newValue.utf16.count, length: 0)) }
    }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        textColor = palette.foreground
        backgroundColor = palette.background
        insertionPointColor = palette.accent
        selectedTextAttributes = [
            .backgroundColor: palette.accent.withAlphaComponent(0.55),
            .foregroundColor: palette.foreground,
        ]
    }

    override func keyDown(with event: NSEvent) {
        if onMacro?(event) == true { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36 where !modifiers.contains(.shift) && !modifiers.contains(.option),
             76 where !modifiers.contains(.shift) && !modifiers.contains(.option):
            submit()
        case 126 where shouldNavigateBackward:
            if let previous = commandHistory.previous(currentText: string) { text = previous }
        case 125 where shouldNavigateForward:
            if let next = commandHistory.next() { text = next }
        case 48 where modifiers.isDisjoint(with: [.control, .command, .option]):
            completeCurrentWord()
        default:
            commandHistory.resetNavigation()
            super.keyDown(with: event)
        }
    }

    func apply(_ conversion: InputConversion) {
        text = conversion.apply(to: string)
    }

    func addToHistory(_ value: String) {
        commandHistory.record(value)
    }

    override func paste(_ sender: Any?) {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        let normalized = pasted.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > 1, onSmartPaste?(lines) == true { return }
        insertText(normalized, replacementRange: selectedRange())
    }

    private var shouldNavigateBackward: Bool {
        let selection = selectedRange()
        return !string.contains("\n") && selection.length == 0 && selection.location == 0
    }

    private var shouldNavigateForward: Bool {
        let selection = selectedRange()
        return !string.contains("\n") && selection.length == 0 && selection.location == string.utf16.count
    }

    private func submit() {
        guard !string.isEmpty else { return }
        let original = string
        let submission = behavior.submission(for: original)
        commandHistory.record(original)
        text = submission.replacement
        onSubmit?(submission.outbound)
    }

    private func completeCurrentWord() {
        let value = string as NSString
        let cursor = selectedRange().location
        var start = cursor
        while start > 0, !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(value.character(at: start - 1))!) {
            start -= 1
        }
        let prefix = value.substring(with: NSRange(location: start, length: cursor - start))
        guard !prefix.isEmpty else { super.insertTab(nil); return }
        let matches = completionCandidates.filter {
            $0.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil
        }
        guard let completion = matches.count == 1 ? matches[0] : matches.sorted().first else {
            NSSound.beep()
            return
        }
        insertText(completion, replacementRange: NSRange(location: start, length: cursor - start))
    }
}
