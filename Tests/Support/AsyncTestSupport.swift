import Foundation

/// A generous diagnostic deadline for asynchronous correctness tests. Shorter
/// intervals should be modeled by an injected sleeper instead of wall time.
public let asyncTestTimeout: Duration = .seconds(10)

public struct AsyncTestTimeoutError: LocalizedError, Sendable {
    public let operation: String
    public let observation: String

    public var errorDescription: String? {
        "Timed out waiting for \(operation). Last observation: \(observation)"
    }
}

/// Polls observable state until it satisfies a condition. Polling is only the
/// notification mechanism; the deadline is hang protection, not an assertion
/// about how fast the machine performs.
public func eventually<Value: Sendable>(
    _ operation: String,
    timeout: Duration = asyncTestTimeout,
    pollInterval: Duration = .milliseconds(10),
    observe: @escaping @Sendable () async throws -> Value,
    until condition: @escaping @Sendable (Value) -> Bool
) async throws -> Value {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var lastValue = try await observe()
    while !condition(lastValue) {
        guard clock.now < deadline else {
            throw AsyncTestTimeoutError(operation: operation, observation: String(describing: lastValue))
        }
        try await Task.sleep(for: pollInterval)
        lastValue = try await observe()
    }
    return lastValue
}

public func eventually(
    _ operation: String,
    timeout: Duration = asyncTestTimeout,
    pollInterval: Duration = .milliseconds(10),
    condition: @escaping @Sendable () async throws -> Bool
) async throws {
    _ = try await eventually(
        operation,
        timeout: timeout,
        pollInterval: pollInterval,
        observe: condition,
        until: { $0 }
    )
}

@MainActor
public func eventuallyOnMainActor(
    _ operation: String,
    timeout: Duration = asyncTestTimeout,
    pollInterval: Duration = .milliseconds(10),
    condition: @escaping @MainActor () throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while try !condition() {
        guard clock.now < deadline else {
            throw AsyncTestTimeoutError(operation: operation, observation: "condition remained false")
        }
        try await Task.sleep(for: pollInterval)
    }
}

/// Waits until work already enqueued on the main dispatch queue has run.
@MainActor
public func awaitMainActorQuiescence() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

/// A controllable sleeper for tests of timers and watchdogs. `advance()`
/// releases one generation of waits regardless of their requested duration.
public actor TestSleeper {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var requestedDurations: [Duration] = []

    public init() {}

    public func sleep(for duration: Duration) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    requestedDurations.append(duration)
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    public func pendingCount() -> Int { waiters.count }

    public func durations() -> [Duration] { requestedDurations }

    public func advance() {
        let active = waiters.values
        waiters.removeAll()
        active.forEach { $0.resume() }
    }

    public func cancelAll() {
        let active = waiters.values
        waiters.removeAll()
        active.forEach { $0.resume(throwing: CancellationError()) }
    }

    private func cancel(_ id: UUID) {
        if let continuation = waiters.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        }
    }
}
