@preconcurrency import Network
import BeipCore
import Foundation
import Security

public actor NetworkTransport: SessionTransport {
    private var connection: NWConnection?
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    private var activeRequest: ConnectionRequest?
    private var attempt = 0
    private var connectionTimeoutTask: Task<Void, Never>?
    private var reachedReady = false
    private let queue = DispatchQueue(label: "org.beipmu.transport", qos: .userInitiated)

    public init() {}

    public func events() -> AsyncStream<TransportEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func connect(to request: ConnectionRequest) async throws {
        await disconnect()
        activeRequest = request
        attempt = 0
        startAttempt(request)
    }

    private func startAttempt(_ request: ConnectionRequest) {
        guard let port = NWEndpoint.Port(rawValue: request.server.port) else {
            continuation?.yield(.state(.failed(TransportError.invalidPort(request.server.port).localizedDescription)))
            return
        }

        attempt += 1
        reachedReady = false
        continuation?.yield(.state(.resolving))
        let parameters = makeParameters(for: request)
        let newConnection = NWConnection(
            host: NWEndpoint.Host(request.server.host),
            port: port,
            using: parameters
        )
        connection = newConnection
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = Task { [weak self, weak newConnection] in
            do { try await Task.sleep(for: .milliseconds(request.policy.connectTimeoutMilliseconds)) }
            catch { return }
            guard let newConnection else { return }
            await self?.connectionTimedOut(newConnection)
        }
        newConnection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(state, from: newConnection) }
        }
        newConnection.start(queue: queue)
        continuation?.yield(.state(.connecting))
        receive(on: newConnection)
    }

    public func send(_ data: Data) async throws {
        guard let connection else { throw TransportError.notConnected }
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { result.resume(throwing: error) }
                else { result.resume() }
            })
        }
        continuation?.yield(.sent(data))
    }

    public func disconnect() async {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        activeRequest = nil
        guard let connection else { return }
        continuation?.yield(.state(.disconnecting))
        connection.stateUpdateHandler = nil
        connection.cancel()
        self.connection = nil
        continuation?.yield(.state(.disconnected))
    }

    private func makeParameters(for request: ConnectionRequest) -> NWParameters {
        let server = request.server
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = request.policy.noDelay
        tcp.enableKeepalive = request.policy.keepAlive
        tcp.connectionTimeout = max(1, request.policy.connectTimeoutMilliseconds / 1_000)

        let parameters: NWParameters
        if server.usesTLS {
            let tls = NWProtocolTLS.Options()
            if !server.verifiesCertificate {
                sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
                    complete(true)
                }, queue)
            }
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        if server.forceIPv4 {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: .any)
        }
        return parameters
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            Task {
                if let data, !data.isEmpty { await self.emitReceived(data, from: connection) }
                if let error { await self.fail(connection, message: error.localizedDescription) }
                else if complete { await self.finish(connection, with: .disconnected) }
                else { await self.receiveAgain(on: connection) }
            }
        }
    }

    private func receiveAgain(on connection: NWConnection) { receive(on: connection) }
    private func emitReceived(_ data: Data, from source: NWConnection) {
        guard connection === source else { return }
        continuation?.yield(.received(data))
    }

    private func handle(_ state: NWConnection.State, from source: NWConnection) {
        guard connection === source else { return }
        switch state {
        case .ready:
            connectionTimeoutTask?.cancel()
            connectionTimeoutTask = nil
            reachedReady = true
            continuation?.yield(.state(.connected))
        case let .failed(error):
            fail(source, message: error.localizedDescription)
        case .cancelled: finish(source, with: .disconnected)
        case .preparing: continuation?.yield(.state(.connecting))
        case .waiting: continuation?.yield(.state(.connecting))
        case .setup: break
        @unknown default: break
        }
    }

    private func finish(_ source: NWConnection, with state: ConnectionState) {
        guard connection === source else { return }
        source.stateUpdateHandler = nil
        source.cancel()
        connection = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        continuation?.yield(.state(state))
    }

    private func fail(_ source: NWConnection, message: String) {
        guard connection === source else { return }
        let shouldRetry = !reachedReady && canRetry
        finish(source, with: .failed(message))
        if shouldRetry { scheduleRetry() }
    }

    private func connectionTimedOut(_ source: NWConnection) {
        guard connection === source, !reachedReady else { return }
        let shouldRetry = canRetry
        finish(source, with: .failed("Connection timed out."))
        if shouldRetry { scheduleRetry() }
    }

    private var canRetry: Bool {
        guard let request = activeRequest else { return false }
        return request.policy.retryForever || attempt < request.policy.retryCount
    }

    private func scheduleRetry() {
        guard let request = activeRequest else { return }
        let delay = request.policy.connectTimeoutMilliseconds
        let expectedAttempt = attempt
        queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            Task { await self?.retry(request, afterAttempt: expectedAttempt) }
        }
    }

    private func retry(_ request: ConnectionRequest, afterAttempt expectedAttempt: Int) {
        guard activeRequest == request, attempt == expectedAttempt, connection == nil else { return }
        startAttempt(request)
    }

    public enum TransportError: LocalizedError {
        case invalidPort(UInt16)
        case notConnected

        public var errorDescription: String? {
            switch self {
            case let .invalidPort(port): "Invalid port: \(port)"
            case .notConnected: "No active connection."
            }
        }
    }
}
