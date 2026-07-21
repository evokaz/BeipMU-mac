import BeipCore
import Foundation

public enum TriggerAction: Sendable, Hashable, Codable {
    case replace(String, expandVariables: Bool)
    case gag(display: Bool, log: Bool)
    case send(String, captureIndex: Int, expandVariables: Bool)
    case spawn(title: String, copy: Bool)
    case activity(important: Bool)
    case sound(String)
    case speech(String, wholeLine: Bool)
    case script(String)
    case notification
    case color(foreground: RGBColor?, background: RGBColor?, wholeLine: Bool)
}

public struct Trigger: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var description: String
    public var match: MatchDefinition
    public var disabled: Bool
    public var stopProcessing: Bool
    public var oncePerLine: Bool
    public var cooldown: TimeInterval?
    public var actions: [TriggerAction]
    public var children: [Trigger]

    public init(
        id: UUID = UUID(),
        description: String = "",
        match: MatchDefinition,
        disabled: Bool = false,
        stopProcessing: Bool = false,
        oncePerLine: Bool = false,
        cooldown: TimeInterval? = nil,
        actions: [TriggerAction] = [],
        children: [Trigger] = []
    ) {
        self.id = id
        self.description = description
        self.match = match
        self.disabled = disabled
        self.stopProcessing = stopProcessing
        self.oncePerLine = oncePerLine
        self.cooldown = cooldown
        self.actions = actions
        self.children = children
    }
}

public enum AutomationEffect: Sendable, Hashable {
    case replace(range: NSRange, with: String)
    case gagDisplay
    case gagLog
    case send(String)
    case spawn(title: String, line: RenderedLine, copy: Bool)
    case activity(important: Bool)
    case sound(String)
    case speech(String)
    case script(function: String, captures: [String?])
    case notification(String)
    case style(range: NSRange, foreground: RGBColor?, background: RGBColor?)
}

public actor TriggerEngine {
    private var lastHit: [UUID: Date] = [:]

    public init() {}

    public func process(_ line: RenderedLine, triggers: [Trigger], variables: [String: String], now: Date = Date()) throws -> [AutomationEffect] {
        var effects: [AutomationEffect] = []
        try process(line, triggers: triggers, variables: variables, now: now, effects: &effects)
        return effects
    }

    private func process(
        _ line: RenderedLine,
        triggers: [Trigger],
        variables: [String: String],
        now: Date,
        effects: inout [AutomationEffect]
    ) throws {
        for trigger in triggers where !trigger.disabled {
            if let cooldown = trigger.cooldown,
               let previous = lastHit[trigger.id], now.timeIntervalSince(previous) < cooldown { continue }
            let captures = try trigger.match.matches(in: line.text)
            guard !captures.isEmpty else { continue }
            lastHit[trigger.id] = now
            for capture in trigger.oncePerLine ? Array(captures.prefix(1)) : captures {
                for action in trigger.actions {
                    effects.append(contentsOf: makeEffects(for: action, line: line, capture: capture, variables: variables))
                }
                try process(line, triggers: trigger.children, variables: variables, now: now, effects: &effects)
            }
            if trigger.stopProcessing { return }
        }
    }

    private func makeEffects(for action: TriggerAction, line: RenderedLine, capture: MatchCapture, variables: [String: String]) -> [AutomationEffect] {
        switch action {
        case let .replace(template, expand):
            return [.replace(range: capture.range, with: Expansion.apply(template, capture: capture, variables: expand ? variables : [:]))]
        case let .gag(display, log):
            return (display ? [.gagDisplay] : []) + (log ? [.gagLog] : [])
        case let .send(template, captureIndex, expand):
            let selected = capture[captureIndex] ?? template
            return [.send(Expansion.apply(selected, capture: capture, variables: expand ? variables : [:]))]
        case let .spawn(title, copy): return [.spawn(title: title, line: line, copy: copy)]
        case let .activity(important): return [.activity(important: important)]
        case let .sound(path): return [.sound(path)]
        case let .speech(template, wholeLine):
            return [.speech(wholeLine ? line.text : Expansion.apply(template, capture: capture, variables: variables))]
        case let .script(function): return [.script(function: function, captures: capture.values)]
        case .notification: return [.notification(line.text)]
        case let .color(foreground, background, wholeLine):
            let range = wholeLine ? NSRange(location: 0, length: line.text.utf16.count) : capture.range
            return [.style(range: range, foreground: foreground, background: background)]
        }
    }
}
