@testable import BeipAutomation
import BeipCore
import BeipTestSupport
import Foundation
import XCTest

final class MatchingExpansionTests: XCTestCase {
    func testCaptureExpansionSupportsGroup99() throws {
        let pattern = String(repeating: "(a)", count: 99)
        let input = String(repeating: "a", count: 99)
        let capture = try XCTUnwrap(MatchDefinition(text: pattern, isRegularExpression: true).matches(in: input).first)

        XCTAssertEqual(capture.values.count, 100)
        XCTAssertEqual(Expansion.apply("$99", capture: capture, variables: [:]), "a")
    }

    func testCaptureExpansionSupportsWindowsBackslashFormsAndEscapedSlash() throws {
        let capture = try XCTUnwrap(MatchDefinition(text: "(hp) (<tag&>)", isRegularExpression: true).matches(in: "hp <tag&>").first)

        XCTAssertEqual(
            Expansion.apply("\\0|\\1|\\a02|\\\\|\\9", capture: capture, variables: [:]),
            "hp <tag&>|hp|<tag&>|\\|\\9"
        )
    }

    func testHTMLCaptureExpansionEscapesSubstitutions() throws {
        let capture = try XCTUnwrap(MatchDefinition(text: "(<tag&>)", isRegularExpression: true).matches(in: "<tag&>").first)

        XCTAssertEqual(
            Expansion.apply("<b>\\1</b>", capture: capture, variables: [:], escapeHTML: true),
            "<b>&lt;tag&amp;></b>"
        )
    }

    func testEmptyLiteralMatchProducesSingleStartCapture() throws {
        let captures = try MatchDefinition(text: "").matches(in: "abc")

        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.range, NSRange(location: 0, length: 0))
        XCTAssertEqual(captures.first?.values, [""])
    }

    func testLiteralWholeWordUsesWindowsLetterBoundaries() throws {
        let captures = try MatchDefinition(text: "cat", wholeWord: true).matches(in: "cat9 bobcat cat")

        XCTAssertEqual(captures.map(\.range), [
            NSRange(location: 0, length: 3),
            NSRange(location: 12, length: 3),
        ])
    }

    func testLiteralStartsWithAndEndsWithCombinationRequiresWholeLine() throws {
        let exact = MatchDefinition(text: "cat", startsWith: true, endsWith: true)
        let prefix = MatchDefinition(text: "cat", startsWith: true)
        let suffix = MatchDefinition(text: "cat", endsWith: true)

        XCTAssertEqual(try exact.matches(in: "cat").count, 1)
        XCTAssertEqual(try exact.matches(in: "cat nap").count, 0)
        XCTAssertEqual(try prefix.matches(in: "cat nap").first?.range, NSRange(location: 0, length: 3))
        XCTAssertEqual(try suffix.matches(in: "bobcat").first?.range, NSRange(location: 3, length: 3))
    }

    func testZeroLengthRegexStopsAfterFirstEmptyCapture() throws {
        let captures = try MatchDefinition(text: "(?=a)", isRegularExpression: true).matches(in: "aaa")

        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.range, NSRange(location: 0, length: 0))
    }
}
