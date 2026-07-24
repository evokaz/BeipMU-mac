import BeipCore
import Foundation

private final class OutputDrainCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[ScriptOutput], Never>?

    init(_ continuation: CheckedContinuation<[ScriptOutput], Never>) {
        self.continuation = continuation
    }

    func resume(returning outputs: [ScriptOutput]) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outputs)
    }
}

@objc public protocol ScriptServiceProtocol {
    func evaluate(_ source: NSString, hostJSON: NSString, reply: @escaping @Sendable (NSString?, NSString?, NSString?) -> Void)
    func call(_ function: NSString, arguments: [NSString], hostJSON: NSString, reply: @escaping @Sendable (NSString?, NSString?, NSString?) -> Void)
    func callTrigger(_ function: NSString, ranges: [NSNumber], lineJSON: NSString, hostJSON: NSString, reply: @escaping @Sendable (NSString?, NSString?, NSString?) -> Void)
    func dispatchConnectionEvent(_ event: NSString, arguments: [NSString], lineJSON: NSString, hostJSON: NSString, reply: @escaping @Sendable (NSString?, NSString?, NSString?) -> Void)
    func drainOutputs(reply: @escaping @Sendable (NSString?) -> Void)
    func reset(reply: @escaping @Sendable () -> Void)
    func helpTypes(reply: @escaping @Sendable ([NSString]) -> Void)
}

public actor ScriptServiceClient {
    private var connection: NSXPCConnection?
    private var connectionGeneration: UUID?
    private var pending: [UUID: CheckedContinuation<ScriptEvaluation, Never>] = [:]
    private var watchdogs: [UUID: Task<Void, Never>] = [:]
    private var outputPoller: Task<Void, Never>?
    private var asyncOutputHandler: (@MainActor @Sendable ([ScriptOutput]) -> Void)?
    private let requestWatchdogInterval: TimeInterval
    private let connectionFactory: @Sendable () -> NSXPCConnection
    /// Matches the three-second watchdog before the Windows client exposes
    /// its script-abort UI. A fresh XPC connection gives macOS a recoverable
    /// boundary even though JavaScriptCore cannot interrupt a tight loop.
    public static let watchdogInterval: TimeInterval = 3

    public init() {
        requestWatchdogInterval = Self.watchdogInterval
        connectionFactory = {
            NSXPCConnection(serviceName: "org.beipmu.BeipMU.ScriptService")
        }
    }

    init(
        watchdogInterval: TimeInterval,
        connectionFactory: @escaping @Sendable () -> NSXPCConnection
    ) {
        requestWatchdogInterval = watchdogInterval
        self.connectionFactory = connectionFactory
    }

    public func startAsyncOutputDelivery(
        _ handler: @escaping @MainActor @Sendable ([ScriptOutput]) -> Void
    ) {
        asyncOutputHandler = handler
        guard outputPoller == nil else { return }
        outputPoller = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    return
                }
                await self?.pollAsyncOutputs()
            }
        }
    }

    public func stopAsyncOutputDelivery() {
        outputPoller?.cancel()
        outputPoller = nil
        asyncOutputHandler = nil
    }

    public func evaluate(_ source: String, host: ScriptHostSnapshot = .init()) async -> ScriptEvaluation {
        let id = UUID()
        let connection = activeConnection()
        return await withCheckedContinuation { continuation in
            register(continuation, id: id)
            let proxy = connection.remoteObjectProxyWithErrorHandler(makeErrorHandler(id: id))
            guard let service = proxy as? ScriptServiceProtocol else {
                complete(id: id, result: .init(error: "Unable to create the BeipMU script service proxy."))
                return
            }
            service.evaluate(
                source as NSString,
                hostJSON: Self.encodeHost(host) as NSString,
                reply: makeEvaluationReply(id: id)
            )
        }
    }

    public func call(_ function: String, arguments: [String], host: ScriptHostSnapshot = .init()) async -> ScriptEvaluation {
        let id = UUID()
        let connection = activeConnection()
        return await withCheckedContinuation { continuation in
            register(continuation, id: id)
            let proxy = connection.remoteObjectProxyWithErrorHandler(makeErrorHandler(id: id))
            guard let service = proxy as? ScriptServiceProtocol else {
                complete(id: id, result: .init(error: "Unable to create the BeipMU script service proxy."))
                return
            }
            service.call(
                function as NSString,
                arguments: arguments.map { $0 as NSString },
                hostJSON: Self.encodeHost(host) as NSString,
                reply: makeEvaluationReply(id: id)
            )
        }
    }

    public func callTrigger(
        _ function: String,
        ranges: [NSRange],
        line: RenderedLine,
        host: ScriptHostSnapshot = .init()
    ) async -> ScriptEvaluation {
        let id = UUID()
        let connection = activeConnection()
        let flattened = ranges.flatMap { [$0.location, NSMaxRange($0)] }.map(NSNumber.init(value:))
        return await withCheckedContinuation { continuation in
            register(continuation, id: id)
            let proxy = connection.remoteObjectProxyWithErrorHandler(makeErrorHandler(id: id))
            guard let service = proxy as? ScriptServiceProtocol else {
                complete(id: id, result: .init(error: "Unable to create the BeipMU script service proxy."))
                return
            }
            service.callTrigger(
                function as NSString,
                ranges: flattened,
                lineJSON: Self.encodeLine(line) as NSString,
                hostJSON: Self.encodeHost(host) as NSString,
                reply: makeEvaluationReply(id: id)
            )
        }
    }

    public func dispatchConnectionEvent(
        _ event: String,
        arguments: [String] = [],
        line: RenderedLine? = nil,
        host: ScriptHostSnapshot = .init()
    ) async -> ScriptEvaluation {
        let id = UUID()
        let connection = activeConnection()
        return await withCheckedContinuation { continuation in
            register(continuation, id: id)
            let proxy = connection.remoteObjectProxyWithErrorHandler(makeErrorHandler(id: id))
            guard let service = proxy as? ScriptServiceProtocol else {
                complete(id: id, result: .init(error: "Unable to create the BeipMU script service proxy."))
                return
            }
            service.dispatchConnectionEvent(
                event as NSString,
                arguments: arguments.map { $0 as NSString },
                lineJSON: Self.encodeOptionalLine(line) as NSString,
                hostJSON: Self.encodeHost(host) as NSString,
                reply: makeEvaluationReply(id: id)
            )
        }
    }

    public func reset() async {
        // Discarding the connection, rather than asking a potentially blocked
        // JavaScriptCore actor to reset itself, is the macOS equivalent of the
        // Windows abort/reset path. The service exports a distinct runtime for
        // every connection, so the next evaluation cannot queue behind it.
        terminate(reason: "Scripting runtime reset.")
    }

    public func invalidate() {
        outputPoller?.cancel()
        outputPoller = nil
        terminate(reason: "Scripting service connection was invalidated.")
    }

    private func pollAsyncOutputs() async {
        guard connection != nil, let asyncOutputHandler else { return }
        let outputs = await withCheckedContinuation { continuation in
            let completion = OutputDrainCompletion(continuation)
            let proxy = activeConnection().remoteObjectProxyWithErrorHandler(
                makeDrainErrorHandler(completion: completion)
            )
            guard let service = proxy as? ScriptServiceProtocol else {
                completion.resume(returning: [])
                return
            }
            service.drainOutputs(reply: makeDrainReply(completion: completion))
        }
        guard !outputs.isEmpty else { return }
        await asyncOutputHandler(outputs)
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = connectionFactory()
        let generation = UUID()
        connection.remoteObjectInterface = NSXPCInterface(with: ScriptServiceProtocol.self)
        connection.interruptionHandler = makeConnectionFailureHandler(
            generation: generation,
            reason: "Scripting service was interrupted; the runtime was reset."
        )
        connection.invalidationHandler = makeConnectionFailureHandler(
            generation: generation,
            reason: "Scripting service was invalidated; the runtime was reset."
        )
        connection.resume()
        self.connection = connection
        connectionGeneration = generation
        return connection
    }

    private func register(_ continuation: CheckedContinuation<ScriptEvaluation, Never>, id: UUID) {
        pending[id] = continuation
        let interval = requestWatchdogInterval
        watchdogs[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            await self?.watchdogExpired(id: id)
        }
    }

    private func complete(id: UUID, result: ScriptEvaluation) {
        watchdogs.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(returning: result)
    }

    private func watchdogExpired(id: UUID) {
        guard pending[id] != nil else { return }
        terminate(reason: "Script exceeded the \(Self.formatWatchdogInterval(requestWatchdogInterval))-second watchdog and was aborted; the scripting service connection was reset.")
    }

    private func connectionFailed(generation: UUID, reason: String) {
        guard connectionGeneration == generation else { return }
        terminate(reason: reason)
    }

    /// NSXPC invokes these blocks on its private queues. Building them from a
    /// nonisolated context prevents Swift from attaching this actor's executor
    /// to an Objective-C callback that must first hop back through `Task`.
    private nonisolated func makeErrorHandler(id: UUID) -> @Sendable (Error) -> Void {
        { [weak self] error in
            Task { await self?.complete(id: id, result: .init(error: error.localizedDescription)) }
        }
    }

    private nonisolated func makeEvaluationReply(
        id: UUID
    ) -> @Sendable (NSString?, NSString?, NSString?) -> Void {
        { [weak self] value, error, outputs in
            let result = ScriptEvaluation(
                value: value as String?,
                error: error as String?,
                outputs: Self.decodeOutputs(outputs as String?)
            )
            Task { await self?.complete(id: id, result: result) }
        }
    }

    private nonisolated func makeConnectionFailureHandler(
        generation: UUID,
        reason: String
    ) -> @Sendable () -> Void {
        { [weak self] in
            Task { await self?.connectionFailed(generation: generation, reason: reason) }
        }
    }

    private nonisolated func makeDrainErrorHandler(
        completion: OutputDrainCompletion
    ) -> @Sendable (Error) -> Void {
        { _ in completion.resume(returning: []) }
    }

    private nonisolated func makeDrainReply(
        completion: OutputDrainCompletion
    ) -> @Sendable (NSString?) -> Void {
        { source in completion.resume(returning: Self.decodeOutputs(source as String?)) }
    }

    private func terminate(reason: String) {
        let oldConnection = connection
        connection = nil
        connectionGeneration = nil
        oldConnection?.invalidate()
        let suspended = pending
        pending.removeAll()
        let activeWatchdogs = watchdogs
        watchdogs.removeAll()
        activeWatchdogs.values.forEach { $0.cancel() }
        for continuation in suspended.values {
            continuation.resume(returning: .init(error: reason))
        }
    }

    private static func decodeOutputs(_ source: String?) -> [ScriptOutput] {
        guard let source, let data = source.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ScriptOutput].self, from: data)) ?? []
    }

    private static func formatWatchdogInterval(_ interval: TimeInterval) -> String {
        if interval.rounded() == interval {
            return String(Int(interval))
        }
        return String(format: "%.3g", interval)
    }

    private static func encodeHost(_ host: ScriptHostSnapshot) -> String {
        guard let data = try? JSONEncoder().encode(host),
              let source = String(data: data, encoding: .utf8) else { return "{}" }
        return source
    }

    private static func encodeLine(_ line: RenderedLine) -> String {
        guard let data = try? JSONEncoder().encode(line),
              let source = String(data: data, encoding: .utf8) else { return "{}" }
        return source
    }

    private static func encodeOptionalLine(_ line: RenderedLine?) -> String {
        guard let line else { return "null" }
        return encodeLine(line)
    }
}
