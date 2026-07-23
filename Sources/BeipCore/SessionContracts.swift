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
    case mcp(MCPMessage)
    case encoding(TextEncoding)
    case requestNAWS
    case diagnostic(String)
}

public protocol ByteStreamProcessor: Sendable {
    mutating func reset()
    mutating func resetFormatting()
    mutating func setTerminalType(_ value: String)
    mutating func consume(_ data: Data) -> [ProtocolOutput]
    mutating func encode(_ text: String) throws -> Data
    mutating func encodeMCP(_ message: MCPMessage) -> [Data]
    mutating func windowSizeChanged(columns: UInt16, rows: UInt16) -> Data?
    mutating func manualWindowSize(columns: UInt16, rows: UInt16) -> Data?
}

public extension ByteStreamProcessor {
    mutating func resetFormatting() {}
    mutating func setTerminalType(_ value: String) {}
    mutating func encodeMCP(_ message: MCPMessage) -> [Data] { [] }
    mutating func windowSizeChanged(columns: UInt16, rows: UInt16) -> Data? { nil }
    mutating func manualWindowSize(columns: UInt16, rows: UInt16) -> Data? {
        windowSizeChanged(columns: columns, rows: rows)
    }
}

public enum SessionEvent: Sendable, Hashable {
    case state(ConnectionState)
    case received(Data)
    case sent(Data)
    case prompt(RenderedLine)
    case renderedLine(RenderedLine)
    case gmcp(GMCPMessage)
    case mcp(MCPMessage)
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
    private var connectedAt: ContinuousClock.Instant?
    private var statisticsValue = ConnectionStatistics()
    private var idleTask: Task<Void, Never>?
    private var idleConfiguration: (interval: TimeInterval, text: String)?
    private var pingStartedAt: ContinuousClock.Instant?
    private var localEchoEnabled: Bool
    private var localEchoColor = RGBColor(red: 0, green: 205, blue: 205)

    public init(
        transport: any SessionTransport,
        processor: any ByteStreamProcessor,
        localEcho: Bool = false
    ) {
        self.transport = transport
        self.processor = processor
        self.localEchoEnabled = localEcho
    }

    deinit { transportTask?.cancel(); idleTask?.cancel() }

    public func statistics() -> ConnectionStatistics {
        var result = statisticsValue
        if let connectedAt {
            result.secondsConnected += Self.seconds(from: connectedAt.duration(to: .now))
        }
        return result
    }

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
        recordConnectedDuration()
        isConnected = false
        idleTask?.cancel()
        idleTask = nil
        await transport.disconnect()
    }

    public func reconnect() async {
        guard let request else {
            eventContinuation?.yield(.error("No previous connection to reconnect."))
            return
        }
        await connect(request)
    }

    public func receive(_ text: String) async {
        for output in processor.consume(Data((text + "\r\n").utf8)) {
            await handle(output)
        }
    }

    public func receiveGMCP(_ message: GMCPMessage) {
        eventContinuation?.yield(.gmcp(message))
    }

    public func sendMCP(_ message: MCPMessage) async {
        for data in processor.encodeMCP(message) { await transmit(data) }
    }

    public func ping(_ text: String) async {
        pingStartedAt = .now
        await send(text)
    }

    public func configureIdle(interval: TimeInterval?, text: String?) {
        if let interval, interval > 0, let text, !text.isEmpty {
            idleConfiguration = (interval, text)
        } else {
            idleConfiguration = nil
        }
        if isConnected { startIdleActionIfNeeded() }
    }

    public func configureLocalEcho(_ enabled: Bool, color: RGBColor? = nil) {
        localEchoEnabled = enabled
        if let color { localEchoColor = color }
    }

    public func send(_ text: String) async {
        await send(text, echo: true)
    }

    private func send(_ text: String, echo: Bool) async {
        if echo, localEchoEnabled {
            let style = TextStyle(foreground: localEchoColor)
            eventContinuation?.yield(.renderedLine(.init(
                text: text,
                runs: [.init(range: 0..<text.utf16.count, style: style)],
                source: .localEcho
            )))
        }
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

    public func resetFormatting() {
        processor.resetFormatting()
    }

    public func setTerminalType(_ value: String) {
        processor.setTerminalType(value)
    }

    public func sendWindowSize(columns: UInt16, rows: UInt16) async {
        guard columns > 0, rows > 0,
              let data = processor.manualWindowSize(columns: columns, rows: rows) else { return }
        await transmit(data)
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
            case .connected:
                isConnected = true
                connectedAt = .now
                statisticsValue.connectionCount += 1
                startIdleActionIfNeeded()
            case .disconnected, .failed:
                recordConnectedDuration()
                isConnected = false
                idleTask?.cancel()
                idleTask = nil
            case .resolving, .connecting, .disconnecting: break
            }
            eventContinuation?.yield(.state(state))
            if case .connected = state, let character = request?.character, !character.connectText.isEmpty {
                await send(expandConnectText(character.connectText, character: character), echo: false)
            }
        case let .sent(data):
            statisticsValue.bytesSent += UInt64(data.count)
            eventContinuation?.yield(.sent(data))
        case let .received(data):
            statisticsValue.bytesReceived += UInt64(data.count)
            eventContinuation?.yield(.received(data))
            if let pingStartedAt {
                let elapsed = Self.seconds(from: pingStartedAt.duration(to: .now))
                self.pingStartedAt = nil
                eventContinuation?.yield(.log(String(format: "Ping response time: %.3f seconds", elapsed)))
            }
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

    private func startIdleActionIfNeeded() {
        idleTask?.cancel()
        let configured = idleConfiguration ?? request?.character.flatMap { character in
            guard let interval = character.idleTimeout, interval > 0, !character.idleText.isEmpty else { return nil }
            return (interval: interval, text: character.idleText)
        }
        guard let configured else { return }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(configured.interval)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.send(configured.text)
            }
        }
    }

    private func recordConnectedDuration() {
        guard let connectedAt else { return }
        statisticsValue.secondsConnected += Self.seconds(from: connectedAt.duration(to: .now))
        self.connectedAt = nil
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
