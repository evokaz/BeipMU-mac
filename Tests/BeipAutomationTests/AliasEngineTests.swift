@testable import BeipAutomation
import BeipCore
import BeipTestSupport
import Foundation
import XCTest

final class AliasEngineTests: XCTestCase {
    func testAliasCaptureAndVariables() throws {
        let alias = Alias(
            match: .init(text: "^say (.+)$", isRegularExpression: true),
            replacement: "pose says $1 to %target%",
            expandVariables: true
        )
        let result = try AliasEngine.process("say hello", groups: [.init(aliases: [alias])], variables: ["target": "Sam"])
        XCTAssertEqual(result.text, "pose says hello to Sam")
        XCTAssertEqual(result.matchedAliases, [alias.id])
    }

    func testAliasReplacesEveryOccurrenceWithoutDiscardingUnmatchedText() throws {
        let alias = Alias(
            match: .init(text: "cat"),
            replacement: "dog"
        )
        let result = try AliasEngine.process(
            "cat and cat",
            groups: [.init(aliases: [alias])],
            variables: [:]
        )
        XCTAssertEqual(result.text, "dog and dog")
        XCTAssertEqual(result.matchedAliases, [alias.id])
        XCTAssertEqual(result.trace.map(\.matchCount), [2])
        XCTAssertEqual(result.trace.first?.output, "dog and dog")
    }

    func testAliasUsesWindowsReplacementCursorAndSkipsEmptyPlaceholders() throws {
        let expanding = Alias(match: .init(text: "a"), replacement: "aa")
        let empty = Alias(match: .init(text: ""), replacement: "unexpected")
        let result = try AliasEngine.process(
            "aaa",
            groups: [.init(aliases: [expanding, empty])],
            variables: [:]
        )
        XCTAssertEqual(result.text, "aaaaaa")
        XCTAssertEqual(result.matchedAliases, [expanding.id])
        XCTAssertEqual(result.trace.last?.matchCount, 0)
    }

    func testAliasInvalidRegexDoesNotPreventLaterAliases() throws {
        let invalid = Alias(description: "Bad", match: .init(text: "(", isRegularExpression: true), replacement: "bad")
        let valid = Alias(description: "Good", match: .init(text: "ok"), replacement: "done")
        let result = try AliasEngine.process("ok", groups: [.init(aliases: [invalid, valid])], variables: [:])
        XCTAssertEqual(result.text, "done")
        XCTAssertEqual(result.diagnostics.map(\.description), ["Bad"])
        XCTAssertTrue(result.trace.first?.reason?.contains("Invalid regular expression") == true)
    }

    func testAliasSpecificProcessingEchoAndCommandFlags() throws {
        let inactive = Alias(
            description: "Inactive",
            match: .init(text: "one"),
            replacement: "wrong",
            active: false
        )
        let command = Alias(
            description: "Command",
            match: .init(text: "two"),
            replacement: "/look",
            echo: false,
            processCommands: true
        )
        let result = try AliasEngine.process(
            "one two",
            groups: [.init(echo: true, processCommands: false, aliases: [inactive, command])],
            variables: [:]
        )

        XCTAssertEqual(result.text, "one /look")
        XCTAssertEqual(result.matchedAliases, [command.id])
        XCTAssertFalse(result.echo)
        XCTAssertTrue(result.processCommands)
        XCTAssertTrue(result.trace.contains { $0.reason == "Skipped: alias inactive" })
    }

    func testAliasUsesWindowsCaptureFormsAndFolderChildOrder() throws {
        let first = Alias(match: .init(text: "a"), replacement: "A")
        let post = Alias(match: .init(text: "A"), replacement: "B")
        let folder = Alias(
            match: .init(text: ""),
            replacement: "",
            folder: true,
            children: [first, post],
            childrenAfterCount: 1
        )
        let ordered = try AliasEngine.process("a", groups: [.init(aliases: [folder])], variables: [:])
        XCTAssertEqual(ordered.text, "B")

        let regex = Alias(
            match: .init(text: "(hp) (\\d+)", isRegularExpression: true),
            replacement: "\\0|\\1|\\a02|%who%",
            expandVariables: true
        )
        let result = try AliasEngine.process("hp 42", groups: [.init(aliases: [regex])], variables: ["who": "Ada"])
        XCTAssertEqual(result.text, "hp 42|hp|42|Ada")
    }

    func testAliasStopRunsAfterChildren() throws {
        let child = Alias(match: .init(text: "north"), replacement: "N")
        let parent = Alias(
            match: .init(text: "go"),
            replacement: "north",
            stopProcessing: true,
            children: [child]
        )
        let later = Alias(match: .init(text: "N"), replacement: "done")
        let stopped = try AliasEngine.process("go", groups: [.init(aliases: [parent, later])], variables: [:])
        XCTAssertEqual(stopped.text, "N")
        XCTAssertTrue(stopped.stopped)
    }

    func testAliasHierarchyRunsFoldersAlwaysAndChildrenOnlyAfterParentMatch() throws {
        let nested = Alias(match: .init(text: "north"), replacement: "N")
        let folder = Alias(
            match: .init(text: ""),
            replacement: "",
            folder: true,
            children: [nested]
        )
        let gated = Alias(
            match: .init(text: "go"),
            replacement: "north",
            children: [nested]
        )

        let folderResult = try AliasEngine.process(
            "north",
            groups: [.init(aliases: [folder])],
            variables: [:]
        )
        XCTAssertEqual(folderResult.text, "N")

        let noMatchResult = try AliasEngine.process(
            "north",
            groups: [.init(aliases: [gated])],
            variables: [:]
        )
        XCTAssertEqual(noMatchResult.text, "north")

        let matchResult = try AliasEngine.process(
            "go",
            groups: [.init(aliases: [gated])],
            variables: [:]
        )
        XCTAssertEqual(matchResult.text, "N")
    }
}
