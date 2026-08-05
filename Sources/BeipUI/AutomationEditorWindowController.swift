import AppKit
import BeipAutomation
import BeipPersistence
import UniformTypeIdentifiers

@MainActor
private final class MacroKeyCaptureField: NSTextField {
    var onCapture: ((String) -> Void)?
    private(set) var isCapturing = false

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            isCapturing = true
            needsDisplay = true
        }
        return becameFirstResponder
    }

    override func resignFirstResponder() -> Bool {
        let resignedFirstResponder = super.resignFirstResponder()
        if resignedFirstResponder {
            isCapturing = false
            needsDisplay = true
        }
        return resignedFirstResponder
    }

    override func mouseDown(with event: NSEvent) {
        // This field is deliberately not editable: its text is a preview of
        // the captured shortcut. Claiming first-responder status here makes a
        // click on the field enter capture mode instead of starting ordinary
        // NSTextField selection/editing behavior.
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isCapturing, isEnabled else { return }

        // NSTextField's normal border is intentionally retained; this accent
        // ring adds a clear "ready to record" state without changing the
        // field's resting appearance.
        let ring = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
            xRadius: 4,
            yRadius: 4
        )
        ring.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        ring.stroke()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), let key = Self.keyName(for: event) else {
            NSSound.beep()
            return
        }
        onCapture?(KeyboardMacroKey.canonicalFormat(
            key: key,
            control: flags.contains(.control),
            alt: flags.contains(.option),
            shift: flags.contains(.shift)
        ))
    }

    private static func keyName(for event: NSEvent) -> String? {
        KeyboardMacroKey.keyName(
            forKeyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

@MainActor
private final class MacroOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 120 where selectedRow >= 0:
            editColumn(0, row: selectedRow, with: nil, select: true)
        case 51 where selectedRow >= 0, 117 where selectedRow >= 0:
            onDelete?()
        default:
            super.keyDown(with: event)
        }
    }
}

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
    private let aliasSamplesOutline = NSOutlineView()
    private var triggerOutlineNodes: [TriggerOutlineNode] = []
    private var aliasOutlineNodes: [AliasOutlineNode] = []
    private var aliasSampleNodes: [AliasOutlineNode] = []
    private var selectedTriggerScope: LegacyConfigurationWorkspace.AutomationScope?
    private var selectedAliasScope: LegacyConfigurationWorkspace.AutomationScope?
    private let status = NSTextField(labelWithString: "")
    private let descriptionField = NSTextField()
    private let matchField = NSTextField()
    private let regex = NSButton(checkboxWithTitle: "Regular expression", target: nil, action: nil)
    private let actionPopup = NSPopUpButton()
    private let actionField = NSTextField()
    private var triggerDetail: TriggerDetailView?
    private var aliasDetail: AliasDetailView?
    private let triggerScopeAfterCount = NSTextField()
    private let triggerScopeApply = NSButton(title: "Save Post Count", target: nil, action: nil)
    private let aliasAfterCount = NSTextField()
    private let aliasScopeApply = NSButton(title: "Save Post Count", target: nil, action: nil)
    private var selectedIndex: Int?
    private var selectedTriggerPath: [Int]?
    private var selectedTriggerIdentity: TriggerSelectionIdentity?
    private var selectedAliasPath: [Int]?
    private var selectedAliasIdentity: AliasSelectionIdentity?
    private let macroOutline = MacroOutlineView()
    private let macroSamplesOutline = NSOutlineView()
    private var macroOutlineNodes: [MacroOutlineNode] = []
    private var macroSampleNodes: [MacroOutlineNode] = []
    private var selectedMacroScope: LegacyConfigurationWorkspace.AutomationScope?
    private var selectedMacroPath: [Int]?
    private var selectedMacroIdentity: MacroSelectionIdentity?
    private var macroDestinationScope: LegacyConfigurationWorkspace.AutomationScope?
    private var macroDestinationParentPath: [Int] = []
    private var macroSampleSelected = false
    private var macroExpansionStateInitialized = false
    private var expandedMacroKeys: Set<String> = []
    private var isReloadingMacroOutline = false
    private let macroActive = NSButton(checkboxWithTitle: "Process Keyboard Macros", target: nil, action: nil)
    private let macroFolder = NSButton(checkboxWithTitle: "Treat As Folder (This macro has no effect)", target: nil, action: nil)
    private let macroTypeIntoInput = NSButton(checkboxWithTitle: "Type into Input Window", target: nil, action: nil)
    private let macroControl = NSButton(checkboxWithTitle: "Control", target: nil, action: nil)
    private let macroAlt = NSButton(checkboxWithTitle: "Option", target: nil, action: nil)
    private let macroShift = NSButton(checkboxWithTitle: "Shift", target: nil, action: nil)
    private let macroKeyField = MacroKeyCaptureField()
    private let macroTextView = NSTextView()
    private var stagedMacroWorkspace: LegacyConfigurationWorkspace?
    private var macroExpectedRevision: UInt64 = 0
    private var macroDidClose = false
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

    private final class AliasOutlineNode {
        enum Kind {
            case scope(LegacyConfigurationWorkspace.AutomationScope)
            case alias(LegacyConfigurationWorkspace.AutomationScope, [Int], AliasSelectionIdentity)
            case sample(Alias)
        }

        let title: String
        let kind: Kind
        var children: [AliasOutlineNode]

        init(title: String, kind: Kind, children: [AliasOutlineNode] = []) {
            self.title = title
            self.kind = kind
            self.children = children
        }
    }

    private struct AliasSelectionKey: Equatable {
        var scope: LegacyConfigurationWorkspace.AutomationScope
        var path: [String]
        var aliasPath: [Int]?
        var aliasIdentity: AliasSelectionIdentity?
    }

    private final class MacroOutlineNode {
        enum Kind {
            case scope(LegacyConfigurationWorkspace.AutomationScope)
            case macro(LegacyConfigurationWorkspace.AutomationScope, [Int], MacroSelectionIdentity)
            case sample(KeyboardMacro)
        }

        let title: String
        let kind: Kind
        var children: [MacroOutlineNode]

        init(title: String, kind: Kind, children: [MacroOutlineNode] = []) {
            self.title = title
            self.kind = kind
            self.children = children
        }
    }

    private struct MacroSelectionIdentity: Equatable {
        let id: UUID
        let fingerprint: MacroFingerprint

        init(_ macro: KeyboardMacro) {
            id = macro.id
            fingerprint = MacroFingerprint(macro)
        }

        func matches(_ other: MacroSelectionIdentity) -> Bool {
            id == other.id || fingerprint == other.fingerprint
        }
    }

    private struct MacroFingerprint: Equatable {
        let description: String
        let macro: String
        let key: String
        let typeIntoInput: Bool
        let folder: Bool
        let childrenActive: Bool
        let children: [MacroFingerprint]

        init(_ macro: KeyboardMacro) {
            description = macro.description
            self.macro = macro.macro
            key = macro.key
            typeIntoInput = macro.typeIntoInput
            folder = macro.folder
            childrenActive = macro.childrenActive
            children = macro.children.map(MacroFingerprint.init)
        }
    }

    private struct AliasSelectionIdentity: Equatable {
        var id: UUID
        var fingerprint: AliasFingerprint

        init(_ alias: Alias) {
            id = alias.id
            fingerprint = AliasFingerprint(alias)
        }

        func matches(_ other: AliasSelectionIdentity) -> Bool {
            id == other.id || fingerprint == other.fingerprint
        }
    }

    private struct AliasFingerprint: Equatable {
        var description: String
        var match: MatchDefinition
        var example: String
        var replacement: String
        var folder: Bool
        var active: Bool
        var echo: Bool
        var processCommands: Bool
        var stopProcessing: Bool
        var expandVariables: Bool
        var childrenActive: Bool
        var childrenAfterCount: Int
        var children: [AliasFingerprint]

        init(_ alias: Alias) {
            description = alias.description
            match = alias.match
            example = alias.example
            replacement = alias.replacement
            folder = alias.folder
            active = alias.active
            echo = alias.echo
            processCommands = alias.processCommands
            stopProcessing = alias.stopProcessing
            expandVariables = alias.expandVariables
            childrenActive = alias.childrenActive
            childrenAfterCount = alias.childrenAfterCount
            children = alias.children.map(AliasFingerprint.init)
        }
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
        let size: NSSize = switch kind {
        case .triggers: NSSize(width: 980, height: 700)
        case .aliases: NSSize(width: 1060, height: 680)
        case .macros: NSSize(width: 760, height: 525)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(kind.title) — \(scope.displayName)"
        window.minSize = switch kind {
        case .triggers: NSSize(width: 860, height: 560)
        case .aliases: NSSize(width: 900, height: 560)
        case .macros: NSSize(width: 620, height: 360)
        }
        super.init(window: window)
        window.delegate = self
        let accessibilityIdentifier = switch kind {
        case .aliases: "aliasesEditor"
        case .triggers: "triggersEditor"
        case .macros: "macrosEditor"
        }
        window.setAccessibilityIdentifier(accessibilityIdentifier)
        if kind == .macros {
            let snapshot = library.beginWorkspaceEditor()
            stagedMacroWorkspace = snapshot.workspace
            macroExpectedRevision = snapshot.revision
        }
        configure(in: window)
        reload(selecting: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard kind == .macros, !macroDidClose else { return true }
        macroDidClose = true
        stagedMacroWorkspace = nil
        return true
    }

    private func configure(in window: NSWindow) {
        if kind == .triggers {
            configureTriggerEditor(in: window)
            return
        }
        if kind == .aliases {
            configureAliasEditor(in: window)
            return
        }
        if kind == .macros {
            configureMacroEditor(in: window)
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
        matchField.placeholderString = kind == .macros ? "Control+Option+M or F1" : "Text to match"
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
            "Use macOS modifier names such as Control+Option+M or F1. Config.txt stores Option as the legacy Alt spelling. Edits preserve unknown macro fields and nested folders."
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

    private func configureMacroEditor(in window: NSWindow) {
        window.title = "Keyboard Macros"
        window.minSize = NSSize(width: 700, height: 480)

        for (outline, identifier, label) in [
            (macroOutline, "macroScopeOutline", "Editable keyboard macros"),
            (macroSamplesOutline, "macroSamplesOutline", "Sample keyboard macros"),
        ] {
            outline.headerView = nil
            outline.style = .sourceList
            outline.rowHeight = 22
            outline.addTableColumn(NSTableColumn(identifier: .init(identifier + "Column")))
            outline.outlineTableColumn = outline.tableColumns[0]
            outline.delegate = self
            outline.dataSource = self
            outline.setAccessibilityIdentifier(identifier)
            outline.setAccessibilityLabel(label)
        }
        macroOutline.tableColumns[0].isEditable = true
        macroOutline.onDelete = { [weak self] in self?.removeEntry(nil) }
        macroOutline.registerForDraggedTypes([Self.keyboardMacroPasteboardType])
        macroSamplesOutline.registerForDraggedTypes([Self.keyboardMacroPasteboardType])

        let editableScroll = NSScrollView()
        editableScroll.documentView = macroOutline
        editableScroll.hasVerticalScroller = true
        editableScroll.hasHorizontalScroller = true
        editableScroll.borderType = .bezelBorder
        let sampleScroll = NSScrollView()
        sampleScroll.documentView = macroSamplesOutline
        sampleScroll.hasVerticalScroller = true
        sampleScroll.borderType = .bezelBorder
        sampleScroll.heightAnchor.constraint(equalToConstant: 145).isActive = true

        let sampleHeading = NSTextField(labelWithString: "Samples")
        sampleHeading.font = .systemFont(ofSize: 12, weight: .semibold)
        let new = NSButton(title: "New", target: self, action: #selector(addEntry(_:)))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyMacro(_:)))
        let delete = NSButton(title: "Delete", target: self, action: #selector(removeEntry(_:)))
        let importButton = NSButton(title: "Import…", target: self, action: #selector(importMacros(_:)))
        let exportButton = NSButton(title: "Export…", target: self, action: #selector(exportMacros(_:)))
        for (button, identifier) in [
            (new, "macroNew"), (copy, "macroCopy"), (delete, "macroDelete"),
            (importButton, "macroImport"), (exportButton, "macroExport"),
        ] {
            button.setAccessibilityIdentifier(identifier)
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let buttons = NSStackView(views: [new, copy, delete, importButton, exportButton])
        buttons.orientation = .horizontal
        buttons.spacing = 4
        buttons.distribution = .fillEqually
        let moveUp = NSButton(title: "Up", target: self, action: #selector(moveMacroUp(_:)))
        let moveDown = NSButton(title: "Down", target: self, action: #selector(moveMacroDown(_:)))
        let moveIn = NSButton(title: "In", target: self, action: #selector(moveMacroIn(_:)))
        let moveOut = NSButton(title: "Out", target: self, action: #selector(moveMacroOut(_:)))
        for (button, identifier) in [
            (moveUp, "macroMoveUp"), (moveDown, "macroMoveDown"),
            (moveIn, "macroMoveIn"), (moveOut, "macroMoveOut"),
        ] {
            button.setAccessibilityIdentifier(identifier)
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let moves = NSStackView(views: [moveUp, moveDown, moveIn, moveOut])
        moves.orientation = .horizontal
        moves.spacing = 4
        moves.distribution = .fillEqually
        let left = NSStackView(views: [editableScroll, sampleHeading, sampleScroll, buttons, moves])
        left.orientation = .vertical
        left.spacing = 7
        left.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 8)
        left.widthAnchor.constraint(equalToConstant: 300).isActive = true

        macroActive.setAccessibilityIdentifier("macroProcessKeyboardMacros")
        macroActive.setAccessibilityLabel("Process Keyboard Macros")
        macroActive.target = self
        macroActive.action = #selector(toggleMacroActive(_:))

        descriptionField.placeholderString = "Optional description"
        descriptionField.setAccessibilityIdentifier("macroDescription")
        descriptionField.setAccessibilityLabel("Description")

        macroFolder.setAccessibilityIdentifier("macroFolder")
        macroFolder.setAccessibilityLabel("Treat As Folder")
        macroFolder.target = self
        macroFolder.action = #selector(macroFolderChanged(_:))

        macroTextView.isRichText = false
        macroTextView.isVerticallyResizable = true
        macroTextView.isHorizontallyResizable = false
        macroTextView.autoresizingMask = [.width]
        macroTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        macroTextView.textContainerInset = NSSize(width: 4, height: 4)
        macroTextView.setAccessibilityIdentifier("macroText")
        macroTextView.setAccessibilityLabel("Macro Text")
        let macroTextScroll = NSScrollView()
        macroTextScroll.documentView = macroTextView
        macroTextScroll.hasVerticalScroller = true
        macroTextScroll.hasHorizontalScroller = true
        macroTextScroll.borderType = .bezelBorder
        macroTextScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 125).isActive = true
        macroTextScroll.widthAnchor.constraint(equalToConstant: 390).isActive = true

        macroTypeIntoInput.setAccessibilityIdentifier("macroTypeIntoInput")
        macroTypeIntoInput.setAccessibilityLabel("Type into Input Window")
        macroControl.setAccessibilityIdentifier("macroControl")
        macroAlt.setAccessibilityIdentifier("macroAlt")
        macroAlt.setAccessibilityLabel("Option")
        macroShift.setAccessibilityIdentifier("macroShift")
        for button in [macroTypeIntoInput, macroControl, macroAlt, macroShift] {
            button.target = self
            button.action = #selector(macroControlChanged(_:))
        }

        macroKeyField.isEditable = false
        macroKeyField.isSelectable = false
        macroKeyField.focusRingType = .none
        macroKeyField.placeholderString = "Press a key combination"
        macroKeyField.setAccessibilityIdentifier("macroKeyCapture")
        macroKeyField.setAccessibilityLabel("Keyboard shortcut")
        macroKeyField.setAccessibilityHelp("Click to focus, then press the key combination to assign this macro.")
        macroKeyField.alignment = .left
        macroKeyField.onCapture = { [weak self] key in
            self?.macroKeyField.stringValue = KeyboardMacroKey.displayString(key)
            self?.macroKeyField.setAccessibilityValue(key)
            self?.macroKeyChanged(key)
        }
        macroKeyField.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let keyRow = NSStackView(views: [NSTextField(labelWithString: "Key:"), macroKeyField])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        let modifiers = NSStackView(views: [macroControl, macroAlt, macroShift])
        modifiers.orientation = .horizontal
        modifiers.spacing = 9
        let limitation = NSTextField(wrappingLabelWithString: "Note: Macros assigned to the letters 'A'–'Z' will only work if they have Option or Control modifiers. Command shortcuts are reserved by macOS.")
        limitation.textColor = .secondaryLabelColor
        limitation.maximumNumberOfLines = 0
        limitation.setAccessibilityIdentifier("macroModifierLimitation")

        let form = NSGridView(views: [[
            NSTextField(labelWithString: "Description:"), descriptionField,
        ]])
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 330
        form.rowSpacing = 8

        let detailsHeading = NSTextField(labelWithString: "Keyboard Macros")
        detailsHeading.font = .systemFont(ofSize: 16, weight: .semibold)
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyEntry(_:)))
        apply.setAccessibilityIdentifier("macroApply")
        let ok = NSButton(title: "OK", target: self, action: #selector(acceptMacroEditor(_:)))
        ok.setAccessibilityIdentifier("macroOK")
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelMacroEditor(_:)))
        cancel.setAccessibilityIdentifier("macroCancel")
        let help = NSButton(title: "Help", target: self, action: #selector(openMacroHelp(_:)))
        help.setAccessibilityIdentifier("macroHelp")
        let footer = NSStackView(views: [NSView(), apply, ok, cancel, help])
        footer.orientation = .horizontal
        footer.spacing = 8

        let detail = NSStackView(views: [
            detailsHeading, macroActive, form, macroFolder, NSTextField(labelWithString: "Macro Text:"),
            macroTextScroll, macroTypeIntoInput, keyRow, modifiers, limitation, NSView(), status, footer,
        ])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 8
        detail.edgeInsets = NSEdgeInsets(top: 15, left: 18, bottom: 12, right: 18)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        window.contentView = split
        window.initialFirstResponder = macroOutline
    }

    private func configureAliasEditor(in window: NSWindow) {
        triggerOutline.headerView = nil
        triggerOutline.style = .sourceList
        triggerOutline.rowHeight = 22
        triggerOutline.addTableColumn(NSTableColumn(identifier: .init("aliasOutlineEntry")))
        triggerOutline.outlineTableColumn = triggerOutline.tableColumns[0]
        triggerOutline.delegate = self
        triggerOutline.dataSource = self
        triggerOutline.setAccessibilityIdentifier("aliasScopeOutline")
        triggerOutline.setAccessibilityLabel("Aliases")

        aliasSamplesOutline.headerView = nil
        aliasSamplesOutline.style = .sourceList
        aliasSamplesOutline.rowHeight = 22
        aliasSamplesOutline.addTableColumn(NSTableColumn(identifier: .init("aliasSamplesEntry")))
        aliasSamplesOutline.outlineTableColumn = aliasSamplesOutline.tableColumns[0]
        aliasSamplesOutline.delegate = self
        aliasSamplesOutline.dataSource = self
        aliasSamplesOutline.setAccessibilityIdentifier("aliasSamplesOutline")
        aliasSamplesOutline.setAccessibilityLabel("Sample aliases")

        let userScroll = NSScrollView()
        userScroll.documentView = triggerOutline
        userScroll.hasVerticalScroller = true
        userScroll.hasHorizontalScroller = true
        userScroll.borderType = .bezelBorder
        let sampleScroll = NSScrollView()
        sampleScroll.documentView = aliasSamplesOutline
        sampleScroll.hasVerticalScroller = true
        sampleScroll.borderType = .bezelBorder
        let sampleHeading = NSTextField(labelWithString: "Samples")
        sampleHeading.font = .systemFont(ofSize: 12, weight: .semibold)

        // NSScrollView has no intrinsic height. Give both trees space in the
        // vertical sidebar so the read-only sample catalog cannot collapse to
        // zero rows on shorter windows.
        userScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        sampleScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true

        aliasAfterCount.controlSize = .small
        aliasAfterCount.widthAnchor.constraint(equalToConstant: 52).isActive = true
        aliasAfterCount.setAccessibilityIdentifier("aliasAfterCount")
        aliasScopeApply.target = self
        aliasScopeApply.action = #selector(applyAliasScopeSettings(_:))
        aliasScopeApply.setAccessibilityIdentifier("aliasScopeApply")
        aliasScopeApply.controlSize = .small
        let scopeSettings = NSStackView(views: [
            NSTextField(labelWithString: "Post count:"),
            aliasAfterCount,
            aliasScopeApply,
        ])
        scopeSettings.orientation = .vertical
        scopeSettings.alignment = .leading
        scopeSettings.spacing = 3

        let new = NSButton(title: "New", target: self, action: #selector(addEntry(_:)))
        let copy = NSButton(title: "Copy", target: self, action: #selector(copyAlias(_:)))
        let delete = NSButton(title: "Delete", target: self, action: #selector(removeEntry(_:)))
        let moveUp = NSButton(title: "Up", target: self, action: #selector(moveAliasUp(_:)))
        let moveDown = NSButton(title: "Down", target: self, action: #selector(moveAliasDown(_:)))
        let moveIn = NSButton(title: "In", target: self, action: #selector(moveAliasIn(_:)))
        let moveOut = NSButton(title: "Out", target: self, action: #selector(moveAliasOut(_:)))
        let importButton = NSButton(title: "Import…", target: self, action: #selector(importAliases(_:)))
        let exportButton = NSButton(title: "Export…", target: self, action: #selector(exportAliases(_:)))
        for (button, identifier) in [
            (new, "aliasNew"), (copy, "aliasCopy"), (delete, "aliasDelete"),
            (moveUp, "aliasMoveUp"), (moveDown, "aliasMoveDown"),
            (moveIn, "aliasMoveIn"), (moveOut, "aliasMoveOut"),
            (importButton, "aliasImport"), (exportButton, "aliasExport"),
        ] {
            button.setAccessibilityIdentifier(identifier)
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let buttons = NSStackView(views: [new, copy, delete, importButton, exportButton])
        buttons.orientation = .horizontal
        buttons.spacing = 4
        let moves = NSStackView(views: [moveUp, moveDown, moveIn, moveOut])
        moves.orientation = .horizontal
        moves.spacing = 4
        let left = NSStackView(views: [userScroll, sampleHeading, sampleScroll, scopeSettings, buttons, moves])
        left.orientation = .vertical
        left.alignment = .width
        left.spacing = 7
        left.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 8)
        left.widthAnchor.constraint(equalToConstant: 390).isActive = true

        let detail = AliasDetailView()
        aliasDetail = detail
        let heading = NSTextField(labelWithString: "Aliases")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "Changes are written to Config.txt and propagated to open sessions when you press Apply.")
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyEntry(_:)))
        apply.keyEquivalent = "\r"
        apply.setAccessibilityIdentifier("aliasApply")
        let help = NSButton(title: "Help", target: self, action: #selector(openAliasHelp(_:)))
        help.setAccessibilityIdentifier("aliasHelp")
        status.setAccessibilityIdentifier("aliasEditorStatus")
        let right = NSStackView(views: [heading, detail, note, NSView(), status, NSStackView(views: [apply, help])])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        right.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        window.contentView = split
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

    private struct MacroDragPayload: Codable {
        var scope: String?
        var path: [Int]?
        var sample: KeyboardMacro?
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard kind == .macros, let node = item as? MacroOutlineNode else { return nil }
        let payload: MacroDragPayload
        switch node.kind {
        case let .macro(scope, path, _):
            payload = .init(scope: macroScopeToken(scope), path: path, sample: nil)
        case let .sample(macro):
            payload = .init(scope: nil, path: nil, sample: macro)
        case .scope:
            return nil
        }
        guard let data = try? JSONEncoder().encode(payload),
              let string = String(data: data, encoding: .utf8) else { return nil }
        let item = NSPasteboardItem()
        item.setString(string, forType: Self.keyboardMacroPasteboardType)
        return item
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard kind == .macros,
              let value = info.draggingPasteboard.string(forType: Self.keyboardMacroPasteboardType),
              let payload = decodeMacroDragPayload(value) else { return [] }
        return payload.sample == nil ? .move : .copy
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard kind == .macros,
              let value = info.draggingPasteboard.string(forType: Self.keyboardMacroPasteboardType),
              let payload = decodeMacroDragPayload(value),
              let destination = macroDropDestination(item: item, index: index) else { return false }
        stageMacroFormIfNeeded()
        do {
            var candidate = macroWorkspace
            let moved: [Int]
            if let sample = payload.sample {
                moved = try candidate.addMacro(
                    in: destination.scope,
                    parentPath: destination.parentPath,
                    macro: sample
                )
            } else if let scopeToken = payload.scope,
                      let path = payload.path,
                      let sourceScope = macroScope(from: scopeToken) {
                moved = try candidate.moveMacro(
                    at: path,
                    in: sourceScope,
                    to: destination.scope,
                    parentPath: destination.parentPath,
                    index: destination.index
                )
            } else {
                return false
            }
            stagedMacroWorkspace = candidate
            reloadMacroOutline(selecting: macroSelectionKey(scope: destination.scope, path: moved))
            return true
        } catch {
            present(error)
            return false
        }
    }

    private static let keyboardMacroPasteboardType = NSPasteboard.PasteboardType("com.beipmu.keyboard-macro")

    private func macroScopeToken(_ scope: LegacyConfigurationWorkspace.AutomationScope) -> String {
        switch scope {
        case .global: return "global"
        case let .server(serverID): return "server:\(serverID.uuidString)"
        case let .character(serverID, characterID): return "character:\(serverID.uuidString):\(characterID.uuidString)"
        case let .puppet(serverID, characterID, puppetID): return "puppet:\(serverID.uuidString):\(characterID.uuidString):\(puppetID.uuidString)"
        }
    }

    private func macroScope(from token: String) -> LegacyConfigurationWorkspace.AutomationScope? {
        let parts = token.split(separator: ":").map(String.init)
        switch parts.first {
        case "global": return .global
        case "server" where parts.count == 2: return UUID(uuidString: parts[1]).map(LegacyConfigurationWorkspace.AutomationScope.server)
        case "character" where parts.count == 3:
            guard let server = UUID(uuidString: parts[1]), let character = UUID(uuidString: parts[2]) else { return nil }
            return .character(server: server, character: character)
        case "puppet" where parts.count == 4:
            guard let server = UUID(uuidString: parts[1]), let character = UUID(uuidString: parts[2]), let puppet = UUID(uuidString: parts[3]) else { return nil }
            return .puppet(server: server, character: character, puppet: puppet)
        default: return nil
        }
    }

    private func decodeMacroDragPayload(_ value: String) -> MacroDragPayload? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MacroDragPayload.self, from: data)
    }

    private func macroDropDestination(item: Any?, index: Int) -> (scope: LegacyConfigurationWorkspace.AutomationScope, parentPath: [Int], index: Int)? {
        guard let node = item as? MacroOutlineNode else {
            return (
                macroDestinationScope ?? macroEditingScope,
                macroDestinationParentPath,
                max(0, index)
            )
        }
        switch node.kind {
        case let .scope(scope):
            return (scope, [], max(0, index))
        case let .macro(scope, path, identity):
            let parent = identity.fingerprint.folder ? path : Array(path.dropLast())
            return (scope, parent, max(0, index))
        case .sample:
            return nil
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
        if kind == .macros {
            let node = item as? MacroOutlineNode
            return (node?.children ?? (outlineView === macroSamplesOutline ? macroSampleNodes : macroOutlineNodes)).count
        }
        if kind == .aliases {
            let node = item as? AliasOutlineNode
            return (node?.children ?? (outlineView === aliasSamplesOutline ? aliasSampleNodes : aliasOutlineNodes)).count
        }
        let node = item as? TriggerOutlineNode
        return (node?.children ?? triggerOutlineNodes).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if kind == .macros {
            let node = item as? MacroOutlineNode
            return (node?.children ?? (outlineView === macroSamplesOutline ? macroSampleNodes : macroOutlineNodes))[index]
        }
        if kind == .aliases {
            let node = item as? AliasOutlineNode
            return (node?.children ?? (outlineView === aliasSamplesOutline ? aliasSampleNodes : aliasOutlineNodes))[index]
        }
        let node = item as? TriggerOutlineNode
        return (node?.children ?? triggerOutlineNodes)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if kind == .macros {
            return (item as? MacroOutlineNode)?.children.isEmpty == false
        }
        if kind == .aliases {
            return (item as? AliasOutlineNode)?.children.isEmpty == false
        }
        guard let node = item as? TriggerOutlineNode else { return false }
        return !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if kind == .macros, let node = item as? MacroOutlineNode {
            let identifier = NSUserInterfaceItemIdentifier("macroOutlineRow")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
                let result = NSTableCellView()
                result.identifier = identifier
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.imageScaling = .scaleProportionallyDown
                let text = NSTextField()
                text.isEditable = outlineView === macroOutline
                text.isSelectable = outlineView === macroOutline
                text.isBordered = false
                text.drawsBackground = false
                text.translatesAutoresizingMaskIntoConstraints = false
                result.addSubview(image)
                result.addSubview(text)
                result.imageView = image
                result.textField = text
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: result.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: result.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
                    text.trailingAnchor.constraint(equalTo: result.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: result.centerYAnchor),
                ])
                return result
            }()
            view.textField?.stringValue = node.title
            switch node.kind {
            case let .scope(scope):
                let symbol: String
                switch scope {
                case .global: symbol = "globe"
                case .server: symbol = "network"
                case .character: symbol = "person"
                case .puppet: symbol = "person.2"
                }
                view.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Scope")
            case let .macro(_, _, identity):
                view.imageView?.image = identity.fingerprint.folder
                    ? NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
                    : NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Macro")
            case .sample:
                view.imageView?.image = NSImage(systemSymbolName: "star", accessibilityDescription: "Sample")
            }
            return view
        }
        if kind == .aliases, let node = item as? AliasOutlineNode {
            let identifier = NSUserInterfaceItemIdentifier("aliasOutlineRow")
            let view = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
                let result = NSTableCellView()
                result.identifier = identifier
                let text = NSTextField(labelWithString: "")
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
            return view
        }
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

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldEdit tableColumn: NSTableColumn?,
        item: Any
    ) -> Bool {
        guard kind == .macros,
              outlineView === macroOutline,
              let node = item as? MacroOutlineNode else { return false }
        guard case .macro = node.kind else { return false }
        return true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        setObjectValue object: Any?,
        for tableColumn: NSTableColumn?,
        byItem item: Any?
    ) {
        guard kind == .macros,
              outlineView === macroOutline,
              let title = object as? String,
              let node = item as? MacroOutlineNode,
              case let .macro(scope, path, _) = node.kind,
              let existing = macroWorkspace.macro(at: path, in: scope) else { return }
        do {
            var candidate = macroWorkspace
            var updated = existing
            updated.description = title
            try candidate.updateMacro(at: path, in: scope, macro: updated)
            stagedMacroWorkspace = candidate
            reloadMacroOutline(selecting: macroSelectionKey(scope: scope, path: path))
        } catch {
            present(error)
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if kind == .macros {
            if !isReloadingMacroOutline { stageMacroFormIfNeeded() }
            if notification.object as? NSOutlineView === macroSamplesOutline {
                guard macroSamplesOutline.selectedRow >= 0,
                      let node = macroSamplesOutline.item(atRow: macroSamplesOutline.selectedRow) as? MacroOutlineNode,
                      case let .sample(macro) = node.kind else { return }
                macroSampleSelected = true
                selectedMacroPath = nil
                selectedMacroIdentity = nil
                loadMacroSample(macro)
                return
            }
            guard notification.object as? NSOutlineView === macroOutline else { return }
            guard macroOutline.selectedRow >= 0,
                  let node = macroOutline.item(atRow: macroOutline.selectedRow) as? MacroOutlineNode else {
                selectedMacroScope = nil
                selectedMacroPath = nil
                selectedMacroIdentity = nil
                clearFields()
                return
            }
            switch node.kind {
            case let .scope(scope):
                macroSampleSelected = false
                selectedMacroScope = scope
                selectedMacroPath = nil
                selectedMacroIdentity = nil
                macroDestinationScope = scope
                macroDestinationParentPath = []
                loadMacroScope(scope)
                clearFields()
            case let .macro(scope, path, identity):
                macroSampleSelected = false
                selectedMacroScope = scope
                selectedMacroPath = path
                selectedMacroIdentity = identity
                macroDestinationScope = scope
                macroDestinationParentPath = macroWorkspace.macro(at: path, in: scope)?.folder == true
                    ? path
                    : Array(path.dropLast())
                loadMacro(at: path, in: scope)
            case .sample:
                break
            }
            return
        }
        if kind == .aliases {
            guard notification.object as? NSOutlineView === triggerOutline else { return }
            guard triggerOutline.selectedRow >= 0,
                  let node = triggerOutline.item(atRow: triggerOutline.selectedRow) as? AliasOutlineNode else {
                selectedAliasScope = nil
                selectedAliasPath = nil
                selectedAliasIdentity = nil
                clearFields()
                return
            }
            switch node.kind {
            case let .scope(scope):
                selectedAliasScope = scope
                selectedAliasPath = nil
                selectedAliasIdentity = nil
                loadAliasScopeSettings(scope)
                clearFields()
            case let .alias(scope, path, identity):
                selectedAliasScope = scope
                selectedAliasPath = path
                selectedAliasIdentity = identity
                loadAliasScopeSettings(scope)
                aliasDetail?.load(library.workspace.alias(at: path, in: scope) ?? .init(match: .init(text: ""), replacement: ""))
            case .sample:
                break
            }
            return
        }
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
        if kind == .macros {
            stageMacroFormIfNeeded()
            let targetScope = macroDestinationScope ?? selectedMacroScope ?? macroEditingScope
            let parentPath = macroDestinationParentPath
            do {
                let added: [Int]
                var candidate = macroWorkspace
                added = try candidate.addMacro(
                    in: targetScope,
                    parentPath: parentPath,
                    macro: .init(description: "New Macro", macro: "", key: "Control+Option+M")
                )
                stagedMacroWorkspace = candidate
                reloadMacroOutline(selecting: macroSelectionKey(scope: targetScope, path: added))
            } catch { present(error) }
            return
        }
        if kind == .aliases {
            let targetScope = selectedAliasScope ?? scope
            let parentPath = selectedAliasPath ?? []
            do {
                var added: [Int] = []
                try library.mutate {
                    added = try $0.addAlias(in: targetScope, parentPath: parentPath, description: kind.emptyTitle)
                }
                reloadAliasOutline(selecting: aliasSelectionKey(scope: targetScope, aliasPath: added))
            } catch { present(error) }
            return
        }
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
        if kind == .macros {
            stageMacroFormIfNeeded()
            guard let selectedMacroPath, let selectedMacroScope else { NSSound.beep(); return }
            let parentPath = Array(selectedMacroPath.dropLast())
            do {
                var candidate = macroWorkspace
                _ = try candidate.removeMacro(at: selectedMacroPath, in: selectedMacroScope)
                stagedMacroWorkspace = candidate
                reloadMacroOutline(selecting: macroSelectionKey(
                    scope: selectedMacroScope,
                    path: parentPath.isEmpty ? nil : parentPath
                ))
            } catch { present(error) }
            return
        }
        if kind == .aliases {
            guard let selectedAliasPath, let selectedAliasScope else { NSSound.beep(); return }
            let parentPath = Array(selectedAliasPath.dropLast())
            do {
                try library.mutate {
                    _ = try $0.removeAlias(at: selectedAliasPath, in: selectedAliasScope)
                }
                reloadAliasOutline(selecting: aliasSelectionKey(
                    scope: selectedAliasScope,
                    aliasPath: parentPath.isEmpty ? nil : parentPath
                ))
            } catch { present(error) }
            return
        }
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
        if kind == .macros {
            _ = applyMacroChanges()
            return
        }
        if kind == .aliases {
            guard let aliasDetail, let selectedAliasScope, let selectedAliasPath,
                  let existing = library.workspace.alias(at: selectedAliasPath, in: selectedAliasScope) else {
                NSSound.beep()
                return
            }
            do {
                try aliasDetail.validateForApply()
                let updated = aliasDetail.updatedAlias(preserving: existing)
                try library.mutate {
                    try $0.updateAlias(at: selectedAliasPath, in: selectedAliasScope, alias: updated)
                }
                status.stringValue = "Applied and saved."
                reloadAliasOutline(selecting: aliasSelectionKey(scope: selectedAliasScope, aliasPath: selectedAliasPath))
            } catch {
                status.stringValue = error.localizedDescription
                NSSound.beep()
            }
            return
        }
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

    @objc private func copyAlias(_ sender: Any?) {
        guard kind == .aliases else { return }
        let sample: Alias? = {
            guard aliasSamplesOutline.selectedRow >= 0,
                  let node = aliasSamplesOutline.item(atRow: aliasSamplesOutline.selectedRow) as? AliasOutlineNode,
                  case let .sample(alias) = node.kind else { return nil }
            return alias
        }()
        let source: Alias?
        let targetScope: LegacyConfigurationWorkspace.AutomationScope
        let parentPath: [Int]
        if let sample {
            source = sample
            targetScope = selectedAliasScope ?? scope
            parentPath = selectedAliasPath ?? []
        } else if let selectedAliasPath, let selectedAliasScope {
            source = library.workspace.alias(at: selectedAliasPath, in: selectedAliasScope)
            targetScope = selectedAliasScope
            parentPath = Array(selectedAliasPath.dropLast())
        } else {
            NSSound.beep()
            return
        }
        guard let source else { NSSound.beep(); return }
        var copy = source
        if sample != nil {
            copy.description = source.description.isEmpty ? "Sample alias" : source.description
        } else {
            copy.description = source.description.isEmpty ? "Copy of \(source.match.text)" : "Copy of \(source.description)"
        }
        do {
            var added: [Int] = []
            try library.mutate {
                added = try $0.addAlias(in: targetScope, parentPath: parentPath, alias: copy)
            }
            reloadAliasOutline(selecting: aliasSelectionKey(scope: targetScope, aliasPath: added))
        } catch { present(error) }
    }

    @objc private func copyMacro(_ sender: Any?) {
        guard kind == .macros else { return }
        stageMacroFormIfNeeded()
        let sample: KeyboardMacro? = {
            guard macroSamplesOutline.selectedRow >= 0,
                  let node = macroSamplesOutline.item(atRow: macroSamplesOutline.selectedRow) as? MacroOutlineNode,
                  case let .sample(macro) = node.kind else { return nil }
            return macro
        }()
        do {
            let targetScope = macroDestinationScope ?? selectedMacroScope ?? macroEditingScope
            let parentPath = macroDestinationParentPath
            var candidate = macroWorkspace
            let added: [Int]
            if let sample {
                added = try candidate.addMacro(in: targetScope, parentPath: parentPath, macro: sample)
            } else if let selectedMacroPath, let selectedMacroScope {
                added = try candidate.copyMacro(
                    at: selectedMacroPath,
                    in: selectedMacroScope,
                    to: selectedMacroScope,
                    parentPath: Array(selectedMacroPath.dropLast())
                )
            } else {
                NSSound.beep()
                return
            }
            stagedMacroWorkspace = candidate
            reloadMacroOutline(selecting: macroSelectionKey(scope: targetScope, path: added))
        } catch { present(error) }
    }

    @objc private func moveMacroUp(_ sender: Any?) {
        guard let path = selectedMacroPath, let index = path.last, index > 0 else { NSSound.beep(); return }
        moveSelectedMacro(toParentPath: Array(path.dropLast()), index: index - 1)
    }

    @objc private func moveMacroDown(_ sender: Any?) {
        guard let path = selectedMacroPath, let scope = selectedMacroScope, let index = path.last else { NSSound.beep(); return }
        let parent = Array(path.dropLast())
        let count = parent.isEmpty
            ? macroWorkspace.macros(in: scope).count
            : macroWorkspace.macro(at: parent, in: scope)?.children.count ?? 0
        guard index + 1 < count else { NSSound.beep(); return }
        moveSelectedMacro(toParentPath: parent, index: index + 1)
    }

    @objc private func moveMacroIn(_ sender: Any?) {
        guard let path = selectedMacroPath, let index = path.last, index > 0 else { NSSound.beep(); return }
        let parent = Array(path.dropLast())
        let destination = parent + [index - 1]
        let count = macroWorkspace.macro(at: destination, in: selectedMacroScope ?? macroEditingScope)?.children.count ?? 0
        moveSelectedMacro(toParentPath: destination, index: count)
    }

    @objc private func moveMacroOut(_ sender: Any?) {
        guard let path = selectedMacroPath, path.count > 1, let parentIndex = path.dropLast().last else {
            NSSound.beep()
            return
        }
        let parent = Array(path.dropLast())
        moveSelectedMacro(toParentPath: Array(parent.dropLast()), index: parentIndex + 1)
    }

    private func moveSelectedMacro(toParentPath destinationParentPath: [Int], index destinationIndex: Int) {
        guard let sourcePath = selectedMacroPath, let selectedMacroScope else { NSSound.beep(); return }
        stageMacroFormIfNeeded()
        do {
            var candidate = macroWorkspace
            let moved = try candidate.moveMacro(
                at: sourcePath,
                in: selectedMacroScope,
                to: selectedMacroScope,
                parentPath: destinationParentPath,
                index: destinationIndex
            )
            stagedMacroWorkspace = candidate
            reloadMacroOutline(selecting: macroSelectionKey(scope: selectedMacroScope, path: moved))
        } catch { present(error) }
    }

    @objc private func moveAliasUp(_ sender: Any?) {
        guard let selectedAliasPath, let index = selectedAliasPath.last, index > 0 else { NSSound.beep(); return }
        moveSelectedAlias(toParentPath: Array(selectedAliasPath.dropLast()), index: index - 1)
    }

    @objc private func moveAliasDown(_ sender: Any?) {
        guard let selectedAliasPath, let selectedAliasScope, let index = selectedAliasPath.last else { NSSound.beep(); return }
        let parent = Array(selectedAliasPath.dropLast())
        let count = parent.isEmpty
            ? library.workspace.aliases(in: selectedAliasScope).count
            : library.workspace.alias(at: parent, in: selectedAliasScope)?.children.count ?? 0
        guard index + 1 < count else { NSSound.beep(); return }
        moveSelectedAlias(toParentPath: parent, index: index + 1)
    }

    @objc private func moveAliasIn(_ sender: Any?) {
        guard let selectedAliasPath, let index = selectedAliasPath.last, index > 0 else { NSSound.beep(); return }
        let parent = Array(selectedAliasPath.dropLast())
        let destination = parent + [index - 1]
        moveSelectedAlias(toParentPath: destination, index: aliasCount(inParentPath: destination))
    }

    @objc private func moveAliasOut(_ sender: Any?) {
        guard let selectedAliasPath, selectedAliasPath.count > 1 else { NSSound.beep(); return }
        let parent = Array(selectedAliasPath.dropLast())
        guard let parentIndex = parent.last else { NSSound.beep(); return }
        moveSelectedAlias(toParentPath: Array(parent.dropLast()), index: parentIndex + 1)
    }

    private func moveSelectedAlias(toParentPath destinationParentPath: [Int], index destinationIndex: Int) {
        guard let selectedAliasPath, let selectedAliasScope else { NSSound.beep(); return }
        do {
            var moved: [Int] = []
            try library.mutate {
                moved = try $0.moveAlias(
                    at: selectedAliasPath,
                    in: selectedAliasScope,
                    toParentPath: destinationParentPath,
                    index: destinationIndex
                )
            }
            reloadAliasOutline(selecting: aliasSelectionKey(scope: selectedAliasScope, aliasPath: moved))
        } catch { present(error) }
    }

    private func aliasCount(inParentPath parentPath: [Int]) -> Int {
        guard let selectedAliasScope else { return 0 }
        if parentPath.isEmpty { return library.workspace.aliases(in: selectedAliasScope).count }
        return library.workspace.alias(at: parentPath, in: selectedAliasScope)?.children.count ?? 0
    }

    @objc private func applyAliasScopeSettings(_ sender: Any?) {
        guard kind == .aliases, let selectedAliasScope else { return }
        do {
            let group = library.workspace.aliasGroup(in: selectedAliasScope)
            try library.mutate {
                try $0.updateAliasGroupSettings(
                    in: selectedAliasScope,
                    active: group.active,
                    echo: group.echo,
                    processCommands: group.processCommands,
                    afterCount: max(0, aliasAfterCount.integerValue)
                )
            }
            status.stringValue = "Post count saved."
            reloadAliasOutline(selecting: aliasSelectionKey(
                scope: selectedAliasScope,
                aliasPath: selectedAliasPath,
                aliasIdentity: selectedAliasIdentity
            ))
        } catch { present(error) }
    }

    @objc private func importAliases(_ sender: Any?) {
        guard kind == .aliases else { return }
        let targetScope = selectedAliasScope ?? scope
        let parentPath = selectedAliasPath ?? []
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText]
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.performAliasImport(from: url, into: targetScope, parentPath: parentPath) }
        }
    }

    @objc private func importMacros(_ sender: Any?) {
        guard kind == .macros else { return }
        stageMacroFormIfNeeded()
        let targetScope = macroDestinationScope ?? selectedMacroScope ?? macroEditingScope
        let parentPath = macroDestinationParentPath
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.message = "Import keyboard macros into \(macroScopeTitle(targetScope))."
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.performMacroImport(from: url, into: targetScope, parentPath: parentPath) }
        }
    }

    @objc private func exportMacros(_ sender: Any?) {
        guard kind == .macros else { return }
        stageMacroFormIfNeeded()
        let targetScope = selectedMacroScope ?? macroEditingScope
        let targetPath = selectedMacroPath
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(macroScopeTitle(targetScope))-macros.txt"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.performMacroExport(to: url, from: targetScope, path: targetPath) }
        }
    }

    @objc private func openMacroHelp(_ sender: Any?) {
        guard let url = Bundle.module.url(forResource: "Macros", withExtension: "md") else {
            status.stringValue = "Macro help is unavailable."
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func exportAliases(_ sender: Any?) {
        guard kind == .aliases else { return }
        let targetScope = selectedAliasScope ?? scope
        let targetPath = selectedAliasPath
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(aliasScopeTitle(targetScope))-aliases.txt"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.performAliasExport(to: url, from: targetScope, path: targetPath) }
        }
    }

    @objc private func openAliasHelp(_ sender: Any?) {
        guard let url = Bundle.module.url(forResource: "Aliases", withExtension: "md") else {
            status.stringValue = "Alias help is unavailable."
            return
        }
        NSWorkspace.shared.open(url)
    }

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
        if kind == .aliases {
            reloadAliasOutline(selecting: aliasSelectionKey(
                scope: selectedAliasScope ?? scope,
                aliasPath: index.map { [$0] }
            ))
            return
        }
        if kind == .triggers {
            reloadTriggerOutline(selecting: triggerSelectionKey(scope: scope, triggerPath: index.map { [$0] }))
            return
        }
        reloadMacroOutline(selecting: index.map { macroSelectionKey(scope: selectedMacroScope ?? macroEditingScope, path: [$0]) })
    }

    private var macroWorkspace: LegacyConfigurationWorkspace {
        stagedMacroWorkspace ?? library.workspace
    }

    private var macroEditingScope: LegacyConfigurationWorkspace.AutomationScope {
        switch scope {
        case let .puppet(serverID, characterID, _):
            return .character(server: serverID, character: characterID)
        default:
            return scope
        }
    }

    private func macroScopeTitle(_ scope: LegacyConfigurationWorkspace.AutomationScope) -> String {
        switch scope {
        case .global:
            return "Global"
        case let .server(serverID):
            return macroWorkspace.servers.first { $0.profile.id == serverID }?.profile.name ?? "World"
        case let .character(serverID, characterID):
            guard let server = macroWorkspace.servers.first(where: { $0.profile.id == serverID }),
                  let character = server.characters.first(where: { $0.id == characterID }) else { return "Character" }
            return "\(server.profile.name)-\(character.name)"
        case .puppet:
            return "Character"
        }
    }

    private func makeMacroOutlineNodes() -> [MacroOutlineNode] {
        var roots = [scopeMacroNode("Global", scope: .global)]
        for server in macroWorkspace.servers {
            let serverScope: LegacyConfigurationWorkspace.AutomationScope = .server(server.profile.id)
            let serverNode = scopeMacroNode(server.profile.name, scope: serverScope)
            for character in server.characters {
                let characterScope: LegacyConfigurationWorkspace.AutomationScope = .character(
                    server: server.profile.id,
                    character: character.id
                )
                serverNode.children.append(scopeMacroNode(character.name, scope: characterScope))
            }
            roots.append(serverNode)
        }
        return roots
    }

    private func scopeMacroNode(
        _ title: String,
        scope: LegacyConfigurationWorkspace.AutomationScope
    ) -> MacroOutlineNode {
        MacroOutlineNode(
            title: title,
            kind: .scope(scope),
            children: macroNodes(macroWorkspace.macros(in: scope), scope: scope, parentPath: [])
        )
    }

    private func macroNodes(
        _ macros: [KeyboardMacro],
        scope: LegacyConfigurationWorkspace.AutomationScope,
        parentPath: [Int]
    ) -> [MacroOutlineNode] {
        macros.enumerated().map { index, macro in
            let path = parentPath + [index]
            let title: String
            if !macro.description.isEmpty {
                title = macro.description
            } else if macro.folder {
                title = "Folder"
            } else if macro.key.isEmpty {
                title = "(No Key)"
            } else {
                title = KeyboardMacroKey.displayString(macro.key)
            }
            return MacroOutlineNode(
                title: title,
                kind: .macro(scope, path, MacroSelectionIdentity(macro)),
                children: macroNodes(macro.children, scope: scope, parentPath: path)
            )
        }
    }

    private func makeMacroSampleNodes() -> [MacroOutlineNode] {
        guard let url = Bundle.module.url(forResource: "SampleConfig", withExtension: "txt"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let sampleWorkspace = try? LegacyConfigurationWorkspace(document: .init(source: source)) else {
            return []
        }
        return sampleWorkspace.globalMacros.map { macro in
            macroSampleNode(macro)
        }
    }

    private func macroSampleNode(_ macro: KeyboardMacro) -> MacroOutlineNode {
        let title = macro.description.isEmpty
            ? (macro.key.isEmpty ? "(No Key)" : KeyboardMacroKey.displayString(macro.key))
            : macro.description
        return MacroOutlineNode(
            title: title,
            kind: .sample(macro),
            children: macro.children.map(macroSampleNode)
        )
    }

    private func macroSelectionKey(
        scope: LegacyConfigurationWorkspace.AutomationScope,
        path: [Int]?,
        identity: MacroSelectionIdentity? = nil
    ) -> MacroSelectionKey {
        .init(
            scope: scope,
            path: macroScopePath(scope),
            macroPath: path,
            macroIdentity: identity ?? path.flatMap { macroWorkspace.macro(at: $0, in: scope) }.map(MacroSelectionIdentity.init)
        )
    }

    private struct MacroSelectionKey: Equatable {
        let scope: LegacyConfigurationWorkspace.AutomationScope
        let path: [String]
        var macroPath: [Int]?
        var macroIdentity: MacroSelectionIdentity?
    }

    private func macroScopePath(_ scope: LegacyConfigurationWorkspace.AutomationScope) -> [String] {
        switch scope {
        case .global:
            return ["Global"]
        case let .server(serverID):
            return [macroWorkspace.servers.first { $0.profile.id == serverID }?.profile.name ?? "World"]
        case let .character(serverID, characterID):
            guard let server = macroWorkspace.servers.first(where: { $0.profile.id == serverID }),
                  let character = server.characters.first(where: { $0.id == characterID }) else {
                return ["World", "Character"]
            }
            return [server.profile.name, character.name]
        case .puppet:
            return ["World", "Character"]
        }
    }

    private func rowForMacroSelection(_ selection: MacroSelectionKey) -> Int? {
        for row in 0..<macroOutline.numberOfRows {
            guard let node = macroOutline.item(atRow: row) as? MacroOutlineNode else { continue }
            switch node.kind {
            case let .scope(nodeScope) where selection.macroPath == nil && (nodeScope == selection.scope || macroScopePath(nodeScope) == selection.path):
                return row
            case let .macro(nodeScope, nodePath, identity) where nodeScope == selection.scope || macroScopePath(nodeScope) == selection.path:
                if selection.macroIdentity?.matches(identity) == true || selection.macroPath == nodePath { return row }
            default:
                continue
            }
        }
        return nil
    }

    private func reloadMacroOutline(selecting selection: MacroSelectionKey?) {
        isReloadingMacroOutline = true
        defer { isReloadingMacroOutline = false }
        if macroExpansionStateInitialized {
            expandedMacroKeys = Set((0..<macroOutline.numberOfRows).compactMap { row in
                guard macroOutline.isItemExpanded(macroOutline.item(atRow: row)) else { return nil }
                return macroExpansionKey(macroOutline.item(atRow: row))
            })
        }
        macroOutlineNodes = makeMacroOutlineNodes()
        macroSampleNodes = makeMacroSampleNodes()
        macroOutline.reloadData()
        macroSamplesOutline.reloadData()
        if macroExpansionStateInitialized {
            for row in 0..<macroOutline.numberOfRows {
                let item = macroOutline.item(atRow: row)
                if expandedMacroKeys.contains(macroExpansionKey(item)) {
                    macroOutline.expandItem(item, expandChildren: false)
                }
            }
        } else {
            macroOutlineNodes.forEach { macroOutline.expandItem($0, expandChildren: true) }
        }
        macroExpansionStateInitialized = true
        macroSampleNodes.forEach { macroSamplesOutline.expandItem($0, expandChildren: true) }
        let fallback = selection ?? macroSelectionKey(
            scope: selectedMacroScope ?? macroEditingScope,
            path: selectedMacroPath,
            identity: selectedMacroIdentity
        )
        expandMacroAncestors(for: fallback)
        if let row = rowForMacroSelection(fallback) {
            macroOutline.selectRowIndexes(.init(integer: row), byExtendingSelection: false)
            macroOutline.scrollRowToVisible(row)
            outlineViewSelectionDidChange(.init(
                name: NSOutlineView.selectionDidChangeNotification,
                object: macroOutline
            ))
        } else {
            selectedMacroScope = fallback.scope
            selectedMacroPath = nil
            selectedMacroIdentity = nil
            loadMacroScope(fallback.scope)
            clearFields()
        }
    }

    private func expandMacroAncestors(for selection: MacroSelectionKey) {
        guard let scopeNode = macroOutlineNodes.first(where: {
            if case let .scope(scope) = $0.kind { return scope == selection.scope }
            return false
        }) else { return }
        macroOutline.expandItem(scopeNode, expandChildren: false)
        guard let path = selection.macroPath else { return }
        var node = scopeNode
        for index in path.dropLast() {
            guard node.children.indices.contains(index) else { return }
            node = node.children[index]
            macroOutline.expandItem(node, expandChildren: false)
        }
    }

    private func macroExpansionKey(_ item: Any?) -> String {
        guard let node = item as? MacroOutlineNode else { return "" }
        switch node.kind {
        case let .scope(scope): return "scope:\(macroScopeToken(scope))"
        case let .macro(scope, path, _): return "macro:\(macroScopeToken(scope)):\(path.map(String.init).joined(separator: "."))"
        case .sample: return "sample:\(node.title)"
        }
    }

    private func loadMacroScope(_ scope: LegacyConfigurationWorkspace.AutomationScope) {
        macroActive.state = macroWorkspace.macroGroup(in: .global).active ? .on : .off
        macroActive.isEnabled = true
        descriptionField.isEnabled = false
        macroFolder.isEnabled = false
        macroTextView.isEditable = false
        macroKeyField.isEnabled = false
        macroTypeIntoInput.isEnabled = false
        macroControl.isEnabled = false
        macroAlt.isEnabled = false
        macroShift.isEnabled = false
    }

    private var macroKeyCanonical = ""

    private func loadMacro(at path: [Int], in scope: LegacyConfigurationWorkspace.AutomationScope) {
        guard let macro = macroWorkspace.macro(at: path, in: scope) else {
            clearFields()
            return
        }
        macroActive.state = macroWorkspace.macroGroup(in: .global).active ? .on : .off
        macroActive.isEnabled = true
        descriptionField.stringValue = macro.description
        descriptionField.isEnabled = true
        macroFolder.state = macro.folder ? .on : .off
        macroFolder.isEnabled = true
        macroTextView.string = macro.macro
        macroKeyCanonical = macro.key
        macroKeyField.stringValue = macro.key.isEmpty ? "(No Key)" : KeyboardMacroKey.displayString(macro.key)
        macroKeyField.setAccessibilityValue(macro.key)
        macroTypeIntoInput.state = macro.typeIntoInput ? .on : .off
        setMacroModifier(macro.key, button: macroControl) { $0.control }
        setMacroModifier(macro.key, button: macroAlt) { $0.alt }
        setMacroModifier(macro.key, button: macroShift) { $0.shift }
        macroTextView.isEditable = !macro.folder
        macroKeyField.isEnabled = !macro.folder
        macroTypeIntoInput.isEnabled = !macro.folder
        macroControl.isEnabled = !macro.folder
        macroAlt.isEnabled = !macro.folder
        macroShift.isEnabled = !macro.folder
        status.stringValue = ""
    }

    private func loadMacroSample(_ macro: KeyboardMacro) {
        macroActive.state = .off
        macroActive.isEnabled = false
        descriptionField.stringValue = macro.description
        descriptionField.isEnabled = false
        macroFolder.state = macro.folder ? .on : .off
        macroFolder.isEnabled = false
        macroTextView.string = macro.macro
        macroTextView.isEditable = false
        macroKeyCanonical = macro.key
        macroKeyField.stringValue = macro.key.isEmpty ? "(No Key)" : KeyboardMacroKey.displayString(macro.key)
        macroKeyField.setAccessibilityValue(macro.key)
        macroKeyField.isEnabled = false
        macroTypeIntoInput.state = macro.typeIntoInput ? .on : .off
        macroTypeIntoInput.isEnabled = false
        setMacroModifier(macro.key, button: macroControl) { $0.control }
        setMacroModifier(macro.key, button: macroAlt) { $0.alt }
        setMacroModifier(macro.key, button: macroShift) { $0.shift }
        macroControl.isEnabled = false
        macroAlt.isEnabled = false
        macroShift.isEnabled = false
    }

    private func setMacroModifier(
        _ key: String,
        button: NSButton,
        component: (KeyboardMacroKey.Components) -> Bool?
    ) {
        guard let parsed = KeyboardMacroKey.parse(key) else {
            button.state = .off
            return
        }
        switch component(parsed) {
        case .some(true): button.state = .on
        case .some(false): button.state = .off
        case .none: button.state = .mixed
        }
        button.allowsMixedState = true
    }

    @objc private func toggleMacroActive(_ sender: Any?) {
        // The checkbox is part of the staged form; it is persisted with the
        // selected scope when Apply/OK is pressed.
    }

    @objc private func macroFolderChanged(_ sender: Any?) {
        let isFolder = macroFolder.state == .on
        macroTextView.isEditable = !isFolder
        macroKeyField.isEnabled = !isFolder
        macroTypeIntoInput.isEnabled = !isFolder
        macroControl.isEnabled = !isFolder
        macroAlt.isEnabled = !isFolder
        macroShift.isEnabled = !isFolder
    }

    @objc private func macroControlChanged(_ sender: Any?) {
        // Checkbox changes are read when the staged form is applied. Mixed
        // states intentionally remain untouched until the user clicks them.
    }

    private func macroKeyChanged(_ key: String) {
        macroKeyCanonical = KeyboardMacroKey.canonical(key)
        setMacroModifier(macroKeyCanonical, button: macroControl) { $0.control }
        setMacroModifier(macroKeyCanonical, button: macroAlt) { $0.alt }
        setMacroModifier(macroKeyCanonical, button: macroShift) { $0.shift }
        macroControl.state = macroControl.state == .mixed ? .off : macroControl.state
        macroAlt.state = macroAlt.state == .mixed ? .off : macroAlt.state
        macroShift.state = macroShift.state == .mixed ? .off : macroShift.state
    }

    private func macroFormValue(preserving existing: KeyboardMacro) -> KeyboardMacro {
        let oldComponents = KeyboardMacroKey.parse(existing.key)
        let parsedKey = KeyboardMacroKey.parse(macroKeyCanonical)
        let updatedKey: String
        if let parsedKey, KeyboardMacroKey.isSupportedKey(parsedKey.key) {
            updatedKey = KeyboardMacroKey.canonicalFormat(
                key: parsedKey.key,
                control: concreteModifierState(macroControl, preserving: oldComponents?.control),
                alt: concreteModifierState(macroAlt, preserving: oldComponents?.alt),
                shift: concreteModifierState(macroShift, preserving: oldComponents?.shift)
            )
        } else {
            // Imported key expressions outside the Mac vocabulary are
            // displayed but preserved verbatim on unrelated edits.
            updatedKey = existing.key
        }
        var updated = existing
        updated.description = descriptionField.stringValue
        updated.macro = macroTextView.string
        updated.key = updatedKey
        updated.typeIntoInput = macroTypeIntoInput.state == .on
        updated.folder = macroFolder.state == .on
        return updated
    }

    /// Detail controls are intentionally staged as the user navigates the
    /// tree. This keeps a tree action from discarding a form edit while still
    /// keeping the live workspace untouched until Apply/OK.
    private func stageMacroFormIfNeeded() {
        guard kind == .macros,
              !macroSampleSelected,
              let selectedMacroScope else { return }
        guard macroTextView.string.utf16.count <= 65_536 else {
            status.stringValue = LegacyConfigurationWorkspace.WorkspaceError.macroTextTooLong.localizedDescription
            return
        }
        do {
            var candidate = macroWorkspace
            if let selectedMacroPath,
               let existing = candidate.macro(at: selectedMacroPath, in: selectedMacroScope) {
                try candidate.updateMacro(
                    at: selectedMacroPath,
                    in: selectedMacroScope,
                    macro: macroFormValue(preserving: existing)
                )
            }
            try candidate.setMacroMasterActive(macroActive.state == .on)
            stagedMacroWorkspace = candidate
        } catch {
            present(error)
        }
    }

    private func concreteModifierState(_ button: NSButton, preserving old: Bool?) -> Bool {
        switch button.state {
        case .on: return true
        case .mixed: return old ?? false
        default: return false
        }
    }

    private func applyMacroChanges() -> Bool {
        guard kind == .macros else { return false }
        guard let selectedMacroScope else { NSSound.beep(); return false }
        do {
            var candidate = macroWorkspace
            let active = macroSampleSelected
                ? candidate.macroGroup(in: .global).active
                : macroActive.state == .on
            if !macroSampleSelected, let selectedMacroPath,
               let existing = candidate.macro(at: selectedMacroPath, in: selectedMacroScope) {
                guard macroTextView.string.utf16.count <= 65_536 else {
                    throw LegacyConfigurationWorkspace.WorkspaceError.macroTextTooLong
                }
                let updated = macroFormValue(preserving: existing)
                try candidate.updateMacro(at: selectedMacroPath, in: selectedMacroScope, macro: updated)
            }
            try candidate.setMacroMasterActive(active)
            try library.commit(candidate, expectedRevision: macroExpectedRevision)
            stagedMacroWorkspace = library.workspace
            macroExpectedRevision = library.workspaceRevision
            status.stringValue = "Applied and saved."
            reloadMacroOutline(selecting: macroSelectionKey(
                scope: selectedMacroScope,
                path: selectedMacroPath,
                identity: selectedMacroPath.flatMap { macroWorkspace.macro(at: $0, in: selectedMacroScope) }.map(MacroSelectionIdentity.init)
            ))
            return true
        } catch let error as ProfileLibrary.WorkspaceCommitError {
            let alert = NSAlert()
            alert.messageText = "Configuration changed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                let snapshot = library.beginWorkspaceEditor()
                stagedMacroWorkspace = snapshot.workspace
                macroExpectedRevision = snapshot.revision
                reloadMacroOutline(selecting: nil)
            }
            return false
        } catch {
            present(error)
            return false
        }
    }

    @objc private func acceptMacroEditor(_ sender: Any?) {
        guard applyMacroChanges() else { return }
        macroDidClose = true
        window?.close()
    }

    @objc private func cancelMacroEditor(_ sender: Any?) {
        guard kind == .macros else { return }
        stagedMacroWorkspace = nil
        macroDidClose = true
        window?.close()
    }

    private func performMacroImport(
        from url: URL,
        into scope: LegacyConfigurationWorkspace.AutomationScope,
        parentPath: [Int]
    ) {
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            let imported = try LegacyConfigurationDocument(source: source)
            var candidate = macroWorkspace
            let count = try candidate.importMacros(from: imported, into: scope, parentPath: parentPath)
            guard count > 0 else {
                status.stringValue = "No keyboard macros found to import."
                return
            }
            stagedMacroWorkspace = candidate
            let suffix = count == 1 ? "" : "s"
            status.stringValue = "Imported \(count) macro\(suffix) into the staged workspace."
            reloadMacroOutline(selecting: macroSelectionKey(scope: scope, path: parentPath.isEmpty ? nil : parentPath))
        } catch { present(error) }
    }

    private func performMacroExport(
        to url: URL,
        from scope: LegacyConfigurationWorkspace.AutomationScope,
        path: [Int]?
    ) {
        do {
            let document = try macroWorkspace.exportMacros(in: scope, path: path)
            try Data(document.serialized().utf8).write(to: url, options: .atomic)
            status.stringValue = "Exported keyboard macros."
        } catch { present(error) }
    }

    private func reloadAliasOutline(selecting selection: AliasSelectionKey?) {
        aliasOutlineNodes = makeAliasOutlineNodes()
        aliasSampleNodes = makeAliasSampleNodes()
        triggerOutline.reloadData()
        aliasSamplesOutline.reloadData()
        aliasOutlineNodes.forEach { triggerOutline.expandItem($0, expandChildren: true) }
        aliasSampleNodes.forEach { aliasSamplesOutline.expandItem($0, expandChildren: true) }

        let fallback = selection ?? aliasSelectionKey(
            scope: selectedAliasScope ?? scope,
            aliasPath: selectedAliasPath,
            aliasIdentity: selectedAliasIdentity
        )
        if let row = rowForAliasSelection(fallback) {
            triggerOutline.selectRowIndexes(.init(integer: row), byExtendingSelection: false)
            triggerOutline.scrollRowToVisible(row)
            outlineViewSelectionDidChange(.init(name: NSOutlineView.selectionDidChangeNotification, object: triggerOutline))
        } else {
            selectedAliasScope = fallback.scope
            selectedAliasPath = nil
            selectedAliasIdentity = nil
            loadAliasScopeSettings(fallback.scope)
            clearFields()
        }
    }

    private func makeAliasOutlineNodes() -> [AliasOutlineNode] {
        var roots = [scopeAliasNode("Global", scope: .global)]
        for server in library.workspace.servers {
            let serverScope: LegacyConfigurationWorkspace.AutomationScope = .server(server.profile.id)
            let serverNode = scopeAliasNode(server.profile.name, scope: serverScope)
            for character in server.characters {
                let characterScope: LegacyConfigurationWorkspace.AutomationScope = .character(
                    server: server.profile.id,
                    character: character.id
                )
                let characterNode = scopeAliasNode(character.name, scope: characterScope)
                for puppet in character.puppets {
                    let puppetScope: LegacyConfigurationWorkspace.AutomationScope = .puppet(
                        server: server.profile.id,
                        character: character.id,
                        puppet: puppet.id
                    )
                    characterNode.children.append(scopeAliasNode(puppet.name, scope: puppetScope))
                }
                serverNode.children.append(characterNode)
            }
            roots.append(serverNode)
        }
        return roots
    }

    private func scopeAliasNode(
        _ title: String,
        scope: LegacyConfigurationWorkspace.AutomationScope
    ) -> AliasOutlineNode {
        AliasOutlineNode(
            title: title,
            kind: .scope(scope),
            children: aliasNodes(library.workspace.aliases(in: scope), scope: scope, parentPath: [])
        )
    }

    private func aliasNodes(
        _ aliases: [Alias],
        scope: LegacyConfigurationWorkspace.AutomationScope,
        parentPath: [Int]
    ) -> [AliasOutlineNode] {
        aliases.enumerated().map { index, alias in
            let path = parentPath + [index]
            return AliasOutlineNode(
                title: alias.folder
                    ? (alias.description.isEmpty ? "Folder" : alias.description)
                    : (alias.description.isEmpty ? alias.match.text : alias.description),
                kind: .alias(scope, path, AliasSelectionIdentity(alias)),
                children: aliasNodes(alias.children, scope: scope, parentPath: path)
            )
        }
    }

    private func makeAliasSampleNodes() -> [AliasOutlineNode] {
        guard let url = Bundle.module.url(forResource: "AliasesSamples", withExtension: "txt"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let workspace = try? LegacyConfigurationWorkspace(document: .init(source: source)) else {
            return []
        }
        return workspace.globalAliases.map {
            AliasOutlineNode(
                title: $0.description.isEmpty ? $0.match.text : $0.description,
                kind: .sample($0),
                children: aliasNodesForSample($0.children)
            )
        }
    }

    private func aliasNodesForSample(_ aliases: [Alias]) -> [AliasOutlineNode] {
        aliases.map {
            AliasOutlineNode(
                title: $0.description.isEmpty ? $0.match.text : $0.description,
                kind: .sample($0),
                children: aliasNodesForSample($0.children)
            )
        }
    }

    private func rowForAliasSelection(_ selection: AliasSelectionKey) -> Int? {
        for row in 0..<triggerOutline.numberOfRows {
            guard let node = triggerOutline.item(atRow: row) as? AliasOutlineNode else { continue }
            switch node.kind {
            case let .scope(scope) where selection.aliasPath == nil && aliasScopeMatches(scope, selection):
                return row
            case let .alias(scope, path, identity) where aliasScopeMatches(scope, selection):
                if selection.aliasIdentity?.matches(identity) == true || selection.aliasPath == path {
                    return row
                }
            case .sample:
                continue
            default:
                continue
            }
        }
        return nil
    }

    private func aliasSelectionKey(
        scope: LegacyConfigurationWorkspace.AutomationScope,
        aliasPath: [Int]?,
        aliasIdentity: AliasSelectionIdentity? = nil
    ) -> AliasSelectionKey {
        let identity = aliasIdentity ?? aliasPath
            .flatMap { library.workspace.alias(at: $0, in: scope) }
            .map(AliasSelectionIdentity.init)
        return .init(
            scope: scope,
            path: triggerScopePath(scope),
            aliasPath: aliasPath,
            aliasIdentity: identity
        )
    }

    private func aliasScopeMatches(
        _ scope: LegacyConfigurationWorkspace.AutomationScope,
        _ selection: AliasSelectionKey
    ) -> Bool {
        scope == selection.scope || triggerScopePath(scope) == selection.path
    }

    private func loadAliasScopeSettings(_ scope: LegacyConfigurationWorkspace.AutomationScope) {
        let group = library.workspace.aliasGroup(in: scope)
        aliasAfterCount.stringValue = String(group.afterCount)
        aliasAfterCount.setAccessibilityValue(String(group.afterCount))
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
        if kind == .macros {
            descriptionField.stringValue = ""
            descriptionField.isEnabled = false
            macroFolder.state = .off
            macroFolder.isEnabled = false
            macroTextView.string = ""
            macroTextView.isEditable = false
            macroKeyCanonical = ""
            macroKeyField.stringValue = ""
            macroKeyField.setAccessibilityValue("")
            macroKeyField.isEnabled = false
            macroTypeIntoInput.state = .off
            macroTypeIntoInput.isEnabled = false
            macroControl.state = .off
            macroAlt.state = .off
            macroShift.state = .off
            macroControl.isEnabled = false
            macroAlt.isEnabled = false
            macroShift.isEnabled = false
            status.stringValue = ""
            return
        }
        selectedIndex = nil
        selectedTriggerPath = nil
        selectedTriggerIdentity = nil
        descriptionField.stringValue = ""
        matchField.stringValue = ""
        regex.state = .off
        actionField.stringValue = ""
        status.stringValue = ""
        if kind == .triggers { triggerDetail?.reset() }
        else if kind == .aliases { aliasDetail?.reset() }
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

    private func performAliasImport(
        from url: URL,
        into scope: LegacyConfigurationWorkspace.AutomationScope,
        parentPath: [Int]
    ) {
        do {
            let source = try String(contentsOf: url, encoding: .utf8)
            let imported = try LegacyConfigurationWorkspace(document: .init(source: source))
            let aliases = imported.globalAliases
            guard !aliases.isEmpty else {
                status.stringValue = "No aliases found to import."
                return
            }
            var lastPath: [Int] = parentPath
            try library.mutate { workspace in
                for alias in aliases {
                    lastPath = try workspace.addAlias(in: scope, parentPath: parentPath, alias: alias)
                }
            }
            status.stringValue = "Imported \(aliases.count) alias\(aliases.count == 1 ? "" : "es")."
            reloadAliasOutline(selecting: aliasSelectionKey(scope: scope, aliasPath: lastPath))
        } catch { present(error) }
    }

    private func performAliasExport(
        to url: URL,
        from scope: LegacyConfigurationWorkspace.AutomationScope,
        path: [Int]?
    ) {
        do {
            let aliases: [Alias]
            if let path, let alias = library.workspace.alias(at: path, in: scope) {
                aliases = [alias]
            } else {
                aliases = library.workspace.aliases(in: scope)
            }
            var exported = try LegacyConfigurationWorkspace.empty()
            for alias in aliases {
                _ = try exported.addAlias(in: .global, parentPath: [], alias: alias)
            }
            try Data(exported.document.serialized().utf8).write(to: url, options: .atomic)
            status.stringValue = "Exported \(aliases.count) alias\(aliases.count == 1 ? "" : "es")."
        } catch { present(error) }
    }

    private func aliasScopeTitle(_ scope: LegacyConfigurationWorkspace.AutomationScope) -> String {
        switch scope {
        case .global:
            return "Global"
        case let .server(serverID):
            return library.workspace.servers.first { $0.profile.id == serverID }?.profile.name ?? "World"
        case let .character(serverID, characterID):
            guard let server = library.workspace.servers.first(where: { $0.profile.id == serverID }),
                  let character = server.characters.first(where: { $0.id == characterID }) else { return "Character" }
            return "\(server.profile.name)-\(character.name)"
        case let .puppet(serverID, characterID, puppetID):
            guard let server = library.workspace.servers.first(where: { $0.profile.id == serverID }),
                  let character = server.characters.first(where: { $0.id == characterID }),
                  let puppet = character.puppets.first(where: { $0.id == puppetID }) else { return "Puppet" }
            return "\(server.profile.name)-\(character.name)-\(puppet.name)"
        }
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
