import AppKit
import BeipScriptRuntime

@MainActor
private final class ScriptEventWindow: NSWindow {
    var onScriptEvent: ((String, [String]) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved, let contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            onScriptEvent?("mouseMove", [String(Int(point.x)), String(Int(point.y))])
        } else if event.type == .keyDown {
            onScriptEvent?("key", [String(event.keyCode)])
        }
        super.sendEvent(event)
    }
}

@MainActor
final class ScriptWindowController: NSWindowController, NSWindowDelegate {
    private let kind: String
    private let textView: NSTextView?
    private let textScrollView: NSScrollView?
    private let graphicsView: ScriptGraphicsView?
    private var fixedColumns = 80
    private var fixedRows = 25
    private var isTextPaused = false
    var onClose: (() -> Void)?
    var onEvent: ((String, [String]) -> Void)?

    init(operation: ScriptWindowOperation) {
        kind = operation.kind
        let width = operation.numbers.first ?? (operation.kind == "fixed" ? 80 : 320)
        let height = operation.numbers.dropFirst().first ?? (operation.kind == "fixed" ? 25 : 240)
        let contentSize: NSSize
        if operation.kind == "fixed" {
            fixedColumns = max(1, min(240, Int(width)))
            fixedRows = max(1, min(100, Int(height)))
            contentSize = .init(width: CGFloat(fixedColumns) * 8 + 24, height: CGFloat(fixedRows) * 16 + 24)
        } else {
            contentSize = .init(width: max(160, min(2_048, width)), height: max(120, min(2_048, height)))
        }
        let window = ScriptEventWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = operation.kind == "graphics" ? "Script Graphics" : operation.kind == "fixed" ? "Script Fixed Text" : "Script Text"
        window.setAccessibilityIdentifier("script\(operation.kind.capitalized)Window")
        if operation.kind == "graphics" {
            let graphics = ScriptGraphicsView(frame: NSRect(origin: .zero, size: contentSize))
            graphics.setAccessibilityLabel("Script graphics canvas")
            graphicsView = graphics
            textView = nil
            textScrollView = nil
            window.contentView = graphics
        } else {
            let scroll = NSScrollView(frame: NSRect(origin: .zero, size: contentSize))
            let text = NSTextView(frame: scroll.bounds)
            text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            text.isEditable = false
            text.isRichText = true
            text.textContainerInset = .init(width: 8, height: 8)
            text.setAccessibilityLabel(operation.kind == "fixed" ? "Script fixed text" : "Script text output")
            scroll.documentView = text
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = operation.kind == "fixed"
            graphicsView = nil
            textView = text
            textScrollView = scroll
            window.contentView = scroll
            if operation.kind == "fixed" {
                text.string = Array(repeating: String(repeating: " ", count: fixedColumns), count: fixedRows).joined(separator: "\n")
            }
        }
        super.init(window: window)
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.onScriptEvent = { [weak self] event, arguments in self?.onEvent?(event, arguments) }
        if operation.kind == "text", let textScrollView {
            textScrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: textScrollView.contentView
            )
        }
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ operation: ScriptWindowOperation, relativeTo owner: NSWindow?) {
        switch operation.action {
        case "title":
            window?.title = operation.strings.first ?? ""
        case "write":
            appendPlain(operation.strings.first ?? "")
        case "html":
            appendHTML(operation.strings.first ?? "")
        case "clear":
            if kind == "fixed" { textView?.string = emptyFixedGrid() }
            else if kind == "text" { textView?.string = "" }
            else { graphicsView?.clear(color: operation.numbers.first ?? 0) }
        case "writeAt":
            writeFixed(
                operation.strings.first ?? "",
                x: Int(operation.numbers.first ?? 0),
                y: Int(operation.numbers.dropFirst().first ?? 0)
            )
        case "pixel": graphicsView?.pixel(operation.numbers)
        case "line": graphicsView?.line(operation.numbers)
        case "drawText": graphicsView?.text(operation.strings.first ?? "", numbers: operation.numbers)
        case "dock": dock(side: Int(operation.numbers.first ?? 0), relativeTo: owner)
        default: break
        }
    }

    private func appendPlain(_ value: String) {
        guard let storage = textView?.textStorage else { return }
        storage.append(NSAttributedString(string: value, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]))
        if !isTextPaused { textView?.scrollToEndOfDocument(nil) }
    }

    private func appendHTML(_ value: String) {
        guard let data = value.data(using: .utf8),
              let rich = NSAttributedString(html: data, documentAttributes: nil) else {
            appendPlain(value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            return
        }
        textView?.textStorage?.append(rich)
        if !isTextPaused { textView?.scrollToEndOfDocument(nil) }
    }

    private func emptyFixedGrid() -> String {
        Array(repeating: String(repeating: " ", count: fixedColumns), count: fixedRows).joined(separator: "\n")
    }

    private func writeFixed(_ value: String, x: Int, y: Int) {
        guard let textView, y >= 0, y < fixedRows else { return }
        var rows = textView.string.components(separatedBy: "\n")
        while rows.count < fixedRows { rows.append(String(repeating: " ", count: fixedColumns)) }
        var characters = Array(rows[y])
        let start = max(0, min(fixedColumns, x))
        for (offset, character) in value.enumerated() where start + offset < fixedColumns {
            characters[start + offset] = character
        }
        rows[y] = String(characters)
        textView.string = rows.prefix(fixedRows).joined(separator: "\n")
    }

    private func dock(side: Int, relativeTo owner: NSWindow?) {
        guard let owner, let window else { return }
        var frame = window.frame
        switch side {
        case 0: frame.origin = .init(x: owner.frame.minX - frame.width, y: owner.frame.minY)
        case 1: frame.origin = .init(x: owner.frame.minX, y: owner.frame.maxY)
        case 2: frame.origin = .init(x: owner.frame.maxX, y: owner.frame.minY)
        default: frame.origin = .init(x: owner.frame.minX, y: owner.frame.minY - frame.height)
        }
        window.setFrame(frame, display: true, animate: !AccessibilityDisplayOptions.current.reduceMotion)
        owner.addChildWindow(window, ordered: .above)
    }

    @objc private func textBoundsChanged(_ notification: Notification) {
        guard kind == "text", let scroll = textScrollView, let document = scroll.documentView else { return }
        let paused = scroll.contentView.bounds.maxY < document.bounds.maxY - 2
        guard paused != isTextPaused else { return }
        isTextPaused = paused
        onEvent?("pause", [paused ? "true" : "false"])
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: textScrollView?.contentView)
        onEvent?("close", [])
        onClose?()
    }
}

@MainActor
private final class ScriptGraphicsView: NSView {
    private enum Command { case pixel(CGPoint, NSColor); case line(CGPoint, CGPoint, NSColor, CGFloat); case text(CGPoint, String, NSColor) }
    private var background = NSColor.black
    private var commands: [Command] = []
    override var isFlipped: Bool { true }

    func clear(color: Double) { background = Self.color(color); commands.removeAll(); needsDisplay = true }
    func pixel(_ values: [Double]) {
        guard values.count >= 3 else { return }
        commands.append(.pixel(.init(x: values[0], y: values[1]), Self.color(values[2]))); needsDisplay = true
    }
    func line(_ values: [Double]) {
        guard values.count >= 6 else { return }
        commands.append(.line(.init(x: values[0], y: values[1]), .init(x: values[2], y: values[3]), Self.color(values[4]), max(1, values[5]))); needsDisplay = true
    }
    func text(_ value: String, numbers: [Double]) {
        guard numbers.count >= 3 else { return }
        commands.append(.text(.init(x: numbers[0], y: numbers[1]), value, Self.color(numbers[2]))); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        background.setFill(); bounds.fill()
        for command in commands {
            switch command {
            case let .pixel(point, color): color.setFill(); NSRect(origin: point, size: .init(width: 1, height: 1)).fill()
            case let .line(start, end, color, width):
                color.setStroke(); let path = NSBezierPath(); path.lineWidth = width; path.move(to: start); path.line(to: end); path.stroke()
            case let .text(point, value, color):
                value.draw(at: point, withAttributes: [.foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
            }
        }
    }
    private static func color(_ value: Double) -> NSColor {
        let raw = UInt32(clamping: Int(value))
        return NSColor(
            calibratedRed: CGFloat(raw & 255) / 255,
            green: CGFloat((raw >> 8) & 255) / 255,
            blue: CGFloat((raw >> 16) & 255) / 255,
            alpha: 1
        )
    }
}
