import AppKit

@MainActor
final class LoggingWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Entry: Equatable {
        let url: URL
        let isAutomatic: Bool
    }

    enum StartHistory: Int, CaseIterable {
        case now
        case beginning
        case topOfWindow

        var title: String {
            switch self {
            case .now: "From now"
            case .beginning: "From the beginning"
            case .topOfWindow: "From the top of the window"
            }
        }
    }

    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No active session logs.")
    private let historyPopUp = NSPopUpButton()
    private let stopButton = KeyboardFocusableButton(title: "Stop", target: nil, action: nil)
    private let stopAllButton = KeyboardFocusableButton(title: "Stop All", target: nil, action: nil)
    private var entries: [Entry]

    var onClose: (() -> Void)?
    var onStart: ((StartHistory) -> Void)?
    var onStop: ((URL) -> Void)?
    var onStopAll: (() -> Void)?

    init(entries: [Entry]) {
        self.entries = entries
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 360),
            styleMask: [.titled, .closable, .utilityWindow, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Session Logging"
        panel.setAccessibilityIdentifier("loggingWindow")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        super.init(window: panel)
        panel.delegate = self
        configureContent(in: panel)
        updateControls()
    }

    required init?(coder: NSCoder) { nil }

    func update(entries: [Entry]) {
        let selectedURL = selectedEntry?.url
        self.entries = entries
        tableView.reloadData()
        if let selectedURL, let row = entries.firstIndex(where: { $0.url == selectedURL }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateControls()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let entry = entries[row]
        let field = NSTextField(labelWithString: identifier.rawValue == "type"
            ? (entry.isAutomatic ? "Automatic" : "Manual")
            : entry.url.path)
        field.lineBreakMode = .byTruncatingMiddle
        field.setAccessibilityLabel(identifier.rawValue == "type" ? "Log type" : "Log file")
        field.setAccessibilityValue(identifier.rawValue == "type"
            ? (entry.isAutomatic ? "Automatic" : "Manual")
            : entry.url.path)
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }

    func windowWillClose(_ notification: Notification) { onClose?() }

    private var selectedEntry: Entry? {
        let row = tableView.selectedRow
        return entries.indices.contains(row) ? entries[row] : nil
    }

    private func configureContent(in panel: NSPanel) {
        let heading = NSTextField(labelWithString: "Session Logging")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)

        let detail = NSTextField(wrappingLabelWithString: "Start a new log or stop logs currently writing this session.")
        detail.textColor = .secondaryLabelColor

        let fileColumn = NSTableColumn(identifier: .init("file"))
        fileColumn.title = "Log file"
        fileColumn.minWidth = 260
        let typeColumn = NSTableColumn(identifier: .init("type"))
        typeColumn.title = "Type"
        typeColumn.width = 100
        tableView.addTableColumn(fileColumn)
        tableView.addTableColumn(typeColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityIdentifier("loggingActiveLogs")
        tableView.setAccessibilityLabel("Active session logs")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.setAccessibilityIdentifier("loggingEmptyState")

        historyPopUp.addItems(withTitles: StartHistory.allCases.map(\.title))
        historyPopUp.selectItem(at: StartHistory.now.rawValue)
        historyPopUp.setAccessibilityIdentifier("loggingStartHistory")
        historyPopUp.setAccessibilityLabel("Include log history")

        let startButton = KeyboardFocusableButton(title: "Start New Log…", target: self, action: #selector(startLog(_:)))
        startButton.setAccessibilityIdentifier("loggingStart")
        stopButton.target = self
        stopButton.action = #selector(stopSelectedLog(_:))
        stopButton.setAccessibilityIdentifier("loggingStop")
        stopAllButton.target = self
        stopAllButton.action = #selector(stopAllLogs(_:))
        stopAllButton.setAccessibilityIdentifier("loggingStopAll")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [historyPopUp, startButton, spacer, stopButton, stopAllButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10

        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(scrollView)
        listContainer.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: listContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor),
        ])

        let stack = NSStackView(views: [heading, detail, listContainer, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -18),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            listContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        panel.initialFirstResponder = startButton
    }

    private func updateControls() {
        emptyLabel.isHidden = !entries.isEmpty
        tableView.isHidden = entries.isEmpty
        stopButton.isEnabled = selectedEntry != nil
        stopAllButton.isEnabled = !entries.isEmpty
    }

    @objc private func startLog(_ sender: NSButton) {
        let history = StartHistory(rawValue: historyPopUp.indexOfSelectedItem) ?? .now
        onStart?(history)
    }

    @objc private func stopSelectedLog(_ sender: NSButton) {
        guard let url = selectedEntry?.url else { return }
        onStop?(url)
    }

    @objc private func stopAllLogs(_ sender: NSButton) { onStopAll?() }
}
