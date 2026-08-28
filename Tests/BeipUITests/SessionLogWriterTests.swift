import BeipCore
import BeipTestSupport
import Foundation
@testable import BeipUI
import XCTest

@MainActor
final class SessionLogWriterTests: XCTestCase {
    func testBlockedLiveWriteDoesNotBlockMainActorAppends() throws {
        let handle = TestSessionLogFileHandle()
        let writer = try makeWriter(handle: handle)
        defer { handle.releaseBlockedWrite() }

        handle.blockNextWrite()
        writer.appendScript("first\n")
        XCTAssertEqual(handle.writeStarted.wait(timeout: .now() + 1), .success)

        let start = ContinuousClock.now
        for index in 0..<100 { writer.appendScript("queued-\(index)\n") }
        let elapsed = start.duration(to: .now)

        XCTAssertLessThan(elapsed, .seconds(1))

        handle.releaseBlockedWrite()
        try writer.stop()
        XCTAssertTrue(handle.recordedText.contains("queued-99"))
    }

    func testQueuedChunksRemainInOriginalOrder() throws {
        let handle = TestSessionLogFileHandle()
        let writer = try makeWriter(handle: handle)
        defer { handle.releaseBlockedWrite() }

        handle.blockNextWrite()
        writer.appendScript("one\n")
        XCTAssertEqual(handle.writeStarted.wait(timeout: .now() + 1), .success)
        writer.appendScript("two\n")
        writer.appendScript("three\n")
        writer.appendScript("four\n")
        handle.releaseBlockedWrite()

        try writer.stop()
        let result = handle.recordedText
        XCTAssertLessThan(result.range(of: "one\n")!.lowerBound, result.range(of: "two\n")!.lowerBound)
        XCTAssertLessThan(result.range(of: "two\n")!.lowerBound, result.range(of: "three\n")!.lowerBound)
        XCTAssertLessThan(result.range(of: "three\n")!.lowerBound, result.range(of: "four\n")!.lowerBound)
    }

    func testStopDrainsQueuedContentThenSynchronizesAndCloses() throws {
        let handle = TestSessionLogFileHandle()
        let writer = try makeWriter(handle: handle)
        defer { handle.releaseBlockedWrite() }

        handle.blockNextWrite()
        writer.appendScript("before stop\n")
        XCTAssertEqual(handle.writeStarted.wait(timeout: .now() + 1), .success)
        writer.appendScript("after first\n")

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            handle.releaseBlockedWrite()
        }
        try writer.stop()

        let events = handle.events
        let stopWrite = try XCTUnwrap(
            events.lastIndex(where: { $0.contains("Logging stopped") }),
            "events: \(events)"
        )
        XCTAssertEqual(Array(events.dropFirst(stopWrite + 1)), ["synchronize", "close"])
        XCTAssertTrue(handle.recordedText.contains("Logging stopped"))
    }

    func testWriteFailureIsReportedOnce() async throws {
        let handle = TestSessionLogFileHandle()
        let recorder = FailureRecorder()
        let writer = try makeWriter(handle: handle) { failure in
            recorder.record(failure)
        }

        handle.failNextWrite()
        writer.appendScript("failure\n")
        try await eventually("write failure callback") {
            recorder.count == 1
        }
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(recorder.failures.first?.token, writer.token)
        XCTAssertTrue(recorder.failures.first?.message.isEmpty == false)
        writer.cancel()
    }

    func testStopPropagatesAWriteFailureFromItsSynchronousDrain() throws {
        let handle = TestSessionLogFileHandle()
        let writer = try makeWriter(handle: handle)
        defer { handle.releaseBlockedWrite() }

        handle.blockNextWrite()
        handle.failNextWrite()
        writer.appendScript("fails while stopping\n")
        XCTAssertEqual(handle.writeStarted.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            handle.releaseBlockedWrite()
        }

        XCTAssertThrowsError(try writer.stop()) { error in
            XCTAssertTrue(error.localizedDescription.contains("simulated write failure"))
        }
    }

    func testBufferOverflowCancelsWithoutWaitingForBlockedWorker() async throws {
        let handle = TestSessionLogFileHandle()
        let recorder = FailureRecorder()
        let writer = try makeWriter(handle: handle, bufferSize: 16) { failure in
            recorder.record(failure)
        }
        defer { handle.releaseBlockedWrite() }

        handle.blockNextWrite()
        writer.appendScript("1234567890")
        XCTAssertEqual(handle.writeStarted.wait(timeout: .now() + 1), .success)

        let start = ContinuousClock.now
        writer.appendScript("1234567")
        let elapsed = start.duration(to: .now)

        XCTAssertLessThan(elapsed, .seconds(1))
        await awaitMainActorQuiescence()
        XCTAssertEqual(recorder.count, 1)
        XCTAssertTrue(recorder.failures[0].message.contains("16 bytes"))

        handle.releaseBlockedWrite()
    }

    func testCoordinatorRemovesOnlyTheWriterWithTheFailedToken() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failedURL = directory.appendingPathComponent("failed.txt")
        let healthyURL = directory.appendingPathComponent("healthy.txt")
        let failedHandle = TestSessionLogFileHandle()
        let healthyHandle = TestSessionLogFileHandle()
        let recorder = CoordinatorRecorder()
        let coordinator = makeCoordinator(
            handles: [failedURL: failedHandle, healthyURL: healthyHandle],
            recorder: recorder
        )

        coordinator.start(template: failedURL.path, history: .none, outputHistory: [], visibleHistory: [])
        coordinator.start(template: healthyURL.path, history: .none, outputHistory: [], visibleHistory: [])
        failedHandle.failNextWrite()
        coordinator.appendScript("fails\n", asLine: false)

        try await eventuallyOnMainActor("failed log removal") {
            coordinator.activeURLs.count == 1 && coordinator.activeURLs.first == healthyURL
        }
        XCTAssertEqual(recorder.errors.count, 1)
        XCTAssertTrue(recorder.errors[0].contains("failed.txt"))

        coordinator.stopAll(announcing: false)
    }

    func testCoordinatorBufferOverflowLeavesOtherLogsActive() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let overflowingURL = directory.appendingPathComponent("overflowing.txt")
        let healthyURL = directory.appendingPathComponent("healthy.txt")
        let overflowingHandle = TestSessionLogFileHandle()
        let healthyHandle = TestSessionLogFileHandle()
        let recorder = CoordinatorRecorder()
        let coordinator = makeCoordinator(
            handles: [overflowingURL: overflowingHandle, healthyURL: healthyHandle],
            recorder: recorder,
            bufferSize: 16
        )

        coordinator.start(template: overflowingURL.path, history: .none, outputHistory: [], visibleHistory: [])
        coordinator.start(template: healthyURL.path, history: .none, outputHistory: [], visibleHistory: [])
        overflowingHandle.blockNextWrite()
        coordinator.appendScript("1234567890", asLine: false)
        XCTAssertEqual(overflowingHandle.writeStarted.wait(timeout: .now() + 1), .success)

        coordinator.appendScript("1234567", asLine: false)
        try await eventuallyOnMainActor("overflowing log removal") {
            coordinator.activeURLs == [healthyURL]
        }
        XCTAssertEqual(recorder.errors.count, 1)
        XCTAssertTrue(recorder.errors[0].contains("16 bytes"))

        overflowingHandle.releaseBlockedWrite()
        coordinator.stopAll(announcing: false)
    }

    func testInitialOpenFailureIsReportedImmediately() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cannot-open.txt")
        let recorder = CoordinatorRecorder()
        let coordinator = makeCoordinator(handles: [:], recorder: recorder)

        coordinator.start(template: url.path, history: .none, outputHistory: [], visibleHistory: [])

        XCTAssertEqual(coordinator.activeLogCount, 0)
        XCTAssertEqual(recorder.errors.count, 1)
        XCTAssertTrue(recorder.errors[0].contains("Cannot create log"))
    }

    private func makeWriter(
        handle: TestSessionLogFileHandle,
        bufferSize: Int? = nil,
        failureHandler: SessionLogWriterFailureHandler? = nil
    ) throws -> SessionLogWriter {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLogWriterTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("session.txt")
        return try SessionLogWriter(
            url: url,
            options: .init(),
            title: "Test Session",
            foregroundHex: "#FFFFFF",
            backgroundHex: "#000000",
            bufferSizeOverride: bufferSize,
            fileHandleFactory: { _ in handle },
            failureHandler: failureHandler
        )
    }

    private func makeCoordinator(
        handles: [URL: TestSessionLogFileHandle],
        recorder: CoordinatorRecorder,
        bufferSize: Int? = nil
    ) -> SessionLoggingCoordinator {
        let context = SessionLoggingCoordinator.Context(
            options: { .init() },
            baseWindowTitle: { "Test Session" },
            serverName: { "Test Server" },
            characterName: { "Test Character" },
            loggingPath: { "" },
            workspaceSourceURL: { nil },
            themePalette: { (foreground: "#FFFFFF", background: "#000000") },
            automaticConfiguration: { .init() }
        )
        let callbacks = SessionLoggingCoordinator.Callbacks(
            informationalNotice: { _ in },
            clientNotice: { _ in },
            error: { recorder.recordError($0) },
            stateChanged: { }
        )
        return SessionLoggingCoordinator(
            context: context,
            callbacks: callbacks,
            fileHandleFactory: { url in
                guard let handle = handles[url] else { throw TestSessionLogFileHandle.TestError.writeFailed }
                return handle
            },
            bufferSizeOverride: bufferSize
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionLoggingCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SessionLogWriterFailure] = []

    var count: Int { lock.withLock { values.count } }
    var failures: [SessionLogWriterFailure] { lock.withLock { values } }

    func record(_ value: SessionLogWriterFailure) {
        lock.withLock { values.append(value) }
    }
}

private final class CoordinatorRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var errorMessages: [String] = []

    var errors: [String] { lock.withLock { errorMessages } }

    func recordError(_ message: String) {
        lock.withLock { errorMessages.append(message) }
    }
}

private final class TestSessionLogFileHandle: SessionLogFileHandle, @unchecked Sendable {
    enum TestError: LocalizedError {
        case writeFailed

        var errorDescription: String? { "simulated write failure" }
    }

    private let lock = NSLock()
    private let proceed = DispatchSemaphore(value: 0)
    let writeStarted = DispatchSemaphore(value: 0)
    private var data = Data()
    private var eventList: [String] = []
    private var shouldBlockNextWrite = false
    private var shouldFailNextWrite = false

    var recordedText: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    var events: [String] { lock.withLock { eventList } }

    func blockNextWrite() {
        lock.withLock { shouldBlockNextWrite = true }
    }

    func releaseBlockedWrite() {
        proceed.signal()
    }

    func failNextWrite() {
        lock.withLock { shouldFailNextWrite = true }
    }

    func seekToEnd() throws -> UInt64 { lock.withLock { UInt64(data.count) } }

    func write(contentsOf value: Data) throws {
        let action = lock.withLock { () -> (block: Bool, fail: Bool) in
            let block = shouldBlockNextWrite
            let fail = shouldFailNextWrite
            shouldBlockNextWrite = false
            shouldFailNextWrite = false
            return (block, fail)
        }
        if action.block {
            writeStarted.signal()
            proceed.wait()
        }
        if action.fail { throw TestError.writeFailed }

        lock.withLock {
            data.append(value)
            let text = String(decoding: value, as: UTF8.self)
            if text.contains("Logging stopped") {
                eventList.append("write:Logging stopped")
            } else {
                let preview = String(decoding: value.prefix(32), as: UTF8.self)
                    .replacingOccurrences(of: "\n", with: "\\n")
                eventList.append("write:\(preview)")
            }
        }
    }

    func synchronize() throws {
        lock.withLock { eventList.append("synchronize") }
    }

    func close() throws {
        lock.withLock { eventList.append("close") }
    }
}
