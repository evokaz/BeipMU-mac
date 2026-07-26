import AppKit
import BeipAutomation
import BeipPersistence

/// Native, Config.txt-backed editor for global aliases, triggers, and keyboard
/// macros. It exposes the common actions while preserving unsupported fields
/// and nested blocks on existing rows.
@MainActor
final class AutomationEditorWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    enum Kind: Equatable {
        case aliases
        case triggers
        case macros

        var title: String {
            switch self {
            case .aliases: "Aliases"
            case .triggers: "Triggers"
            case .macros: "Keyboard Macros"
            }
        }

        var emptyTitle: String {
            switch self {
            case .aliases: "New Alias"
            case .triggers: "New Trigger"
            case .macros: "New Macro"
            }
        }
    }

    private let library: ProfileLibrary
    private let kind: Kind
    private let scope: LegacyConfigurationWorkspace.AutomationScope
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let descriptionField = NSTextField()
    private let matchField = NSTextField()
    private let regex = NSButton(checkboxWithTitle: "Regular expression", target: nil, action: nil)
    private let actionPopup = NSPopUpButton()
    private let actionField = NSTextField()
    private var selectedIndex: Int?
    var onClose: (() -> Void)?

    init(library: ProfileLibrary, kind: Kind, scope: LegacyConfigurationWorkspace.AutomationScope = .global) {
        self.library = library
        self.kind = kind
        self.scope = scope
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(kind.title) — \(scope.displayName)"
        window.minSize = NSSize(width: 620, height: 360)
        super.init(window: window)
        window.delegate = self
        let accessibilityIdentifier = switch kind {
        case .aliases: "aliasesEditor"
        case .triggers: "triggersEditor"
        case .macros: "macrosEditor"
        }
        window.setAccessibilityIdentifier(accessibilityIdentifier)
        configure(in: window)
        reload(selecting: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private func configure(in window: NSWindow) {
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 28
        table.addTableColumn(NSTableColumn(identifier: .init("automationEntry")))
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityIdentifier("automationEntryList")
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder

        let add = NSButton(title: "+", target: self, action: #selector(addEntry(_:)))
        add.toolTip = "Add \(kind == .macros ? "macro" : String(kind.title.dropLast()))"
        let remove = NSButton(title: "−", target: self, action: #selector(removeEntry(_:)))
        remove.toolTip = "Remove selected \(kind == .macros ? "macro" : String(kind.title.dropLast()))"
        let listButtons = NSStackView(views: [add, remove, NSView()])
        listButtons.orientation = .horizontal
        listButtons.spacing = 6
        let sidebar = NSStackView(views: [listScroll, listButtons])
        sidebar.orientation = .vertical
        sidebar.spacing = 8
        sidebar.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 8)
        sidebar.widthAnchor.constraint(equalToConstant: 250).isActive = true

        let heading = NSTextField(labelWithString: kind.title)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        descriptionField.placeholderString = "Optional description"
        descriptionField.setAccessibilityIdentifier("automationDescription")
        matchField.placeholderString = kind == .macros ? "Control+Alt+M or F1" : "Text to match"
        matchField.setAccessibilityIdentifier("automationMatch")
        regex.title = kind == .macros ? "Type into input" : "Regular expression"
        actionField.setAccessibilityIdentifier("automationActionText")
        actionPopup.addItems(withTitles: ["Gag display", "Gag display and log", "Send text"])
        actionPopup.target = self
        actionPopup.action = #selector(actionChanged(_:))
        let matchGrid = NSGridView(views: [
            [NSTextField(labelWithString: "Description:"), descriptionField],
            [NSTextField(labelWithString: kind == .macros ? "Key:" : "Match:"), matchField],
            [NSView(), regex],
        ])
        matchGrid.column(at: 0).xPlacement = .trailing
        matchGrid.column(at: 1).width = 370
        matchGrid.rowSpacing = 8

        let actionGrid: NSGridView
        if kind == .aliases {
            actionGrid = NSGridView(views: [[NSTextField(labelWithString: "Replace with:"), actionField]])
        } else if kind == .triggers {
            actionGrid = NSGridView(views: [
                [NSTextField(labelWithString: "Action:"), actionPopup],
                [NSTextField(labelWithString: "Send text:"), actionField],
            ])
        } else {
            actionGrid = NSGridView(views: [[NSTextField(labelWithString: "Macro:"), actionField]])
        }
        actionGrid.column(at: 0).xPlacement = .trailing
        actionGrid.column(at: 1).width = 370
        actionGrid.rowSpacing = 8
        let noteText = switch kind {
        case .aliases:
            "Edits preserve unknown alias fields and nested aliases."
        case .triggers:
            "Edits preserve unsupported trigger actions and nested triggers. Gag and Send are the native editing actions in this first pass."
        case .macros:
            "Use legacy key spelling such as Control+Alt+M or F1. Edits preserve unknown macro fields and nested folders."
        }
        let note = NSTextField(wrappingLabelWithString: noteText)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 0
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyEntry(_:)))
        apply.keyEquivalent = "\r"
        let detail = NSStackView(views: [heading, matchGrid, actionGrid, note, NSView(), status, apply])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 12
        detail.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        window.contentView = split
        updateActionFieldState()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch kind {
        case .aliases: library.workspace.aliases(in: scope).count
        case .triggers: library.workspace.triggers(in: scope).count
        case .macros: library.workspace.macros(in: scope).count
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("automationRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let result = NSTableCellView()
            result.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            result.addSubview(text)
            result.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: result.leadingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: result.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: result.centerYAnchor),
            ])
            return result
        }()
        switch kind {
        case .aliases:
            let alias = library.workspace.aliases(in: scope)[row]
            view.textField?.stringValue = alias.description.isEmpty ? alias.match.text : alias.description
        case .triggers:
            let trigger = library.workspace.triggers(in: scope)[row]
            view.textField?.stringValue = trigger.description.isEmpty ? trigger.match.text : trigger.description
        case .macros:
            let macro = library.workspace.macros(in: scope)[row]
            view.textField?.stringValue = macro.description.isEmpty ? macro.key : macro.description
        }
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0 else { selectedIndex = nil; clearFields(); return }
        selectedIndex = row
        loadEntry(at: row)
    }

    @objc private func addEntry(_ sender: Any?) {
        do {
            let index: Int
            switch kind {
            case .aliases:
                var added = 0
                try library.mutate { added = try $0.addAlias(in: scope, description: kind.emptyTitle) }
                index = added
            case .triggers:
                var added = 0
                try library.mutate { added = try $0.addTrigger(in: scope, description: kind.emptyTitle) }
                index = added
            case .macros:
                var added = 0
                try library.mutate { added = try $0.addMacro(in: scope, description: kind.emptyTitle) }
                index = added
            }
            reload(selecting: index)
        } catch { present(error) }
    }

    @objc private func removeEntry(_ sender: Any?) {
        guard let selectedIndex else { NSSound.beep(); return }
        do {
            try library.mutate {
                switch kind {
                case .aliases: try $0.removeAutomationEntry(at: selectedIndex, in: scope, kind: .aliases)
                case .triggers: try $0.removeAutomationEntry(at: selectedIndex, in: scope, kind: .triggers)
                case .macros: try $0.removeAutomationEntry(at: selectedIndex, in: scope, kind: .macros)
                }
            }
            reload(selecting: max(0, selectedIndex - 1))
        } catch { present(error) }
    }

    @objc private func applyEntry(_ sender: Any?) {
        guard let selectedIndex else { NSSound.beep(); return }
        if kind == .macros {
            do {
                try library.mutate {
                    try $0.updateMacro(
                        at: selectedIndex,
                        in: scope,
                        description: descriptionField.stringValue,
                        key: matchField.stringValue,
                        macro: actionField.stringValue,
                        typeIntoInput: regex.state == .on
                    )
                }
                status.stringValue = "Applied and saved."
                reload(selecting: selectedIndex)
            } catch { present(error) }
            return
        }
        let existingMatch: MatchDefinition = switch kind {
        case .aliases: library.workspace.aliases(in: scope)[selectedIndex].match
        case .triggers: library.workspace.triggers(in: scope)[selectedIndex].match
        case .macros: preconditionFailure("Macros are handled above.")
        }
        let match = MatchDefinition(
            text: matchField.stringValue,
            isRegularExpression: regex.state == .on,
            matchCase: existingMatch.matchCase,
            startsWith: existingMatch.startsWith,
            endsWith: existingMatch.endsWith,
            wholeWord: existingMatch.wholeWord
        )
        do {
            try library.mutate {
                switch kind {
                case .aliases:
                    try $0.updateAlias(at: selectedIndex, in: scope, description: descriptionField.stringValue, match: match, replacement: actionField.stringValue)
                case .triggers:
                    try $0.updateTrigger(at: selectedIndex, in: scope, description: descriptionField.stringValue, match: match, action: selectedTriggerAction)
                case .macros:
                    break
                }
            }
            status.stringValue = "Applied and saved."
            reload(selecting: selectedIndex)
        } catch { present(error) }
    }

    @objc private func actionChanged(_ sender: Any?) { updateActionFieldState() }

    private var selectedTriggerAction: LegacyConfigurationWorkspace.EditableTriggerAction {
        switch actionPopup.indexOfSelectedItem {
        case 1: .gag(display: true, log: true)
        case 2: .send(actionField.stringValue)
        default: .gag(display: true, log: false)
        }
    }

    private func reload(selecting index: Int?) {
        table.reloadData()
        guard let index, index >= 0, index < numberOfRows(in: table) else { clearFields(); return }
        table.selectRowIndexes(.init(integer: index), byExtendingSelection: false)
        selectedIndex = index
        loadEntry(at: index)
    }

    private func loadEntry(at index: Int) {
        switch kind {
        case .aliases:
            let alias = library.workspace.aliases(in: scope)[index]
            descriptionField.stringValue = alias.description
            matchField.stringValue = alias.match.text
            regex.state = alias.match.isRegularExpression ? .on : .off
            actionField.stringValue = alias.replacement
        case .triggers:
            let trigger = library.workspace.triggers(in: scope)[index]
            descriptionField.stringValue = trigger.description
            matchField.stringValue = trigger.match.text
            regex.state = trigger.match.isRegularExpression ? .on : .off
            if let send = trigger.actions.compactMap({ action -> String? in if case let .send(text, _, _, _) = action { return text }; return nil }).first {
                actionPopup.selectItem(at: 2)
                actionField.stringValue = send
            } else if let gag = trigger.actions.compactMap({ action -> (Bool, Bool)? in
                if case let .gag(display, log) = action { return (display, log) }
                return nil
            }).first {
                actionPopup.selectItem(at: gag.1 ? 1 : 0)
                actionField.stringValue = ""
            } else {
                actionPopup.selectItem(at: 0)
                actionField.stringValue = ""
            }
            updateActionFieldState()
        case .macros:
            let macro = library.workspace.macros(in: scope)[index]
            descriptionField.stringValue = macro.description
            matchField.stringValue = macro.key
            regex.state = macro.typeIntoInput ? .on : .off
            actionField.stringValue = macro.macro
            actionField.isEnabled = true
            actionField.placeholderString = "Text to send or insert"
        }
    }

    private func clearFields() {
        selectedIndex = nil
        descriptionField.stringValue = ""
        matchField.stringValue = ""
        regex.state = .off
        actionField.stringValue = ""
        status.stringValue = ""
        if kind == .triggers { actionPopup.selectItem(at: 0); updateActionFieldState() }
        else { actionField.isEnabled = true }
    }

    private func updateActionFieldState() {
        guard kind == .triggers else { return }
        let isSend = actionPopup.indexOfSelectedItem == 2
        actionField.isEnabled = isSend
        actionField.placeholderString = isSend ? "Text sent when the trigger matches" : ""
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}
