import Foundation

public enum ConnectionState: Sendable, Hashable {
    case disconnected
    case resolving
    case connecting
    case connected
    case disconnecting
    case failed(String)
}

public enum ConnectionNotice: Sendable, Hashable {
    case lookingUp(host: String, port: UInt16)
    case connecting(host: String, port: UInt16)
    case connected
    case retryScheduled(seconds: String)
    case retrying(attempt: Int, limit: String)
    case retryLimitReached
    case disconnected
}

public enum TransportEvent: Sendable, Hashable {
    case state(ConnectionState)
    case received(Data)
    case sent(Data)
    case notice(ConnectionNotice)
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
    case beep
    case gmcp(GMCPMessage)
    case mcp(MCPMessage)
    case encoding(TextEncoding)
    case requestNAWS
    case diagnostic(String)
}

public protocol ByteStreamProcessor: Sendable {
    mutating func reset()
    mutating func resetFormatting()
    mutating func configureANSI(_ settings: ANSISettings)
    mutating func setTerminalType(_ value: String)
    mutating func consume(_ data: Data) -> [ProtocolOutput]
    var hasBufferedDisplayableText: Bool { get }
    mutating func encode(_ text: String) throws -> Data
    mutating func encodeMCP(_ message: MCPMessage) -> [Data]
    mutating func windowSizeChanged(columns: UInt16, rows: UInt16) -> Data?
    mutating func manualWindowSize(columns: UInt16, rows: UInt16) -> Data?
}

public extension ByteStreamProcessor {
    var hasBufferedDisplayableText: Bool { false }
    mutating func resetFormatting() {}
    mutating func configureANSI(_ settings: ANSISettings) {}
    mutating func setTerminalType(_ value: String) {}
    mutating func encodeMCP(_ message: MCPMessage) -> [Data] { [] }
    mutating func windowSizeChanged(columns: UInt16, rows: UInt16) -> Data? { nil }
    mutating func manualWindowSize(columns: UInt16, rows: UInt16) -> Data? {
        windowSizeChanged(columns: columns, rows: rows)
    }
}

public enum SessionEvent: Sendable, Hashable {
    case state(ConnectionState)
    case transportConnected
    case received(Data)
    case sent(Data)
    case prompt(RenderedLine)
    case renderedLine(RenderedLine)
    case beep
    case gmcp(GMCPMessage)
    case mcp(MCPMessage)
    case encoding(TextEncoding)
    case activity(important: Bool)
    case log(String)
    case connectionNotice(ConnectionNotice)
    case error(String)
}

public actor SessionActor {
    private struct PendingConnectText {
        let generation: UInt64
        let text: String
        var connectionReady = false
        var hasDisplayableGreeting = false
    }

    private let transport: any SessionTransport
    private var processor: any ByteStreamProcessor
    private var eventContinuation: AsyncStream<SessionEvent>.Continuation?
    private var transportTask: Task<Void, Never>?
    private var request: ConnectionRequest?
    private var windowColumns: UInt16 = 80
    private var windowRows: UInt16 = 24
    /// Changes whenever the active connection attempt is replaced or stopped.
    /// Pending automatic login text is bound to the attempt that created it.
    private var connectionGeneration: UInt64 = 0
    private var pendingConnectText: PendingConnectText?
    private var connectTextEchoesToSuppress: [String] = []
    private var connectTextEchoDeadline: ContinuousClock.Instant?
    private var greetingFallbackTask: Task<Void, Never>?
    private var startupReadyGeneration: UInt64?
    private var startupFailedGeneration: UInt64?
    private var isConnected = false
    private var connectedAt: ContinuousClock.Instant?
    private var statisticsValue = ConnectionStatistics()
    private var idleTask: Task<Void, Never>?
    private var idleConfiguration: (interval: TimeInterval, text: String)?
    private var pingStartedAt: ContinuousClock.Instant?
    private var localEchoEnabled: Bool
    private var localEchoColor = RGBColor(red: 0, green: 205, blue: 205)
    private let idleSleep: @Sendable (Duration) async throws -> Void
    private let idleNow: @Sendable () -> TimeInterval
    private var lastIdleActivityAt: TimeInterval?

    public init(
        transport: any SessionTransport,
        processor: any ByteStreamProcessor,
        localEcho: Bool = false
    ) {
        self.transport = transport
        self.processor = processor
        self.localEchoEnabled = localEcho
        idleSleep = { try await Task.sleep(for: $0) }
        idleNow = { ProcessInfo.processInfo.systemUptime }
    }

    init(
        transport: any SessionTransport,
        processor: any ByteStreamProcessor,
        localEcho: Bool = false,
        idleSleep: @escaping @Sendable (Duration) async throws -> Void,
        idleNow: @escaping @Sendable () -> TimeInterval
    ) {
        self.transport = transport
        self.processor = processor
        self.localEchoEnabled = localEcho
        self.idleSleep = idleSleep
        self.idleNow = idleNow
    }

    deinit { transportTask?.cancel(); idleTask?.cancel(); greetingFallbackTask?.cancel() }

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
        connectionGeneration &+= 1
        let generation = connectionGeneration
        self.request = request
        recordConnectedDuration()
        isConnected = false
        idleTask?.cancel()
        idleTask = nil
        startupReadyGeneration = nil
        startupFailedGeneration = nil
        pendingConnectText = request.character.flatMap { character in
            let text = expandConnectText(character.connectText, character: character)
            guard !text.isEmpty else { return nil }
            return PendingConnectText(generation: generation, text: text)
        }
        connectTextEchoesToSuppress = []
        connectTextEchoDeadline = nil
        greetingFallbackTask?.cancel()
        greetingFallbackTask = nil
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
        connectionGeneration &+= 1
        pendingConnectText = nil
        connectTextEchoesToSuppress = []
        connectTextEchoDeadline = nil
        greetingFallbackTask?.cancel()
        greetingFallbackTask = nil
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

    @discardableResult
    private func send(_ text: String, echo: Bool, countsAsActivity: Bool = true) async -> Bool {
        if countsAsActivity { recordActivity() }
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
            return true
        } catch {
            eventContinuation?.yield(.error(error.localizedDescription))
            return false
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

    public func configureANSI(_ settings: ANSISettings) {
        processor.configureANSI(settings)
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
                lastIdleActivityAt = idleNow()
                statisticsValue.connectionCount += 1
                if var pending = pendingConnectText, pending.generation == connectionGeneration {
                    pending.connectionReady = true
                    pendingConnectText = pending
                }
                let generation = connectionGeneration
                eventContinuation?.yield(.transportConnected)
                if pendingConnectText?.generation == generation {
                    await sendConnectTextIfReady(for: generation)
                } else {
                    publishStartupReady(for: generation)
                }
            case .disconnected, .failed:
                let wasConnected = isConnected
                recordConnectedDuration()
                isConnected = false
                idleTask?.cancel()
                idleTask = nil
                if wasConnected {
                    pendingConnectText = nil
                    connectTextEchoesToSuppress = []
                    connectTextEchoDeadline = nil
                } else if case .failed = state, var pending = pendingConnectText {
                    // A failed pre-ready transport attempt may be retried by
                    // NetworkTransport. Keep its command for the next ready
                    // connection, but require a fresh greeting there.
                    pending.connectionReady = false
                    pending.hasDisplayableGreeting = false
                    pendingConnectText = pending
                    connectTextEchoesToSuppress = []
                    connectTextEchoDeadline = nil
                }
                greetingFallbackTask?.cancel()
                greetingFallbackTask = nil
                eventContinuation?.yield(.state(state))
            case .resolving, .connecting, .disconnecting:
                eventContinuation?.yield(.state(state))
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
            scheduleGreetingFallbackIfNeeded()
        case let .notice(notice):
            eventContinuation?.yield(.connectionNotice(notice))
        }
    }

    private func handle(_ output: ProtocolOutput) async {
        switch output {
        case let .transmit(data):
            await transmit(data)
        case let .line(line):
            guard !suppressConnectTextEcho(line.text) else {
                return
            }
            eventContinuation?.yield(.renderedLine(line))
            eventContinuation?.yield(.activity(important: false))
            if !line.text.isEmpty { await noteDisplayableGreeting() }
        case let .prompt(line):
            guard !suppressConnectTextEcho(line.text) else {
                return
            }
            eventContinuation?.yield(.prompt(line))
            if !line.text.isEmpty { await noteDisplayableGreeting() }
        case .beep: eventContinuation?.yield(.beep)
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

    private func noteDisplayableGreeting(cancelFallback: Bool = true) async {
        guard var pending = pendingConnectText,
              pending.generation == connectionGeneration else { return }
        pending.hasDisplayableGreeting = true
        pendingConnectText = pending
        if cancelFallback { greetingFallbackTask?.cancel() }
        greetingFallbackTask = nil
        await sendConnectTextIfReady(for: pending.generation)
    }

    private func scheduleGreetingFallbackIfNeeded() {
        guard let pending = pendingConnectText,
              pending.generation == connectionGeneration,
              pending.connectionReady,
              processor.hasBufferedDisplayableText else { return }
        greetingFallbackTask?.cancel()
        let generation = pending.generation
        greetingFallbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.sendAfterUnterminatedGreeting(for: generation)
        }
    }

    private func sendAfterUnterminatedGreeting(for generation: UInt64) async {
        guard generation == connectionGeneration,
              !Task.isCancelled,
              processor.hasBufferedDisplayableText else { return }
        await noteDisplayableGreeting(cancelFallback: false)
    }

    private func suppressConnectTextEcho(_ text: String) -> Bool {
        guard let deadline = connectTextEchoDeadline,
              ContinuousClock.now < deadline,
              let index = connectTextEchoesToSuppress.firstIndex(of: text) else {
            connectTextEchoesToSuppress = []
            connectTextEchoDeadline = nil
            return false
        }
        connectTextEchoesToSuppress.remove(at: index)
        if connectTextEchoesToSuppress.isEmpty { connectTextEchoDeadline = nil }
        return true
    }

    private func sendConnectTextIfReady(for generation: UInt64) async {
        guard generation == connectionGeneration,
              isConnected,
              let pending = pendingConnectText,
              pending.generation == generation,
              pending.connectionReady,
              pending.hasDisplayableGreeting else { return }

        // Clear the pending command before awaiting the transport. A reconnect
        // during the send cannot cause this attempt to send it a second time.
        pendingConnectText = nil
        connectTextEchoesToSuppress = pending.text
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        connectTextEchoDeadline = connectTextEchoesToSuppress.isEmpty
            ? nil : ContinuousClock.now.advanced(by: .seconds(2))
        let didSend = await send(pending.text, echo: false)
        guard didSend else {
            if generation == connectionGeneration {
                connectTextEchoesToSuppress = []
                connectTextEchoDeadline = nil
                startupFailedGeneration = generation
            }
            return
        }
        publishStartupReady(for: generation)
    }

    private func publishStartupReady(for generation: UInt64) {
        guard generation == connectionGeneration,
              isConnected,
              startupFailedGeneration != generation,
              startupReadyGeneration != generation else { return }
        startupReadyGeneration = generation
        eventContinuation?.yield(.state(.connected))
        startIdleActionIfNeeded()
    }

    private func startIdleActionIfNeeded() {
        guard isStartupReady else { return }
        idleTask?.cancel()
        let configured = idleConfiguration ?? request?.character.flatMap { character in
            guard let interval = character.idleTimeout, interval > 0, !character.idleText.isEmpty else { return nil }
            return (interval: interval, text: character.idleText)
        }
        guard let configured else { return }
        let idleSleep = self.idleSleep
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await idleSleep(.seconds(configured.interval)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.sendIdleTextIfNeeded(configured.text, after: configured.interval)
            }
        }
    }

    private func recordActivity() {
        lastIdleActivityAt = idleNow()
        if isStartupReady { startIdleActionIfNeeded() }
    }

    private var isStartupReady: Bool {
        isConnected && startupReadyGeneration == connectionGeneration
    }

    private func sendIdleTextIfNeeded(_ text: String, after interval: TimeInterval) async {
        guard isStartupReady,
              let lastIdleActivityAt,
              idleNow() - lastIdleActivityAt >= interval else { return }
        await send(text, echo: true, countsAsActivity: false)
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
