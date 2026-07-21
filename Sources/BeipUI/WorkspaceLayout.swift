import Foundation

enum WorkspacePaneKind: String, Codable, CaseIterable, Hashable, Sendable {
    case main
    case notes
    case diagnostics

    var title: String {
        switch self {
        case .main: "Session"
        case .notes: "Notes"
        case .diagnostics: "Diagnostics"
        }
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
