import AppKit
import BeipAutomation

/// The editable Windows-style alias pane. It intentionally owns only the
/// alias fields; the window controller owns scope/group settings and tree
/// operations so the same view can be reused for nested aliases.
@MainActor
final class AliasDetailView: NSView {
    enum ValidationError: LocalizedError {
        case invalidRegularExpression(String)

        var errorDescription: String? {
            switch self {
            case let .invalidRegularExpression(message): "Invalid regular expression: \(message)"
            }
        }
    }

    private let folder = NSButton(checkboxWithTitle: "Treat as Folder", target: nil, action: nil)
    private let descriptionField = NSTextField()
    private let matchField = NSTextField()
    private let testStringView = NSTextView()
    private let testResultView = NSTextView()
    private let replacementView = NSTextView()
    private let regularExpression = NSButton(checkboxWithTitle: "Regular Expression", target: nil, action: nil)
    private let matchCase = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    private let wholeWord = NSButton(checkboxWithTitle: "Whole Word", target: nil, action: nil)
    private let startsWith = NSButton(checkboxWithTitle: "Line Starts With", target: nil, action: nil)
    private let endsWith = NSButton(checkboxWithTitle: "Line Ends With", target: nil, action: nil)
    private let processAliases = NSButton(checkboxWithTitle: "Process Aliases", target: nil, action: nil)
    private let echoProcessedAlias = NSButton(checkboxWithTitle: "Echo processed alias", target: nil, action: nil)
    private let processCommands = NSButton(checkboxWithTitle: "Process commands in result", target: nil, action: nil)
    private let stopProcessing = NSButton(checkboxWithTitle: "Stop Processing if hit", target: nil, action: nil)
    private let expandVariables = NSButton(checkboxWithTitle: "Expand %variables%", target: nil, action: nil)
    private let regex101 = NSButton(title: "Regex101", target: nil, action: nil)
    private let testError = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { nil }

    func load(_ alias: Alias) {
        folder.state = alias.folder ? .on : .off
        descriptionField.stringValue = alias.description
        matchField.stringValue = alias.match.text
        testStringView.string = alias.example
        replacementView.string = alias.replacement
        regularExpression.state = alias.match.isRegularExpression ? .on : .off
        matchCase.state = alias.match.matchCase ? .on : .off
        wholeWord.state = alias.match.wholeWord ? .on : .off
        startsWith.state = alias.match.startsWith ? .on : .off
        endsWith.state = alias.match.endsWith ? .on : .off
        processAliases.state = alias.active ? .on : .off
        echoProcessedAlias.state = alias.echo ? .on : .off
        processCommands.state = alias.processCommands ? .on : .off
        stopProcessing.state = alias.stopProcessing ? .on : .off
        expandVariables.state = alias.expandVariables ? .on : .off
        updateEnabled()
        updateTester()
    }

    func reset() {
        load(.init(match: .init(text: ""), replacement: ""))
        descriptionField.stringValue = ""
        testStringView.string = ""
        updateTester()
    }

    func validateForApply() throws {
        guard regularExpression.state == .on, !matchField.stringValue.isEmpty else { return }
        do {
            _ = try MatchDefinition(text: matchField.stringValue, isRegularExpression: true).matches(in: testStringView.string)
        } catch {
            throw ValidationError.invalidRegularExpression(error.localizedDescription)
        }
    }

    func updatedAlias(preserving alias: Alias) -> Alias {
        var updated = alias
        updated.folder = folder.state == .on
        updated.description = descriptionField.stringValue
        updated.example = testStringView.string
        updated.match = currentMatch
        updated.replacement = replacementView.string
        updated.active = processAliases.state == .on
        updated.echo = echoProcessedAlias.state == .on
        updated.processCommands = processCommands.state == .on
        updated.stopProcessing = stopProcessing.state == .on
        updated.expandVariables = expandVariables.state == .on
        return updated
    }

    private var currentMatch: MatchDefinition {
        .init(
            text: matchField.stringValue,
            isRegularExpression: regularExpression.state == .on,
            matchCase: matchCase.state == .on,
            startsWith: startsWith.state == .on,
            endsWith: endsWith.state == .on,
            wholeWord: wholeWord.state == .on
        )
    }

    @objc private func controlChanged(_ sender: Any?) {
        updateEnabled()
        updateTester()
    }

    @objc private func textChanged(_ notification: Notification) {
        updateTester()
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        descriptionField.setAccessibilityIdentifier("aliasDescription")
        matchField.setAccessibilityIdentifier("aliasMatch")
        testStringView.setAccessibilityIdentifier("aliasTestString")
        testStringView.setAccessibilityLabel("Alias example and test string")
        testResultView.setAccessibilityIdentifier("aliasTestResult")
        testResultView.setAccessibilityLabel("Alias test result")
        testError.setAccessibilityIdentifier("aliasTestError")
        testError.setAccessibilityLabel("Alias test error")
        replacementView.setAccessibilityIdentifier("aliasReplacement")
        regex101.setAccessibilityIdentifier("aliasRegex101")

        for (button, identifier) in [
            (folder, "aliasFolder"),
            (regularExpression, "aliasRegularExpression"),
            (matchCase, "aliasMatchCase"),
            (wholeWord, "aliasWholeWord"),
            (startsWith, "aliasStartsWith"),
            (endsWith, "aliasEndsWith"),
            (processAliases, "aliasProcessAliases"),
            (echoProcessedAlias, "aliasEcho"),
            (processCommands, "aliasProcessCommands"),
            (stopProcessing, "aliasStopProcessing"),
            (expandVariables, "aliasExpandVariables"),
        ] {
            button.setAccessibilityIdentifier(identifier)
            button.target = self
            button.action = #selector(controlChanged(_:))
        }
        regex101.target = self
        regex101.action = #selector(openRegex101(_:))
        testError.textColor = .systemRed
        testError.maximumNumberOfLines = 2

        let testScroll = scrollView(testStringView, height: 42)
        let resultScroll = scrollView(testResultView, height: 60)
        let replacementScroll = scrollView(replacementView, height: 90)
        let fields = NSStackView(views: [
            row("Description:", descriptionField),
            row("Matcharoo:", matchField),
            row("Example:", testScroll),
            row("Test Result:", resultScroll),
            testError,
            row("Alias for:", replacementScroll),
        ])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 6

        let processing = NSStackView(views: [
            processAliases,
            echoProcessedAlias,
            processCommands,
        ])
        processing.orientation = .vertical
        processing.spacing = 4

        let options = NSStackView(views: [
            NSStackView(views: [regularExpression, matchCase, wholeWord]),
            NSStackView(views: [startsWith, endsWith, stopProcessing]),
            expandVariables,
            processing,
            regex101,
        ])
        options.orientation = .vertical
        options.spacing = 4

        let stack = NSStackView(views: [folder, fields, options])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            descriptionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            matchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
        ])

        for object in [descriptionField, matchField] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textChanged(_:)),
                name: NSControl.textDidChangeNotification,
                object: object
            )
        }
        for object in [testStringView, replacementView] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textChanged(_:)),
                name: NSText.didChangeNotification,
                object: object
            )
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Alias settings")
    }

    private func row(_ label: String, _ view: NSView) -> NSStackView {
        let text = NSTextField(labelWithString: label)
        text.alignment = .right
        text.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let row = NSStackView(views: [text, view])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        return row
    }

    private func scrollView(_ textView: NSTextView, height: CGFloat) -> NSScrollView {
        textView.isEditable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.widthAnchor.constraint(equalToConstant: 440).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func updateEnabled() {
        let enabled = folder.state != .on
        testStringView.isEditable = enabled
        testResultView.isEditable = false
        replacementView.isEditable = enabled
        for button in [regularExpression, matchCase, wholeWord, startsWith, endsWith,
                       stopProcessing, expandVariables, regex101, echoProcessedAlias,
                       processCommands] {
            button.isEnabled = enabled
        }
        // A folder can be disabled as a container, but echoing or processing
        // slash commands only applies to an alias that actually matched.
        processAliases.isEnabled = true
        matchCase.isEnabled = enabled
        let literal = enabled && regularExpression.state != .on
        wholeWord.isEnabled = literal
        startsWith.isEnabled = literal
        endsWith.isEnabled = literal
        testError.isHidden = !enabled
    }

    private func updateTester() {
        guard folder.state != .on else {
            testResultView.string = ""
            testError.stringValue = ""
            applyMatchHighlights([])
            return
        }
        do {
            let captures = try currentMatch.matches(in: testStringView.string)
            testError.stringValue = ""
            if captures.isEmpty {
                testResultView.string = "No match"
                applyMatchHighlights([])
                return
            }
            let preview = try AliasEngine.process(
                testStringView.string,
                groups: [.init(aliases: [.init(match: currentMatch, replacement: replacementView.string)])],
                variables: [:]
            )
            let result = "\(captures.count) match\(captures.count == 1 ? "" : "es")\n\(preview.text)"
            testResultView.string = result
            applyMatchHighlights(captures)
        } catch {
            testResultView.string = ""
            testError.stringValue = "Invalid regular expression: \(error.localizedDescription)"
            applyMatchHighlights([])
        }
    }

    private func applyMatchHighlights(_ matches: [MatchCapture]) {
        guard let storage = testStringView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        let selection = testStringView.selectedRanges
        storage.beginEditing()
        storage.setAttributes([
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ], range: fullRange)
        for match in matches {
            for (index, range) in match.ranges.enumerated()
                where range.location != NSNotFound && range.length > 0
                    && range.location + range.length <= storage.length {
                let colors: [NSColor] = [
                    .systemBlue.withAlphaComponent(0.24),
                    .systemGreen.withAlphaComponent(0.34),
                    .systemYellow.withAlphaComponent(0.42),
                    .systemPurple.withAlphaComponent(0.28),
                ]
                storage.addAttribute(.backgroundColor, value: colors[index % colors.count], range: range)
            }
        }
        storage.endEditing()
        testStringView.selectedRanges = selection
    }

    @objc private func openRegex101(_ sender: Any?) {
        var components = URLComponents(string: "https://regex101.com/")
        components?.queryItems = [
            .init(name: "regex", value: matchField.stringValue),
            .init(name: "testString", value: testStringView.string),
            .init(name: "flags", value: matchCase.state == .on ? "" : "i"),
        ]
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
