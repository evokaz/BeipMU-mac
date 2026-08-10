@testable import BeipAutomation
import BeipCore
import BeipTestSupport
import Foundation
import XCTest

final class DelaySchedulerTests: XCTestCase {
    func testDelayCommandGrammarAndScheduler() async throws {
        let registry = CommandRegistry()
        XCTAssertEqual(registry.parse("/delay list", variables: [:]), .delay(.list))
        XCTAssertEqual(registry.parse("/delay killall", variables: [:]), .delay(.killAll))
        XCTAssertEqual(registry.parse("/delay kill timer", variables: [:]), .delay(.kill("timer")))
        XCTAssertEqual(
            registry.parse("/delay id pulse every 2m \"look\"", variables: [:]),
            .delay(.schedule(id: "pulse", repeating: true, seconds: 120, command: "look"))
        )

        let sleeper = TestSleeper()
        let scheduler = DelayScheduler(sleep: sleeper.sleep(for:))
        let fired = expectation(description: "delayed action")
        let id = await scheduler.schedule(repeating: false, seconds: 0.01, command: "look") { command in
            XCTAssertEqual(command, "look")
            fired.fulfill()
        }
        XCTAssertEqual(id, "1")
        let initialEntries = await scheduler.entries()
        XCTAssertEqual(initialEntries.map(\.id), ["1"])
        try await eventually("delay scheduler to begin sleeping") {
            await sleeper.pendingCount() == 1
        }
        await sleeper.advance()
        await fulfillment(of: [fired], timeout: 10)
        try await eventually("one-shot delay removal") {
            await scheduler.entries().isEmpty
        }
        let finalEntries = await scheduler.entries()
        XCTAssertTrue(finalEntries.isEmpty)
    }

    func testReplacingTimerIDCannotEraseItsReplacementAfterOldActionCompletes() async throws {
        let sleeper = TestSleeper()
        let scheduler = DelayScheduler(sleep: sleeper.sleep(for:))
        let oldStarted = expectation(description: "old timer action started")
        let releaseOld = expectation(description: "release old timer action")
        let replacementFired = expectation(description: "replacement timer fired")
        let oldReleaseGate = AsyncGate()

        _ = await scheduler.schedule(id: "shared", repeating: false, seconds: 0, command: "old") { _ in
            oldStarted.fulfill()
            await oldReleaseGate.wait()
            releaseOld.fulfill()
        }
        try await eventually("old delay to begin sleeping") {
            await sleeper.pendingCount() == 1
        }
        await sleeper.advance()
        await fulfillment(of: [oldStarted], timeout: 10)
        _ = await scheduler.schedule(id: "shared", repeating: false, seconds: 0.05, command: "new") { command in
            XCTAssertEqual(command, "new")
            replacementFired.fulfill()
        }
        await oldReleaseGate.open()
        await fulfillment(of: [releaseOld], timeout: 10)
        try await eventually("replacement delay to begin sleeping") {
            await sleeper.pendingCount() == 1
        }
        await sleeper.advance()
        await fulfillment(of: [replacementFired], timeout: 10)
        try await eventually("replacement delay removal") {
            await scheduler.entries().isEmpty
        }
        let entries = await scheduler.entries()
        XCTAssertTrue(entries.isEmpty)
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
