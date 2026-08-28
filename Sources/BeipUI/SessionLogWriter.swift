import BeipCore
import Foundation

/// The small portion of FileHandle used by session logging.
///
/// This is internal on purpose. Production logging uses the FileHandle
/// adapter below, while tests can provide a deterministic handle without
/// changing any user-facing API.
protocol SessionLogFileHandle: AnyObject {
    func seekToEnd() throws -> UInt64
    func write(contentsOf data: Data) throws
    func synchronize() throws
    func close() throws
}

private final class SystemSessionLogFileHandle: SessionLogFileHandle, @unchecked Sendable {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func seekToEnd() throws -> UInt64 { try handle.seekToEnd() }
    func write(contentsOf data: Data) throws { try handle.write(contentsOf: data) }
    func synchronize() throws { try handle.synchronize() }
    func close() throws { try handle.close() }
}

typealias SessionLogFileHandleFactory = (URL) throws -> any SessionLogFileHandle

struct SessionLogWriterFailure: Sendable {
    let token: UUID
    let message: String
}

typealias SessionLogWriterFailureHandler = @MainActor @Sendable (SessionLogWriterFailure) -> Void

private struct SessionLogWriterWorkerError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// Owns the serial worker and all state which can be touched by that worker.
/// The SessionLogWriter façade remains main-actor isolated, but the worker is
/// deliberately independent so a blocked FileHandle never blocks rendering or
/// enqueueing on the main actor.
private final class SessionLogWriteWorker: @unchecked Sendable {
    private enum Status {
        case open
        case stopping(Data)
        case failed
        case closed
    }

    private enum EnqueueResult {
        case ignored
        case accepted(shouldSchedule: Bool)
        case exceededBuffer(shouldSchedule: Bool)
    }

    private enum StopResult {
        case alreadyTerminated(message: String?)
        case scheduled(shouldSchedule: Bool)
    }

    private enum PassAction {
        case batch([Data])
        case finish(Data)
        case idle
        case terminated
    }

    private let handle: any SessionLogFileHandle
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let bufferLimit: Int
    private let token: UUID
    private let failureHandler: SessionLogWriterFailureHandler?

    private var status: Status = .open
    private var pending: [Data] = []
    /// Includes both queued data and the batch currently being written.
    private var pendingBytes = 0
    private var workerScheduled = false
    private var stopError: Error?
    private var failureMessage: String?

    init(
        handle: any SessionLogFileHandle,
        bufferLimit: Int,
        token: UUID,
        failureHandler: SessionLogWriterFailureHandler?
    ) {
        self.handle = handle
        queue = DispatchQueue(label: "com.beipmu.session-log.\(token.uuidString)")
        self.bufferLimit = max(0, bufferLimit)
        self.token = token
        self.failureHandler = failureHandler
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        let result: EnqueueResult = lock.withLock {
            guard case .open = status else { return .ignored }

            let exceedsLimit = data.count > bufferLimit || pendingBytes > bufferLimit - data.count
            if exceedsLimit {
                status = .failed
                failureMessage = "The pending log buffer exceeded \(Self.byteCountDescription(bufferLimit))."
                pending.removeAll(keepingCapacity: false)
                pendingBytes = 0
                let shouldSchedule = scheduleWorkerLocked()
                return .exceededBuffer(shouldSchedule: shouldSchedule)
            }

            pending.append(data)
            pendingBytes += data.count
            return .accepted(shouldSchedule: scheduleWorkerLocked())
        }

        switch result {
        case .ignored:
            break
        case let .accepted(shouldSchedule):
            if shouldSchedule { schedulePass() }
        case let .exceededBuffer(shouldSchedule):
            if shouldSchedule { schedulePass() }
            reportFailure("The pending log buffer exceeded \(Self.byteCountDescription(bufferLimit)).")
        }
    }

    /// Adds the stop marker and synchronously drains the worker. The marker
    /// is kept separate from the bounded live-data buffer so explicit stop
    /// always remains able to finalize a log which has nearly reached its cap.
    func stop(with marker: Data) throws {
        let result: StopResult = lock.withLock {
            switch status {
            case .open:
                status = .stopping(marker)
                return .scheduled(shouldSchedule: scheduleWorkerLocked())
            case .stopping:
                return .alreadyTerminated(message: nil)
            case .failed:
                return .alreadyTerminated(message: failureMessage)
            case .closed:
                return .alreadyTerminated(message: nil)
            }
        }

        if case let .alreadyTerminated(message: message) = result,
           let message {
            throw SessionLogWriterWorkerError(message: message)
        }
        guard case let .scheduled(shouldSchedule) = result else { return }
        if shouldSchedule { schedulePass() }
        queue.sync {}

        let error = lock.withLock { stopError }
        if let error { throw error }
    }

    /// Cancels without waiting for the worker. This is used after a live
    /// failure has already removed the writer from the coordinator.
    func cancel() {
        let shouldSchedule = lock.withLock { () -> Bool in
            switch status {
            case .open, .stopping:
                status = .failed
                pending.removeAll(keepingCapacity: false)
                pendingBytes = 0
                return scheduleWorkerLocked()
            case .failed, .closed:
                return false
            }
        }
        if shouldSchedule { schedulePass() }
    }

    private func scheduleWorkerLocked() -> Bool {
        guard !workerScheduled else { return false }
        workerScheduled = true
        return true
    }

    private func schedulePass() {
        queue.async { [self] in runPass() }
    }

    private func runPass() {
        while true {
            switch nextPassAction() {
            case let .batch(batch):
                for data in batch {
                    do {
                        try handle.write(contentsOf: data)
                    } catch {
                        failFromWorker(error)
                        return
                    }

                    let shouldStop = lock.withLock {
                        guard pendingBytes >= data.count else {
                            pendingBytes = 0
                            return isTerminalFailure(status)
                        }
                        pendingBytes -= data.count
                        return isTerminalFailure(status)
                    }
                    if shouldStop {
                        closeAfterCancellation()
                        return
                    }
                }
            case let .finish(marker):
                finishSynchronously(with: marker)
                return
            case .idle:
                return
            case .terminated:
                closeAfterCancellation()
                return
            }
        }
    }

    private func nextPassAction() -> PassAction {
        lock.withLock {
            switch status {
            case .open, .stopping:
                if !pending.isEmpty {
                    let batch = pending
                    pending.removeAll(keepingCapacity: false)
                    return .batch(batch)
                }
                if case let .stopping(marker) = status { return .finish(marker) }
                workerScheduled = false
                return .idle
            case .failed, .closed:
                workerScheduled = false
                return .terminated
            }
        }
    }

    private func failFromWorker(_ error: Error) {
        let shouldReport = lock.withLock { () -> Bool in
            switch status {
            case .open:
                status = .failed
                failureMessage = error.localizedDescription
                pending.removeAll(keepingCapacity: false)
                pendingBytes = 0
                return true
            case .stopping:
                status = .failed
                failureMessage = error.localizedDescription
                stopError = error
                pending.removeAll(keepingCapacity: false)
                pendingBytes = 0
                return false
            case .failed, .closed:
                return false
            }
        }
        if shouldReport { reportFailure(error.localizedDescription) }
        closeAfterCancellation()
    }

    private func closeAfterCancellation() {
        try? handle.close()
        lock.withLock {
            if case .failed = status { workerScheduled = false }
            if case .closed = status { workerScheduled = false }
        }
    }

    private func finishSynchronously(with marker: Data) {
        var firstError: Error?
        do { try handle.write(contentsOf: marker) }
        catch { firstError = error }
        do { try handle.synchronize() }
        catch { if firstError == nil { firstError = error } }
        do { try handle.close() }
        catch { if firstError == nil { firstError = error } }

        lock.withLock {
            stopError = firstError
            status = .closed
            workerScheduled = false
            pending.removeAll(keepingCapacity: false)
            pendingBytes = 0
        }
    }

    private func reportFailure(_ message: String) {
        guard let failureHandler else { return }
        let failure = SessionLogWriterFailure(token: token, message: message)
        Task { @MainActor in failureHandler(failure) }
    }

    private func isTerminalFailure(_ status: Status) -> Bool {
        if case .failed = status { return true }
        return false
    }

    private static func byteCountDescription(_ count: Int) -> String {
        if count % (1024 * 1024) == 0 { return "\(count / (1024 * 1024)) MiB" }
        if count % 1024 == 0 { return "\(count / 1024) KiB" }
        return "\(count) bytes"
    }
}

@MainActor
final class SessionLogWriter {
    static let defaultBufferSize = 8 * 1024 * 1024

    let url: URL
    let format: SessionLogFormat
    let token = UUID()

    private let renderer: SessionLogRenderer
    private let worker: SessionLogWriteWorker
    private var stopped = false

    init(
        url: URL,
        options: SessionLogOptions,
        title: String,
        foregroundHex: String,
        backgroundHex: String,
        history: [RenderedLine] = [],
        bufferSizeOverride: Int? = nil,
        fileHandleFactory: @escaping SessionLogFileHandleFactory = SessionLogWriter.defaultFileHandle,
        failureHandler: SessionLogWriterFailureHandler? = nil
    ) throws {
        self.url = url
        format = .infer(from: url)
        renderer = .init(
            format: format,
            options: options,
            title: title,
            foregroundHex: foregroundHex,
            backgroundHex: backgroundHex
        )

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }

        let handle = try fileHandleFactory(url)
        do {
            let size = try handle.seekToEnd()
            if size == 0 { try Self.write(renderer.documentHeader(), to: handle) }
            try Self.write(renderer.startMarker(), to: handle)
            for line in history { try Self.write(renderer.line(line), to: handle) }
        } catch {
            try? handle.close()
            throw error
        }

        worker = SessionLogWriteWorker(
            handle: handle,
            bufferLimit: bufferSizeOverride ?? Self.defaultBufferSize,
            token: token,
            failureHandler: failureHandler
        )
    }

    /// Convenience label for tests and other internal callers which prefer a
    /// non-optional override.
    convenience init(
        url: URL,
        options: SessionLogOptions,
        title: String,
        foregroundHex: String,
        backgroundHex: String,
        history: [RenderedLine] = [],
        bufferSize: Int,
        fileHandleFactory: @escaping SessionLogFileHandleFactory = SessionLogWriter.defaultFileHandle,
        failureHandler: SessionLogWriterFailureHandler? = nil
    ) throws {
        try self.init(
            url: url,
            options: options,
            title: title,
            foregroundHex: foregroundHex,
            backgroundHex: backgroundHex,
            history: history,
            bufferSizeOverride: bufferSize,
            fileHandleFactory: fileHandleFactory,
            failureHandler: failureHandler
        )
    }

    func append(_ line: RenderedLine) {
        enqueue(renderer.line(line))
    }

    func appendTyped(_ text: String, at date: Date = Date()) {
        enqueue(renderer.typed(text, at: date))
    }

    func appendSent(_ text: String, at date: Date = Date()) {
        enqueue(renderer.sent(text, at: date))
    }

    func appendScript(_ text: String) {
        enqueue(text)
    }

    func appendScriptLine(_ text: String) {
        enqueue(renderer.line(.init(text: text)))
    }

    func stop() throws {
        guard !stopped else { return }
        stopped = true
        try worker.stop(with: Data(renderer.stopMarker().utf8))
    }

    /// Makes removal after an asynchronous failure non-blocking. A failed
    /// worker is already responsible for closing its handle when its current
    /// write returns.
    func cancel() {
        guard !stopped else { return }
        stopped = true
        worker.cancel()
    }

    private func enqueue(_ text: String) {
        guard !stopped, !text.isEmpty else { return }
        worker.enqueue(Data(text.utf8))
    }

    private static func write(_ text: String, to handle: any SessionLogFileHandle) throws {
        guard !text.isEmpty else { return }
        try handle.write(contentsOf: Data(text.utf8))
    }

    nonisolated static func defaultFileHandle(for url: URL) throws -> any SessionLogFileHandle {
        SystemSessionLogFileHandle(try FileHandle(forWritingTo: url))
    }
}
