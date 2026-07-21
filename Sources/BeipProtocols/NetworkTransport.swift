@preconcurrency import Network
import BeipCore
import Foundation
import Security

public actor NetworkTransport: SessionTransport {
    private var connection: NWConnection?
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    private let queue = DispatchQueue(label: "org.beipmu.transport", qos: .userInitiated)

    public init() {}

    public func events() -> AsyncStream<TransportEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func connect(to request: ConnectionRequest) async throws {
        await disconnect()
        guard let port = NWEndpoint.Port(rawValue: request.server.port) else {
            throw TransportError.invalidPort(request.server.port)
        }

        continuation?.yield(.state(.resolving))
        let parameters = makeParameters(for: request.server)
        let newConnection = NWConnection(
            host: NWEndpoint.Host(request.server.host),
            port: port,
            using: parameters
        )
        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(state) }
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
        guard let connection else { return }
        continuation?.yield(.state(.disconnecting))
        connection.stateUpdateHandler = nil
        connection.cancel()
        self.connection = nil
        continuation?.yield(.state(.disconnected))
    }

    private func makeParameters(for server: ServerProfile) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true

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
        // Network.framework does not expose its IP version selector through the
        // public Swift options object. Explicit A-record resolution is tracked
        // separately in the parity matrix; the default resolver is used here.
        return parameters
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            Task {
                if let data, !data.isEmpty { await self.emitReceived(data) }
                if let error { await self.emitFailure(error.localizedDescription) }
                else if complete { await self.emitDisconnected() }
                else { await self.receiveAgain(on: connection) }
            }
        }
    }

    private func receiveAgain(on connection: NWConnection) { receive(on: connection) }
    private func emitReceived(_ data: Data) { continuation?.yield(.received(data)) }
    private func emitFailure(_ message: String) { continuation?.yield(.state(.failed(message))) }
    private func emitDisconnected() { continuation?.yield(.state(.disconnected)) }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready: continuation?.yield(.state(.connected))
        case let .failed(error): continuation?.yield(.state(.failed(error.localizedDescription)))
        case .cancelled: continuation?.yield(.state(.disconnected))
        case .preparing: continuation?.yield(.state(.connecting))
        case .waiting: continuation?.yield(.state(.connecting))
        case .setup: break
        @unknown default: break
        }
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
