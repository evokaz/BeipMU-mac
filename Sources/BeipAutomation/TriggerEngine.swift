import BeipCore
import Foundation

public struct TextStylePatch: Sendable, Hashable, Codable {
    public var bold: Bool?
    public var italic: Bool?
    public var underline: Bool?
    public var strikeout: Bool?
    public var blink: TextStyle.Blink?

    public init(
        bold: Bool? = nil,
        italic: Bool? = nil,
        underline: Bool? = nil,
        strikeout: Bool? = nil,
        blink: TextStyle.Blink? = nil
    ) {
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikeout = strikeout
        self.blink = blink
    }

    public func applying(to style: inout TextStyle) {
        if let bold { style.bold = bold }
        if let italic { style.italic = italic }
        if let underline { style.underline = underline }
        if let strikeout { style.strikeout = strikeout }
        if let blink { style.blink = blink }
    }
}

public struct ParagraphPatch: Sendable, Hashable, Codable {
    public var alignment: ParagraphStyle.Alignment?
    public var leftIndent: Double?
    public var rightIndent: Double?
    public var topPadding: Double?
    public var bottomPadding: Double?
    public var background: RGBColor?
    public var backgroundHash: Bool
    public var borderWidth: Double?
    public var borderStyle: ParagraphStyle.BorderStyle?
    public var strokeWidth: Double?
    public var strokeColor: RGBColor?
    public var strokeHash: Bool
    public var strokeStyle: ParagraphStyle.StrokeStyle?
    public var horizontalRule: Bool?

    public init(
        alignment: ParagraphStyle.Alignment? = nil,
        leftIndent: Double? = nil,
        rightIndent: Double? = nil,
        topPadding: Double? = nil,
        bottomPadding: Double? = nil,
        background: RGBColor? = nil,
        backgroundHash: Bool = false,
        borderWidth: Double? = nil,
        borderStyle: ParagraphStyle.BorderStyle? = nil,
        strokeWidth: Double? = nil,
        strokeColor: RGBColor? = nil,
        strokeHash: Bool = false,
        strokeStyle: ParagraphStyle.StrokeStyle? = nil,
        horizontalRule: Bool? = nil
    ) {
        self.alignment = alignment
        self.leftIndent = leftIndent
        self.rightIndent = rightIndent
        self.topPadding = topPadding
        self.bottomPadding = bottomPadding
        self.background = background
        self.backgroundHash = backgroundHash
        self.borderWidth = borderWidth
        self.borderStyle = borderStyle
        self.strokeWidth = strokeWidth
        self.strokeColor = strokeColor
        self.strokeHash = strokeHash
        self.strokeStyle = strokeStyle
        self.horizontalRule = horizontalRule
    }

    public var isEmpty: Bool {
        alignment == nil && leftIndent == nil && rightIndent == nil
            && topPadding == nil && bottomPadding == nil && background == nil && !backgroundHash
            && borderWidth == nil && borderStyle == nil && strokeWidth == nil && strokeColor == nil
            && !strokeHash && strokeStyle == nil && horizontalRule == nil
    }

    public func applying(to paragraph: inout ParagraphStyle) {
        if let alignment { paragraph.alignment = alignment }
        if let leftIndent { paragraph.leftIndent = leftIndent }
        if let rightIndent { paragraph.rightIndent = rightIndent }
        if let topPadding { paragraph.topPadding = topPadding }
        if let bottomPadding { paragraph.bottomPadding = bottomPadding }
        if let background { paragraph.background = background }
        if let borderWidth { paragraph.borderWidth = borderWidth }
        if let borderStyle { paragraph.borderStyle = borderStyle }
        if let strokeWidth { paragraph.strokeWidth = strokeWidth }
        if let strokeColor { paragraph.strokeColor = strokeColor }
        if let strokeStyle { paragraph.strokeStyle = strokeStyle }
        if let horizontalRule { paragraph.horizontalRule = horizontalRule }
    }
}

public enum TriggerAction: Sendable, Hashable, Codable {
    case replace(String, expandVariables: Bool)
    case replaceHTML(String, expandVariables: Bool)
    case gag(display: Bool, log: Bool)
    case send(String, captureIndex: Int, expandVariables: Bool, sendOnClick: Bool = false)
    case spawn(TriggerSpawnAction)
    case activity(important: Bool)
    case activateWindow
    case suppressActivity
    case sound(String)
    case speech(String, wholeLine: Bool)
    case script(String)
    case notification
    case color(foreground: RGBColor?, background: RGBColor?, wholeLine: Bool)
    case colorDefault(foreground: Bool, background: Bool, wholeLine: Bool)
    case colorHash(foreground: Bool, background: Bool, wholeLine: Bool)
    case font(face: String, size: Double, useDefault: Bool, wholeLine: Bool)
    case appearance(TextStylePatch, wholeLine: Bool)
    case paragraph(ParagraphPatch)
    case avatar(String)
    case stat(TriggerStatAction)
}

public struct TriggerSpawnAction: Sendable, Hashable, Codable {
    public var title: String
    public var tabGroup: String
    public var captureUntil: String
    public var onlyChildrenDuringCapture: Bool
    public var clear: Bool
    public var showTab: Bool
    public var gagLog: Bool
    public var copy: Bool

    public init(
        title: String = "",
        tabGroup: String = "",
        captureUntil: String = "",
        onlyChildrenDuringCapture: Bool = false,
        clear: Bool = false,
        showTab: Bool = false,
        gagLog: Bool = false,
        copy: Bool = false
    ) {
        self.title = title
        self.tabGroup = tabGroup
        self.captureUntil = captureUntil
        self.onlyChildrenDuringCapture = onlyChildrenDuringCapture
        self.clear = clear
        self.showTab = showTab
        self.gagLog = gagLog
        self.copy = copy
    }
}

public enum TriggerStatKind: String, Sendable, Hashable, Codable {
    case integer
    case string
    case range
}

public struct TriggerFontStyle: Sendable, Hashable, Codable {
    public var name: String
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikeout: Bool

    public init(name: String, size: Double, bold: Bool = false, italic: Bool = false, underline: Bool = false, strikeout: Bool = false) {
        self.name = name
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikeout = strikeout
    }
}

/// The persisted Stat action. Prefix controls ordering without appearing in
/// the stat's visible name, mirroring the Windows Stats window.
public struct TriggerStatAction: Sendable, Hashable, Codable {
    public var title: String
    public var name: String
    public var prefix: String
    public var value: String
    public var kind: TriggerStatKind
    public var addsToExistingInteger: Bool
    public var lower: String
    public var upper: String
    public var color: RGBColor?
    public var rangeColor: RGBColor?
    public var nameAlignment: ParagraphStyle.Alignment
    public var font: TriggerFontStyle?

    public init(
        title: String = "",
        name: String,
        prefix: String = "",
        value: String,
        kind: TriggerStatKind = .integer,
        addsToExistingInteger: Bool = false,
        lower: String = "",
        upper: String = "",
        color: RGBColor? = nil,
        rangeColor: RGBColor? = nil,
        nameAlignment: ParagraphStyle.Alignment = .center,
        font: TriggerFontStyle? = nil
    ) {
        self.title = title
        self.name = name
        self.prefix = prefix
        self.value = value
        self.kind = kind
        self.addsToExistingInteger = addsToExistingInteger
        self.lower = lower
        self.upper = upper
        self.color = color
        self.rangeColor = rangeColor
        self.nameAlignment = nameAlignment
        self.font = font
    }

    public init(
        title: String, name: String, prefix: String, value: String,
        kind: TriggerStatKind, addsToExistingInteger: Bool, lower: String,
        upper: String, color: RGBColor?, rangeColor: RGBColor?
    ) {
        self.init(
            title: title, name: name, prefix: prefix, value: value, kind: kind,
            addsToExistingInteger: addsToExistingInteger, lower: lower, upper: upper,
            color: color, rangeColor: rangeColor, nameAlignment: .center, font: nil
        )
    }
}

public enum TriggerStatisticValue: Sendable, Hashable, Codable {
    case integer(Int)
    case string(String)
    case range(value: Int, lower: Int, upper: Int, color: RGBColor?)
}

public struct TriggerStatisticUpdate: Sendable, Hashable, Codable {
    public var title: String
    public var name: String
    public var prefix: String
    public var value: TriggerStatisticValue
    public var addsToExistingInteger: Bool
    public var color: RGBColor?
    public var nameAlignment: ParagraphStyle.Alignment
    public var font: TriggerFontStyle?

    public init(
        title: String,
        name: String,
        prefix: String,
        value: TriggerStatisticValue,
        addsToExistingInteger: Bool,
        color: RGBColor?,
        nameAlignment: ParagraphStyle.Alignment = .center,
        font: TriggerFontStyle? = nil
    ) {
        self.title = title
        self.name = name
        self.prefix = prefix
        self.value = value
        self.addsToExistingInteger = addsToExistingInteger
        self.color = color
        self.nameAlignment = nameAlignment
        self.font = font
    }

    public init(
        title: String, name: String, prefix: String, value: TriggerStatisticValue,
        addsToExistingInteger: Bool, color: RGBColor?
    ) {
        self.init(
            title: title, name: name, prefix: prefix, value: value,
            addsToExistingInteger: addsToExistingInteger, color: color,
            nameAlignment: .center, font: nil
        )
    }

    public var key: String { prefix + name }
}

public struct TriggerStatistic: Sendable, Hashable, Codable {
    public var name: String
    public var prefix: String
    public var value: TriggerStatisticValue
    public var color: RGBColor?
    public var nameAlignment: ParagraphStyle.Alignment
    public var font: TriggerFontStyle?

    public init(
        name: String, prefix: String, value: TriggerStatisticValue, color: RGBColor?,
        nameAlignment: ParagraphStyle.Alignment = .center, font: TriggerFontStyle? = nil
    ) {
        self.name = name
        self.prefix = prefix
        self.value = value
        self.color = color
        self.nameAlignment = nameAlignment
        self.font = font
    }

    public init(name: String, prefix: String, value: TriggerStatisticValue, color: RGBColor?) {
        self.init(name: name, prefix: prefix, value: value, color: color, nameAlignment: .center, font: nil)
    }
}

/// Small deterministic reducer used by the UI and tests. The dictionary key
/// retains the invisible prefix, while the visible `name` remains untouched.
public struct TriggerStatisticStore: Sendable, Hashable, Codable {
    public private(set) var values: [String: TriggerStatistic] = [:]

    public init() {}

    public mutating func apply(_ update: TriggerStatisticUpdate) {
        let key = update.key
        let value: TriggerStatisticValue
        if update.addsToExistingInteger,
           case let .integer(previous)? = values[key]?.value,
           case let .integer(increment) = update.value {
            value = .integer(previous + increment)
        } else {
            value = update.value
        }
        values[key] = .init(
            name: update.name, prefix: update.prefix, value: value, color: update.color,
            nameAlignment: update.nameAlignment, font: update.font
        )
    }

    public var ordered: [TriggerStatistic] {
        values.sorted { $0.key < $1.key }.map(\.value)
    }
}

/// Arms a trigger's child tree for subsequent received lines. A zero limit or
/// duration means that dimension is unbounded; at least one must be finite.
public struct MultilineTriggerOptions: Sendable, Hashable, Codable {
    public var lineLimit: Int
    public var timeLimit: TimeInterval

    public init(lineLimit: Int = 0, timeLimit: TimeInterval = 0) {
        self.lineLimit = max(0, lineLimit)
        self.timeLimit = max(0, timeLimit)
    }

    public var isEnabled: Bool { lineLimit > 0 || timeLimit > 0 }
}

public struct Trigger: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var description: String
    public var match: MatchDefinition
    public var folder: Bool
    public var disabled: Bool
    public var stopProcessing: Bool
    public var oncePerLine: Bool
    public var awayPresent: Bool
    public var awayPresentOnce: Bool
    public var away: Bool
    public var cooldown: TimeInterval?
    public var multiline: MultilineTriggerOptions?
    public var actions: [TriggerAction]
    public var children: [Trigger]
    public var childrenActive: Bool

    public init(
        id: UUID = UUID(),
        description: String = "",
        match: MatchDefinition,
        folder: Bool = false,
        disabled: Bool = false,
        stopProcessing: Bool = false,
        oncePerLine: Bool = false,
        awayPresent: Bool = false,
        awayPresentOnce: Bool = false,
        away: Bool = true,
        cooldown: TimeInterval? = nil,
        multiline: MultilineTriggerOptions? = nil,
        actions: [TriggerAction] = [],
        children: [Trigger] = [],
        childrenActive: Bool = true
    ) {
        self.id = id
        self.description = description
        self.match = match
        self.folder = folder
        self.disabled = disabled
        self.stopProcessing = stopProcessing
        self.oncePerLine = oncePerLine
        self.awayPresent = awayPresent
        self.awayPresentOnce = awayPresentOnce
        self.away = away
        self.cooldown = cooldown
        self.multiline = multiline
        self.actions = actions
        self.children = children
        self.childrenActive = childrenActive
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case description
        case match
        case folder
        case disabled
        case stopProcessing
        case oncePerLine
        case awayPresent
        case awayPresentOnce
        case away
        case cooldown
        case multiline
        case actions
        case children
        case childrenActive
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(UUID.self, forKey: .id)
        self.description = try values.decode(String.self, forKey: .description)
        self.match = try values.decode(MatchDefinition.self, forKey: .match)
        self.folder = try values.decodeIfPresent(Bool.self, forKey: .folder) ?? false
        self.disabled = try values.decode(Bool.self, forKey: .disabled)
        self.stopProcessing = try values.decode(Bool.self, forKey: .stopProcessing)
        self.oncePerLine = try values.decode(Bool.self, forKey: .oncePerLine)
        self.awayPresent = try values.decode(Bool.self, forKey: .awayPresent)
        self.awayPresentOnce = try values.decode(Bool.self, forKey: .awayPresentOnce)
        self.away = try values.decode(Bool.self, forKey: .away)
        self.cooldown = try values.decodeIfPresent(TimeInterval.self, forKey: .cooldown)
        self.multiline = try values.decodeIfPresent(MultilineTriggerOptions.self, forKey: .multiline)
        self.actions = try values.decode([TriggerAction].self, forKey: .actions)
        self.children = try values.decode([Trigger].self, forKey: .children)
        self.childrenActive = try values.decode(Bool.self, forKey: .childrenActive)
    }
}

public struct TriggerGroup: Sendable, Hashable, Codable {
    public var active: Bool
    public var afterCount: Int
    public var triggers: [Trigger]

    public init(active: Bool = true, afterCount: Int = 0, triggers: [Trigger] = []) {
        self.active = active
        self.afterCount = afterCount
        self.triggers = triggers
    }

    public var pre: [Trigger] {
        triggers.dropLast(max(0, min(afterCount, triggers.count))).map { $0 }
    }

    public var post: [Trigger] {
        triggers.suffix(max(0, min(afterCount, triggers.count))).map { $0 }
    }
}

public enum AutomationEffect: Sendable, Hashable {
    case replace(range: NSRange, with: String)
    case replaceHTML(range: NSRange, with: String)
    case gagDisplay
    case gagLog
    case send(String)
    case link(range: NSRange, send: String)
    case spawn(action: TriggerSpawnAction, line: RenderedLine, children: [Trigger])
    case activity(important: Bool)
    case activateWindow
    case suppressActivity
    case sound(String)
    case speech(String)
    case script(function: String, ranges: [NSRange], line: RenderedLine)
    case notification(String)
    case style(range: NSRange, foreground: RGBColor?, background: RGBColor?)
    case resetColors(range: NSRange, foreground: Bool, background: Bool)
    case font(range: NSRange, face: String?, size: Double?)
    case appearance(range: NSRange, patch: TextStylePatch)
    case paragraph(ParagraphPatch)
    case avatar(String)
    case stat(TriggerStatisticUpdate)
}

public actor TriggerEngine {
    private struct ActiveMultiline: Sendable {
        var triggerID: UUID
        var children: [Trigger]
        var lineLimit: Int
        var lineCount: Int
        var expiresAt: Date?
    }

    private var lastHit: [UUID: Date] = [:]
    private var multiline: [ActiveMultiline] = []
    private var pendingMultiline: [ActiveMultiline] = []
    private var traceEvents: [AutomationTraceEvent] = []
    private var isAway = false
    private var awayNotified = false

    public init() {}

    public func resetRuntimeState() {
        lastHit.removeAll(keepingCapacity: true)
        multiline.removeAll(keepingCapacity: true)
        pendingMultiline.removeAll(keepingCapacity: true)
        traceEvents.removeAll(keepingCapacity: true)
        isAway = false
        awayNotified = false
    }

    public func process(_ line: RenderedLine, triggers: [Trigger], variables: [String: String], now: Date = Date(), isAway: Bool = false) throws -> [AutomationEffect] {
        updateAwayState(isAway)
        traceEvents.removeAll(keepingCapacity: true)
        var effects: [AutomationEffect] = []
        var stopped = false
        var workingLine = line
        try processMultiline(&workingLine, variables: variables, now: now, effects: &effects, stopped: &stopped)
        try process(&workingLine, triggers: triggers, variables: variables, now: now, effects: &effects, stopped: &stopped)
        advanceMultiline(now: now)
        return effects
    }

    public func process(_ line: RenderedLine, groups: [TriggerGroup], variables: [String: String], now: Date = Date(), isAway: Bool = false) throws -> [AutomationEffect] {
        updateAwayState(isAway)
        traceEvents.removeAll(keepingCapacity: true)
        var effects: [AutomationEffect] = []
        var stopped = false
        var workingLine = line
        try processMultiline(&workingLine, variables: variables, now: now, effects: &effects, stopped: &stopped)
        for group in groups where !stopped {
            guard group.active else {
                traceEvents.append(.init(
                    engine: .trigger,
                    description: "Trigger group",
                    pattern: "<group>",
                    input: line.text,
                    matchCount: 0,
                    output: line.text,
                    reason: "Skipped: disabled group"
                ))
                continue
            }
            try process(&workingLine, triggers: group.triggers, variables: variables, now: now, effects: &effects, stopped: &stopped)
        }
        advanceMultiline(now: now)
        return effects
    }

    /// Processes a deliberately scoped trigger tree without running any
    /// previously armed multiline trees. This is used while a Spawn action is
    /// capturing output with `OnlyChildrenDuringCapture` enabled: unrelated
    /// multiline triggers must not observe those captured lines.
    public func processOnly(_ line: RenderedLine, triggers: [Trigger], variables: [String: String], now: Date = Date(), isAway: Bool = false) throws -> [AutomationEffect] {
        updateAwayState(isAway)
        traceEvents.removeAll(keepingCapacity: true)
        var effects: [AutomationEffect] = []
        var stopped = false
        var workingLine = line
        try process(&workingLine, triggers: triggers, variables: variables, now: now, effects: &effects, stopped: &stopped)
        advanceMultiline(now: now)
        return effects
    }

    public func lastTrace() -> [AutomationTraceEvent] { traceEvents }

    private func process(
        _ line: inout RenderedLine,
        triggers: [Trigger],
        variables: [String: String],
        now: Date,
        effects: inout [AutomationEffect],
        stopped: inout Bool
    ) throws {
        for trigger in triggers where !stopped {
            if trigger.folder {
                if trigger.childrenActive {
                    try process(&line, triggers: trigger.children, variables: variables, now: now, effects: &effects, stopped: &stopped)
                }
                continue
            }
            if trigger.disabled {
                traceEvents.append(.init(
                    engine: .trigger,
                    description: trigger.description,
                    pattern: trigger.folder ? "<folder>" : trigger.match.text,
                    input: line.text,
                    matchCount: 0,
                    output: line.text,
                    reason: "Skipped: trigger disabled"
                ))
                if let options = trigger.multiline, options.isEnabled {
                    activateMultiline(for: trigger, options: options, now: now)
                } else if trigger.childrenActive {
                    try process(&line, triggers: trigger.children, variables: variables, now: now, effects: &effects, stopped: &stopped)
                }
                continue
            }
            if let cooldown = trigger.cooldown,
               let previous = lastHit[trigger.id], now.timeIntervalSince(previous) < cooldown {
                traceEvents.append(.init(
                    engine: .trigger,
                    description: trigger.description,
                    pattern: trigger.match.text,
                    input: line.text,
                    matchCount: 0,
                    output: line.text,
                    reason: "Skipped: cooldown active"
                ))
                continue
            }
            if trigger.awayPresent,
               (trigger.away && (!isAway || (trigger.awayPresentOnce && awayNotified))
                || (!trigger.away && isAway)) {
                let state = trigger.away ? "Away" : "Present"
                let once = trigger.awayPresentOnce && awayNotified ? " once-per-state already fired" : ""
                traceEvents.append(.init(
                    engine: .trigger,
                    description: trigger.description,
                    pattern: trigger.match.text,
                    input: line.text,
                    matchCount: 0,
                    output: line.text,
                    reason: "Skipped: \(state) condition not met\(once)"
                ))
                continue
            }
            let captures: [MatchCapture]
            do {
                captures = try trigger.match.matches(in: line.text)
            } catch {
                traceEvents.append(.init(
                    engine: .trigger,
                    description: trigger.description,
                    pattern: trigger.match.text,
                    input: line.text,
                    matchCount: 0,
                    output: "Invalid regular expression: \(error.localizedDescription)",
                    reason: "Skipped: invalid regex"
                ))
                continue
            }
            traceEvents.append(.init(
                engine: .trigger,
                description: trigger.description,
                pattern: trigger.match.text,
                input: line.text,
                matchCount: captures.count,
                output: line.text
            ))
            guard !captures.isEmpty else { continue }
            if trigger.awayPresentOnce { awayNotified = true }
            lastHit[trigger.id] = now
            var cumulativeDelta = 0
            for originalCapture in trigger.oncePerLine ? Array(captures.prefix(1)) : captures {
                var capture = Self.offset(originalCapture, by: cumulativeDelta)
                for action in trigger.actions {
                    let actionEffects = makeEffects(
                        for: action,
                        line: line,
                        capture: capture,
                        variables: variables,
                        children: trigger.children
                    )
                    effects.append(contentsOf: actionEffects)
                    for effect in actionEffects {
                        let delta = Self.applyReplacement(effect, to: &line)
                        cumulativeDelta += delta
                        if delta != 0 {
                            capture = Self.replacingLength(in: capture, delta: delta)
                        }
                    }
                }
            }
            if let options = trigger.multiline, options.isEnabled {
                activateMultiline(for: trigger, options: options, now: now)
            } else {
                if trigger.childrenActive {
                    try process(&line, triggers: trigger.children, variables: variables, now: now, effects: &effects, stopped: &stopped)
                }
            }
            if trigger.stopProcessing {
                traceEvents.append(.init(
                    engine: .trigger,
                    description: trigger.description,
                    pattern: trigger.match.text,
                    input: line.text,
                    matchCount: 0,
                    output: line.text,
                    reason: "Stop Processing: remaining triggers skipped"
                ))
                stopped = true
            }
        }
    }

    private func processMultiline(
        _ line: inout RenderedLine,
        variables: [String: String],
        now: Date,
        effects: inout [AutomationEffect],
        stopped: inout Bool
    ) throws {
        multiline.removeAll { $0.expiresAt.map { $0 <= now } ?? false }
        for active in multiline where !stopped {
            try process(&line, triggers: active.children, variables: variables, now: now, effects: &effects, stopped: &stopped)
        }
    }

    private static func offset(_ capture: MatchCapture, by delta: Int) -> MatchCapture {
        guard delta != 0 else { return capture }
        return .init(values: capture.values, ranges: capture.ranges.map {
            $0.location == NSNotFound ? $0 : NSRange(location: $0.location + delta, length: $0.length)
        })
    }

    private static func replacingLength(in capture: MatchCapture, delta: Int) -> MatchCapture {
        guard !capture.ranges.isEmpty else { return capture }
        var ranges = capture.ranges
        ranges[0].length = max(0, ranges[0].length + delta)
        return .init(values: capture.values, ranges: ranges)
    }

    private static func applyReplacement(_ effect: AutomationEffect, to line: inout RenderedLine) -> Int {
        let range: NSRange
        let replacement: String
        switch effect {
        case let .replace(valueRange, value):
            range = valueRange
            replacement = value
        case let .replaceHTML(valueRange, value):
            range = valueRange
            replacement = visibleText(fromHTML: value)
        default:
            return 0
        }
        guard let swiftRange = Range(range, in: line.text) else { return 0 }
        line.text.replaceSubrange(swiftRange, with: replacement)
        return replacement.utf16.count - range.length
    }

    private static func visibleText(fromHTML source: String) -> String {
        let withoutTags = source.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        return withoutTags
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    private func activateMultiline(for trigger: Trigger, options: MultilineTriggerOptions, now: Date) {
        multiline.removeAll { $0.triggerID == trigger.id }
        pendingMultiline.removeAll { $0.triggerID == trigger.id }
        pendingMultiline.insert(.init(
            triggerID: trigger.id,
            children: trigger.children,
            lineLimit: options.lineLimit,
            lineCount: 0,
            expiresAt: options.timeLimit > 0 ? now.addingTimeInterval(options.timeLimit) : nil
        ), at: 0)
    }

    private func updateAwayState(_ value: Bool) {
        if isAway != value { awayNotified = false }
        isAway = value
    }

    private func advanceMultiline(now: Date) {
        multiline = multiline.compactMap { active in
            guard active.expiresAt.map({ $0 > now }) ?? true else { return nil }
            var updated = active
            updated.lineCount += 1
            guard updated.lineLimit == 0 || updated.lineCount < updated.lineLimit else { return nil }
            return updated
        }
        multiline = pendingMultiline + multiline
        pendingMultiline.removeAll()
    }

    private func makeEffects(
        for action: TriggerAction,
        line: RenderedLine,
        capture: MatchCapture,
        variables: [String: String],
        children: [Trigger]
    ) -> [AutomationEffect] {
        switch action {
        case let .replace(template, expand):
            return [.replace(range: capture.range, with: Expansion.apply(template, capture: capture, variables: expand ? variables : [:]))]
        case let .replaceHTML(template, expand):
            return [.replaceHTML(
                range: capture.range,
                with: Expansion.apply(template, capture: capture, variables: expand ? variables : [:], escapeHTML: true)
            )]
        case let .gag(display, log):
            return (display ? [.gagDisplay] : []) + (log ? [.gagLog] : [])
        case let .send(template, captureIndex, expand, sendOnClick):
            let value = Expansion.apply(template, capture: capture, variables: expand ? variables : [:])
            guard sendOnClick else { return [.send(value)] }
            let requested = capture.ranges.indices.contains(captureIndex) ? capture.ranges[captureIndex] : capture.range
            let range = requested.location == NSNotFound ? capture.range : requested
            return [.link(range: range, send: value)]
        case let .spawn(action):
            var expanded = action
            expanded.title = Expansion.apply(action.title, capture: capture, variables: variables)
            expanded.tabGroup = Expansion.apply(action.tabGroup, capture: nil, variables: variables)
            expanded.captureUntil = Expansion.apply(action.captureUntil, capture: capture, variables: variables)
            return [.spawn(action: expanded, line: line, children: children)]
        case let .activity(important): return [.activity(important: important)]
        case .activateWindow: return [.activateWindow]
        case .suppressActivity: return [.suppressActivity]
        case let .sound(path): return [.sound(Expansion.apply(path, capture: nil, variables: variables))]
        case let .speech(template, wholeLine):
            return [.speech(wholeLine ? line.text : Expansion.apply(template, capture: capture, variables: variables))]
        case let .script(function): return [.script(function: function, ranges: capture.ranges, line: line)]
        case .notification: return [.notification(line.text)]
        case let .color(foreground, background, wholeLine):
            let ranges = visualRanges(for: capture, wholeLine: wholeLine, line: line)
            return ranges.map { .style(range: $0, foreground: foreground, background: background) }
        case let .colorDefault(foreground, background, wholeLine):
            return visualRanges(for: capture, wholeLine: wholeLine, line: line).map {
                .resetColors(range: $0, foreground: foreground, background: background)
            }
        case let .colorHash(foreground, background, wholeLine):
            let ranges = visualRanges(for: capture, wholeLine: wholeLine, line: line)
            let hashSource = wholeLine ? (capture.ranges.dropFirst().first ?? capture.range) : nil
            return ranges.map { range in
                let sourceRange = hashSource ?? range
                let text = Self.substring(line.text, range: sourceRange)
                return .style(
                    range: range,
                    foreground: foreground ? Self.hashColor(text, brightness: 1) : nil,
                    background: background ? Self.hashColor(text, brightness: 0.5) : nil
                )
            }
        case let .font(face, size, useDefault, wholeLine):
            return visualRanges(for: capture, wholeLine: wholeLine, line: line).map {
                .font(range: $0, face: useDefault ? nil : face, size: useDefault ? nil : size)
            }
        case let .appearance(patch, wholeLine):
            let ranges = visualRanges(for: capture, wholeLine: wholeLine, line: line)
            return ranges.map { .appearance(range: $0, patch: patch) }
        case var .paragraph(patch):
            let source = capture.ranges.dropFirst().first ?? capture.range
            let text = Self.substring(line.text, range: source)
            if patch.backgroundHash { patch.background = Self.hashColor(text, brightness: 0.5) }
            if patch.strokeHash { patch.strokeColor = Self.hashColor(text, brightness: 1) }
            return patch.isEmpty ? [] : [.paragraph(patch)]
        case let .avatar(url):
            return url.isEmpty ? [] : [.avatar(Expansion.apply(url, capture: capture, variables: variables))]
        case let .stat(action):
            return Self.statEffects(from: action, capture: capture, variables: variables)
        }
    }

    private func visualRanges(for capture: MatchCapture, wholeLine: Bool, line: RenderedLine) -> [NSRange] {
        if wholeLine { return [NSRange(location: 0, length: line.text.utf16.count)] }
        let ranges = capture.ranges.count > 1 ? Array(capture.ranges.dropFirst()) : [capture.range]
        return ranges.filter { $0.location != NSNotFound && $0.length > 0 }
    }

    private static func substring(_ value: String, range: NSRange) -> String {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else { return value }
        return String(value[swiftRange])
    }

    private static func hashColor(_ value: String, brightness: Double) -> RGBColor {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let hue = Double(hash & 0xFFF) / 4095
        let saturation = Double((hash >> 12) & 0xFFF) / 8190 + 0.5
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - floor(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - fraction * saturation)
        let t = brightness * (1 - (1 - fraction) * saturation)
        let rgb: (Double, Double, Double) = switch index {
        case 0: (brightness, t, p)
        case 1: (q, brightness, p)
        case 2: (p, brightness, t)
        case 3: (p, q, brightness)
        case 4: (t, p, brightness)
        default: (brightness, p, q)
        }
        return .init(red: UInt8(rgb.0 * 255), green: UInt8(rgb.1 * 255), blue: UInt8(rgb.2 * 255))
    }

    private static func statEffects(
        from action: TriggerStatAction,
        capture: MatchCapture,
        variables: [String: String]
    ) -> [AutomationEffect] {
        let expand: (String) -> String = { Expansion.apply($0, capture: capture, variables: variables) }
        let name = expand(action.name)
        guard !name.isEmpty else { return [] }
        let value: TriggerStatisticValue
        switch action.kind {
        case .integer:
            guard let integer = Int(expand(action.value)) else { return [] }
            value = .integer(integer)
        case .string:
            value = .string(expand(action.value))
        case .range:
            guard let current = Int(expand(action.value)),
                  let lower = Int(expand(action.lower)),
                  let upper = Int(expand(action.upper)) else { return [] }
            value = .range(value: current, lower: lower, upper: upper, color: action.rangeColor)
        }
        return [.stat(.init(
            title: expand(action.title),
            name: name,
            prefix: expand(action.prefix),
            value: value,
            addsToExistingInteger: action.addsToExistingInteger,
            color: action.color,
            nameAlignment: action.nameAlignment,
            font: action.font
        ))]
    }
}
