import AppKit
import BeipAutomation
import BeipPersistence
import UniformTypeIdentifiers

/// Native, Config.txt-backed editor for global aliases, triggers, and keyboard
/// macros. It exposes the common actions while preserving unsupported fields
/// and nested blocks on existing rows.
@MainActor
final class AutomationEditorWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate {
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
    private let triggerOutline = NSOutlineView()
    private var triggerOutlineNodes: [TriggerOutlineNode] = []
    private var selectedTriggerScope: LegacyConfigurationWorkspace.AutomationScope?
    private let status = NSTextField(labelWithString: "")
    private let descriptionField = NSTextField()
    private let matchField = NSTextField()
    private let regex = NSButton(checkboxWithTitle: "Regular expression", target: nil, action: nil)
    private let actionPopup = NSPopUpButton()
    private let actionField = NSTextField()
    private var triggerDetail: TriggerDetailView?
    private let triggerScopeAfterCount = NSTextField()
    private let triggerScopeApply = NSButton(title: "Save Post Count", target: nil, action: nil)
    private var selectedIndex: Int?
    private var selectedTriggerPath: [Int]?
    private var selectedTriggerIdentity: TriggerSelectionIdentity?
    var onClose: (() -> Void)?

    private final class TriggerOutlineNode {
        enum Kind {
            case scope(LegacyConfigurationWorkspace.AutomationScope)
            case trigger(LegacyConfigurationWorkspace.AutomationScope, [Int], TriggerSelectionIdentity)
        }

        let title: String
        let kind: Kind
        var children: [TriggerOutlineNode]

        init(title: String, kind: Kind, children: [TriggerOutlineNode] = []) {
            self.title = title
            self.kind = kind
            self.children = children
        }
    }

    private struct TriggerSelectionKey: Equatable {
        var scope: LegacyConfigurationWorkspace.AutomationScope
        var path: [String]
        var triggerPath: [Int]?
        var triggerIdentity: TriggerSelectionIdentity?
    }

    private struct TriggerSelectionIdentity: Equatable {
        var id: UUID
        var fingerprint: TriggerFingerprint

        init(_ trigger: Trigger) {
            id = trigger.id
            fingerprint = TriggerFingerprint(trigger)
        }

        func matches(_ other: TriggerSelectionIdentity) -> Bool {
            id == other.id || fingerprint == other.fingerprint
        }
    }

    private struct TriggerFingerprint: Equatable {
        var description: String
        var match: MatchDefinition
        var folder: Bool
        var disabled: Bool
        var stopProcessing: Bool
        var oncePerLine: Bool
        var awayPresent: Bool
        var awayPresentOnce: Bool
        var away: Bool
        var cooldown: TimeInterval?
        var multiline: MultilineTriggerOptions?
        var actions: [TriggerAction]
        var childrenActive: Bool
        var children: [TriggerFingerprint]

        init(_ trigger: Trigger) {
            description = trigger.description
            match = trigger.match
            folder = trigger.folder
            disabled = trigger.disabled
            stopProcessing = trigger.stopProcessing
            oncePerLine = trigger.oncePerLine
            awayPresent = trigger.awayPresent
            awayPresentOnce = trigger.awayPresentOnce
            away = trigger.away
            cooldown = trigger.cooldown
            multiline = trigger.multiline
            actions = trigger.actions
            childrenActive = trigger.childrenActive
            children = trigger.children.map(TriggerFingerprint.init)
        }
    }

    init(library: ProfileLibrary, kind: Kind, scope: LegacyConfigurationWorkspace.AutomationScope = .global) {
        self.library = library
        self.kind = kind
        self.scope = scope
        let size = kind == .triggers
            ? NSSize(width: 980, height: 700)
            : NSSize(width: 760, height: 480)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(kind.title) — \(scope.displayName)"
        window.minSize = kind == .triggers
            ? NSSize(width: 860, height: 560)
            : NSSize(width: 620, height: 360)
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
        if kind == .triggers {
            configureTriggerEditor(in: window)
            return
        }

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

        if kind == .triggers {
            let heading = NSTextField(labelWithString: kind.title)
            heading.font = .systemFont(ofSize: 16, weight: .semibold)
            let triggerDetail = TriggerDetailView()
            self.triggerDetail = triggerDetail
            let note = NSTextField(wrappingLabelWithString: "Native editor for the Windows trigger options. Unknown legacy fields and nested triggers are preserved.")
            note.textColor = .secondaryLabelColor
            note.maximumNumberOfLines = 0
            let apply = NSButton(title: "Apply", target: self, action: #selector(applyEntry(_:)))
            apply.keyEquivalent = "\r"
            let detail = NSStackView(views: [heading, triggerDetail, note, NSView(), status, apply])
            detail.orientation = .vertical
            detail.alignment = .leading
            detail.spacing = 10
            detail.edgeInsets = NSEdgeInsets(top: 16, left: 22, bottom: 16, right: 22)

            let split = NSSplitView()
            split.isVertical = true
            split.dividerStyle = .thin
            split.addArrangedSubview(sidebar)
            split.addArrangedSubview(detail)
            split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
            window.contentView = split
            return
        }

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

    private func configureTriggerEditor(in window: NSWindow) {
        triggerOutline.headerView = nil
        triggerOutline.style = .sourceList
        triggerOutline.rowHeight = 22
        triggerOutline.addTableColumn(NSTableColumn(identifier: .init("triggerOutlineEntry")))
        triggerOutline.outlineTableColumn = triggerOutline.tableColumns[0]
        triggerOutline.delegate = self
        triggerOutline.dataSource = self
        triggerOutline.setAccessibilityIdentifier("triggerScopeOutline")

        let listScroll = NSScrollView()
        listScroll.documentView = triggerOutline
        listScroll.hasVerticalScroller = true
        listScroll.hasHorizontalScroller = true
        listScroll.borderType = .bezelBorder
        triggerScopeAfterCount.setAccessibilityIdentifier("triggerScopeAfterCount")
        triggerScopeAfterCount.controlSize = .small
        triggerScopeApply.target = self
        triggerScopeApply.action = #selector(applyTriggerScopeSettings(_:))
        triggerScopeApply.bezelStyle = .rounded
        triggerScopeApply.controlSize = .small
        triggerScopeApply.setAccessibilityIdentifier("triggerScopeApply")
        triggerScopeAfterCount.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let scopeControls = NSStackView(views: [
            NSTextField(labelWithString: "Post count:"),
            triggerScopeAfterCount,
            triggerScopeApply,
        ])
        scopeControls.orientation = NSUserInterfaceLayoutOrientation.horizontal
        scopeControls.alignment = NSLayoutConstraint.Attribute.centerY
        scopeControls.spacing = 5

        let new = NSButton(title: "New", target: self, action: #selector(addEntry(_:)))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyTrigger(_:)))
        let delete = NSButton(title: "Delete", target: self, action: #selector(removeEntry(_:)))
        let moveUp = NSButton(title: "Up", target: self, action: #selector(moveTriggerUp(_:)))
        let moveDown = NSButton(title: "Down", target: self, action: #selector(moveTriggerDown(_:)))
        let moveIn = NSButton(title: "In", target: self, action: #selector(moveTriggerIn(_:)))
        let moveOut = NSButton(title: "Out", target: self, action: #selector(moveTriggerOut(_:)))
        let importButton = NSButton(title: "Import…", target: self, action: #selector(importTriggers(_:)))
        let exportButton = NSButton(title: "Export…", target: self, action: #selector(exportTriggers(_:)))
        new.setAccessibilityIdentifier("triggerNew")
        copy.setAccessibilityIdentifier("triggerCopy")
        delete.setAccessibilityIdentifier("triggerDelete")
        moveUp.setAccessibilityIdentifier("triggerMoveUp")
        moveDown.setAccessibilityIdentifier("triggerMoveDown")
        moveIn.setAccessibilityIdentifier("triggerMoveIn")
        moveOut.setAccessibilityIdentifier("triggerMoveOut")
        importButton.setAccessibilityIdentifier("triggerImport")
        exportButton.setAccessibilityIdentifier("triggerExport")
        moveUp.toolTip = "Move selected trigger up"
        moveDown.toolTip = "Move selected trigger down"
        moveIn.toolTip = "Move selected trigger into the previous trigger"
        moveOut.toolTip = "Move selected trigger out to its parent's level"
        for button in [new, copy, delete, moveUp, moveDown, moveIn, moveOut, importButton, exportButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let listButtons = NSStackView(views: [new, copy, delete, importButton, exportButton])
        listButtons.orientation = .horizontal
        listButtons.spacing = 4
        listButtons.distribution = .fillEqually
        let moveButtons = NSStackView(views: [moveUp, moveDown, moveIn, moveOut])
        moveButtons.orientation = .horizontal
        moveButtons.spacing = 4
        moveButtons.distribution = .fillEqually

        let sidebar = NSStackView(views: [listScroll, scopeControls, listButtons, moveButtons])
        sidebar.orientation = NSUserInterfaceLayoutOrientation.vertical
        sidebar.spacing = 8
        sidebar.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 8)
        sidebar.widthAnchor.constraint(equalToConstant: 370).isActive = true

        let heading = NSTextField(labelWithString: kind.title)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        let triggerDetail = TriggerDetailView()
        self.triggerDetail = triggerDetail
        let note = NSTextField(wrappingLabelWithString: "Select Global, a world, or a character on the left to manage triggers in that scope. Unknown legacy fields and nested triggers are preserved.")
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 0
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyEntry(_:)))
        apply.keyEquivalent = "\r"
        apply.setAccessibilityIdentifier("triggerApply")
        status.setAccessibilityIdentifier("triggerEditorStatus")
        let detail = NSStackView(views: [heading, triggerDetail, note, NSView(), status, apply])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 10
        detail.edgeInsets = NSEdgeInsets(top: 16, left: 22, bottom: 16, right: 22)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        window.contentView = split
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
        guard notification.object as? NSTableView === table else { return }
        let row = table.selectedRow
        guard row >= 0 else { selectedIndex = nil; clearFields(); return }
        selectedIndex = row
        loadEntry(at: row)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let node = item as? TriggerOutlineNode
        return (node?.children ?? triggerOutlineNodes).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = item as? TriggerOutlineNode
        return (node?.children ?? triggerOutlineNodes)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? TriggerOutlineNode else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TriggerOutlineNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("triggerOutlineRow")
        let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let result = NSTableCellView()
            result.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            result.addSubview(text)
            result.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: result.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: result.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: result.centerYAnchor),
            ])
            return result
        }()
        view.textField?.stringValue = node.title
        view.imageView?.image = nil
        return view
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSOutlineView === triggerOutline else { return }
        guard triggerOutline.selectedRow >= 0,
              let node = triggerOutline.item(atRow: triggerOutline.selectedRow) as? TriggerOutlineNode else {
            selectedIndex = nil
            selectedTriggerScope = nil
            selectedTriggerPath = nil
            selectedTriggerIdentity = nil
            clearFields()
            return
        }
        switch node.kind {
        case let .scope(scope):
            selectedTriggerScope = scope
            selectedIndex = nil
            selectedTriggerPath = nil
            selectedTriggerIdentity = nil
            loadTriggerScopeSettings(scope)
            clearFields()
        case let .trigger(scope, path, identity):
            selectedTriggerScope = scope
            selectedTriggerPath = path
            selectedTriggerIdentity = identity
            selectedIndex = path.first
            loadTriggerScopeSettings(scope)
            loadTrigger(at: path, in: scope)
        }
    }

    @objc private func addEntry(_ sender: Any?) {
        if kind == .triggers {
            let targetScope = selectedTriggerScope ?? scope
            let parentPath = selectedTriggerPath ?? []
            var selection = triggerSelectionKey(scope: targetScope, triggerPath: nil)
            do {
                var added: [Int] = []
                try library.mutate {
                    added = try $0.addTrigger(in: targetScope, parentPath: parentPath, description: kind.emptyTitle)
                }
                selection.triggerPath = added
                reloadTriggerOutline(selecting: selection)
            } catch { present(error) }
            return
        }
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
        if kind == .triggers {
            guard let selectedTriggerPath, let selectedTriggerScope else { NSSound.beep(); return }
            let parentPath = Array(selectedTriggerPath.dropLast())
            let selection = triggerSelectionKey(scope: selectedTriggerScope, triggerPath: parentPath.isEmpty ? nil : parentPath)
            do {
                try library.mutate {
                    try $0.removeTrigger(at: selectedTriggerPath, in: selectedTriggerScope)
                }
                reloadTriggerOutline(selecting: selection)
            } catch { present(error) }
            return
        }
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
        if kind == .triggers {
            guard let triggerDetail, let selectedTriggerScope, let selectedTriggerPath else { NSSound.beep(); return }
            do {
                try triggerDetail.validateForApply()
                guard let existing = library.workspace.trigger(at: selectedTriggerPath, in: selectedTriggerScope) else {
                    throw LegacyConfigurationWorkspace.WorkspaceError.automationEntryNotFound
                }
                let updated = triggerDetail.updatedTrigger(preserving: existing)
                let selection = triggerSelectionKey(scope: selectedTriggerScope, triggerPath: selectedTriggerPath)
                try library.mutate {
                    try $0.updateTrigger(at: selectedTriggerPath, in: selectedTriggerScope, trigger: updated)
                }
                status.stringValue = "Applied and saved."
                reloadTriggerOutline(selecting: selection)
            } catch {
                status.stringValue = error.localizedDescription
                NSSound.beep()
            }
            return
        }
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

    @objc private func applyTriggerScopeSettings(_ sender: Any?) {
        guard kind == .triggers, let selectedTriggerScope else { NSSound.beep(); return }
        do {
            try library.mutate {
                try $0.updateTriggerGroupSettings(
                    in: selectedTriggerScope,
                    active: true,
                    afterCount: max(0, triggerScopeAfterCount.integerValue)
                )
            }
            status.stringValue = "Scope settings saved."
            reloadTriggerOutline(selecting: triggerSelectionKey(
                scope: selectedTriggerScope,
                triggerPath: selectedTriggerPath,
                triggerIdentity: selectedTriggerIdentity
            ))
        } catch { present(error) }
    }

    @objc private func copyTrigger(_ sender: Any?) {
        guard kind == .triggers,
              let selectedTriggerPath,
              let selectedTriggerScope else {
            NSSound.beep()
            return
        }
        do {
            guard let source = library.workspace.trigger(at: selectedTriggerPath, in: selectedTriggerScope) else {
                throw LegacyConfigurationWorkspace.WorkspaceError.automationEntryNotFound
            }
            var copy = source
            copy.description = source.description.isEmpty ? "Copy of \(source.match.text)" : "Copy of \(source.description)"
            let parentPath = Array(selectedTriggerPath.dropLast())
            var selection = triggerSelectionKey(scope: selectedTriggerScope, triggerPath: nil)
            var added: [Int] = []
            try library.mutate {
                added = try $0.addTrigger(in: selectedTriggerScope, parentPath: parentPath, trigger: copy)
            }
            selection.triggerPath = added
            reloadTriggerOutline(selecting: selection)
        } catch { present(error) }
    }

    @objc private func moveTriggerUp(_ sender: Any?) {
        guard let selectedTriggerPath,
              let index = selectedTriggerPath.last,
              index > 0 else {
            NSSound.beep()
            return
        }
        moveSelectedTrigger(toParentPath: Array(selectedTriggerPath.dropLast()), index: index - 1)
    }

    @objc private func moveTriggerDown(_ sender: Any?) {
        guard let selectedTriggerPath,
              let index = selectedTriggerPath.last else {
            NSSound.beep()
            return
        }
        let parentPath = Array(selectedTriggerPath.dropLast())
        guard index + 1 < triggerCount(inParentPath: parentPath) else {
            NSSound.beep()
            return
        }
        moveSelectedTrigger(toParentPath: parentPath, index: index + 1)
    }

    @objc private func moveTriggerIn(_ sender: Any?) {
        guard let selectedTriggerPath,
              let index = selectedTriggerPath.last,
              index > 0 else {
            NSSound.beep()
            return
        }
        let parentPath = Array(selectedTriggerPath.dropLast())
        let destinationParent = parentPath + [index - 1]
        moveSelectedTrigger(
            toParentPath: destinationParent,
            index: triggerCount(inParentPath: destinationParent)
        )
    }

    @objc private func moveTriggerOut(_ sender: Any?) {
        guard let selectedTriggerPath,
              selectedTriggerPath.count > 1 else {
            NSSound.beep()
            return
        }
        let parentPath = Array(selectedTriggerPath.dropLast())
        guard let parentIndex = parentPath.last else {
            NSSound.beep()
            return
        }
        moveSelectedTrigger(toParentPath: Array(parentPath.dropLast()), index: parentIndex + 1)
    }

    private func moveSelectedTrigger(toParentPath destinationParentPath: [Int], index destinationIndex: Int) {
        guard kind == .triggers,
              let selectedTriggerPath,
              let selectedTriggerScope else {
            NSSound.beep()
            return
        }
        do {
            var movedPath: [Int] = []
            try library.mutate {
                movedPath = try $0.moveTrigger(
                    at: selectedTriggerPath,
                    in: selectedTriggerScope,
                    toParentPath: destinationParentPath,
                    index: destinationIndex
                )
            }
            reloadTriggerOutline(selecting: triggerSelectionKey(scope: selectedTriggerScope, triggerPath: movedPath))
        } catch { present(error) }
    }

    private func triggerCount(inParentPath parentPath: [Int]) -> Int {
        guard let selectedTriggerScope else { return 0 }
        if parentPath.isEmpty { return library.workspace.triggers(in: selectedTriggerScope).count }
        return library.workspace.trigger(at: parentPath, in: selectedTriggerScope)?.children.count ?? 0
    }

    @objc private func importTriggers(_ sender: Any?) {
        guard kind == .triggers else { return }
        let targetScope = selectedTriggerScope ?? scope
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.message = "Import triggers into \(triggerScopeTitle(targetScope))."
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.performTriggerImport(from: url, into: targetScope) }
        }
    }

    @objc private func exportTriggers(_ sender: Any?) {
        guard kind == .triggers else { return }
        let targetScope = selectedTriggerScope ?? scope
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(triggerScopeTitle(targetScope))-triggers.txt"
        panel.message = "Export triggers from \(triggerScopeTitle(targetScope))."
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.performTriggerExport(to: url, from: targetScope) }
        }
    }

    private var selectedTriggerAction: LegacyConfigurationWorkspace.EditableTriggerAction {
        switch actionPopup.indexOfSelectedItem {
        case 1: .gag(display: true, log: true)
        case 2: .send(actionField.stringValue)
        default: .gag(display: true, log: false)
        }
    }

    private func reload(selecting index: Int?) {
        if kind == .triggers {
            reloadTriggerOutline(selecting: triggerSelectionKey(scope: scope, triggerPath: index.map { [$0] }))
            return
        }
        table.reloadData()
        guard let index, index >= 0, index < numberOfRows(in: table) else { clearFields(); return }
        table.selectRowIndexes(.init(integer: index), byExtendingSelection: false)
        selectedIndex = index
        loadEntry(at: index)
    }

    private func reloadTriggerOutline(selecting selection: TriggerSelectionKey?) {
        triggerOutlineNodes = makeTriggerOutlineNodes()
        triggerOutline.reloadData()
        triggerOutlineNodes.forEach { triggerOutline.expandItem($0, expandChildren: true) }

        let fallback = selection ?? triggerSelectionKey(
            scope: selectedTriggerScope ?? scope,
            triggerPath: selectedTriggerPath,
            triggerIdentity: selectedTriggerIdentity
        )
        if let row = rowForTriggerSelection(fallback) {
            triggerOutline.selectRowIndexes(.init(integer: row), byExtendingSelection: false)
            triggerOutline.scrollRowToVisible(row)
            outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification, object: triggerOutline))
        } else {
            selectedTriggerScope = fallback.scope
            selectedIndex = nil
            selectedTriggerPath = nil
            selectedTriggerIdentity = nil
            loadTriggerScopeSettings(fallback.scope)
            clearFields()
        }
    }

    private func makeTriggerOutlineNodes() -> [TriggerOutlineNode] {
        var roots: [TriggerOutlineNode] = []
        roots.append(scopeNode("Global", scope: .global))
        for server in library.workspace.servers {
            let serverScope: LegacyConfigurationWorkspace.AutomationScope = .server(server.profile.id)
            let serverNode = scopeNode(server.profile.name, scope: serverScope)
            for character in server.characters {
                let characterScope: LegacyConfigurationWorkspace.AutomationScope = .character(
                    server: server.profile.id,
                    character: character.id
                )
                let characterNode = scopeNode(character.name, scope: characterScope)
                for puppet in character.puppets {
                    let puppetScope: LegacyConfigurationWorkspace.AutomationScope = .puppet(
                        server: server.profile.id,
                        character: character.id,
                        puppet: puppet.id
                    )
                    characterNode.children.append(scopeNode(puppet.name, scope: puppetScope))
                }
                serverNode.children.append(characterNode)
            }
            roots.append(serverNode)
        }
        return roots
    }

    private func scopeNode(_ title: String, scope: LegacyConfigurationWorkspace.AutomationScope) -> TriggerOutlineNode {
        let children = triggerNodes(library.workspace.triggers(in: scope), scope: scope, parentPath: [])
        return TriggerOutlineNode(title: title, kind: .scope(scope), children: children)
    }

    private func triggerNodes(
        _ triggers: [Trigger],
        scope: LegacyConfigurationWorkspace.AutomationScope,
        parentPath: [Int]
    ) -> [TriggerOutlineNode] {
        triggers.enumerated().map { index, trigger in
            let path = parentPath + [index]
            return TriggerOutlineNode(
                title: trigger.description.isEmpty ? trigger.match.text : trigger.description,
                kind: .trigger(scope, path, TriggerSelectionIdentity(trigger)),
                children: triggerNodes(trigger.children, scope: scope, parentPath: path)
            )
        }
    }

    private func rowForTriggerSelection(_ selection: TriggerSelectionKey) -> Int? {
        for row in 0..<triggerOutline.numberOfRows {
            guard let node = triggerOutline.item(atRow: row) as? TriggerOutlineNode else { continue }
            switch node.kind {
            case let .scope(scope) where selection.triggerPath == nil && triggerScopeMatches(scope, selection):
                return row
            case let .trigger(scope, path, identity) where triggerScopeMatches(scope, selection):
                if selection.triggerIdentity?.matches(identity) == true {
                    return row
                }
                if selection.triggerPath == path {
                    return row
                }
            default:
                continue
            }
        }
        return nil
    }

    private func triggerSelectionKey(
        scope: LegacyConfigurationWorkspace.AutomationScope,
        triggerPath: [Int]?,
        triggerIdentity: TriggerSelectionIdentity? = nil
    ) -> TriggerSelectionKey {
        let identity = triggerIdentity ?? triggerPath
            .flatMap { library.workspace.trigger(at: $0, in: scope) }
            .map(TriggerSelectionIdentity.init)
        return .init(scope: scope, path: triggerScopePath(scope), triggerPath: triggerPath, triggerIdentity: identity)
    }

    private func triggerScopeMatches(
        _ scope: LegacyConfigurationWorkspace.AutomationScope,
        _ selection: TriggerSelectionKey
    ) -> Bool {
        scope == selection.scope || triggerScopePath(scope) == selection.path
    }

    private func triggerScopePath(_ scope: LegacyConfigurationWorkspace.AutomationScope) -> [String] {
        switch scope {
        case .global:
            return ["Global"]
        case let .server(serverID):
            guard let server = library.workspace.servers.first(where: { $0.profile.id == serverID }) else {
                return ["World"]
            }
            return [server.profile.name]
        case let .character(serverID, characterID):
            guard let server = library.workspace.servers.first(where: { $0.profile.id == serverID }),
                  let character = server.characters.first(where: { $0.id == characterID }) else {
                return ["World", "Character"]
            }
            return [server.profile.name, character.name]
        case let .puppet(serverID, characterID, puppetID):
            guard let server = library.workspace.servers.first(where: { $0.profile.id == serverID }),
                  let character = server.characters.first(where: { $0.id == characterID }),
                  let puppet = character.puppets.first(where: { $0.id == puppetID }) else {
                return ["World", "Character", "Puppet"]
            }
            return [server.profile.name, character.name, puppet.name]
        }
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
            triggerDetail?.load(trigger)
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

    private func loadTrigger(at path: [Int], in scope: LegacyConfigurationWorkspace.AutomationScope) {
        guard let trigger = library.workspace.trigger(at: path, in: scope) else { clearFields(); return }
        triggerDetail?.load(trigger)
        status.stringValue = ""
    }

    private func loadTriggerScopeSettings(_ scope: LegacyConfigurationWorkspace.AutomationScope) {
        let group = library.workspace.triggerGroup(in: scope)
        triggerScopeAfterCount.stringValue = String(group.afterCount)
        triggerScopeAfterCount.setAccessibilityValue(String(group.afterCount))
    }

    private func clearFields() {
        selectedIndex = nil
        selectedTriggerPath = nil
        selectedTriggerIdentity = nil
        descriptionField.stringValue = ""
        matchField.stringValue = ""
        regex.state = .off
        actionField.stringValue = ""
        status.stringValue = ""
        if kind == .triggers { triggerDetail?.reset() }
        else { actionField.isEnabled = true }
    }

    private func updateActionFieldState() {
        guard kind == .triggers else { return }
        let isSend = actionPopup.indexOfSelectedItem == 2
        actionField.isEnabled = isSend
        actionField.placeholderString = isSend ? "Text sent when the trigger matches" : ""
    }

    private func performTriggerImport(from url: URL, into scope: LegacyConfigurationWorkspace.AutomationScope) {
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            let imported = try LegacyConfigurationWorkspace(document: .init(source: source))
            let triggers = imported.globalTriggers
            guard !triggers.isEmpty else {
                status.stringValue = "No triggers found to import."
                return
            }
            var lastIndex = 0
            var selection = triggerSelectionKey(scope: scope, triggerPath: nil)
            try library.mutate { workspace in
                for trigger in triggers {
                    lastIndex = try workspace.addTrigger(in: scope, trigger: trigger)
                }
            }
            status.stringValue = "Imported \(triggers.count) trigger\(triggers.count == 1 ? "" : "s")."
            selection.triggerPath = [lastIndex]
            reloadTriggerOutline(selecting: selection)
        } catch { present(error) }
    }

    private func performTriggerExport(to url: URL, from scope: LegacyConfigurationWorkspace.AutomationScope) {
        do {
            let triggers = library.workspace.triggers(in: scope)
            var exported = try LegacyConfigurationWorkspace.empty()
            for trigger in triggers {
                try exported.addGlobalTrigger(trigger)
            }
            let document = try exported.renderedDocument()
            try Data(document.serialized().utf8).write(to: url, options: .atomic)
            status.stringValue = "Exported \(triggers.count) trigger\(triggers.count == 1 ? "" : "s")."
        } catch { present(error) }
    }

    private func triggerScopeTitle(_ scope: LegacyConfigurationWorkspace.AutomationScope) -> String {
        switch scope {
        case .global:
            return "Global"
        case let .server(serverID):
            return library.workspace.servers.first { $0.profile.id == serverID }?.profile.name ?? "World"
        case let .character(serverID, characterID):
            guard let server = library.workspace.servers.first(where: { $0.profile.id == serverID }),
                  let character = server.characters.first(where: { $0.id == characterID }) else {
                return "Character"
            }
            return "\(server.profile.name)-\(character.name)"
        case let .puppet(serverID, characterID, puppetID):
            guard let server = library.workspace.servers.first(where: { $0.profile.id == serverID }),
                  let character = server.characters.first(where: { $0.id == characterID }),
                  let puppet = character.puppets.first(where: { $0.id == puppetID }) else {
                return "Puppet"
            }
            return "\(server.profile.name)-\(character.name)-\(puppet.name)"
        }
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}
