import AppKit
import BeipAutomation
import BeipCore

@MainActor
final class TriggerDetailView: NSView {
    private enum MatchValidationError: LocalizedError {
        case invalidRegularExpression(String)

        var errorDescription: String? {
            switch self {
            case let .invalidRegularExpression(message):
                "Invalid regular expression: \(message)"
            }
        }
    }

    private let enabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let folder = NSButton(checkboxWithTitle: "Folder", target: nil, action: nil)
    private let processChildren = NSButton(checkboxWithTitle: "Process child triggers", target: nil, action: nil)
    private let descriptionField = NSTextField()
    private let matchField = NSTextField()
    private let testStringField = NSTextField()
    private let regex = NSButton(checkboxWithTitle: "Regular Expression", target: nil, action: nil)
    private let matchCase = NSButton(checkboxWithTitle: "Match Case", target: nil, action: nil)
    private let wholeWord = NSButton(checkboxWithTitle: "Whole Word", target: nil, action: nil)
    private let startsWith = NSButton(checkboxWithTitle: "Line Starts With", target: nil, action: nil)
    private let endsWith = NSButton(checkboxWithTitle: "Line Ends With", target: nil, action: nil)
    private let testResult = NSTextField(labelWithString: "")
    private let testError = NSTextField(labelWithString: "")
    private let stopProcessing = NSButton(checkboxWithTitle: "Stop Processing if hit", target: nil, action: nil)
    private let oncePerLine = NSButton(checkboxWithTitle: "Once per line", target: nil, action: nil)
    private let cooldownEnabled = NSButton(checkboxWithTitle: "Limit to once every", target: nil, action: nil)
    private let cooldownSeconds = NSTextField()
    private let multilineEnabled = NSButton(checkboxWithTitle: "Run child triggers for next", target: nil, action: nil)
    private let multilineLines = NSTextField()
    private let multilineSeconds = NSTextField()
    private let onlyWhen = NSButton(checkboxWithTitle: "Only when:", target: nil, action: nil)
    private let away = NSButton(radioButtonWithTitle: "Away", target: nil, action: nil)
    private let present = NSButton(radioButtonWithTitle: "Present", target: nil, action: nil)
    private let awayPresentOnce = NSButton(checkboxWithTitle: "Once", target: nil, action: nil)

    private let fontEnabled = NSButton(checkboxWithTitle: "Font", target: nil, action: nil)
    private let fontFace = NSTextField()
    private let fontSize = NSTextField()
    private let fontDefault = NSButton(checkboxWithTitle: "Default", target: nil, action: nil)
    private let wholeLineAppearance = NSButton(checkboxWithTitle: "Whole line", target: nil, action: nil)
    private let foregroundEnabled = NSButton(checkboxWithTitle: "Foreground Color", target: nil, action: nil)
    private let foregroundColor = NSColorWell()
    private let foregroundDefault = NSButton(checkboxWithTitle: "Default", target: nil, action: nil)
    private let foregroundHash = NSButton(checkboxWithTitle: "Hash", target: nil, action: nil)
    private let backgroundEnabled = NSButton(checkboxWithTitle: "Background Color", target: nil, action: nil)
    private let backgroundColor = NSColorWell()
    private let backgroundDefault = NSButton(checkboxWithTitle: "Default", target: nil, action: nil)
    private let backgroundHash = NSButton(checkboxWithTitle: "Hash", target: nil, action: nil)
    private let bold = NSButton(checkboxWithTitle: "Bold", target: nil, action: nil)
    private let italic = NSButton(checkboxWithTitle: "Italic", target: nil, action: nil)
    private let underline = NSButton(checkboxWithTitle: "Underline", target: nil, action: nil)
    private let strikeout = NSButton(checkboxWithTitle: "Strikeout", target: nil, action: nil)
    private let flashing = NSButton(checkboxWithTitle: "Flashing", target: nil, action: nil)
    private let fastFlash = NSButton(checkboxWithTitle: "Use Fast Flash", target: nil, action: nil)

    private let paragraphBackground = NSButton(checkboxWithTitle: "Background", target: nil, action: nil)
    private let paragraphBackgroundColor = NSColorWell()
    private let paragraphBackgroundHash = NSButton(checkboxWithTitle: "Hash", target: nil, action: nil)
    private let strokeEnabled = NSButton(checkboxWithTitle: "Stroke (px)", target: nil, action: nil)
    private let strokeWidth = NSTextField()
    private let strokeColor = NSColorWell()
    private let strokeHash = NSButton(checkboxWithTitle: "Hash", target: nil, action: nil)
    private let strokeStyle = NSPopUpButton()
    private let borderEnabled = NSButton(checkboxWithTitle: "Border (px)", target: nil, action: nil)
    private let borderWidth = NSTextField()
    private let borderStyle = NSSegmentedControl(labels: ["Square", "Round"], trackingMode: .selectOne, target: nil, action: nil)
    private let alignmentEnabled = NSButton(checkboxWithTitle: "Alignment", target: nil, action: nil)
    private let alignment = NSSegmentedControl(labels: ["Left", "Center", "Right"], trackingMode: .selectOne, target: nil, action: nil)
    private let leftIndentEnabled = NSButton(checkboxWithTitle: "Indent Left %", target: nil, action: nil)
    private let leftIndent = NSTextField()
    private let rightIndentEnabled = NSButton(checkboxWithTitle: "Indent Right %", target: nil, action: nil)
    private let rightIndent = NSTextField()
    private let topPaddingEnabled = NSButton(checkboxWithTitle: "Padding Top (px)", target: nil, action: nil)
    private let topPadding = NSTextField()
    private let bottomPaddingEnabled = NSButton(checkboxWithTitle: "Padding Bottom (px)", target: nil, action: nil)
    private let bottomPadding = NSTextField()

    private let playSound = NSButton(checkboxWithTitle: "Play Sound", target: nil, action: nil)
    private let soundFile = NSTextField()
    private let speak = NSButton(checkboxWithTitle: "Speak", target: nil, action: nil)
    private let speakWholeLine = NSButton(checkboxWithTitle: "Say whole line", target: nil, action: nil)
    private let speechText: NSTextView

    private let spawnActive = NSButton(checkboxWithTitle: "Active", target: nil, action: nil)
    private let spawnTitle = NSTextField()
    private let spawnTabGroup = NSTextField()
    private let spawnCaptureUntil = NSTextField()
    private let spawnOnlyChildren = NSButton(checkboxWithTitle: "During capture, process only children of this trigger", target: nil, action: nil)
    private let spawnClear = NSButton(checkboxWithTitle: "Clear spawn before displaying", target: nil, action: nil)
    private let spawnShowTab = NSButton(checkboxWithTitle: "If in tab group, switch to this tab", target: nil, action: nil)
    private let spawnGagLog = NSButton(checkboxWithTitle: "Gag from log", target: nil, action: nil)
    private let spawnCopy = NSButton(checkboxWithTitle: "Copy line instead of move", target: nil, action: nil)

    private let statPrefix = NSTextField()
    private let statTitle = NSTextField()
    private let statName = NSTextField()
    private let statValue = NSTextField()
    private let statAlignment = NSSegmentedControl(labels: ["Left", "Center", "Right"], trackingMode: .selectOne, target: nil, action: nil)
    private let statColorEnabled = NSButton(checkboxWithTitle: "Custom Color", target: nil, action: nil)
    private let statColor = NSColorWell()
    private let statFontEnabled = NSButton(checkboxWithTitle: "Custom Font", target: nil, action: nil)
    private let statFontName = NSTextField()
    private let statFontSize = NSTextField()
    private let statKind = NSSegmentedControl(labels: ["Integer", "String", "Range"], trackingMode: .selectOne, target: nil, action: nil)
    private let statAddValue = NSButton(checkboxWithTitle: "Add Value", target: nil, action: nil)
    private let statRangeMin = NSTextField()
    private let statRangeMax = NSTextField()
    private let statRangeColor = NSColorWell()

    private let sendText = NSButton(checkboxWithTitle: "Send Text", target: nil, action: nil)
    private let sendOnClick = NSButton(checkboxWithTitle: "Send on click of matched text", target: nil, action: nil)
    private let sendCaptureIndex = NSTextField()
    private let sendExpandVariables = NSButton(checkboxWithTitle: "Expand %variables%", target: nil, action: nil)
    private let sendTextView: NSTextView

    private let filterText = NSButton(checkboxWithTitle: "Filter Text", target: nil, action: nil)
    private let filterHTML = NSButton(checkboxWithTitle: "Parse HTML Tags on replacement", target: nil, action: nil)
    private let filterExpandVariables = NSButton(checkboxWithTitle: "Expand %variables%", target: nil, action: nil)
    private let filterTextView: NSTextView
    private let avatarURL = NSTextField()
    private let gagDisplay = NSButton(checkboxWithTitle: "Gag this line (don't display it)", target: nil, action: nil)
    private let gagLog = NSButton(checkboxWithTitle: "Gag this line in the log file (don't log it)", target: nil, action: nil)

    private let activityImportant = NSButton(checkboxWithTitle: "Show as important activity on window tab", target: nil, action: nil)
    private let activateWindow = NSButton(checkboxWithTitle: "Activate window on trigger", target: nil, action: nil)
    private let activityNormal = NSButton(checkboxWithTitle: "Show as activity", target: nil, action: nil)
    private let suppressActivity = NSButton(checkboxWithTitle: "Don't show as activity", target: nil, action: nil)
    private let systemNotification = NSButton(checkboxWithTitle: "System Notification Message when trigger hits", target: nil, action: nil)

    private let scriptEnabled = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let scriptFunction = NSTextField()

    override init(frame frameRect: NSRect) {
        let speechScroll = Self.textView()
        speechText = speechScroll.documentView as! NSTextView
        let sendScroll = Self.textView()
        sendTextView = sendScroll.documentView as! NSTextView
        let filterScroll = Self.textView()
        filterTextView = filterScroll.documentView as! NSTextView
        super.init(frame: frameRect)
        build(speechScroll: speechScroll, sendScroll: sendScroll, filterScroll: filterScroll)
        configureMatchTester()
        reset()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func load(_ trigger: Trigger) {
        reset()
        enabled.state = trigger.disabled ? .off : .on
        folder.state = trigger.folder ? .on : .off
        processChildren.state = trigger.childrenActive ? .on : .off
        descriptionField.stringValue = trigger.description
        matchField.stringValue = trigger.match.text
        regex.state = trigger.match.isRegularExpression ? .on : .off
        matchCase.state = trigger.match.matchCase ? .on : .off
        wholeWord.state = trigger.match.wholeWord ? .on : .off
        startsWith.state = trigger.match.startsWith ? .on : .off
        endsWith.state = trigger.match.endsWith ? .on : .off
        updateMatchTester()
        stopProcessing.state = trigger.stopProcessing ? .on : .off
        oncePerLine.state = trigger.oncePerLine ? .on : .off
        cooldownEnabled.state = trigger.cooldown == nil ? .off : .on
        cooldownSeconds.stringValue = trigger.cooldown.map(Self.number) ?? "0"
        multilineEnabled.state = trigger.multiline?.isEnabled == true ? .on : .off
        multilineLines.stringValue = String(trigger.multiline?.lineLimit ?? 0)
        multilineSeconds.stringValue = trigger.multiline.map { Self.number($0.timeLimit) } ?? "0"
        onlyWhen.state = trigger.awayPresent ? .on : .off
        away.state = trigger.away ? .on : .off
        present.state = trigger.away ? .off : .on
        awayPresentOnce.state = trigger.awayPresentOnce ? .on : .off

        for action in trigger.actions {
            switch action {
            case let .color(foreground, background, wholeLine):
                if let foreground {
                    foregroundEnabled.state = .on
                    foregroundColor.color = NSColor(rgb: foreground)
                }
                if let background {
                    backgroundEnabled.state = .on
                    backgroundColor.color = NSColor(rgb: background)
                }
                wholeLineAppearance.state = wholeLine ? .on : wholeLineAppearance.state
            case let .colorDefault(foreground, background, wholeLine):
                foregroundDefault.state = foreground ? .on : .off
                backgroundDefault.state = background ? .on : .off
                wholeLineAppearance.state = wholeLine ? .on : wholeLineAppearance.state
            case let .colorHash(foreground, background, wholeLine):
                foregroundHash.state = foreground ? .on : .off
                backgroundHash.state = background ? .on : .off
                wholeLineAppearance.state = wholeLine ? .on : wholeLineAppearance.state
            case let .font(face, size, useDefault, wholeLine):
                fontEnabled.state = .on
                fontFace.stringValue = face
                fontSize.stringValue = Self.number(size)
                fontDefault.state = useDefault ? .on : .off
                wholeLineAppearance.state = wholeLine ? .on : wholeLineAppearance.state
            case let .appearance(patch, wholeLine):
                bold.state = patch.bold == true ? .on : .off
                italic.state = patch.italic == true ? .on : .off
                underline.state = patch.underline == true ? .on : .off
                strikeout.state = patch.strikeout == true ? .on : .off
                flashing.state = patch.blink == nil ? .off : .on
                fastFlash.state = patch.blink == .fast ? .on : .off
                wholeLineAppearance.state = wholeLine ? .on : wholeLineAppearance.state
            case let .paragraph(patch):
                loadParagraph(patch)
            case let .gag(display, log):
                gagDisplay.state = display ? .on : .off
                gagLog.state = log ? .on : .off
            case let .send(text, captureIndex, expandVariables, clickToSend):
                sendText.state = .on
                sendTextView.string = text
                sendCaptureIndex.stringValue = String(captureIndex)
                sendExpandVariables.state = expandVariables ? .on : .off
                sendOnClick.state = clickToSend ? .on : .off
            case let .spawn(action):
                spawnActive.state = .on
                spawnTitle.stringValue = action.title
                spawnTabGroup.stringValue = action.tabGroup
                spawnCaptureUntil.stringValue = action.captureUntil
                spawnOnlyChildren.state = action.onlyChildrenDuringCapture ? .on : .off
                spawnClear.state = action.clear ? .on : .off
                spawnShowTab.state = action.showTab ? .on : .off
                spawnGagLog.state = action.gagLog ? .on : .off
                spawnCopy.state = action.copy ? .on : .off
            case let .stat(action):
                loadStat(action)
            case let .sound(path):
                playSound.state = .on
                soundFile.stringValue = path
            case let .speech(text, wholeLine):
                speak.state = .on
                speechText.string = text
                speakWholeLine.state = wholeLine ? .on : .off
            case .activity(important: true):
                activityImportant.state = .on
            case .activity(important: false):
                activityNormal.state = .on
            case .activateWindow:
                activateWindow.state = .on
            case .suppressActivity:
                suppressActivity.state = .on
            case .notification:
                systemNotification.state = .on
            case let .replace(text, expandVariables):
                filterText.state = .on
                filterTextView.string = text
                filterExpandVariables.state = expandVariables ? .on : .off
            case let .replaceHTML(text, expandVariables):
                filterText.state = .on
                filterHTML.state = .on
                filterTextView.string = text
                filterExpandVariables.state = expandVariables ? .on : .off
            case let .avatar(url):
                avatarURL.stringValue = url
            case let .script(function):
                scriptEnabled.state = .on
                scriptFunction.stringValue = function
            }
        }
        refreshAccessibilityStateDescriptions()
    }

    func reset() {
        for button in recursiveSubviews().compactMap({ $0 as? NSButton }) {
            button.state = .off
        }
        enabled.state = .on
        processChildren.state = .on
        away.state = .on
        alignment.selectedSegment = 0
        borderStyle.selectedSegment = 1
        statAlignment.selectedSegment = 1
        statKind.selectedSegment = 0
        strokeStyle.selectItem(at: 0)
        foregroundColor.color = .textColor
        backgroundColor.color = .textBackgroundColor
        paragraphBackgroundColor.color = .textBackgroundColor
        strokeColor.color = .textColor
        statColor.color = .textColor
        statRangeColor.color = .systemGreen
        for field in recursiveSubviews().compactMap({ $0 as? NSTextField }) {
            guard !field.isEditable else { field.stringValue = ""; continue }
        }
        fontSize.stringValue = "13"
        strokeWidth.stringValue = "2"
        borderWidth.stringValue = "1"
        leftIndent.stringValue = "0"
        rightIndent.stringValue = "0"
        topPadding.stringValue = "0"
        bottomPadding.stringValue = "0"
        cooldownSeconds.stringValue = "0"
        multilineLines.stringValue = "0"
        multilineSeconds.stringValue = "0"
        sendCaptureIndex.stringValue = "1"
        statFontSize.stringValue = "13"
        speechText.string = ""
        sendTextView.string = ""
        filterTextView.string = ""
        updateMatchTester()
        refreshAccessibilityStateDescriptions()
    }

    func validateForApply() throws {
        if let error = currentMatchErrorDescription() {
            throw MatchValidationError.invalidRegularExpression(error)
        }
    }

    func testingConfigureMatch(
        text: String,
        testString: String,
        isRegularExpression: Bool = false,
        matchCase: Bool = false,
        startsWith: Bool = false,
        endsWith: Bool = false,
        wholeWord: Bool = false
    ) {
        matchField.stringValue = text
        testStringField.stringValue = testString
        regex.state = isRegularExpression ? .on : .off
        self.matchCase.state = matchCase ? .on : .off
        self.startsWith.state = startsWith ? .on : .off
        self.endsWith.state = endsWith ? .on : .off
        self.wholeWord.state = wholeWord ? .on : .off
        updateMatchTester()
    }

    var testingMatchResult: String { testResult.stringValue }
    var testingMatchError: String { testError.stringValue }

    func updatedTrigger(preserving trigger: Trigger) -> Trigger {
        var actions: [TriggerAction] = []
        let wholeLine = wholeLineAppearance.state == .on
        let foreground = foregroundEnabled.state == .on ? foregroundColor.color.rgbColor : nil
        let background = backgroundEnabled.state == .on ? backgroundColor.color.rgbColor : nil
        if foreground != nil || background != nil {
            actions.append(.color(foreground: foreground, background: background, wholeLine: wholeLine))
        }
        if foregroundDefault.state == .on || backgroundDefault.state == .on {
            actions.append(.colorDefault(foreground: foregroundDefault.state == .on, background: backgroundDefault.state == .on, wholeLine: wholeLine))
        }
        if foregroundHash.state == .on || backgroundHash.state == .on {
            actions.append(.colorHash(foreground: foregroundHash.state == .on, background: backgroundHash.state == .on, wholeLine: wholeLine))
        }
        if fontEnabled.state == .on {
            actions.append(.font(face: fontFace.stringValue, size: double(fontSize, fallback: 13), useDefault: fontDefault.state == .on, wholeLine: wholeLine))
        }
        var patch = TextStylePatch()
        patch.bold = bold.state == .on ? true : nil
        patch.italic = italic.state == .on ? true : nil
        patch.underline = underline.state == .on ? true : nil
        patch.strikeout = strikeout.state == .on ? true : nil
        patch.blink = flashing.state == .on ? (fastFlash.state == .on ? .fast : .slow) : nil
        if patch.bold != nil || patch.italic != nil || patch.underline != nil || patch.strikeout != nil || patch.blink != nil {
            actions.append(.appearance(patch, wholeLine: wholeLine))
        }

        let paragraph = paragraphPatch()
        if !paragraph.isEmpty { actions.append(.paragraph(paragraph)) }
        if gagDisplay.state == .on || gagLog.state == .on {
            actions.append(.gag(display: gagDisplay.state == .on, log: gagLog.state == .on))
        }
        if activateWindow.state == .on { actions.append(.activateWindow) }
        if activityImportant.state == .on { actions.append(.activity(important: true)) }
        if activityNormal.state == .on { actions.append(.activity(important: false)) }
        if suppressActivity.state == .on { actions.append(.suppressActivity) }
        if spawnActive.state == .on {
            actions.append(.spawn(.init(
                title: spawnTitle.stringValue,
                tabGroup: spawnTabGroup.stringValue,
                captureUntil: spawnCaptureUntil.stringValue,
                onlyChildrenDuringCapture: spawnOnlyChildren.state == .on,
                clear: spawnClear.state == .on,
                showTab: spawnShowTab.state == .on,
                gagLog: spawnGagLog.state == .on,
                copy: spawnCopy.state == .on
            )))
        }
        if !statName.stringValue.isEmpty {
            actions.append(.stat(statAction()))
        }
        if playSound.state == .on && !soundFile.stringValue.isEmpty {
            actions.append(.sound(soundFile.stringValue))
        }
        if speak.state == .on {
            actions.append(.speech(speechText.string, wholeLine: speakWholeLine.state == .on))
        }
        if sendText.state == .on && !sendTextView.string.isEmpty {
            actions.append(.send(
                sendTextView.string,
                captureIndex: max(0, sendCaptureIndex.integerValue),
                expandVariables: sendExpandVariables.state == .on,
                sendOnClick: sendOnClick.state == .on
            ))
        }
        if systemNotification.state == .on { actions.append(.notification) }
        if filterText.state == .on {
            if filterHTML.state == .on {
                actions.append(.replaceHTML(filterTextView.string, expandVariables: filterExpandVariables.state == .on))
            } else {
                actions.append(.replace(filterTextView.string, expandVariables: filterExpandVariables.state == .on))
            }
        }
        if !avatarURL.stringValue.isEmpty { actions.append(.avatar(avatarURL.stringValue)) }
        if scriptEnabled.state == .on && !scriptFunction.stringValue.isEmpty {
            actions.append(.script(scriptFunction.stringValue))
        }

        let match = MatchDefinition(
            text: matchField.stringValue,
            isRegularExpression: regex.state == .on,
            matchCase: matchCase.state == .on,
            startsWith: startsWith.state == .on,
            endsWith: endsWith.state == .on,
            wholeWord: wholeWord.state == .on
        )
        return Trigger(
            id: trigger.id,
            description: descriptionField.stringValue,
            match: match,
            folder: folder.state == .on,
            disabled: enabled.state != .on,
            stopProcessing: stopProcessing.state == .on,
            oncePerLine: oncePerLine.state == .on,
            awayPresent: onlyWhen.state == .on,
            awayPresentOnce: awayPresentOnce.state == .on,
            away: present.state != .on,
            cooldown: cooldownEnabled.state == .on ? max(0, cooldownSeconds.doubleValue) : nil,
            multiline: multilineEnabled.state == .on
                ? MultilineTriggerOptions(lineLimit: max(0, multilineLines.integerValue), timeLimit: max(0, multilineSeconds.doubleValue))
                : nil,
            actions: actions,
            children: trigger.children,
            childrenActive: processChildren.state == .on
        )
    }

    private func build(speechScroll: NSScrollView, sendScroll: NSScrollView, filterScroll: NSScrollView) {
        translatesAutoresizingMaskIntoConstraints = false
        descriptionField.setAccessibilityIdentifier("triggerDescription")
        matchField.setAccessibilityIdentifier("triggerMatch")
        testStringField.setAccessibilityIdentifier("triggerTestString")
        testResult.setAccessibilityIdentifier("triggerTestResult")
        testResult.setAccessibilityLabel("Trigger test result")
        testResult.maximumNumberOfLines = 3
        testResult.lineBreakMode = .byTruncatingTail
        testError.setAccessibilityIdentifier("triggerTestError")
        testError.setAccessibilityLabel("Trigger test error")
        testError.textColor = .systemRed
        testError.maximumNumberOfLines = 2
        let top = NSStackView(views: [
            row([enabled, folder, processChildren]),
            formRow("Description:", descriptionField),
            formRow("Matcharoo:", matchField),
            formRow("Test String:", testStringField),
            row([regex, matchCase, wholeWord, startsWith, endsWith]),
            testResult,
            testError,
            row([stopProcessing, oncePerLine]),
            row([cooldownEnabled, fixed(cooldownSeconds, width: 72), label("seconds")]),
            row([multilineEnabled, fixed(multilineLines, width: 72), label("lines or after"), fixed(multilineSeconds, width: 72), label("seconds")]),
            row([onlyWhen, away, present, awayPresentOnce]),
        ])
        top.orientation = .vertical
        top.alignment = .leading
        top.spacing = 6

        let tabs = NSTabView()
        tabs.setAccessibilityIdentifier("triggerActionTabs")
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab("Appearance", appearancePane()))
        tabs.addTabViewItem(tab("Paragraph", paragraphPane()))
        tabs.addTabViewItem(tab("Sound", soundPane(speechScroll: speechScroll)))
        tabs.addTabViewItem(tab("Spawn", spawnPane()))
        tabs.addTabViewItem(tab("Stat", statPane()))
        tabs.addTabViewItem(tab("Send", sendPane(sendScroll: sendScroll)))
        tabs.addTabViewItem(tab("Misc", miscPane(filterScroll: filterScroll)))
        tabs.addTabViewItem(tab("Activity", activityPane()))
        tabs.addTabViewItem(tab("Script", scriptPane()))

        let stack = NSStackView(views: [top, tabs])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 330),
            tabs.widthAnchor.constraint(greaterThanOrEqualToConstant: 560),
        ])
        configureAccessibility()
    }

    private func configureAccessibility() {
        let controls: [(NSView, String)] = [
            (enabled, "triggerEnabled"),
            (folder, "triggerFolder"),
            (processChildren, "triggerProcessChildren"),
            (regex, "triggerRegularExpression"),
            (matchCase, "triggerMatchCase"),
            (wholeWord, "triggerWholeWord"),
            (startsWith, "triggerStartsWith"),
            (endsWith, "triggerEndsWith"),
            (stopProcessing, "triggerStopProcessing"),
            (oncePerLine, "triggerOncePerLine"),
            (cooldownEnabled, "triggerCooldownEnabled"),
            (cooldownSeconds, "triggerCooldownSeconds"),
            (multilineEnabled, "triggerMultilineEnabled"),
            (multilineLines, "triggerMultilineLines"),
            (multilineSeconds, "triggerMultilineSeconds"),
            (onlyWhen, "triggerAwayPresentEnabled"),
            (away, "triggerAway"),
            (present, "triggerPresent"),
            (awayPresentOnce, "triggerAwayPresentOnce"),
            (fontEnabled, "triggerFontEnabled"),
            (fontFace, "triggerFontFace"),
            (fontSize, "triggerFontSize"),
            (fontDefault, "triggerFontDefault"),
            (wholeLineAppearance, "triggerWholeLineAppearance"),
            (foregroundEnabled, "triggerForegroundEnabled"),
            (foregroundColor, "triggerForegroundColor"),
            (foregroundDefault, "triggerForegroundDefault"),
            (foregroundHash, "triggerForegroundHash"),
            (backgroundEnabled, "triggerBackgroundEnabled"),
            (backgroundColor, "triggerBackgroundColor"),
            (backgroundDefault, "triggerBackgroundDefault"),
            (backgroundHash, "triggerBackgroundHash"),
            (bold, "triggerBold"),
            (italic, "triggerItalic"),
            (underline, "triggerUnderline"),
            (strikeout, "triggerStrikeout"),
            (flashing, "triggerFlashing"),
            (fastFlash, "triggerFastFlash"),
            (paragraphBackground, "triggerParagraphBackground"),
            (paragraphBackgroundColor, "triggerParagraphBackgroundColor"),
            (paragraphBackgroundHash, "triggerParagraphBackgroundHash"),
            (strokeEnabled, "triggerStrokeEnabled"),
            (strokeWidth, "triggerStrokeWidth"),
            (strokeColor, "triggerStrokeColor"),
            (strokeHash, "triggerStrokeHash"),
            (strokeStyle, "triggerStrokeStyle"),
            (borderEnabled, "triggerBorderEnabled"),
            (borderWidth, "triggerBorderWidth"),
            (borderStyle, "triggerBorderStyle"),
            (alignmentEnabled, "triggerAlignmentEnabled"),
            (alignment, "triggerAlignment"),
            (leftIndentEnabled, "triggerLeftIndentEnabled"),
            (leftIndent, "triggerLeftIndent"),
            (rightIndentEnabled, "triggerRightIndentEnabled"),
            (rightIndent, "triggerRightIndent"),
            (topPaddingEnabled, "triggerTopPaddingEnabled"),
            (topPadding, "triggerTopPadding"),
            (bottomPaddingEnabled, "triggerBottomPaddingEnabled"),
            (bottomPadding, "triggerBottomPadding"),
            (playSound, "triggerPlaySound"),
            (soundFile, "triggerSoundFile"),
            (speak, "triggerSpeak"),
            (speakWholeLine, "triggerSpeakWholeLine"),
            (spawnActive, "triggerSpawnActive"),
            (spawnTitle, "triggerSpawnTitle"),
            (spawnTabGroup, "triggerSpawnTabGroup"),
            (spawnCaptureUntil, "triggerSpawnCaptureUntil"),
            (spawnOnlyChildren, "triggerSpawnOnlyChildren"),
            (spawnClear, "triggerSpawnClear"),
            (spawnShowTab, "triggerSpawnShowTab"),
            (spawnGagLog, "triggerSpawnGagLog"),
            (spawnCopy, "triggerSpawnCopy"),
            (statPrefix, "triggerStatPrefix"),
            (statTitle, "triggerStatTitle"),
            (statName, "triggerStatName"),
            (statValue, "triggerStatValue"),
            (statAlignment, "triggerStatAlignment"),
            (statColorEnabled, "triggerStatColorEnabled"),
            (statColor, "triggerStatColor"),
            (statFontEnabled, "triggerStatFontEnabled"),
            (statFontName, "triggerStatFontName"),
            (statFontSize, "triggerStatFontSize"),
            (statKind, "triggerStatKind"),
            (statAddValue, "triggerStatAddValue"),
            (statRangeMin, "triggerStatRangeMin"),
            (statRangeMax, "triggerStatRangeMax"),
            (statRangeColor, "triggerStatRangeColor"),
            (sendText, "triggerSendText"),
            (sendOnClick, "triggerSendOnClick"),
            (sendCaptureIndex, "triggerSendCaptureIndex"),
            (sendExpandVariables, "triggerSendExpandVariables"),
            (filterText, "triggerFilterText"),
            (filterHTML, "triggerFilterHTML"),
            (filterExpandVariables, "triggerFilterExpandVariables"),
            (avatarURL, "triggerAvatarURL"),
            (gagDisplay, "triggerGagDisplay"),
            (gagLog, "triggerGagLog"),
            (activityImportant, "triggerActivityImportant"),
            (activateWindow, "triggerActivateWindow"),
            (activityNormal, "triggerActivityNormal"),
            (suppressActivity, "triggerSuppressActivity"),
            (systemNotification, "triggerSystemNotification"),
            (scriptEnabled, "triggerScriptEnabled"),
            (scriptFunction, "triggerScriptFunction"),
        ]
        for (view, identifier) in controls {
            view.setAccessibilityIdentifier(identifier)
        }
        speechText.setAccessibilityIdentifier("triggerSpeechText")
        speechText.setAccessibilityLabel("Trigger speech text")
        sendTextView.setAccessibilityIdentifier("triggerSendTextBody")
        sendTextView.setAccessibilityLabel("Trigger send text")
        filterTextView.setAccessibilityIdentifier("triggerFilterTextBody")
        filterTextView.setAccessibilityLabel("Trigger filter text")
        refreshAccessibilityStateDescriptions()
    }

    private func refreshAccessibilityStateDescriptions() {
        for button in recursiveSubviews().compactMap({ $0 as? NSButton }) {
            button.setAccessibilityValue(button.state == .on ? "On" : "Off")
        }
        if statKind.selectedSegment >= 0 {
            statKind.setAccessibilityValue(statKind.label(forSegment: statKind.selectedSegment) ?? "")
        }
        if statAlignment.selectedSegment >= 0 {
            statAlignment.setAccessibilityValue(statAlignment.label(forSegment: statAlignment.selectedSegment) ?? "")
        }
        if alignment.selectedSegment >= 0 {
            alignment.setAccessibilityValue(alignment.label(forSegment: alignment.selectedSegment) ?? "")
        }
        if borderStyle.selectedSegment >= 0 {
            borderStyle.setAccessibilityValue(borderStyle.label(forSegment: borderStyle.selectedSegment) ?? "")
        }
    }

    private func configureMatchTester() {
        for field in [matchField, testStringField] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(matchTesterChanged(_:)),
                name: NSControl.textDidChangeNotification,
                object: field
            )
        }
        for button in [regex, matchCase, wholeWord, startsWith, endsWith] {
            button.target = self
            button.action = #selector(matchTesterChanged(_:))
        }
    }

    @objc private func matchTesterChanged(_ sender: Any?) {
        updateMatchTester()
    }

    private func currentMatchDefinition() -> MatchDefinition {
        MatchDefinition(
            text: matchField.stringValue,
            isRegularExpression: regex.state == .on,
            matchCase: matchCase.state == .on,
            startsWith: startsWith.state == .on,
            endsWith: endsWith.state == .on,
            wholeWord: wholeWord.state == .on
        )
    }

    private func currentMatchErrorDescription() -> String? {
        guard regex.state == .on else { return nil }
        do {
            _ = try currentMatchDefinition().matches(in: testStringField.stringValue)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func updateMatchTester() {
        if regex.state == .on {
            wholeWord.state = .off
            startsWith.state = .off
            endsWith.state = .off
            wholeWord.isEnabled = false
            startsWith.isEnabled = false
            endsWith.isEnabled = false
        } else {
            wholeWord.isEnabled = true
            startsWith.isEnabled = true
            endsWith.isEnabled = true
        }
        do {
            let matches = try currentMatchDefinition().matches(in: testStringField.stringValue)
            testError.stringValue = ""
            testError.setAccessibilityValue("")
            let summary = Self.matchSummary(matches)
            testResult.stringValue = summary
            testResult.setAccessibilityValue(summary)
        } catch {
            testResult.stringValue = "Matches: 0"
            testResult.setAccessibilityValue(testResult.stringValue)
            let message = "Invalid regular expression: \(error.localizedDescription)"
            testError.stringValue = message
            testError.setAccessibilityValue(message)
        }
    }

    private static func matchSummary(_ matches: [MatchCapture]) -> String {
        guard !matches.isEmpty else { return "Matches: 0" }
        let captureSummaries = matches.prefix(3).enumerated().map { matchIndex, capture in
            capture.values.enumerated().map { captureIndex, value in
                let range = capture.ranges[captureIndex]
                let rangeText = range.location == NSNotFound
                    ? "not found"
                    : "\(range.location)-\(range.location + range.length)"
                return "$\(captureIndex)=\(value ?? "") [\(rangeText)]"
            }.joined(separator: ", ")
        }
        let suffix = matches.count > 3 ? " ..." : ""
        return "Matches: \(matches.count) " + captureSummaries.joined(separator: " | ") + suffix
    }

    private func appearancePane() -> NSView {
        fixed(fontFace, width: 170)
        fixed(fontSize, width: 60)
        let left = stack([
            row([fontEnabled, label("Face"), fontFace, label("Size"), fontSize, fontDefault]),
            row([foregroundEnabled, foregroundColor, foregroundDefault, foregroundHash]),
            row([backgroundEnabled, backgroundColor, backgroundDefault, backgroundHash]),
            wholeLineAppearance,
        ])
        let right = stack([bold, italic, underline, strikeout, flashing, fastFlash])
        return padded(row([left, right]))
    }

    private func paragraphPane() -> NSView {
        strokeStyle.addItems(withTitles: ["Outline", "Top", "Bottom"])
        return padded(stack([
            row([paragraphBackground, paragraphBackgroundColor, paragraphBackgroundHash]),
            row([strokeEnabled, fixed(strokeWidth, width: 64), strokeColor, strokeHash, label("Style:"), strokeStyle]),
            row([borderEnabled, fixed(borderWidth, width: 64), label("Border Style:"), borderStyle]),
            row([alignmentEnabled, alignment]),
            row([leftIndentEnabled, fixed(leftIndent, width: 80), rightIndentEnabled, fixed(rightIndent, width: 80)]),
            row([topPaddingEnabled, fixed(topPadding, width: 80), bottomPaddingEnabled, fixed(bottomPadding, width: 80)]),
        ]))
    }

    private func soundPane(speechScroll: NSScrollView) -> NSView {
        speechScroll.heightAnchor.constraint(equalToConstant: 82).isActive = true
        return padded(stack([
            playSound,
            formRow("Sound File", soundFile),
            speak,
            speakWholeLine,
            label("Say only this:"),
            speechScroll,
            label("You can use SAPI XML tags in the text, like <emph>, <spell>, <volume>, and <rate>."),
        ]))
    }

    private func spawnPane() -> NSView {
        return padded(stack([
            spawnActive,
            formRow("Window Title:", spawnTitle),
            formRow("Add to tab group (optional):", spawnTabGroup),
            formRow("Capture Until (optional):", spawnCaptureUntil),
            spawnOnlyChildren,
            spawnClear,
            spawnShowTab,
            spawnGagLog,
            spawnCopy,
            label("To redirect only this trigger's line, leave Capture Until blank."),
        ]))
    }

    private func statPane() -> NSView {
        return padded(stack([
            row([label("Invisible Prefix:"), fixed(statPrefix, width: 120), label("Name:"), fixed(statName, width: 120), label("Value:"), fixed(statValue, width: 120)]),
            row([label("Name alignment:"), statAlignment]),
            row([statColorEnabled, statColor, statFontEnabled, fixed(statFontName, width: 140), fixed(statFontSize, width: 54)]),
            row([statKind, statAddValue]),
            row([label("Range Min:"), fixed(statRangeMin, width: 110), label("Max:"), fixed(statRangeMax, width: 110), label("Range Bar Color"), statRangeColor]),
            formRow("Window Title (optional):", statTitle),
        ]))
    }

    private func sendPane(sendScroll: NSScrollView) -> NSView {
        sendScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        return padded(stack([
            sendText,
            sendOnClick,
            row([label("RegEx Capture Index To Apply To:"), fixed(sendCaptureIndex, width: 70)]),
            sendExpandVariables,
            label("Text to be sent:"),
            sendScroll,
        ]))
    }

    private func miscPane(filterScroll: NSScrollView) -> NSView {
        filterScroll.heightAnchor.constraint(equalToConstant: 70).isActive = true
        return padded(stack([
            filterText,
            filterHTML,
            filterExpandVariables,
            label("Text to replace match text with:"),
            filterScroll,
            label("Avatars (image left of text)"),
            formRow("URL", avatarURL),
            label("Gagging"),
            gagDisplay,
            gagLog,
        ]))
    }

    private func activityPane() -> NSView {
        padded(stack([activityImportant, activateWindow, activityNormal, suppressActivity, systemNotification]))
    }

    private func scriptPane() -> NSView {
        padded(stack([
            scriptEnabled,
            formRow("Name of the function To Call", scriptFunction),
            label("""
            The function being called should look something like this:
            function Sample(window, line, search_ranges) {
              window.output.add(line);
            }
            """),
        ]))
    }

    private func loadParagraph(_ patch: ParagraphPatch) {
        if let background = patch.background {
            paragraphBackground.state = .on
            paragraphBackgroundColor.color = NSColor(rgb: background)
        }
        paragraphBackgroundHash.state = patch.backgroundHash ? .on : .off
        if let width = patch.strokeWidth {
            strokeEnabled.state = .on
            strokeWidth.stringValue = Self.number(width)
        }
        if let color = patch.strokeColor {
            strokeEnabled.state = .on
            strokeColor.color = NSColor(rgb: color)
        }
        strokeHash.state = patch.strokeHash ? .on : .off
        let strokeIndex = switch patch.strokeStyle {
        case .top: 1
        case .bottom: 2
        default: 0
        }
        strokeStyle.selectItem(at: strokeIndex)
        if let width = patch.borderWidth {
            borderEnabled.state = .on
            borderWidth.stringValue = Self.number(width)
        }
        if let style = patch.borderStyle {
            borderStyle.selectedSegment = style == .round ? 1 : 0
        }
        if let value = patch.alignment {
            alignmentEnabled.state = .on
            alignment.selectedSegment = switch value {
            case .left: 0
            case .center: 1
            case .right: 2
            }
        }
        if let value = patch.leftIndent {
            leftIndentEnabled.state = .on
            leftIndent.stringValue = Self.number(value)
        }
        if let value = patch.rightIndent {
            rightIndentEnabled.state = .on
            rightIndent.stringValue = Self.number(value)
        }
        if let value = patch.topPadding {
            topPaddingEnabled.state = .on
            topPadding.stringValue = Self.number(value)
        }
        if let value = patch.bottomPadding {
            bottomPaddingEnabled.state = .on
            bottomPadding.stringValue = Self.number(value)
        }
    }

    private func loadStat(_ action: TriggerStatAction) {
        statPrefix.stringValue = action.prefix
        statTitle.stringValue = action.title
        statName.stringValue = action.name
        statValue.stringValue = action.value
        statKind.selectedSegment = switch action.kind {
        case .integer: 0
        case .string: 1
        case .range: 2
        }
        statAddValue.state = action.addsToExistingInteger ? .on : .off
        statRangeMin.stringValue = action.lower
        statRangeMax.stringValue = action.upper
        if let color = action.color {
            statColorEnabled.state = .on
            statColor.color = NSColor(rgb: color)
        }
        if let color = action.rangeColor { statRangeColor.color = NSColor(rgb: color) }
        statAlignment.selectedSegment = switch action.nameAlignment {
        case .left: 0
        case .center: 1
        case .right: 2
        }
        if let font = action.font {
            statFontEnabled.state = .on
            statFontName.stringValue = font.name
            statFontSize.stringValue = Self.number(font.size)
        }
    }

    private func paragraphPatch() -> ParagraphPatch {
        ParagraphPatch(
            alignment: alignmentEnabled.state == .on ? selectedAlignment(alignment) : nil,
            leftIndent: leftIndentEnabled.state == .on ? double(leftIndent, fallback: 0) : nil,
            rightIndent: rightIndentEnabled.state == .on ? double(rightIndent, fallback: 0) : nil,
            topPadding: topPaddingEnabled.state == .on ? double(topPadding, fallback: 0) : nil,
            bottomPadding: bottomPaddingEnabled.state == .on ? double(bottomPadding, fallback: 0) : nil,
            background: paragraphBackground.state == .on ? paragraphBackgroundColor.color.rgbColor : nil,
            backgroundHash: paragraphBackgroundHash.state == .on,
            borderWidth: borderEnabled.state == .on ? double(borderWidth, fallback: 1) : nil,
            borderStyle: borderEnabled.state == .on ? (borderStyle.selectedSegment == 1 ? .round : .square) : nil,
            strokeWidth: strokeEnabled.state == .on ? double(strokeWidth, fallback: 1) : nil,
            strokeColor: strokeEnabled.state == .on ? strokeColor.color.rgbColor : nil,
            strokeHash: strokeHash.state == .on,
            strokeStyle: strokeEnabled.state == .on ? selectedStrokeStyle : nil
        )
    }

    private func statAction() -> TriggerStatAction {
        let kind: TriggerStatKind = switch statKind.selectedSegment {
        case 1: .string
        case 2: .range
        default: .integer
        }
        return TriggerStatAction(
            title: statTitle.stringValue,
            name: statName.stringValue,
            prefix: statPrefix.stringValue,
            value: statValue.stringValue,
            kind: kind,
            addsToExistingInteger: statAddValue.state == .on,
            lower: statRangeMin.stringValue,
            upper: statRangeMax.stringValue,
            color: statColorEnabled.state == .on ? statColor.color.rgbColor : nil,
            rangeColor: statRangeColor.color.rgbColor,
            nameAlignment: selectedAlignment(statAlignment),
            font: statFontEnabled.state == .on
                ? .init(name: statFontName.stringValue.isEmpty ? "Courier New" : statFontName.stringValue, size: double(statFontSize, fallback: 13))
                : nil
        )
    }

    private var selectedStrokeStyle: ParagraphStyle.StrokeStyle {
        switch strokeStyle.indexOfSelectedItem {
        case 1: .top
        case 2: .bottom
        default: .outline
        }
    }

    private func selectedAlignment(_ control: NSSegmentedControl) -> ParagraphStyle.Alignment {
        switch control.selectedSegment {
        case 1: .center
        case 2: .right
        default: .left
        }
    }

    private func double(_ field: NSTextField, fallback: Double) -> Double {
        let value = field.doubleValue
        return value.isFinite ? value : fallback
    }

    private func recursiveSubviews() -> [NSView] {
        func collect(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(collect)
        }
        return collect(self)
    }

    private static func textView() -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as? NSTextView
        text?.isRichText = false
        text?.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        return scroll
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private func tab(_ label: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    private func padded(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            view.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            view.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    private func formRow(_ title: String, _ field: NSTextField) -> NSView {
        fixed(field, width: 420)
        return row([label(title), field])
    }

    @discardableResult
    private func fixed<T: NSView>(_ view: T, width: CGFloat) -> T {
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.maximumNumberOfLines = 0
        return label
    }
}

private extension NSColor {
    convenience init(rgb: BeipCore.RGBColor) {
        self.init(
            srgbRed: CGFloat(rgb.red) / 255,
            green: CGFloat(rgb.green) / 255,
            blue: CGFloat(rgb.blue) / 255,
            alpha: CGFloat(rgb.alpha) / 255
        )
    }

    var rgbColor: BeipCore.RGBColor {
        let color = usingColorSpace(.sRGB) ?? self
        return BeipCore.RGBColor(
            red: UInt8(max(0, min(255, (color.redComponent * 255).rounded()))),
            green: UInt8(max(0, min(255, (color.greenComponent * 255).rounded()))),
            blue: UInt8(max(0, min(255, (color.blueComponent * 255).rounded()))),
            alpha: UInt8(max(0, min(255, (color.alphaComponent * 255).rounded())))
        )
    }
}
