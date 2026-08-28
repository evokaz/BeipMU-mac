import Foundation

/// Compact vertical index used by line-based virtualized views. Appends and
/// viewport queries are logarithmic or better; prefix eviction uses a lazy
/// head and periodically compacts instead of shifting every retained line.
public struct LineLayoutIndex: Sendable, Equatable {
    private var heights: [Double] = []
    private var ends: [Double] = []
    private var head = 0
    private var baseOffset: Double = 0

    public init() {}

    public init<S: Sequence>(heights: S) where S.Element == Double {
        replaceHeights(with: heights)
    }

    public var count: Int { heights.count - head }
    public var isEmpty: Bool { count == 0 }
    public var totalHeight: Double { max(0, (ends.last ?? baseOffset) - baseOffset) }

    @discardableResult
    public mutating func append(height: Double) -> Int {
        let normalized = max(1, height.isFinite ? height : 1)
        heights.append(normalized)
        ends.append((ends.last ?? 0) + normalized)
        return count - 1
    }

    public mutating func removeFirst(_ requestedCount: Int) {
        let removed = min(max(0, requestedCount), count)
        guard removed > 0 else { return }
        head += removed
        baseOffset = ends[head - 1]
        if head == heights.count {
            removeAll(keepingCapacity: true)
        } else if head >= 1_024, head * 2 >= heights.count {
            compact()
        }
    }

    /// Removes the last retained height and returns it without rebuilding the
    /// retained prefix, including when the prefix has a lazy head.
    @discardableResult
    public mutating func removeLast() -> Double? {
        guard !isEmpty else { return nil }
        let removed = heights.removeLast()
        ends.removeLast()
        if head == heights.count {
            removeAll(keepingCapacity: true)
        }
        return removed
    }

    public mutating func removeAll(keepingCapacity: Bool = false) {
        heights.removeAll(keepingCapacity: keepingCapacity)
        ends.removeAll(keepingCapacity: keepingCapacity)
        head = 0
        baseOffset = 0
    }

    public mutating func replaceHeights<S: Sequence>(with values: S) where S.Element == Double {
        removeAll(keepingCapacity: true)
        for height in values { append(height: height) }
    }

    public func height(at index: Int) -> Double? {
        guard index >= 0, index < count else { return nil }
        return heights[head + index]
    }

    public func yOffset(for index: Int) -> Double? {
        guard index >= 0, index <= count else { return nil }
        guard index > 0 else { return 0 }
        return ends[head + index - 1] - baseOffset
    }

    public func index(atVerticalOffset y: Double) -> Int? {
        guard !isEmpty, y >= 0, y < totalHeight else { return nil }
        let physical = firstEnd(after: y + baseOffset)
        guard physical < ends.count else { return nil }
        return physical - head
    }

    public func visibleRange(intersecting range: Range<Double>) -> Range<Int> {
        guard !isEmpty, range.upperBound > 0, range.lowerBound < totalHeight else { return 0..<0 }
        let lower = max(0, range.lowerBound)
        let upper = min(totalHeight, range.upperBound)
        let first = max(head, firstEnd(after: lower + baseOffset))
        let lastPhysical = firstEnd(atOrAfter: upper + baseOffset)
        let upperIndex = min(ends.count, max(first, lastPhysical + 1))
        return (first - head)..<(upperIndex - head)
    }

    private func firstEnd(after value: Double) -> Int {
        var lower = head
        var upper = ends.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ends[middle] > value { upper = middle }
            else { lower = middle + 1 }
        }
        return lower
    }

    private func firstEnd(atOrAfter value: Double) -> Int {
        var lower = head
        var upper = ends.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ends[middle] >= value { upper = middle }
            else { lower = middle + 1 }
        }
        return lower
    }

    private mutating func compact() {
        let retainedHeights = Array(heights[head...])
        heights.removeAll(keepingCapacity: true)
        ends.removeAll(keepingCapacity: true)
        head = 0
        baseOffset = 0
        for height in retainedHeights { append(height: height) }
    }
}
