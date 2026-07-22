import BeipCore
import Foundation

@objc public protocol ScriptServiceProtocol {
    func evaluate(_ source: NSString, hostJSON: NSString, reply: @escaping (NSString?, NSString?, NSString?) -> Void)
    func call(_ function: NSString, arguments: [NSString], hostJSON: NSString, reply: @escaping (NSString?, NSString?, NSString?) -> Void)
    func callTrigger(_ function: NSString, ranges: [NSNumber], lineJSON: NSString, hostJSON: NSString, reply: @escaping (NSString?, NSString?, NSString?) -> Void)
    func reset(reply: @escaping () -> Void)
    func helpTypes(reply: @escaping ([NSString]) -> Void)
}

public actor ScriptServiceClient {
    private var connection: NSXPCConnection?
    private var connectionGeneration: UUID?
    private var pending: [UUID: CheckedContinuation<ScriptEvaluation, Never>] = [:]
    private var watchdogs: [UUID: Task<Void, Never>] = [:]
    /// Matches the three-second watchdog before the Windows client exposes
    /// its script-abort UI. A fresh XPC connection gives macOS a recoverable
    /// boundary even though JavaScriptCore cannot interrupt a tight loop.
    public static let watchdogInterval: TimeInterval = 3

    public init() {}

    public func evaluate(_ source: String, host: ScriptHostSnapshot = .init()) async -> ScriptEvaluation {
        let id = UUID()
        let connection = activeConnection()
        return await withCheckedContinuation { continuation in
            register(continuation, id: id)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                Task { self.complete(id: id, result: .init(error: error.localizedDescription)) }
            }
            guard let service = proxy as? ScriptServiceProtocol else {
                complete(id: id, result: .init(error: "Unable to create the BeipMU script service proxy."))
                return
            }
            service.evaluate(source as NSString, hostJSON: Self.encodeHost(host) as NSString) { value, error, outputs in
                let result = ScriptEvaluation(
                    value: value as String?,
                    error: error as String?,
                    outputs: Self.decodeOutputs(outputs as String?)
                )
                Task { self.complete(id: id, result: result) }
            }
        }
    }

    public func call(_ function: String, arguments: [String], host: ScriptHostSnapshot = .init()) async -> ScriptEvaluation {
        let id = UUID()
        let connection = activeConnection()
        return await withCheckedContinuation { continuation in
            register(continuation, id: id)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                Task { self.complete(id: id, result: .init(error: error.localizedDescription)) }
            }
            guard let service = proxy as? ScriptServiceProtocol else {
                complete(id: id, result: .init(error: "Unable to create the BeipMU script service proxy."))
                return
            }
            service.call(function as NSString, arguments: arguments.map { $0 as NSString }, hostJSON: Self.encodeHost(host) as NSString) { value, error, outputs in
                let result = ScriptEvaluation(
                    value: value as String?,
                    error: error as String?,
                    outputs: Self.decodeOutputs(outputs as String?)
                )
                Task { self.complete(id: id, result: result) }
            }
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
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                Task { self.complete(id: id, result: .init(error: error.localizedDescription)) }
            }
            guard let service = proxy as? ScriptServiceProtocol else {
                complete(id: id, result: .init(error: "Unable to create the BeipMU script service proxy."))
                return
            }
            service.callTrigger(
                function as NSString,
                ranges: flattened,
                lineJSON: Self.encodeLine(line) as NSString,
                hostJSON: Self.encodeHost(host) as NSString
            ) { value, error, outputs in
                let result = ScriptEvaluation(
                    value: value as String?,
                    error: error as String?,
                    outputs: Self.decodeOutputs(outputs as String?)
                )
                Task { self.complete(id: id, result: result) }
            }
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
        terminate(reason: "Scripting service connection was invalidated.")
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(serviceName: "org.beipmu.BeipMU.ScriptService")
        let generation = UUID()
        connection.remoteObjectInterface = NSXPCInterface(with: ScriptServiceProtocol.self)
        connection.interruptionHandler = { [weak self] in
            Task { await self?.connectionFailed(generation: generation, reason: "Scripting service was interrupted; the runtime was reset.") }
        }
        connection.invalidationHandler = { [weak self] in
            Task { await self?.connectionFailed(generation: generation, reason: "Scripting service was invalidated; the runtime was reset.") }
        }
        connection.resume()
        self.connection = connection
        connectionGeneration = generation
        return connection
    }

    private func register(_ continuation: CheckedContinuation<ScriptEvaluation, Never>, id: UUID) {
        pending[id] = continuation
        watchdogs[id] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.watchdogInterval))
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
        terminate(reason: "Script exceeded the \(Int(Self.watchdogInterval))-second watchdog and was aborted; the scripting service connection was reset.")
    }

    private func connectionFailed(generation: UUID, reason: String) {
        guard connectionGeneration == generation else { return }
        terminate(reason: reason)
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
}
