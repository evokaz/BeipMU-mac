import Foundation

public enum ConnectionState: Sendable, Hashable {
    case disconnected
    case resolving
    case connecting
    case connected
    case disconnecting
    case failed(String)
}

public enum TransportEvent: Sendable, Hashable {
    case state(ConnectionState)
    case received(Data)
    case sent(Data)
}

public protocol SessionTransport: Sendable {
    func connect(to request: ConnectionRequest) async throws
    func send(_ data: Data) async throws
    func disconnect() async
    func events() async -> AsyncStream<TransportEvent>
}

public struct GMCPMessage: Sendable, Hashable, Codable {
    public var package: String
    public var payload: String

    public init(package: String, payload: String) {
        self.package = package
        self.payload = payload
    }
}

public enum ProtocolOutput: Sendable, Hashable {
    case transmit(Data)
    case line(RenderedLine)
    case prompt(RenderedLine)
    case gmcp(GMCPMessage)
    case mcp(String)
    case encoding(TextEncoding)
    case requestNAWS
    case diagnostic(String)
}

public protocol ByteStreamProcessor: Sendable {
    mutating func reset()
    mutating func consume(_ data: Data) -> [ProtocolOutput]
    mutating func encode(_ text: String) throws -> Data
    mutating func windowSizeChanged(columns: UInt16, rows: UInt16) -> Data?
}

public extension ByteStreamProcessor {
    mutating func windowSizeChanged(columns: UInt16, rows: UInt16) -> Data? { nil }
}

public enum SessionEvent: Sendable, Hashable {
    case state(ConnectionState)
    case received(Data)
    case sent(Data)
    case prompt(RenderedLine)
    case renderedLine(RenderedLine)
    case gmcp(GMCPMessage)
    case mcp(String)
    case encoding(TextEncoding)
    case activity(important: Bool)
    case log(String)
    case error(String)
}

public actor SessionActor {
    private let transport: any SessionTransport
    private var processor: any ByteStreamProcessor
    private var eventContinuation: AsyncStream<SessionEvent>.Continuation?
    private var transportTask: Task<Void, Never>?
    private var request: ConnectionRequest?
    private var windowColumns: UInt16 = 80
    private var windowRows: UInt16 = 24
    private var isConnected = false

    public init(transport: any SessionTransport, processor: any ByteStreamProcessor) {
        self.transport = transport
        self.processor = processor
    }

    deinit { transportTask?.cancel() }

    public func events() -> AsyncStream<SessionEvent> {
        AsyncStream { continuation in
            eventContinuation = continuation
            continuation.onTermination = { @Sendable _ in }
        }
    }

    public func connect(_ request: ConnectionRequest) async {
        self.request = request
        isConnected = false
        processor.reset()
        let stream = await transport.events()
        transportTask?.cancel()
        transportTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }

        do {
            try await transport.connect(to: request)
        } catch {
            eventContinuation?.yield(.error(error.localizedDescription))
            eventContinuation?.yield(.state(.failed(error.localizedDescription)))
        }
    }

    public func disconnect() async {
        isConnected = false
        await transport.disconnect()
    }

    public func send(_ text: String) async {
        do {
            let data = try processor.encode(text + "\r\n")
            try await transport.send(data)
        } catch {
            eventContinuation?.yield(.error(error.localizedDescription))
        }
    }

    public func sendRaw(_ data: Data) async {
        do {
            try await transport.send(data)
        } catch {
            eventContinuation?.yield(.error(error.localizedDescription))
        }
    }

    public func updateWindowSize(columns: UInt16, rows: UInt16) async {
        guard columns > 0, rows > 0 else { return }
        windowColumns = columns
        windowRows = rows
        guard isConnected,
              request?.server.sendNAWSOnResize == true,
              let data = processor.windowSizeChanged(columns: columns, rows: rows) else { return }
        await transmit(data)
    }

    private func handle(_ event: TransportEvent) async {
        switch event {
        case let .state(state):
            switch state {
            case .connected: isConnected = true
            case .disconnected, .failed: isConnected = false
            case .resolving, .connecting, .disconnecting: break
            }
            eventContinuation?.yield(.state(state))
            if case .connected = state, let character = request?.character, !character.connectText.isEmpty {
                await send(expandConnectText(character.connectText, character: character))
            }
        case let .sent(data):
            eventContinuation?.yield(.sent(data))
        case let .received(data):
            eventContinuation?.yield(.received(data))
            for output in processor.consume(data) {
                await handle(output)
            }
        }
    }

    private func handle(_ output: ProtocolOutput) async {
        switch output {
        case let .transmit(data):
            await transmit(data)
        case let .line(line):
            eventContinuation?.yield(.renderedLine(line))
            eventContinuation?.yield(.activity(important: false))
        case let .prompt(line): eventContinuation?.yield(.prompt(line))
        case let .gmcp(message): eventContinuation?.yield(.gmcp(message))
        case let .mcp(message): eventContinuation?.yield(.mcp(message))
        case let .encoding(encoding): eventContinuation?.yield(.encoding(encoding))
        case .requestNAWS:
            if let data = processor.windowSizeChanged(columns: windowColumns, rows: windowRows) {
                await transmit(data)
            }
        case let .diagnostic(message): eventContinuation?.yield(.log(message))
        }
    }

    private func transmit(_ data: Data) async {
        do { try await transport.send(data) }
        catch { eventContinuation?.yield(.error(error.localizedDescription)) }
    }

    private func expandConnectText(_ text: String, character: CharacterProfile) -> String {
        text
            .replacingOccurrences(of: "%NAME%", with: character.name)
            .replacingOccurrences(of: "%PASSWORD%", with: character.password)
    }
}
