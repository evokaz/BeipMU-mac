@preconcurrency import Network
import Foundation
import Security

public struct MUServerScript: Codable, Sendable {
    public var actions: [MUServerAction]

    public init(actions: [MUServerAction]) {
        self.actions = actions
    }

    public static func load(from url: URL) throws -> Self {
        let decoder = JSONDecoder()
        if let script = try? decoder.decode(Self.self, from: Data(contentsOf: url)) {
            return script
        }
        return Self(actions: try decoder.decode([MUServerAction].self, from: Data(contentsOf: url)))
    }
}

public struct MUServerAction: Codable, Sendable {
    public var send: String?
    public var sendHex: String?
    public var chunks: [Int]?
    public var expect: String?
    public var expectHex: String?
    public var delayMilliseconds: UInt64?
    public var disconnect: Bool?

    enum CodingKeys: String, CodingKey {
        case send, chunks, expect, disconnect
        case sendHex = "send_hex"
        case expectHex = "expect_hex"
        case delayMilliseconds = "delay_ms"
    }

    public init(
        send: String? = nil,
        sendHex: String? = nil,
        chunks: [Int]? = nil,
        expect: String? = nil,
        expectHex: String? = nil,
        delayMilliseconds: UInt64? = nil,
        disconnect: Bool? = nil
    ) {
        self.send = send
        self.sendHex = sendHex
        self.chunks = chunks
        self.expect = expect
        self.expectHex = expectHex
        self.delayMilliseconds = delayMilliseconds
        self.disconnect = disconnect
    }
}

public final class ScriptedMUServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.beipmu.scripted-server")
    private let lock = NSLock()
    private var listenerContinuation: CheckedContinuation<UInt16, Error>?
    private var connectionContinuation: CheckedContinuation<NWConnection, Error>?
    private var pendingConnection: NWConnection?
    private var activeConnection: NWConnection?

    public init(tlsIdentity: sec_identity_t? = nil) throws {
        let parameters: NWParameters
        if let tlsIdentity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, tlsIdentity)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        listener = try NWListener(using: parameters, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port?.rawValue else {
                    self.finishListener(.failure(ScriptedMUServerError.missingPort))
                    return
                }
                self.finishListener(.success(port))
            case let .failed(error): self.finishListener(.failure(error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            let continuation = self.lock.withLock { () -> CheckedContinuation<NWConnection, Error>? in
                self.activeConnection = connection
                if let continuation = self.connectionContinuation {
                    self.connectionContinuation = nil
                    return continuation
                }
                self.pendingConnection = connection
                return nil
            }
            continuation?.resume(returning: connection)
        }
    }

    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { listenerContinuation = continuation }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.finishListener(.failure(ScriptedMUServerError.timeout("listener readiness")))
            }
        }
    }

    public func run(_ script: MUServerScript) async throws {
        let connection = try await nextConnection()
        for (index, action) in script.actions.enumerated() {
            if let delay = action.delayMilliseconds {
                try await Task.sleep(for: .milliseconds(delay))
            }
            if action.send != nil || action.sendHex != nil {
                let payload = try action.payload(send: true, actionIndex: index)
                try await send(payload, chunks: action.chunks, on: connection)
            }
            if action.expect != nil || action.expectHex != nil {
                let expected = try action.payload(send: false, actionIndex: index)
                let received = try await receive(exactly: expected.count, on: connection)
                guard received == expected else {
                    throw ScriptedMUServerError.unexpectedBytes(action: index, expected: expected, actual: received)
                }
            }
            if action.disconnect == true {
                try await finish(connection)
                return
            }
        }
    }

    public func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        lock.withLock {
            activeConnection?.cancel()
            activeConnection = nil
            pendingConnection = nil
        }
        finishListener(.failure(ScriptedMUServerError.closed))
        finishConnection(.failure(ScriptedMUServerError.closed))
    }

    private func nextConnection() async throws -> NWConnection {
        try await withCheckedThrowingContinuation { continuation in
            let pending = lock.withLock { () -> NWConnection? in
                if let pendingConnection {
                    self.pendingConnection = nil
                    return pendingConnection
                }
                connectionContinuation = continuation
                return nil
            }
            if let pending { continuation.resume(returning: pending) }
            else {
                queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.finishConnection(.failure(ScriptedMUServerError.timeout("client connection")))
                }
            }
        }
    }

    private func send(_ payload: Data, chunks: [Int]?, on connection: NWConnection) async throws {
        let parts = try payload.partitioned(using: chunks)
        for part in parts {
            try await withTimeout("server send") { completion in
                connection.send(content: part, completion: .contentProcessed(completion))
            }
        }
    }

    private func receive(exactly count: Int, on connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let part: Data = try await withTimeout("server receive") { completion in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                    if let error { completion(error, Data()) }
                    else if let data, !data.isEmpty { completion(nil, data) }
                    else if complete { completion(ScriptedMUServerError.closed, Data()) }
                    else { completion(ScriptedMUServerError.emptyRead, Data()) }
                }
            }
            result.append(part)
        }
        return result
    }

    private func finish(_ connection: NWConnection) async throws {
        try await withTimeout("server disconnect") { completion in
            connection.send(content: nil, contentContext: .defaultStream, isComplete: true, completion: .contentProcessed(completion))
        }
    }

    private func withTimeout(
        _ operation: String,
        start: (@escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ScriptedContinuationGate<Void>(continuation)
            start { error in gate.resume(error.map(Result.failure) ?? .success(())) }
            queue.asyncAfter(deadline: .now() + 3) {
                gate.resume(.failure(ScriptedMUServerError.timeout(operation)))
            }
        }
    }

    private func withTimeout<Value: Sendable>(
        _ operation: String,
        start: (@escaping @Sendable (Error?, Value) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ScriptedContinuationGate<Value>(continuation)
            start { error, value in gate.resume(error.map(Result.failure) ?? .success(value)) }
            queue.asyncAfter(deadline: .now() + 3) {
                gate.resume(.failure(ScriptedMUServerError.timeout(operation)))
            }
        }
    }

    private func finishListener(_ result: Result<UInt16, Error>) {
        let continuation = lock.withLock { defer { listenerContinuation = nil }; return listenerContinuation }
        continuation?.resume(with: result)
    }

    private func finishConnection(_ result: Result<NWConnection, Error>) {
        let continuation = lock.withLock { defer { connectionContinuation = nil }; return connectionContinuation }
        continuation?.resume(with: result)
    }
}

private final class ScriptedContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func resume(_ result: Result<Value, Error>) {
        let continuation = lock.withLock { defer { self.continuation = nil }; return self.continuation }
        continuation?.resume(with: result)
    }
}

private extension MUServerAction {
    func payload(send isSend: Bool, actionIndex: Int) throws -> Data {
        let text = isSend ? send : expect
        let hex = isSend ? sendHex : expectHex
        guard (text == nil) != (hex == nil) else {
            throw ScriptedMUServerError.invalidAction(actionIndex, "specify exactly one text or hex payload")
        }
        if let text { return Data(text.utf8) }
        return try Data(hexString: hex!, actionIndex: actionIndex)
    }
}

private extension Data {
    init(hexString: String, actionIndex: Int) throws {
        guard hexString.count.isMultiple(of: 2), hexString.allSatisfy(\.isHexDigit) else {
            throw ScriptedMUServerError.invalidAction(actionIndex, "hex payload must contain complete byte pairs")
        }
        self.init()
        reserveCapacity(hexString.count / 2)
        var cursor = hexString.startIndex
        while cursor < hexString.endIndex {
            let end = hexString.index(cursor, offsetBy: 2)
            append(UInt8(hexString[cursor..<end], radix: 16)!)
            cursor = end
        }
    }

    func partitioned(using sizes: [Int]?) throws -> [Data] {
        guard let sizes else { return [self] }
        guard sizes.allSatisfy({ $0 > 0 }), sizes.reduce(0, +) == count else {
            throw ScriptedMUServerError.invalidChunks(expected: count, actual: sizes.reduce(0, +))
        }
        var offset = 0
        return sizes.map { size in
            defer { offset += size }
            return Data(self[offset..<(offset + size)])
        }
    }
}

public enum ScriptedMUServerError: LocalizedError {
    case closed, emptyRead, missingPort
    case timeout(String)
    case invalidAction(Int, String)
    case invalidChunks(expected: Int, actual: Int)
    case unexpectedBytes(action: Int, expected: Data, actual: Data)

    public var errorDescription: String? {
        switch self {
        case .closed: "The scripted server connection closed."
        case .emptyRead: "The scripted server received an empty read."
        case .missingPort: "The scripted server did not expose a port."
        case let .timeout(operation): "Timed out waiting for \(operation)."
        case let .invalidAction(index, message): "Invalid action \(index): \(message)."
        case let .invalidChunks(expected, actual): "Chunk sizes total \(actual), expected \(expected)."
        case let .unexpectedBytes(index, expected, actual):
            "Action \(index) expected \(expected.hex), received \(actual.hex)."
        }
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
