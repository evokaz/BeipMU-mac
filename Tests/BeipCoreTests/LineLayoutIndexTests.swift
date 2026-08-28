import BeipCore
import XCTest

final class LineLayoutIndexTests: XCTestCase {
    func testOffsetsLookupAndVisibleIntersection() {
        let index = LineLayoutIndex(heights: [10, 20, 30, 40])
        XCTAssertEqual(index.count, 4)
        XCTAssertEqual(index.totalHeight, 100)
        XCTAssertEqual(index.yOffset(for: 0), 0)
        XCTAssertEqual(index.yOffset(for: 3), 60)
        XCTAssertEqual(index.yOffset(for: 4), 100)
        XCTAssertEqual(index.index(atVerticalOffset: 0), 0)
        XCTAssertEqual(index.index(atVerticalOffset: 9.9), 0)
        XCTAssertEqual(index.index(atVerticalOffset: 10), 1)
        XCTAssertEqual(index.index(atVerticalOffset: 99.9), 3)
        XCTAssertNil(index.index(atVerticalOffset: 100))
        XCTAssertEqual(index.visibleRange(intersecting: 5..<25), 0..<2)
        XCTAssertEqual(index.visibleRange(intersecting: 30..<60), 2..<3)
        XCTAssertEqual(index.visibleRange(intersecting: 100..<120), 0..<0)
    }

    func testLazyPrefixEvictionRebasesOffsetsAndCompacts() {
        var index = LineLayoutIndex()
        for value in 0..<4_000 { index.append(height: Double(value % 7 + 1)) }
        let originalHeight = index.totalHeight
        let removedHeight = (0..<2_500).reduce(0.0) { $0 + Double($1 % 7 + 1) }

        index.removeFirst(2_500)

        XCTAssertEqual(index.count, 1_500)
        XCTAssertEqual(index.totalHeight, originalHeight - removedHeight)
        XCTAssertEqual(index.yOffset(for: 0), 0)
        XCTAssertEqual(index.index(atVerticalOffset: 0), 0)
        XCTAssertEqual(index.visibleRange(intersecting: 0..<1), 0..<1)
    }

    func testRemoveLastAfterNormalAppendsKeepsOffsetsAndReturnsHeight() {
        var index = LineLayoutIndex(heights: [10, 20, 30])

        XCTAssertEqual(index.removeLast(), 30)
        XCTAssertEqual(index.count, 2)
        XCTAssertEqual(index.totalHeight, 30)
        XCTAssertEqual(index.yOffset(for: 2), 30)
        XCTAssertEqual(index.height(at: 1), 20)
    }

    func testRemoveLastAfterLazyPrefixEvictionKeepsRetainedIndex() {
        var index = LineLayoutIndex()
        for value in 0..<4_000 { index.append(height: Double(value % 7 + 1)) }
        let originalHeight = index.totalHeight
        let removedPrefixHeight = (0..<2_500).reduce(0.0) { $0 + Double($1 % 7 + 1) }
        let removedTailHeight = Double(3_999 % 7 + 1)

        index.removeFirst(2_500)
        XCTAssertEqual(index.removeLast(), removedTailHeight)

        XCTAssertEqual(index.count, 1_499)
        XCTAssertEqual(index.totalHeight, originalHeight - removedPrefixHeight - removedTailHeight)
        XCTAssertEqual(index.height(at: index.count - 1), Double(3_998 % 7 + 1))
    }

    func testRemoveLastToEmptyResetsTheIndex() {
        var index = LineLayoutIndex(heights: [10, 20])

        XCTAssertEqual(index.removeLast(), 20)
        XCTAssertEqual(index.removeLast(), 10)
        XCTAssertNil(index.removeLast())
        XCTAssertTrue(index.isEmpty)
        XCTAssertEqual(index.count, 0)
        XCTAssertEqual(index.totalHeight, 0)
        XCTAssertEqual(index.yOffset(for: 0), 0)
    }

    func testInvalidHeightsAndOverRemovalAreSafe() {
        var index = LineLayoutIndex(heights: [0, -.infinity, .nan, 5])
        XCTAssertEqual(index.totalHeight, 8)
        index.removeFirst(99)
        XCTAssertTrue(index.isEmpty)
        XCTAssertEqual(index.totalHeight, 0)
    }

    func testHundredThousandLineViewportQueriesRemainDeterministic() {
        var index = LineLayoutIndex()
        for _ in 0..<100_000 { index.append(height: 17) }
        for row in stride(from: 0, to: 100_000, by: 997) {
            let lower = Double(row * 17)
            let visible = index.visibleRange(intersecting: lower..<(lower + 680))
            XCTAssertEqual(visible.lowerBound, row)
            XCTAssertLessThanOrEqual(visible.count, 40)
        }
    }
}
