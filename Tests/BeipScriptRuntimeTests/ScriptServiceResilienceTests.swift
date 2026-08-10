import BeipCore
@testable import BeipScriptRuntime
import BeipTestSupport
import Foundation
import XCTest

private final class M9ScriptService: NSObject, ScriptServiceProtocol, @unchecked Sendable {
    private let connectionNumber: Int
    private weak var connection: NSXPCConnection?
    private let lock = NSLock()
    private var shouldRaceDrainReplyWithInvalidation = false

    init(connectionNumber: Int, connection: NSXPCConnection) {
        self.connectionNumber = connectionNumber
        self.connection = connection
    }

    func evaluate(
        _ source: NSString,
        hostJSON: NSString,
        reply: @escaping @Sendable (NSString?, NSString?, NSString?) -> Void
    ) {
        switch source as String {
        case "while (true) {}":
            return
        case "terminate-service":
            connection?.invalidate()
        case "ordered-output":
            let outputs = [
                ScriptOutput(kind: .debugText, value: "first"),
                ScriptOutput(kind: .send, value: "second"),
                ScriptOutput(kind: .display, value: "third"),
            ]
            reply("ordered", nil, Self.encode(outputs))
        case "race-drain-invalidation":
            lock.lock()
            shouldRaceDrainReplyWithInvalidation = true
            lock.unlock()
            reply("armed", nil, Self.encode([]))
        case "host-state":
            let host = Self.decodeHost(hostJSON as String)
            let value = "\(host.configPath)|\(host.window.variables["character"] ?? "")"
            reply(value as NSString, nil, Self.encode([]))
        default:
            reply("\(connectionNumber)" as NSString, nil, Self.encode([]))
        }
    }

    func call(
        _ function: NSString,
        arguments: [NSString],
        hostJSON: NSString,
        reply: @escaping @Sendable (NSString?, NSString?, NSString?) -> Void
    ) {
        evaluate(function, hostJSON: hostJSON, reply: reply)
    }

    func callTrigger(
        _ function: NSString,
        ranges: [NSNumber],
        lineJSON: NSString,
        hostJSON: NSString,
        reply: @escaping @Sendable (NSString?, NSString?, NSString?) -> Void
    ) {
        evaluate(function, hostJSON: hostJSON, reply: reply)
    }

    func dispatchConnectionEvent(
        _ event: NSString,
        arguments: [NSString],
        lineJSON: NSString,
        hostJSON: NSString,
        reply: @escaping @Sendable (NSString?, NSString?, NSString?) -> Void
    ) {
        evaluate(event, hostJSON: hostJSON, reply: reply)
    }

    func drainOutputs(reply: @escaping @Sendable (NSString?) -> Void) {
        reply(Self.encode([]))
        lock.lock()
        let shouldInvalidate = shouldRaceDrainReplyWithInvalidation
        shouldRaceDrainReplyWithInvalidation = false
        lock.unlock()
        if shouldInvalidate {
            connection?.invalidate()
        }
    }

    func reset(reply: @escaping @Sendable () -> Void) {
        reply()
    }

    func helpTypes(reply: @escaping @Sendable ([NSString]) -> Void) {
        reply([])
    }

    private static func encode(_ outputs: [ScriptOutput]) -> NSString? {
        guard let data = try? JSONEncoder().encode(outputs),
              let source = String(data: data, encoding: .utf8) else { return nil }
        return source as NSString
    }

    private static func decodeHost(_ source: String) -> ScriptHostSnapshot {
        guard let data = source.data(using: .utf8),
              let host = try? JSONDecoder().decode(ScriptHostSnapshot.self, from: data) else {
            return .init()
        }
        return host
    }
}

private final class M9ScriptServiceListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []

    override init() {
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit {
        listener.invalidate()
    }

    func makeConnection() -> NSXPCConnection {
        NSXPCConnection(listenerEndpoint: listener.endpoint)
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        lock.lock()
        connections.append(connection)
        let connectionNumber = connections.count
        lock.unlock()
        connection.exportedInterface = NSXPCInterface(with: ScriptServiceProtocol.self)
        connection.exportedObject = M9ScriptService(
            connectionNumber: connectionNumber,
            connection: connection
        )
        connection.resume()
        return true
    }
}

final class ScriptServiceResilienceTests: XCTestCase {
    private let watchdogInterval: TimeInterval = 0.08

    func testInfiniteScriptExpiresWatchdogReconnectsAndPreservesHostState() async throws {
        let sleeper = TestSleeper()
        let (client, listener) = makeClient(watchdogSleep: sleeper.sleep(for:))
        let host = ScriptHostSnapshot(
            configPath: "/Users/test/Config.txt",
            window: .init(variables: ["character": "Ada"])
        )

        let pending = Task { await client.evaluate("while (true) {}", host: host) }
        try await eventually("script watchdog to be armed") {
            await sleeper.pendingCount() == 1
        }
        await sleeper.advance()
        let failure = await pending.value
        let recovered = await client.evaluate("host-state", host: host)

        XCTAssertTrue(failure.error?.contains("watchdog") == true)
        XCTAssertEqual(recovered.value, "/Users/test/Config.txt|Ada")
        withExtendedLifetime(listener) {}
    }

    func testExplicitResetCompletesPendingScriptAndNextEvaluationSucceeds() async throws {
        let (client, listener) = makeClient()
        let pending = Task { await client.evaluate("while (true) {}") }
        try await eventually("pending script before reset") {
            await client.pendingRequestCountForTesting() == 1
        }

        await client.reset()
        let resetResult = await pending.value
        let recovered = await client.evaluate("success")

        XCTAssertEqual(resetResult.error, "Scripting runtime reset.")
        XCTAssertEqual(recovered.value, "2")
        withExtendedLifetime(listener) {}
    }

    func testClientInvalidationCompletesPendingScriptAndReconnects() async throws {
        let (client, listener) = makeClient()
        let pending = Task { await client.evaluate("while (true) {}") }
        try await eventually("pending script before invalidation") {
            await client.pendingRequestCountForTesting() == 1
        }

        await client.invalidate()
        let invalidated = await pending.value
        let recovered = await client.evaluate("success")

        XCTAssertEqual(invalidated.error, "Scripting service connection was invalidated.")
        XCTAssertEqual(recovered.value, "2")
        withExtendedLifetime(listener) {}
    }

    func testServiceTerminationCompletesRequestAndReconnects() async {
        let (client, listener) = makeClient()

        let terminated = await client.evaluate("terminate-service")
        let recovered = await client.evaluate("success")

        XCTAssertNotNil(terminated.error)
        XCTAssertEqual(recovered.value, "2")
        withExtendedLifetime(listener) {}
    }

    func testDrainReplyRacingInvalidationCompletesOnceAndRecovers() async throws {
        let (client, listener) = makeClient()
        await client.startAsyncOutputDelivery { _ in }
        let armed = await client.evaluate("race-drain-invalidation")
        await client.pollAsyncOutputsForTesting()
        try await eventually("drain-race connection invalidation") {
            await !client.hasActiveConnectionForTesting()
        }
        let recovered = await client.evaluate("success")
        await client.stopAsyncOutputDelivery()

        XCTAssertEqual(armed.value, "armed")
        XCTAssertEqual(recovered.value, "2")
        withExtendedLifetime(listener) {}
    }

    func testOrderedCallbacksSurviveBeforeFailureAndCompletedWatchdogIsStale() async throws {
        let sleeper = TestSleeper()
        let (client, listener) = makeClient(watchdogSleep: sleeper.sleep(for:))

        let ordered = await client.evaluate("ordered-output")
        try await eventually("completed request watchdog cancellation") {
            await sleeper.pendingCount() == 0
        }
        await sleeper.advance()
        let sameConnection = await client.evaluate("success")
        let terminated = await client.evaluate("terminate-service")
        let recovered = await client.evaluate("ordered-output")

        XCTAssertEqual(ordered.outputs, [
            .init(kind: .debugText, value: "first"),
            .init(kind: .send, value: "second"),
            .init(kind: .display, value: "third"),
        ])
        XCTAssertEqual(sameConnection.value, "1", "A completed request's cancelled watchdog must not reset the connection.")
        XCTAssertNotNil(terminated.error)
        XCTAssertEqual(recovered.outputs, ordered.outputs)
        withExtendedLifetime(listener) {}
    }

    func testConcurrentNetworkCallbackAndScriptWatchdogRemainIsolated() async throws {
        let server = try ScriptedMUServer()
        let port = try await server.start()
        let serverTask = Task {
            try await server.run(.init(actions: [
                .init(expect: "ping"),
                .init(send: "pong", disconnect: true),
            ]))
        }
        let runtime = ScriptRuntime()
        let setup = await runtime.evaluate(
            """
            var socket = app.New_Socket();
            socket.SetOnConnect(function(value) { value.Send('ping'); });
            socket.SetOnReceive(function(value, text) { app.OutputDebugText(text); });
            socket.Connect('127.0.0.1', \(port));
            """
        )
        XCTAssertNil(setup.error)

        let (client, listener) = makeClient()
        async let scriptFailure = client.evaluate("while (true) {}")
        try await serverTask.value

        let networkOutputs = try await eventually(
            "script socket output",
            observe: { await runtime.drainAsyncOutputs() },
            until: { !$0.isEmpty }
        )
        let failure = await scriptFailure
        let recovered = await client.evaluate("success")
        server.stop()

        XCTAssertTrue(failure.error?.contains("watchdog") == true)
        XCTAssertTrue(networkOutputs.contains(.init(kind: .debugText, value: "pong")))
        XCTAssertEqual(recovered.value, "2")
        withExtendedLifetime(listener) {}
    }

    private func makeClient(
        watchdogSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> (ScriptServiceClient, M9ScriptServiceListener) {
        let listener = M9ScriptServiceListener()
        let client = ScriptServiceClient(
            watchdogInterval: watchdogInterval,
            watchdogSleep: watchdogSleep,
            connectionFactory: { [listener] in listener.makeConnection() }
        )
        return (client, listener)
    }
}
