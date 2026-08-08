import Foundation
import BeipCore

enum WorkspacePaneKind: Hashable, Sendable, CaseIterable {
    case main
    case notes
    case diagnostics
    case atlas
    case ai
    case webView(String)
    case spawn(String)
    case spawnTabs(String)

    static var allCases: [WorkspacePaneKind] { [.main, .notes, .diagnostics] }

    var title: String {
        switch self {
        case .main: "Session"
        case .notes: "Notes"
        case .diagnostics: "Diagnostics"
        case .atlas: "Atlas"
        case .ai: "AI"
        case let .webView(identifier): identifier.isEmpty ? "Web View" : identifier
        case let .spawn(title): title
        case let .spawnTabs(title): title
        }
    }

    private var persistenceValue: String {
        switch self {
        case .main: "main"
        case .notes: "notes"
        case .diagnostics: "diagnostics"
        case .atlas: "atlas"
        case .ai: "ai"
        case let .webView(value): "webView:\(Self.encoded(value))"
        case let .spawn(value): "spawn:\(Self.encoded(value))"
        case let .spawnTabs(value): "spawnTabs:\(Self.encoded(value))"
        }
    }

    private static func encoded(_ value: String) -> String { Data(value.utf8).base64EncodedString() }

    private static func decoded(_ value: Substring) -> String? {
        Data(base64Encoded: String(value)).map { String(decoding: $0, as: UTF8.self) }
    }
}

extension WorkspacePaneKind: Codable {
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "main": self = .main
        case "notes": self = .notes
        case "diagnostics": self = .diagnostics
        case "atlas": self = .atlas
        case "ai": self = .ai
        default:
            guard let separator = value.firstIndex(of: ":"),
                  let payload = Self.decoded(value[value.index(after: separator)...]) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unknown workspace pane \(value)"
                )
            }
            switch value[..<separator] {
            case "webView": self = .webView(payload)
            case "spawn": self = .spawn(payload)
            case "spawnTabs": self = .spawnTabs(payload)
            default:
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unknown workspace pane \(value)"
                )
            }
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(persistenceValue)
    }
}

enum WorkspaceSplitAxis: String, Codable, Hashable, Sendable {
    case columns
    case rows
}

enum WorkspaceLayoutBranch: String, Codable, Hashable, Sendable {
    case first
    case second
}

indirect enum WorkspaceLayoutNode: Codable, Equatable, Sendable {
    case pane(WorkspacePaneKind)
    case tabs(panes: [WorkspacePaneKind], selected: WorkspacePaneKind)
    case split(
        axis: WorkspaceSplitAxis,
        fraction: Double,
        first: WorkspaceLayoutNode,
        second: WorkspaceLayoutNode
    )

    static let mainOnly: Self = .pane(.main)

    static let tabbedRight: Self = .split(
        axis: .columns,
        fraction: 0.72,
        first: .pane(.main),
        second: .tabs(panes: [.notes, .diagnostics], selected: .notes)
    )

    static let splitSidebars: Self = .split(
        axis: .columns,
        fraction: 0.22,
        first: .pane(.notes),
        second: .split(
            axis: .columns,
            fraction: 0.76,
            first: .pane(.main),
            second: .pane(.diagnostics)
        )
    )

    static let stackedRight: Self = .split(
        axis: .columns,
        fraction: 0.72,
        first: .pane(.main),
        second: .split(
            axis: .rows,
            fraction: 0.5,
            first: .pane(.notes),
            second: .pane(.diagnostics)
        )
    )

    static let stackedBottom: Self = .split(
        axis: .rows,
        fraction: 0.72,
        first: .pane(.main),
        second: .split(
            axis: .columns,
            fraction: 0.5,
            first: .pane(.notes),
            second: .pane(.diagnostics)
        )
    )

    static func legacyDocked(_ placement: WorkspaceDockPlacement, fraction: Double = 0.72) -> Self {
        let auxiliary: Self = .tabs(panes: [.notes, .diagnostics], selected: .notes)
        let main: Self = .pane(.main)
        let retained = min(0.85, max(0.15, fraction))
        switch placement {
        case .left:
            return .split(axis: .columns, fraction: 1 - retained, first: auxiliary, second: main)
        case .right:
            return .split(axis: .columns, fraction: retained, first: main, second: auxiliary)
        case .top:
            return .split(axis: .rows, fraction: 1 - retained, first: auxiliary, second: main)
        case .bottom:
            return .split(axis: .rows, fraction: retained, first: main, second: auxiliary)
        case .hidden, .floating:
            return .mainOnly
        }
    }

    var panes: [WorkspacePaneKind] {
        switch self {
        case let .pane(pane): [pane]
        case let .tabs(panes, _): panes
        case let .split(_, _, first, second): first.panes + second.panes
        }
    }

    var isValid: Bool {
        let listed = panes
        guard listed.filter({ $0 == .main }).count == 1,
              Set(listed).count == listed.count else { return false }
        return nodesAreValid
    }

    var normalized: Self {
        guard isValid else { return .tabbedRight }
        return normalizedNodes
    }

    private var normalizedNodes: Self {
        switch self {
        case .pane:
            return self
        case let .tabs(panes, selected):
            return .tabs(panes: panes, selected: panes.contains(selected) ? selected : panes[0])
        case let .split(axis, fraction, first, second):
            return .split(
                axis: axis,
                fraction: min(0.85, max(0.15, fraction)),
                first: first.normalizedNodes,
                second: second.normalizedNodes
            )
        }
    }

    func replacingSplitFraction(at path: [WorkspaceLayoutBranch], with fraction: Double) -> Self {
        guard case let .split(axis, existing, first, second) = self else { return self }
        let value = min(0.85, max(0.15, fraction))
        guard let branch = path.first else {
            return .split(axis: axis, fraction: value, first: first, second: second)
        }
        let remainder = Array(path.dropFirst())
        switch branch {
        case .first:
            return .split(
                axis: axis,
                fraction: existing,
                first: first.replacingSplitFraction(at: remainder, with: value),
                second: second
            )
        case .second:
            return .split(
                axis: axis,
                fraction: existing,
                first: first,
                second: second.replacingSplitFraction(at: remainder, with: value)
            )
        }
    }

    func hasSameTopology(as other: Self) -> Bool {
        switch (self, other) {
        case let (.pane(left), .pane(right)):
            left == right
        case let (.tabs(left, _), .tabs(right, _)):
            left == right
        case let (.split(leftAxis, _, leftFirst, leftSecond), .split(rightAxis, _, rightFirst, rightSecond)):
            leftAxis == rightAxis
                && leftFirst.hasSameTopology(as: rightFirst)
                && leftSecond.hasSameTopology(as: rightSecond)
        default:
            false
        }
    }

    func inserting(_ pane: WorkspacePaneKind, side: WebViewDockSide, fraction: Double = 0.72) -> Self {
        let base = removing(pane) ?? .mainOnly
        return base.insertingBesideMain(pane, side: side, fraction: fraction).normalized
    }

    func insertingVerticalStack(
        _ pane: WorkspacePaneKind,
        side: WebViewDockSide,
        fraction: Double = 0.72,
        matching isStackPane: (WorkspacePaneKind) -> Bool,
        relativeTo target: WorkspacePaneKind? = nil,
        before: Bool = false
    ) -> Self {
        var stacked = panes.filter { candidate in
            isStackPane(candidate) && candidate != pane && dockSide(of: candidate) == side
        }
        if let target, let index = stacked.firstIndex(of: target) {
            stacked.insert(pane, at: before ? index : index + 1)
        } else {
            stacked.append(pane)
        }
        let base = stacked.reduce(removing(pane) ?? .mainOnly) { layout, stackedPane in
            layout.removing(stackedPane) ?? .mainOnly
        }
        guard let stack = Self.verticalStack(stacked) else { return base.normalized }
        return base.insertingNodeBesideMain(stack, side: side, fraction: fraction).normalized
    }

    func dockSide(of pane: WorkspacePaneKind) -> WebViewDockSide? {
        switch self {
        case .pane:
            return nil
        case let .tabs(panes, _):
            return panes.contains(pane) ? .right : nil
        case let .split(axis, _, first, second):
            let firstHasMain = first.panes.contains(.main)
            let secondHasMain = second.panes.contains(.main)
            if firstHasMain {
                if second.panes.contains(pane) { return axis == .columns ? .right : .bottom }
                return first.dockSide(of: pane)
            }
            if secondHasMain {
                if first.panes.contains(pane) { return axis == .columns ? .left : .top }
                return second.dockSide(of: pane)
            }
            return nil
        }
    }

    func removing(_ pane: WorkspacePaneKind) -> Self? {
        switch self {
        case let .pane(existing):
            return existing == pane ? nil : self
        case let .tabs(panes, selected):
            let retained = panes.filter { $0 != pane }
            guard !retained.isEmpty else { return nil }
            if retained.count == 1 { return .pane(retained[0]) }
            return .tabs(panes: retained, selected: retained.contains(selected) ? selected : retained[0])
        case let .split(axis, fraction, first, second):
            let newFirst = first.removing(pane)
            let newSecond = second.removing(pane)
            switch (newFirst, newSecond) {
            case let (first?, second?): return .split(axis: axis, fraction: fraction, first: first, second: second)
            case let (first?, nil): return first
            case let (nil, second?): return second
            case (nil, nil): return nil
            }
        }
    }

    /// Removes panes that do not have a live session surface to restore.
    ///
    /// Spawn panes are part of a session's layout, but the global fallback
    /// layout can be reused by a different world. Keeping an unavailable
    /// spawn pane in that fallback produces a misleading placeholder instead
    /// of an empty/default workspace.
    func removingPanes(where shouldRemove: (WorkspacePaneKind) -> Bool) -> Self? {
        switch self {
        case let .pane(pane):
            return shouldRemove(pane) ? nil : self
        case let .tabs(panes, selected):
            let retained = panes.filter { !shouldRemove($0) }
            guard !retained.isEmpty else { return nil }
            return .tabs(
                panes: retained,
                selected: retained.contains(selected) ? selected : retained[0]
            )
        case let .split(axis, fraction, first, second):
            let retainedFirst = first.removingPanes(where: shouldRemove)
            let retainedSecond = second.removingPanes(where: shouldRemove)
            switch (retainedFirst, retainedSecond) {
            case let (first?, second?):
                return .split(axis: axis, fraction: fraction, first: first, second: second)
            case let (first?, nil): return first
            case let (nil, second?): return second
            case (nil, nil): return nil
            }
        }
    }

    private func insertingBesideMain(_ pane: WorkspacePaneKind, side: WebViewDockSide, fraction: Double) -> Self {
        insertingNodeBesideMain(.pane(pane), side: side, fraction: fraction)
    }

    private func insertingNodeBesideMain(_ node: WorkspaceLayoutNode, side: WebViewDockSide, fraction: Double) -> Self {
        if self == .pane(.main) {
            let retained = min(0.85, max(0.15, fraction))
            switch side {
            case .left: return .split(axis: .columns, fraction: 1 - retained, first: node, second: self)
            case .right: return .split(axis: .columns, fraction: retained, first: self, second: node)
            case .top: return .split(axis: .rows, fraction: 1 - retained, first: node, second: self)
            case .bottom: return .split(axis: .rows, fraction: retained, first: self, second: node)
            }
        }
        switch self {
        case .pane, .tabs: return self
        case let .split(axis, fraction, first, second):
            if first.panes.contains(.main) {
                return .split(
                    axis: axis,
                    fraction: fraction,
                    first: first.insertingNodeBesideMain(node, side: side, fraction: fraction),
                    second: second
                )
            }
            return .split(
                axis: axis,
                fraction: fraction,
                first: first,
                second: second.insertingNodeBesideMain(node, side: side, fraction: fraction)
            )
        }
    }

    private static func verticalStack(_ panes: [WorkspacePaneKind]) -> Self? {
        guard let first = panes.first else { return nil }
        guard panes.count > 1 else { return .pane(first) }
        let remainder = Array(panes.dropFirst())
        guard let rest = verticalStack(remainder) else { return .pane(first) }
        return .split(
            axis: .rows,
            fraction: 1 / Double(panes.count),
            first: .pane(first),
            second: rest
        )
    }

    private var nodesAreValid: Bool {
        switch self {
        case .pane:
            true
        case let .tabs(panes, selected):
            !panes.isEmpty && !panes.contains(.main) && Set(panes).count == panes.count && panes.contains(selected)
        case let .split(_, fraction, first, second):
            fraction.isFinite && first.nodesAreValid && second.nodesAreValid
        }
    }
}
