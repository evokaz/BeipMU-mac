import BeipCore
import Darwin
import Foundation
@preconcurrency import JavaScriptCore
@preconcurrency import Network

public struct ScriptEvaluation: Sendable, Equatable {
    public var value: String?
    public var error: String?
    public var outputs: [ScriptOutput]

    public init(value: String? = nil, error: String? = nil, outputs: [ScriptOutput] = []) {
        self.value = value
        self.error = error
        self.outputs = outputs
    }
}

public enum ScriptOutputKind: String, Codable, Sendable, Equatable {
    case debugText
    case debugHTML
    case display
    case displayHTML
    case send
    case transmit
    case receive
    case setInput
    case setVariable
    case deleteVariable
    case closeWindow
    case activity
    case importantActivity
    case runFile
    case playSound
    case stopSounds
    case scriptError
    case reconnect
    case logWrite
    case logWriteLine
    case setInputPrefix
    case setInputTitle
    case setTitlePrefix
    case runCommand
    case openConnectDialog
    case scriptWindow
    case newMainWindow
    case secondaryInput
}

public struct ScriptHostSnapshot: Codable, Sendable, Equatable {
    public struct SecondaryInput: Codable, Sendable, Equatable {
        public var title: String
        public var prefix: String
        public var text: String

        public init(title: String, prefix: String = "", text: String = "") {
            self.title = title
            self.prefix = prefix
            self.text = text
        }
    }

    public struct Item: Codable, Sendable, Equatable {
        public var name: String
        public var description: String
        public var matchText: String

        public init(name: String = "", description: String = "", matchText: String = "") {
            self.name = name
            self.description = description
            self.matchText = matchText
        }
    }

    public struct World: Codable, Sendable, Equatable {
        public var name: String
        public var info: String
        public var host: String
        public var characters: [Item]

        public init(name: String, info: String = "", host: String, characters: [Item] = []) {
            self.name = name
            self.info = info
            self.host = host
            self.characters = characters
        }
    }

    public struct Window: Codable, Sendable, Equatable {
        public var title: String
        public var input: String
        public var inputPrefix: String?
        public var inputTitle: String?
        public var titlePrefix: String?
        public var connected: Bool
        public var logging: Bool
        public var logFileName: String?
        public var variables: [String: String]

        public init(
            title: String = "",
            input: String = "",
            inputPrefix: String? = nil,
            inputTitle: String? = nil,
            titlePrefix: String? = nil,
            connected: Bool = false,
            logging: Bool = false,
            logFileName: String? = nil,
            variables: [String: String] = [:]
        ) {
            self.title = title
            self.input = input
            self.inputPrefix = inputPrefix
            self.inputTitle = inputTitle
            self.titlePrefix = titlePrefix
            self.connected = connected
            self.logging = logging
            self.logFileName = logFileName
            self.variables = variables
        }
    }

    public var buildNumber: Int
    public var version: Int
    public var buildDate: String?
    public var configPath: String
    public var worlds: [World]
    public var aliases: [Item]
    public var triggers: [Item]
    public var activeWorld: String?
    public var activeCharacter: String?
    public var activePuppet: String?
    public var spawnTabGroups: [String]?
    public var secondaryInputs: [SecondaryInput]?
    public var window: Window

    public init(
        buildNumber: Int = 331,
        version: Int = 331,
        buildDate: String? = nil,
        configPath: String = "",
        worlds: [World] = [],
        aliases: [Item] = [],
        triggers: [Item] = [],
        activeWorld: String? = nil,
        activeCharacter: String? = nil,
        activePuppet: String? = nil,
        spawnTabGroups: [String]? = nil,
        secondaryInputs: [SecondaryInput]? = nil,
        window: Window = .init()
    ) {
        self.buildNumber = buildNumber
        self.version = version
        self.buildDate = buildDate
        self.configPath = configPath
        self.worlds = worlds
        self.aliases = aliases
        self.triggers = triggers
        self.activeWorld = activeWorld
        self.activeCharacter = activeCharacter
        self.activePuppet = activePuppet
        self.spawnTabGroups = spawnTabGroups
        self.secondaryInputs = secondaryInputs
        self.window = window
    }
}

/// A synchronous host call made by a JavaScript evaluation.  The XPC caller
/// replays these in order after the evaluation completes, keeping script
/// output deterministic without allowing the script service to touch AppKit.
public struct ScriptOutput: Codable, Sendable, Equatable {
    public var kind: ScriptOutputKind
    public var value: String

    public init(kind: ScriptOutputKind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public struct ScriptWindowOperation: Codable, Sendable, Equatable {
    public var identifier: String
    public var kind: String
    public var action: String
    public var strings: [String]
    public var numbers: [Double]

    public init(identifier: String, kind: String, action: String, strings: [String] = [], numbers: [Double] = []) {
        self.identifier = identifier
        self.kind = kind
        self.action = action
        self.strings = strings
        self.numbers = numbers
    }
}

public actor ScriptRuntime {
    private var virtualMachine: JSVirtualMachine
    private var context: JSContext
    private var asyncOutputs: [ScriptOutput] = []
    private var asyncTasks: [Int: Task<Void, Never>] = [:]
    private var sockets: [Int: NWConnection] = [:]
    private var socketServers: [Int: NWListener] = [:]
    private var disconnectedSockets: Set<Int> = []
    private var generation = UUID()
    private var didInstallNativeBridge = false

    public init() {
        virtualMachine = JSVirtualMachine()
        context = JSContext(virtualMachine: virtualMachine)!
        Self.configure(context)
    }

    public func evaluate(_ source: String, host: ScriptHostSnapshot = .init()) -> ScriptEvaluation {
        installNativeBridgeIfNeeded()
        beginEvaluation()
        install(host)
        let value = context.evaluateScript(source)
        if let error = exceptionError() {
            return .init(error: error, outputs: outputs())
        }
        return .init(value: value?.isUndefined == false ? value?.toString() : nil, outputs: outputs())
    }

    /// Invokes a named global function without source interpolation.  Trigger
    /// captures therefore remain data rather than executable JavaScript.
    public func call(_ function: String, arguments: [String], host: ScriptHostSnapshot = .init()) -> ScriptEvaluation {
        installNativeBridgeIfNeeded()
        beginEvaluation()
        install(host)
        guard let callback = context.objectForKeyedSubscript(function), !callback.isUndefined, !callback.isNull else {
            return .init(error: "JavaScript callback '\(function)' is not defined.")
        }
        guard callback.isObject else {
            return .init(error: "JavaScript callback '\(function)' is not a function.")
        }
        let value = callback.call(withArguments: arguments)
        if let error = exceptionError() {
            return .init(error: error, outputs: outputs())
        }
        return .init(value: value?.isUndefined == false ? value?.toString() : nil, outputs: outputs())
    }

    /// Reproduces the Windows trigger callback contract: a flat start/end
    /// range array, a line object, and the active main-window proxy.
    public func callTrigger(
        _ function: String,
        ranges: [Int],
        line: RenderedLine,
        host: ScriptHostSnapshot = .init()
    ) -> ScriptEvaluation {
        installNativeBridgeIfNeeded()
        beginEvaluation()
        install(host)
        guard let callback = context.objectForKeyedSubscript(function), !callback.isUndefined, !callback.isNull else {
            return .init(error: "JavaScript callback '\(function)' is not defined.")
        }
        guard let data = try? JSONEncoder().encode(line), let lineJSON = String(data: data, encoding: .utf8) else {
            return .init(error: "Unable to encode the trigger line for JavaScript.")
        }
        context.setObject(ranges as NSArray, forKeyedSubscript: "__beipTriggerRanges" as NSString)
        context.setObject(lineJSON as NSString, forKeyedSubscript: "__beipTriggerLineJSON" as NSString)
        let rangeObject = context.evaluateScript("globalThis.__beipUIntArray(globalThis.__beipTriggerRanges)")
        let lineObject = context.evaluateScript("globalThis.__beipLine(JSON.parse(globalThis.__beipTriggerLineJSON))")
        let windowObject = context.objectForKeyedSubscript("window")
        let value = callback.call(withArguments: [rangeObject as Any, lineObject as Any, windowObject as Any])
        context.setObject(nil, forKeyedSubscript: "__beipTriggerRanges" as NSString)
        context.setObject(nil, forKeyedSubscript: "__beipTriggerLineJSON" as NSString)
        if let error = exceptionError() { return .init(error: error, outputs: outputs()) }
        return .init(value: value?.isUndefined == false ? value?.toString() : nil, outputs: outputs())
    }

    public func dispatchConnectionEvent(
        _ event: String,
        arguments: [String] = [],
        line: RenderedLine? = nil,
        host: ScriptHostSnapshot = .init()
    ) -> ScriptEvaluation {
        installNativeBridgeIfNeeded()
        beginEvaluation()
        install(host)
        guard let argumentsData = try? JSONEncoder().encode(arguments),
              let argumentsJSON = String(data: argumentsData, encoding: .utf8) else {
            return .init(error: "Unable to encode connection-hook arguments.")
        }
        context.setObject(event as NSString, forKeyedSubscript: "__beipConnectionEvent" as NSString)
        context.setObject(argumentsJSON as NSString, forKeyedSubscript: "__beipConnectionArgumentsJSON" as NSString)
        if let line,
           let lineData = try? JSONEncoder().encode(line),
           let lineJSON = String(data: lineData, encoding: .utf8) {
            context.setObject(lineJSON as NSString, forKeyedSubscript: "__beipConnectionLineJSON" as NSString)
        } else {
            context.setObject("null" as NSString, forKeyedSubscript: "__beipConnectionLineJSON" as NSString)
        }
        let value = context.evaluateScript(
            "globalThis.__beipDispatchConnectionEvent(globalThis.__beipConnectionEvent, JSON.parse(globalThis.__beipConnectionArgumentsJSON), JSON.parse(globalThis.__beipConnectionLineJSON))"
        )
        context.setObject(nil, forKeyedSubscript: "__beipConnectionEvent" as NSString)
        context.setObject(nil, forKeyedSubscript: "__beipConnectionArgumentsJSON" as NSString)
        context.setObject(nil, forKeyedSubscript: "__beipConnectionLineJSON" as NSString)
        if let error = exceptionError() { return .init(error: error, outputs: outputs()) }
        return .init(value: value?.isUndefined == false ? value?.toString() : nil, outputs: outputs())
    }

    public func reset() {
        asyncTasks.values.forEach { $0.cancel() }
        asyncTasks.removeAll()
        sockets.values.forEach { $0.cancel() }
        sockets.removeAll()
        socketServers.values.forEach { $0.cancel() }
        socketServers.removeAll()
        disconnectedSockets.removeAll()
        asyncOutputs.removeAll()
        generation = UUID()
        didInstallNativeBridge = false
        virtualMachine = JSVirtualMachine()
        context = JSContext(virtualMachine: virtualMachine)!
        Self.configure(context)
    }

    public func helpTypes() -> [String] {
        [
            "Alias", "Aliases", "App", "ArrayUInt", "Character", "Characters", "Connection",
            "FindString", "Log", "Puppet", "Puppets", "Socket", "SocketServer", "TextWindowLine",
            "Timer", "Trigger", "Triggers", "Window_Control_Edit", "Window_Events", "Window_FixedText",
            "Window_Graphics", "Window_Input", "Window_Main", "Window_Properties", "Window_SpawnTabs",
            "Window_Text", "Windows", "World", "Worlds"
        ]
    }

    public func help(for type: String) -> String? {
        Self.help[type.lowercased()]
    }

    /// Returns host calls produced by callbacks that ran after their initiating
    /// evaluation completed (timers and DNS today, sockets in the same channel).
    public func drainAsyncOutputs() -> [ScriptOutput] {
        defer { asyncOutputs.removeAll(keepingCapacity: true) }
        return asyncOutputs
    }

    private func installNativeBridgeIfNeeded() {
        guard !didInstallNativeBridge else { return }
        didInstallNativeBridge = true

        let schedule: @convention(block) (Int32, Double) -> Void = { [weak self] identifier, milliseconds in
            Task { await self?.scheduleTimer(identifier: Int(identifier), milliseconds: milliseconds) }
        }
        let cancel: @convention(block) (Int32) -> Void = { [weak self] identifier in
            Task { await self?.cancelTimer(identifier: Int(identifier)) }
        }
        let forwardDNS: @convention(block) (Int32, NSString) -> Void = { [weak self] identifier, hostname in
            let hostname = String(hostname)
            Task { await self?.startDNSLookup(identifier: Int(identifier), value: hostname, reverse: false) }
        }
        let reverseDNS: @convention(block) (Int32, NSString) -> Void = { [weak self] identifier, address in
            let address = String(address)
            Task { await self?.startDNSLookup(identifier: Int(identifier), value: address, reverse: true) }
        }
        let isAddress: @convention(block) (NSString) -> Bool = { value in
            Self.isIPAddress(value as String)
        }
        let connectSocket: @convention(block) (Int32, NSString, Int32) -> Void = { [weak self] identifier, hostname, port in
            let hostname = String(hostname)
            Task { await self?.connectSocket(identifier: Int(identifier), hostname: hostname, port: Int(port)) }
        }
        let closeSocket: @convention(block) (Int32) -> Void = { [weak self] identifier in
            Task { await self?.closeSocket(identifier: Int(identifier), notify: true) }
        }
        let sendSocket: @convention(block) (Int32, NSString) -> Void = { [weak self] identifier, value in
            let value = String(value)
            Task { await self?.sendSocket(identifier: Int(identifier), value: value) }
        }
        let createSocketServer: @convention(block) (Int32, Int32) -> Void = { [weak self] identifier, port in
            Task { await self?.createSocketServer(identifier: Int(identifier), port: Int(port)) }
        }
        let closeSocketServer: @convention(block) (Int32) -> Void = { [weak self] identifier in
            Task { await self?.closeSocketServer(identifier: Int(identifier)) }
        }
        context.setObject(schedule, forKeyedSubscript: "__beipScheduleTimer" as NSString)
        context.setObject(cancel, forKeyedSubscript: "__beipCancelTimer" as NSString)
        context.setObject(forwardDNS, forKeyedSubscript: "__beipForwardDNS" as NSString)
        context.setObject(reverseDNS, forKeyedSubscript: "__beipReverseDNS" as NSString)
        context.setObject(isAddress, forKeyedSubscript: "__beipIsAddress" as NSString)
        context.setObject(connectSocket, forKeyedSubscript: "__beipSocketConnect" as NSString)
        context.setObject(closeSocket, forKeyedSubscript: "__beipSocketClose" as NSString)
        context.setObject(sendSocket, forKeyedSubscript: "__beipSocketSend" as NSString)
        context.setObject(createSocketServer, forKeyedSubscript: "__beipSocketServerCreate" as NSString)
        context.setObject(closeSocketServer, forKeyedSubscript: "__beipSocketServerClose" as NSString)
    }

    private func scheduleTimer(identifier: Int, milliseconds: Double) {
        asyncTasks.removeValue(forKey: identifier)?.cancel()
        let delay = min(max(milliseconds, 0), 86_400_000)
        let activeGeneration = generation
        asyncTasks[identifier] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delay))
            } catch {
                return
            }
            await self?.fireTimer(identifier: identifier, generation: activeGeneration)
        }
    }

    private func cancelTimer(identifier: Int) {
        asyncTasks.removeValue(forKey: identifier)?.cancel()
    }

    private func fireTimer(identifier: Int, generation expectedGeneration: UUID) {
        guard generation == expectedGeneration else { return }
        asyncTasks.removeValue(forKey: identifier)
        prepareAsyncCallback()
        context.setObject(identifier, forKeyedSubscript: "__beipAsyncIdentifier" as NSString)
        let shouldRepeat = context.evaluateScript("globalThis.__beipFireTimer(globalThis.__beipAsyncIdentifier)")?.toBool() == true
        context.setObject(nil, forKeyedSubscript: "__beipAsyncIdentifier" as NSString)
        collectAsyncCallbackOutput()
        if shouldRepeat,
           let milliseconds = context.evaluateScript("globalThis.__beipTimerDelay(\(identifier))")?.toDouble() {
            scheduleTimer(identifier: identifier, milliseconds: milliseconds)
        }
    }

    private func startDNSLookup(identifier: Int, value: String, reverse: Bool) {
        let activeGeneration = generation
        Task.detached(priority: .utility) { [weak self] in
            let result = reverse ? Self.reverseLookup(value) : Self.forwardLookup(value)
            await self?.completeDNS(identifier: identifier, result: result, generation: activeGeneration)
        }
    }

    private func completeDNS(identifier: Int, result: String, generation expectedGeneration: UUID) {
        guard generation == expectedGeneration else { return }
        prepareAsyncCallback()
        context.setObject(identifier, forKeyedSubscript: "__beipAsyncIdentifier" as NSString)
        context.setObject(result as NSString, forKeyedSubscript: "__beipAsyncString" as NSString)
        _ = context.evaluateScript("globalThis.__beipCompleteDNS(globalThis.__beipAsyncIdentifier, globalThis.__beipAsyncString)")
        context.setObject(nil, forKeyedSubscript: "__beipAsyncIdentifier" as NSString)
        context.setObject(nil, forKeyedSubscript: "__beipAsyncString" as NSString)
        collectAsyncCallbackOutput()
    }

    private func connectSocket(identifier: Int, hostname: String, port: Int) {
        closeSocket(identifier: identifier, notify: false)
        guard (1...65_535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            dispatchSocketEvent(identifier: identifier, event: "disconnect", value: "Invalid port.")
            return
        }
        disconnectedSockets.remove(identifier)
        let activeGeneration = generation
        let connection = NWConnection(host: NWEndpoint.Host(hostname), port: endpointPort, using: .tcp)
        sockets[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { await self?.socketStateChanged(identifier: identifier, generation: activeGeneration, connection: connection, state: state) }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func socketStateChanged(
        identifier: Int,
        generation expectedGeneration: UUID,
        connection: NWConnection?,
        state: NWConnection.State
    ) {
        guard generation == expectedGeneration, sockets[identifier] === connection else { return }
        switch state {
        case .ready:
            dispatchSocketEvent(identifier: identifier, event: "connect")
            receiveSocket(identifier: identifier, generation: expectedGeneration)
        case let .failed(error):
            closeSocket(identifier: identifier, notify: true, reason: error.localizedDescription)
        case .cancelled:
            sockets.removeValue(forKey: identifier)
            notifySocketDisconnected(identifier: identifier, reason: "")
        default:
            break
        }
    }

    private func receiveSocket(identifier: Int, generation expectedGeneration: UUID) {
        guard generation == expectedGeneration, let connection = sockets[identifier] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            let data = data ?? Data()
            let reason = error?.localizedDescription ?? ""
            Task {
                await self?.socketReceived(
                    identifier: identifier,
                    generation: expectedGeneration,
                    connection: connection,
                    data: data,
                    isComplete: isComplete,
                    reason: reason
                )
            }
        }
    }

    private func socketReceived(
        identifier: Int,
        generation expectedGeneration: UUID,
        connection: NWConnection?,
        data: Data,
        isComplete: Bool,
        reason: String
    ) {
        guard generation == expectedGeneration, sockets[identifier] === connection else { return }
        if !data.isEmpty {
            dispatchSocketEvent(identifier: identifier, event: "receive", value: String(decoding: data, as: UTF8.self))
        }
        if isComplete || !reason.isEmpty {
            closeSocket(identifier: identifier, notify: true, reason: reason)
        } else {
            receiveSocket(identifier: identifier, generation: expectedGeneration)
        }
    }

    private func sendSocket(identifier: Int, value: String) {
        guard let connection = sockets[identifier] else {
            dispatchSocketEvent(identifier: identifier, event: "disconnect", value: "Socket is not connected.")
            return
        }
        connection.send(content: Data(value.utf8), completion: .contentProcessed { [weak self, weak connection] error in
            guard let error else { return }
            Task {
                await self?.socketSendFailed(
                    identifier: identifier,
                    connection: connection,
                    reason: error.localizedDescription
                )
            }
        })
    }

    private func socketSendFailed(identifier: Int, connection: NWConnection?, reason: String) {
        guard sockets[identifier] === connection else { return }
        closeSocket(identifier: identifier, notify: true, reason: reason)
    }

    private func closeSocket(identifier: Int, notify: Bool, reason: String = "") {
        let connection = sockets.removeValue(forKey: identifier)
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        if notify { notifySocketDisconnected(identifier: identifier, reason: reason) }
    }

    private func notifySocketDisconnected(identifier: Int, reason: String) {
        guard disconnectedSockets.insert(identifier).inserted else { return }
        dispatchSocketEvent(identifier: identifier, event: "disconnect", value: reason)
    }

    private func dispatchSocketEvent(identifier: Int, event: String, value: String = "") {
        prepareAsyncCallback()
        context.setObject(identifier, forKeyedSubscript: "__beipAsyncIdentifier" as NSString)
        context.setObject(event as NSString, forKeyedSubscript: "__beipAsyncEvent" as NSString)
        context.setObject(value as NSString, forKeyedSubscript: "__beipAsyncString" as NSString)
        _ = context.evaluateScript(
            "globalThis.__beipSocketEvent(globalThis.__beipAsyncIdentifier, globalThis.__beipAsyncEvent, globalThis.__beipAsyncString)"
        )
        context.setObject(nil, forKeyedSubscript: "__beipAsyncIdentifier" as NSString)
        context.setObject(nil, forKeyedSubscript: "__beipAsyncEvent" as NSString)
        context.setObject(nil, forKeyedSubscript: "__beipAsyncString" as NSString)
        collectAsyncCallbackOutput()
    }

    private func createSocketServer(identifier: Int, port: Int) {
        closeSocketServer(identifier: identifier)
        guard (0...65_535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            asyncOutputs.append(.init(kind: .scriptError, value: "Socket server port must be between 0 and 65535."))
            return
        }
        do {
            let listener = try NWListener(using: .tcp, on: endpointPort)
            let activeGeneration = generation
            socketServers[identifier] = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { await self?.socketServerStateChanged(identifier: identifier, generation: activeGeneration, listener: listener, state: state) }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { await self?.acceptSocket(serverIdentifier: identifier, generation: activeGeneration, listener: listener, connection: connection) }
            }
            listener.start(queue: DispatchQueue.global(qos: .utility))
        } catch {
            asyncOutputs.append(.init(kind: .scriptError, value: error.localizedDescription))
        }
    }

    private func socketServerStateChanged(
        identifier: Int,
        generation expectedGeneration: UUID,
        listener: NWListener?,
        state: NWListener.State
    ) {
        guard generation == expectedGeneration, socketServers[identifier] === listener else { return }
        switch state {
        case .ready:
            let port = listener?.port?.rawValue ?? 0
            prepareAsyncCallback()
            context.setObject(identifier, forKeyedSubscript: "__beipAsyncIdentifier" as NSString)
            context.setObject(Int(port), forKeyedSubscript: "__beipAsyncPort" as NSString)
            _ = context.evaluateScript("globalThis.__beipSocketServerReady(globalThis.__beipAsyncIdentifier, globalThis.__beipAsyncPort)")
            context.setObject(nil, forKeyedSubscript: "__beipAsyncIdentifier" as NSString)
            context.setObject(nil, forKeyedSubscript: "__beipAsyncPort" as NSString)
            collectAsyncCallbackOutput()
        case let .failed(error):
            closeSocketServer(identifier: identifier)
            asyncOutputs.append(.init(kind: .scriptError, value: error.localizedDescription))
        case .cancelled:
            socketServers.removeValue(forKey: identifier)
        default:
            break
        }
    }

    private func acceptSocket(
        serverIdentifier: Int,
        generation expectedGeneration: UUID,
        listener: NWListener?,
        connection: NWConnection
    ) {
        guard generation == expectedGeneration, socketServers[serverIdentifier] === listener else {
            connection.cancel()
            return
        }
        prepareAsyncCallback()
        context.setObject(serverIdentifier, forKeyedSubscript: "__beipAsyncIdentifier" as NSString)
        guard let socketIdentifier = context.evaluateScript(
            "globalThis.__beipSocketServerAccept(globalThis.__beipAsyncIdentifier)"
        )?.toInt32() else {
            connection.cancel()
            collectAsyncCallbackOutput()
            return
        }
        context.setObject(nil, forKeyedSubscript: "__beipAsyncIdentifier" as NSString)
        collectAsyncCallbackOutput()
        let identifier = Int(socketIdentifier)
        disconnectedSockets.remove(identifier)
        sockets[identifier] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { await self?.socketStateChanged(identifier: identifier, generation: expectedGeneration, connection: connection, state: state) }
        }
        connection.start(queue: DispatchQueue.global(qos: .utility))
    }

    private func closeSocketServer(identifier: Int) {
        let listener = socketServers.removeValue(forKey: identifier)
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
    }

    private func prepareAsyncCallback() {
        context.setObject(nil, forKeyedSubscript: "__beipLastException" as NSString)
        _ = context.evaluateScript("globalThis.__beipOutput = []")
    }

    private func collectAsyncCallbackOutput() {
        asyncOutputs.append(contentsOf: outputs())
        if let error = exceptionError() {
            asyncOutputs.append(.init(kind: .scriptError, value: error))
        }
        _ = context.evaluateScript("globalThis.__beipOutput = []")
        context.setObject(nil, forKeyedSubscript: "__beipLastException" as NSString)
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString {
            inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1
        }
    }

    private static func forwardLookup(_ hostname: String) -> String {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0, let first = result else { return "" }
        defer { freeaddrinfo(result) }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return ""
        }
        return stringFromCStringBuffer(buffer)
    }

    private static func reverseLookup(_ address: String) -> String {
        var storage = sockaddr_storage()
        var length: socklen_t = 0
        var ipv4Address = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4Address) }) == 1 {
            var ipv4 = sockaddr_in()
            ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            ipv4.sin_family = sa_family_t(AF_INET)
            ipv4.sin_addr = ipv4Address
            withUnsafeBytes(of: &ipv4) { bytes in
                withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: bytes) }
            }
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        } else {
            var ipv6 = sockaddr_in6()
            ipv6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            ipv6.sin6_family = sa_family_t(AF_INET6)
            guard address.withCString({ inet_pton(AF_INET6, $0, &ipv6.sin6_addr) }) == 1 else { return "" }
            withUnsafeBytes(of: &ipv6) { bytes in
                withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: bytes) }
            }
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NAMEREQD)
            }
        }
        return status == 0 ? stringFromCStringBuffer(buffer) : ""
    }

    private static func stringFromCStringBuffer(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:))
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func configure(_ activeContext: JSContext) {
        activeContext.exceptionHandler = { [weak activeContext] _, exception in
            activeContext?.setObject(exception, forKeyedSubscript: "__beipLastException" as NSString)
        }
        activeContext.evaluateScript(Self.compatibilitySource)
    }

    private func beginEvaluation() {
        context.setObject(nil, forKeyedSubscript: "__beipLastException" as NSString)
        _ = context.evaluateScript("globalThis.__beipOutput = []")
    }

    private func install(_ host: ScriptHostSnapshot) {
        guard let data = try? JSONEncoder().encode(host),
              let json = String(data: data, encoding: .utf8) else { return }
        context.setObject(json as NSString, forKeyedSubscript: "__beipHostJSON" as NSString)
        _ = context.evaluateScript("globalThis.__beipSetHostState(JSON.parse(globalThis.__beipHostJSON))")
        context.setObject(nil, forKeyedSubscript: "__beipHostJSON" as NSString)
    }

    private func exceptionError() -> String? {
        guard let exception = context.objectForKeyedSubscript("__beipLastException"), !exception.isNull, !exception.isUndefined else {
            return nil
        }
        return exception.toString()
    }

    private func outputs() -> [ScriptOutput] {
        guard let json = context.evaluateScript("JSON.stringify(globalThis.__beipOutput || [])")?.toString(),
              let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([ScriptOutput].self, from: data)
        else {
            return []
        }
        return values
    }

    private static let compatibilitySource = """
        globalThis.__beipOutput = [];
        globalThis.__beipRecordOutput = function(kind, value) {
          globalThis.__beipOutput.push({ kind: kind, value: String(value) });
          return String(value);
        };
        globalThis.__beipNextAsyncIdentifier = 1;
        globalThis.__beipTimers = {};
        globalThis.__beipDNSCallbacks = {};
        globalThis.__beipSockets = {};
        globalThis.__beipSocketServers = {};
        globalThis.__beipTimer = function(milliseconds, callback, userdata, repeating) {
          if (typeof callback !== 'function') throw new TypeError('Timer callback must be a function.');
          var delay = Number(milliseconds);
          if (!Number.isFinite(delay) || delay < 0) throw new RangeError('Timer interval must be a non-negative finite number.');
          var id = globalThis.__beipNextAsyncIdentifier++;
          var timer = {
            UserData: userdata,
            Active: true,
            Kill: function() {
              if (!this.Active) return;
              this.Active = false;
              globalThis.__beipCancelTimer(id);
              delete globalThis.__beipTimers[id];
            }
          };
          timer.kill = timer.Kill;
          Object.defineProperty(timer, '__beipDelay', { value: delay });
          Object.defineProperty(timer, '__beipRepeating', { value: !!repeating });
          Object.defineProperty(timer, '__beipCallback', { value: callback });
          globalThis.__beipTimers[id] = timer;
          globalThis.__beipScheduleTimer(id, delay);
          return timer;
        };
        globalThis.__beipFireTimer = function(id) {
          var timer = globalThis.__beipTimers[id];
          if (!timer || !timer.Active) return false;
          var stop = timer.__beipCallback(timer.UserData) === true;
          if (!timer.__beipRepeating || stop) {
            timer.Active = false;
            delete globalThis.__beipTimers[id];
            return false;
          }
          return timer.Active;
        };
        globalThis.__beipTimerDelay = function(id) {
          var timer = globalThis.__beipTimers[id];
          return timer ? timer.__beipDelay : 0;
        };
        globalThis.__beipDNSLookup = function(value, callback, userdata, reverse) {
          if (typeof callback !== 'function') throw new TypeError('DNS callback must be a function.');
          var id = globalThis.__beipNextAsyncIdentifier++;
          globalThis.__beipDNSCallbacks[id] = { callback: callback, userdata: userdata };
          if (reverse) globalThis.__beipReverseDNS(id, String(value));
          else globalThis.__beipForwardDNS(id, String(value));
        };
        globalThis.__beipCompleteDNS = function(id, result) {
          var request = globalThis.__beipDNSCallbacks[id];
          if (!request) return;
          delete globalThis.__beipDNSCallbacks[id];
          request.callback(String(result || ''), request.userdata);
        };
        globalThis.__beipCreateSocket = function(existingIdentifier, connected) {
          var id = existingIdentifier === undefined ? globalThis.__beipNextAsyncIdentifier++ : Number(existingIdentifier);
          var socket = {
            UserData: null,
            __beipConnected: !!connected,
            __beipOnConnect: null,
            __beipOnDisconnect: null,
            __beipOnReceive: null,
            __beipLineMode: false,
            __beipReceiveBuffer: '',
            Connect: function(hostname, port) {
              var numericPort = port === undefined ? 1234 : Number(port);
              if (!Number.isInteger(numericPort) || numericPort < 1 || numericPort > 65535) throw new RangeError('Socket port must be between 1 and 65535.');
              globalThis.__beipSocketConnect(id, String(hostname), numericPort);
            },
            Close: function() { globalThis.__beipSocketClose(id); },
            IsConnected: function() { return this.__beipConnected; },
            Send: function(value) { globalThis.__beipSocketSend(id, String(value)); },
            SetOnConnect: function(callback) { this.__beipOnConnect = callback == null ? null : callback; },
            SetOnDisconnect: function(callback) { this.__beipOnDisconnect = callback == null ? null : callback; },
            SetOnReceive: function(callback) { this.__beipOnReceive = callback == null ? null : callback; },
            SetFlag: function(flag, enabled) {
              // Windows flag 1 asks Socket to deliver complete lines only.
              if (Number(flag) === 1) this.__beipLineMode = !!enabled;
            }
          };
          socket.connect = socket.Connect;
          socket.close = socket.Close;
          socket.isConnected = socket.IsConnected;
          socket.send = socket.Send;
          socket.setOnConnect = socket.SetOnConnect;
          socket.setOnDisconnect = socket.SetOnDisconnect;
          socket.setOnReceive = socket.SetOnReceive;
          socket.setFlag = socket.SetFlag;
          globalThis.__beipSockets[id] = socket;
          return socket;
        };
        globalThis.__beipSocketEvent = function(id, event, value) {
          var socket = globalThis.__beipSockets[id];
          if (!socket) return;
          if (event === 'connect') {
            socket.__beipConnected = true;
            if (typeof socket.__beipOnConnect === 'function') socket.__beipOnConnect(socket);
          } else if (event === 'receive') {
            if (typeof socket.__beipOnReceive === 'function') {
              var text = String(value || '');
              if (!socket.__beipLineMode) {
                socket.__beipOnReceive(socket, text);
              } else {
                socket.__beipReceiveBuffer += text;
                var lines = socket.__beipReceiveBuffer.split(/\\r?\\n|\\r/);
                socket.__beipReceiveBuffer = lines.pop() || '';
                lines.forEach(function(line) { socket.__beipOnReceive(socket, line); });
              }
            }
          } else if (event === 'disconnect') {
            socket.__beipConnected = false;
            if (typeof socket.__beipOnDisconnect === 'function') socket.__beipOnDisconnect(socket, String(value || ''));
          }
        };
        globalThis.__beipCreateSocketServer = function(port, callback, userdata) {
          var numericPort = Number(port);
          if (!Number.isInteger(numericPort) || numericPort < 0 || numericPort > 65535) throw new RangeError('Socket server port must be between 0 and 65535.');
          if (typeof callback !== 'function') throw new TypeError('Socket server callback must be a function.');
          var id = globalThis.__beipNextAsyncIdentifier++;
          var server = {
            Active: true,
            Port: numericPort,
            UserData: userdata,
            Shutdown: function() {
              if (!this.Active) return;
              this.Active = false;
              globalThis.__beipSocketServerClose(id);
              delete globalThis.__beipSocketServers[id];
            }
          };
          server.shutdown = server.Shutdown;
          Object.defineProperty(server, '__beipCallback', { value: callback });
          globalThis.__beipSocketServers[id] = server;
          globalThis.__beipSocketServerCreate(id, numericPort);
          return server;
        };
        globalThis.__beipSocketServerReady = function(id, port) {
          var server = globalThis.__beipSocketServers[id];
          if (server) server.Port = Number(port);
        };
        globalThis.__beipSocketServerAccept = function(id) {
          var server = globalThis.__beipSocketServers[id];
          if (!server || !server.Active) return -1;
          var socketId = globalThis.__beipNextAsyncIdentifier++;
          var socket = globalThis.__beipCreateSocket(socketId, true);
          server.__beipCallback(socket, server.UserData);
          return socketId;
        };
        globalThis.__beipState = { worlds: [], aliases: [], triggers: [], window: { variables: {} } };
        globalThis.__beipCollection = function(values) {
          var items = values || [];
          var collection = function(index) { return collection.Item(index); };
          collection.Item = collection.item = function(index) {
            if (typeof index === 'number') return items[index];
            var key = String(index).toLowerCase();
            return items.find(function(value) {
              return String(value.Name || value.name || value.Description || value.description || '').toLowerCase() === key;
            });
          };
          Object.defineProperty(collection, 'Count', { get: function() { return items.length; } });
          Object.defineProperty(collection, 'count', { get: function() { return items.length; } });
          return collection;
        };
        globalThis.__beipAlias = function(value) {
          return {
            Name: value.name || '', Description: value.description || '',
            FindString: { MatchText: value.matchText || '' },
            StopProcessing: !!value.stopProcessing, Folder: !!value.folder
          };
        };
        globalThis.__beipTrigger = function(value) {
          return {
            Name: value.name || '', Description: value.description || '',
            FindString: { MatchText: value.matchText || '', RegularExpression: false, MatchCase: false, StartsWith: false, EndsWith: false, WholeWord: false },
            Disabled: false, StopProcessing: false, OncePerLine: false,
            Triggers: globalThis.__beipCollection([]), Aliases: globalThis.__beipCollection([])
          };
        };
        globalThis.__beipEscapeHTML = function(value) {
          return String(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
        };
        globalThis.__beipCSSColor = function(value) {
          var color = Number(value) >>> 0;
          var red = color & 255, green = (color >>> 8) & 255, blue = (color >>> 16) & 255;
          return 'rgb(' + red + ',' + green + ',' + blue + ')';
        };
        globalThis.__beipLine = function(value, html) {
          var line = { _text: String((value && value.text) || ''), _marks: [], _sourceHTML: html ? String(html) : null };
          var range = function(start, end) {
            start = Math.max(0, Math.min(line._text.length, Number(start) >>> 0));
            end = Math.max(start, Math.min(line._text.length, Number(end) >>> 0));
            return [start, end];
          };
          var mark = function(kind, start, end, setting) {
            var selected = range(start, end);
            line._sourceHTML = null;
            line._marks.push({ kind: kind, start: selected[0], end: selected[1], value: setting });
          };
          line.Insert = function(position, inserted) {
            position = Math.max(0, Math.min(this._text.length, Number(position) >>> 0));
            if (!inserted || inserted === this) throw new TypeError('Insert requires a different TextWindowLine.');
            var text = String(inserted.String || inserted.string || '');
            this._text = this._text.slice(0, position) + text + this._text.slice(position);
            this._marks.forEach(function(item) { if (item.start >= position) item.start += text.length; if (item.end >= position) item.end += text.length; });
            (inserted._marks || []).forEach(function(item) { this._marks.push({ kind: item.kind, start: item.start + position, end: item.end + position, value: item.value }); }, this);
            this._sourceHTML = null;
          };
          line.Delete = function(start, end) {
            var selected = range(start, end), count = selected[1] - selected[0];
            this._text = this._text.slice(0, selected[0]) + this._text.slice(selected[1]);
            this._marks = this._marks.map(function(item) {
              var itemStart = item.start >= selected[1] ? item.start - count : Math.min(item.start, selected[0]);
              var itemEnd = item.end >= selected[1] ? item.end - count : Math.min(item.end, selected[0]);
              return { kind: item.kind, start: itemStart, end: itemEnd, value: item.value };
            }).filter(function(item) { return item.end > item.start; });
            this._sourceHTML = null;
          };
          line.Color = function(start, end, color) { mark('color', start, end, globalThis.__beipCSSColor(color || 0)); };
          line.BgColor = function(start, end, color) { mark('background-color', start, end, globalThis.__beipCSSColor(color || 0)); };
          line.Bold = function(start, end, set) { mark('font-weight', start, end, set === false ? 'normal' : 'bold'); };
          line.Italic = function(start, end, set) { mark('font-style', start, end, set === false ? 'normal' : 'italic'); };
          line.Underline = function(start, end, set) { mark('text-decoration-line', start, end, set === false ? 'none' : 'underline'); };
          line.Strikeout = function(start, end, set) { mark('text-decoration-line', start, end, set === false ? 'none' : 'line-through'); };
          line.Flash = function(start, end, set) { mark('--beip-flash', start, end, set === false ? '0' : '1'); };
          line.FlashMode = function(start, end, mode) { mark('--beip-flash-mode', start, end, Number(mode) === 1 ? 'inverse' : 'normal'); };
          line.Blink = function(start, end, bits, mask) { mark('--beip-blink', start, end, String(Number(bits) >>> 0) + '/' + String(Number(mask) >>> 0)); };
          ['Insert','Delete','Color','BgColor','Bold','Italic','Underline','Strikeout','Flash','FlashMode','Blink'].forEach(function(name) {
            line[name.charAt(0).toLowerCase() + name.slice(1)] = line[name];
          });
          Object.defineProperties(line, {
            String: { get: function() { return this._text; } },
            string: { get: function() { return this._text; } },
            Length: { get: function() { return this._text.length; } },
            length: { get: function() { return this._text.length; } },
            HTMLString: { get: function() {
              if (this._sourceHTML !== null) return this._sourceHTML;
              var result = '';
              for (var index = 0; index < this._text.length; index++) {
                var styles = {};
                this._marks.forEach(function(item) { if (index >= item.start && index < item.end) styles[item.kind] = item.value; });
                var css = Object.keys(styles).map(function(key) { return key + ':' + styles[key]; }).join(';');
                var character = globalThis.__beipEscapeHTML(this._text.charAt(index));
                result += css ? '<span style="' + css + '">' + character + '</span>' : character;
              }
              return '<p>' + result + '</p>';
            } },
            htmlString: { get: function() { return this.HTMLString; } }
          });
          return line;
        };
        globalThis.__beipUIntArray = function(values) {
          var result = Array.from(values || []);
          result.Item = result.item = function(index) { return result[Number(index)]; };
          Object.defineProperty(result, 'Count', { get: function() { return result.length; } });
          return result;
        };
        globalThis.beip = { platform: 'macOS', runtime: 'JavaScriptCore' };
        globalThis.app = {};
        globalThis.window = { UserData: null };
        globalThis.window.output = globalThis.window.Output = {
          Write: function(text) { return globalThis.__beipRecordOutput('display', text); },
          write: function(text) { return globalThis.__beipRecordOutput('display', text); },
          WriteHTML: function(text) { return globalThis.__beipRecordOutput('displayHTML', text); },
          writeHTML: function(text) { return globalThis.__beipRecordOutput('displayHTML', text); },
          Create: function(text) { return globalThis.__beipLine({ text: String(text) }); },
          create: function(text) { return this.Create(text); },
          CreateHTML: function(html) { return globalThis.__beipLine({ text: String(html).replace(/<[^>]*>/g, '') }, String(html)); },
          createHTML: function(html) { return this.CreateHTML(html); },
          Add: function(line) {
            if (line && (line._marks || []).length > 0 || line && line._sourceHTML !== null) return globalThis.__beipRecordOutput('displayHTML', line.HTMLString);
            return globalThis.__beipRecordOutput('display', line.String || String(line));
          },
          add: function(line) { return this.Add(line); },
          Paused: false
        };
        globalThis.window.history = globalThis.window.History = globalThis.window.output;
        globalThis.window.input = globalThis.window.Input = {
          _selection: [0, 0],
          Get: function() { return String(globalThis.__beipState.window.input || ''); },
          get: function() { return this.Get(); },
          Set: function(text) { globalThis.__beipState.window.input = String(text); return globalThis.__beipRecordOutput('setInput', text); },
          set: function(text) { return this.Set(text); },
          SetSel: function(start, end) { this._selection = [Number(start), Number(end)]; },
          GetSelStart: function() { return this._selection[0]; },
          GetSelEnd: function() { return this._selection[1]; }
        };
        Object.defineProperty(globalThis.window.input, 'Length', { get: function() { return globalThis.window.input.Get().length; } });
        Object.defineProperties(globalThis.window.input, {
          Prefix: {
            get: function() { return globalThis.__beipState.window.inputPrefix || ''; },
            set: function(value) { globalThis.__beipState.window.inputPrefix = String(value); globalThis.__beipRecordOutput('setInputPrefix', value); }
          },
          Title: {
            get: function() { return globalThis.__beipState.window.inputTitle || ''; },
            set: function(value) { globalThis.__beipState.window.inputTitle = String(value); globalThis.__beipRecordOutput('setInputTitle', value); }
          }
        });
        Object.defineProperty(globalThis.window.input, 'prefix', { get: function() { return globalThis.window.input.Prefix; }, set: function(value) { globalThis.window.input.Prefix = value; } });
        Object.defineProperty(globalThis.window.input, 'title', { get: function() { return globalThis.window.input.Title; }, set: function(value) { globalThis.window.input.Title = value; } });
        globalThis.window.connection = globalThis.window.Connection = {
          Send: function(text) { return globalThis.__beipRecordOutput('send', text); },
          send: function(text) { return this.Send(text); },
          Transmit: function(text) { return globalThis.__beipRecordOutput('transmit', text); },
          Receive: function(text) { return globalThis.__beipRecordOutput('receive', text); },
          Display: function(text) { return globalThis.__beipRecordOutput('display', text); },
          SetOnSend: function(callback, userdata) { globalThis.__beipSetConnectionHook('send', callback, userdata); },
          SetOnReceive: function(callback, userdata) { globalThis.__beipSetConnectionHook('receive', callback, userdata); },
          SetOnDisplay: function(callback, userdata) { globalThis.__beipSetConnectionHook('display', callback, userdata); },
          SetOnGMCP: function(callback, userdata) { globalThis.__beipSetConnectionHook('gmcp', callback, userdata); },
          SetOnConnect: function(callback, userdata) { globalThis.__beipSetConnectionHook('connect', callback, userdata); },
          SetOnDisconnect: function(callback, userdata) { globalThis.__beipSetConnectionHook('disconnect', callback, userdata); },
          IsConnected: function() { return !!globalThis.__beipState.window.connected; },
          IsLogging: function() { return !!globalThis.__beipState.window.logging; },
          Reconnect: function() {
            if (!globalThis.__beipState.activeWorld) return false;
            globalThis.__beipRecordOutput('reconnect', '');
            return true;
          },
          Window_Main: globalThis.window
        };
        globalThis.window.GetVariable = function(name) { return globalThis.__beipState.window.variables[String(name)]; };
        globalThis.window.SetVariable = function(name, value) {
          globalThis.__beipState.window.variables[String(name)] = String(value);
          return globalThis.__beipRecordOutput('setVariable', JSON.stringify({ name: String(name), value: String(value) }));
        };
        globalThis.window.DeleteVariable = function(name) {
          delete globalThis.__beipState.window.variables[String(name)];
          return globalThis.__beipRecordOutput('deleteVariable', name);
        };
        globalThis.window.Close = function() { return globalThis.__beipRecordOutput('closeWindow', ''); };
        globalThis.window.Activity = function() { return globalThis.__beipRecordOutput('activity', ''); };
        globalThis.window.AddImportantActivity = function() { return globalThis.__beipRecordOutput('importantActivity', ''); };
        // Windows' Window_Main::Run submits the supplied text through the
        // normal BeipMU command/input pipeline. It is deliberately not an
        // eval: the bundled Windows aliases use window.run("buy torch") to
        // issue a client/server command.
        globalThis.window.Run = function(source) { globalThis.__beipRecordOutput('runCommand', source); };
        globalThis.window.RunFile = function(path) { globalThis.__beipRecordOutput('runFile', path); };
        globalThis.window.CreateDialogConnect = function() {
          if (globalThis.__beipState.window.connected) return false;
          globalThis.__beipRecordOutput('openConnectDialog', '');
          return true;
        };
        globalThis.__beipWindowHooks = {};
        globalThis.__beipSetWindowHook = function(event, callback, userdata) {
          if (callback == null) { delete globalThis.__beipWindowHooks[event]; return; }
          if (typeof callback !== 'function') throw new TypeError('Window callback must be a function.');
          globalThis.__beipWindowHooks[event] = { callback: callback, userdata: userdata };
        };
        globalThis.window.SetOnCommand = function(callback, userdata) { globalThis.__beipSetWindowHook('command', callback, userdata); };
        globalThis.window.SetOnActivate = function(callback, userdata) { globalThis.__beipSetWindowHook('activate', callback, userdata); };
        globalThis.window.SetOnClose = function(callback, userdata) { globalThis.__beipSetWindowHook('close', callback, userdata); };
        globalThis.__beipSpawnTabHooks = {};
        globalThis.window.GetSpawnTabs = function(title) {
          title = String(title);
          if ((globalThis.__beipState.spawnTabGroups || []).indexOf(title) < 0) return null;
          return {
            SetOnTabActivate: function(callback, userdata) {
              if (callback == null) { delete globalThis.__beipSpawnTabHooks[title]; return; }
              if (typeof callback !== 'function') throw new TypeError('Tab callback must be a function.');
              globalThis.__beipSpawnTabHooks[title] = { callback: callback, userdata: userdata };
            }
          };
        };
        globalThis.window.GetInput = function(title) {
          title = String(title);
          var state = (globalThis.__beipState.secondaryInputs || []).find(function(value) { return value.title === title; });
          if (!state) return null;
          var selection = [0, 0];
          var record = function(action, value) {
            globalThis.__beipRecordOutput('secondaryInput', JSON.stringify({ identifier: title, kind: 'input', action: action, strings: [String(value)], numbers: [] }));
          };
          var proxy = {
            Get: function() { return String(state.text || ''); },
            Set: function(value) { state.text = String(value); record('set', value); },
            SetSel: function(start, end) { selection = [Number(start)|0, Number(end)|0]; },
            GetSelStart: function() { return selection[0]; },
            GetSelEnd: function() { return selection[1]; }
          };
          proxy.get = proxy.Get; proxy.set = proxy.Set; proxy.setSel = proxy.SetSel;
          Object.defineProperties(proxy, {
            Length: { get: function() { return proxy.Get().length; } },
            Prefix: { get: function() { return String(state.prefix || ''); }, set: function(value) { state.prefix = String(value); record('prefix', value); } },
            Title: { get: function() { return String(state.title || ''); }, set: function(value) { state.title = String(value); record('title', value); } }
          });
          return proxy;
        };
        globalThis.window.getVariable = globalThis.window.GetVariable;
        globalThis.window.setVariable = globalThis.window.SetVariable;
        globalThis.window.deleteVariable = globalThis.window.DeleteVariable;
        globalThis.window.close = globalThis.window.Close;
        globalThis.window.activity = globalThis.window.Activity;
        globalThis.window.addImportantActivity = globalThis.window.AddImportantActivity;
        globalThis.window.run = globalThis.window.Run;
        globalThis.window.runFile = globalThis.window.RunFile;
        globalThis.window.createDialogConnect = globalThis.window.CreateDialogConnect;
        globalThis.window.setOnCommand = globalThis.window.SetOnCommand;
        globalThis.window.setOnActivate = globalThis.window.SetOnActivate;
        globalThis.window.setOnClose = globalThis.window.SetOnClose;
        globalThis.window.getSpawnTabs = globalThis.window.GetSpawnTabs;
        globalThis.window.getInput = globalThis.window.GetInput;
        globalThis.window.connection.transmit = globalThis.window.connection.Transmit;
        globalThis.window.connection.receive = globalThis.window.connection.Receive;
        globalThis.window.connection.display = globalThis.window.connection.Display;
        globalThis.window.connection.isConnected = globalThis.window.connection.IsConnected;
        globalThis.window.connection.isLogging = globalThis.window.connection.IsLogging;
        globalThis.window.connection.reconnect = globalThis.window.connection.Reconnect;
        globalThis.window.connection.setOnSend = globalThis.window.connection.SetOnSend;
        globalThis.window.connection.setOnReceive = globalThis.window.connection.SetOnReceive;
        globalThis.window.connection.setOnDisplay = globalThis.window.connection.SetOnDisplay;
        globalThis.window.connection.setOnGMCP = globalThis.window.connection.SetOnGMCP;
        globalThis.window.connection.setOnConnect = globalThis.window.connection.SetOnConnect;
        globalThis.window.connection.setOnDisconnect = globalThis.window.connection.SetOnDisconnect;
        globalThis.window.Properties = {};
        Object.defineProperty(globalThis.window.Properties, 'HWND', { get: function() { throw new Error('HWND is not supported on macOS'); } });
        Object.defineProperty(globalThis.window.Properties, 'Title', { get: function() { return globalThis.window.Title || ''; } });
        Object.defineProperty(globalThis.window, 'TitlePrefix', {
          get: function() { return globalThis.__beipState.window.titlePrefix || ''; },
          set: function(value) { globalThis.__beipState.window.titlePrefix = String(value); globalThis.__beipRecordOutput('setTitlePrefix', value); }
        });
        Object.defineProperty(globalThis.window, 'titlePrefix', { get: function() { return globalThis.window.TitlePrefix; }, set: function(value) { globalThis.window.TitlePrefix = value; } });
        globalThis.window.output.Properties = globalThis.window.output.properties = globalThis.window.Properties;
        globalThis.window.history.Properties = globalThis.window.history.properties = globalThis.window.Properties;
        globalThis.__beipConnectionHooks = {};
        globalThis.__beipSetConnectionHook = function(event, callback, userdata) {
          if (callback == null) { delete globalThis.__beipConnectionHooks[event]; return; }
          if (typeof callback !== 'function') throw new TypeError('Connection callback must be a function.');
          globalThis.__beipConnectionHooks[event] = { callback: callback, userdata: userdata };
        };
        globalThis.__beipDispatchConnectionEvent = function(event, arguments, lineValue) {
          if (event === 'app:newWindow') {
            return globalThis.__beipOnNewWindow ? globalThis.__beipOnNewWindow.callback(globalThis.__beipOnNewWindow.userdata) : undefined;
          }
          if (String(event).indexOf('spawnTabs:') === 0) {
            var group = String(event).slice(10), tabHook = globalThis.__beipSpawnTabHooks[group];
            return tabHook ? tabHook.callback(String(arguments[0] || ''), tabHook.userdata) : undefined;
          }
          if (String(event).indexOf('scriptWindow:') === 0) {
            var parts = String(event).split(':'), scriptWindow = globalThis.__beipScriptWindows[parts[1]], scriptEvent = parts[2];
            if (!scriptWindow) return undefined;
            if (scriptEvent === 'close' && typeof scriptWindow.__beipOnClose === 'function') return scriptWindow.__beipOnClose(scriptWindow.__beipOnCloseData);
            if (scriptEvent === 'key' && typeof scriptWindow.__beipOnKey === 'function') return scriptWindow.__beipOnKey(Number(arguments[0]), scriptWindow.__beipOnKeyData);
            if (scriptEvent === 'mouseMove' && typeof scriptWindow.__beipOnMouseMove === 'function') return scriptWindow.__beipOnMouseMove(Number(arguments[0]), Number(arguments[1]), scriptWindow.__beipOnMouseMoveData);
            if (scriptEvent === 'pause') {
              scriptWindow.Paused = String(arguments[0]) === 'true';
              return typeof scriptWindow.__beipOnPause === 'function' ? scriptWindow.__beipOnPause(scriptWindow.Paused) : undefined;
            }
            return undefined;
          }
          if (String(event).indexOf('window:') === 0) {
            var windowEvent = String(event).slice(7), windowHook = globalThis.__beipWindowHooks[windowEvent];
            if (!windowHook) return undefined;
            if (windowEvent === 'command') return windowHook.callback(String(arguments[0] || ''), String(arguments[1] || ''), windowHook.userdata);
            if (windowEvent === 'activate') return windowHook.callback(windowHook.userdata, String(arguments[0]) === 'true');
            return windowHook.callback(windowHook.userdata);
          }
          var hook = globalThis.__beipConnectionHooks[event];
          if (!hook) return undefined;
          var callbackArguments;
          if (event === 'connect' || event === 'disconnect') callbackArguments = [hook.userdata];
          else if (event === 'display') {
            var line = globalThis.__beipLine(lineValue || { text: '' });
            var handled = hook.callback(line, hook.userdata) === true;
            return JSON.stringify({ text: line.String, html: line.HTMLString, handled: handled });
          } else callbackArguments = [String((arguments || [])[0] || ''), hook.userdata];
          return hook.callback.apply(null, callbackArguments);
        };
        globalThis.__beipSetHostState = function(state) {
          globalThis.__beipState = state || globalThis.__beipState;
          globalThis.__beipState.window = globalThis.__beipState.window || { variables: {} };
          globalThis.__beipState.window.variables = globalThis.__beipState.window.variables || {};
          var worldValues = (globalThis.__beipState.worlds || []).map(function(value) {
            var world = { Name: value.name, name: value.name, Info: value.info, info: value.info, Host: value.host, host: value.host };
            world.Characters = world.characters = globalThis.__beipCollection((value.characters || []).map(function(character) {
              return { Name: character.name, name: character.name, Description: character.description || '' };
            }));
            return world;
          });
          globalThis.worlds = globalThis.app.Worlds = globalThis.app.worlds = globalThis.__beipCollection(worldValues);
          globalThis.aliases = globalThis.app.Aliases = globalThis.app.aliases = globalThis.__beipCollection((globalThis.__beipState.aliases || []).map(globalThis.__beipAlias));
          globalThis.triggers = globalThis.app.Triggers = globalThis.app.triggers = globalThis.__beipCollection((globalThis.__beipState.triggers || []).map(globalThis.__beipTrigger));
          globalThis.windows = globalThis.app.Windows = globalThis.app.windows = globalThis.__beipCollection([globalThis.window]);
          globalThis.connections = globalThis.__beipCollection([globalThis.window.connection]);
          var findWorld = function(name) {
            if (!name) return null;
            return worldValues.find(function(value) { return String(value.Name).toLowerCase() === String(name).toLowerCase(); }) || null;
          };
          globalThis.window.connection.World = globalThis.window.connection.world = findWorld(globalThis.__beipState.activeWorld);
          globalThis.window.connection.Character = globalThis.window.connection.character = globalThis.__beipState.activeCharacter
            ? { Name: globalThis.__beipState.activeCharacter, name: globalThis.__beipState.activeCharacter, Description: '' } : null;
          globalThis.window.connection.Puppet = globalThis.window.connection.puppet = globalThis.__beipState.activePuppet
            ? { Name: globalThis.__beipState.activePuppet, name: globalThis.__beipState.activePuppet, Description: '' } : null;
          var log = globalThis.__beipState.window.logging ? {
            Write: function(text) { return globalThis.__beipRecordOutput('logWrite', text); },
            WriteLine: function(line) { return globalThis.__beipRecordOutput('logWriteLine', line && line.String !== undefined ? line.String : line); }
          } : null;
          if (log) {
            log.write = log.Write;
            log.writeLine = log.WriteLine;
            Object.defineProperty(log, 'FileName', { get: function() { return globalThis.__beipState.window.logFileName || ''; } });
            Object.defineProperty(log, 'fileName', { get: function() { return log.FileName; } });
          }
          globalThis.window.connection.Log = globalThis.window.connection.log = log;
          var timerCollection = function(index) { return timerCollection.Item(index); };
          timerCollection.Item = timerCollection.item = function(index) { return Object.values(globalThis.__beipTimers)[Number(index)]; };
          Object.defineProperty(timerCollection, 'Count', { get: function() { return Object.keys(globalThis.__beipTimers).length; } });
          Object.defineProperty(timerCollection, 'count', { get: function() { return timerCollection.Count; } });
          globalThis.timers = timerCollection;
          globalThis.logs = globalThis.__beipCollection([]);
          var socketCollection = function(index) { return socketCollection.Item(index); };
          socketCollection.Item = socketCollection.item = function(index) { return Object.values(globalThis.__beipSockets)[Number(index)]; };
          Object.defineProperty(socketCollection, 'Count', { get: function() { return Object.keys(globalThis.__beipSockets).length; } });
          Object.defineProperty(socketCollection, 'count', { get: function() { return socketCollection.Count; } });
          globalThis.sockets = socketCollection;
          globalThis.lines = globalThis.__beipCollection([]);
          globalThis.window.Title = globalThis.__beipState.window.title || '';
        };
        Object.defineProperties(globalThis.app, {
          BuildNumber: { get: function() { return globalThis.__beipState.buildNumber || 0; } },
          BuildDate: { get: function() { return globalThis.__beipState.buildDate ? new Date(globalThis.__beipState.buildDate) : null; } },
          Version: { get: function() { return globalThis.__beipState.version || 0; } },
          ConfigPath: { get: function() { return globalThis.__beipState.configPath || ''; } }
        });
        globalThis.app.ActiveXObject = function(name) { throw new Error('ActiveXObject is not supported on macOS: ' + name); };
        globalThis.ActiveXObject = globalThis.app.ActiveXObject;
        globalThis.app.OutputDebugText = function(text) { return globalThis.__beipRecordOutput('debugText', text); };
        globalThis.app.OutputDebugHTML = function(html) { return globalThis.__beipRecordOutput('debugHTML', html); };
        globalThis.app.Display = function(text) { return globalThis.__beipRecordOutput('display', text); };
        globalThis.app.Send = function(text) { return globalThis.__beipRecordOutput('send', text); };
        globalThis.app.PlaySound = function(path) { return globalThis.__beipRecordOutput('playSound', path); };
        globalThis.app.StopSounds = function() { return globalThis.__beipRecordOutput('stopSounds', ''); };
        globalThis.__beipNextWindowIdentifier = 1;
        globalThis.__beipScriptWindows = {};
        globalThis.__beipWindowOperation = function(windowObject, action, strings, numbers) {
          return globalThis.__beipRecordOutput('scriptWindow', JSON.stringify({
            identifier: windowObject.__beipIdentifier,
            kind: windowObject.__beipKind,
            action: action,
            strings: (strings || []).map(String),
            numbers: (numbers || []).map(Number)
          }));
        };
        globalThis.__beipScriptWindowBase = function(kind, width, height) {
          var object = { __beipIdentifier: 'script-' + globalThis.__beipNextWindowIdentifier++, __beipKind: kind };
          var title = kind === 'text' ? 'Script Text' : kind === 'fixed' ? 'Script Fixed Text' : 'Script Graphics';
          object.Properties = object.properties = {};
          Object.defineProperty(object.Properties, 'Title', {
            get: function() { return title; },
            set: function(value) { title = String(value); globalThis.__beipWindowOperation(object, 'title', [title]); }
          });
          Object.defineProperty(object.Properties, 'title', { get: function() { return title; }, set: function(value) { object.Properties.Title = value; } });
          object.Dock = function(side) { globalThis.__beipWindowOperation(object, 'dock', [], [Number(side)]); };
          object.dock = object.Dock;
          object.Docking = object.docking = { Dock: object.Dock, dock: object.Dock };
          object.Events = object.events = {
            SetOnClose: function(callback, userdata) { object.__beipOnClose = callback; object.__beipOnCloseData = userdata; },
            SetOnKey: function(callback, userdata) { object.__beipOnKey = callback; object.__beipOnKeyData = userdata; },
            SetOnMouseMove: function(callback, userdata) { object.__beipOnMouseMove = callback; object.__beipOnMouseMoveData = userdata; }
          };
          object.Events.setOnClose = object.Events.SetOnClose;
          object.Events.setOnKey = object.Events.SetOnKey;
          object.Events.setOnMouseMove = object.Events.SetOnMouseMove;
          globalThis.__beipScriptWindows[object.__beipIdentifier] = object;
          globalThis.__beipWindowOperation(object, 'create', [], [width, height]);
          return object;
        };
        globalThis.__beipNewTextWindow = function(width, height) {
          var object = globalThis.__beipScriptWindowBase('text', width, height);
          object.Paused = false;
          object.Create = function(text) { return globalThis.__beipLine({ text: String(text) }); };
          object.CreateHTML = function(html) { return globalThis.__beipLine({ text: String(html).replace(/<[^>]*>/g, '') }, String(html)); };
          object.Add = function(line) { globalThis.__beipWindowOperation(object, 'html', [line.HTMLString]); };
          object.Write = function(text) { globalThis.__beipWindowOperation(object, 'write', [text]); };
          object.WriteHTML = function(html) { globalThis.__beipWindowOperation(object, 'html', [html]); };
          object.SetOnPause = function(callback) { object.__beipOnPause = callback; };
          ['Create','CreateHTML','Add','Write','WriteHTML','SetOnPause'].forEach(function(name) { object[name.charAt(0).toLowerCase() + name.slice(1)] = object[name]; });
          return object;
        };
        globalThis.__beipNewFixedWindow = function(width, height) {
          var object = globalThis.__beipScriptWindowBase('fixed', width, height), cursorX = 0, cursorY = 0;
          Object.defineProperties(object, {
            CursorX: { get: function() { return cursorX; }, set: function(value) { cursorX = Number(value) | 0; globalThis.__beipWindowOperation(object, 'cursor', [], [cursorX, cursorY]); } },
            CursorY: { get: function() { return cursorY; }, set: function(value) { cursorY = Number(value) | 0; globalThis.__beipWindowOperation(object, 'cursor', [], [cursorX, cursorY]); } }
          });
          Object.defineProperty(object, 'cursorX', { get: function() { return object.CursorX; }, set: function(value) { object.CursorX = value; } });
          Object.defineProperty(object, 'cursorY', { get: function() { return object.CursorY; }, set: function(value) { object.CursorY = value; } });
          object.Clear = function() { cursorX = 0; cursorY = 0; globalThis.__beipWindowOperation(object, 'clear'); };
          object.Write = function(text) { globalThis.__beipWindowOperation(object, 'writeAt', [text], [cursorX, cursorY]); cursorX += String(text).length; };
          object.clear = object.Clear; object.write = object.Write;
          return object;
        };
        globalThis.__beipNewGraphicsWindow = function(width, height) {
          var object = globalThis.__beipScriptWindowBase('graphics', width, height), pixels = {}, penColor = 0, penWidth = 1, x = 0, y = 0;
          Object.defineProperties(object, { Width: { get: function() { return width; } }, Height: { get: function() { return height; } } });
          object.Clear = function(color) { pixels = {}; globalThis.__beipWindowOperation(object, 'clear', [], [Number(color || 0)]); };
          object.SetPixel = function(px, py, color) { pixels[(Number(px)|0) + ',' + (Number(py)|0)] = Number(color)|0; globalThis.__beipWindowOperation(object, 'pixel', [], [px, py, color]); };
          object.GetPixel = function(px, py) { return pixels[(Number(px)|0) + ',' + (Number(py)|0)] || 0; };
          object.SetPen = function(color, lineWidth) { penColor = Number(color)|0; penWidth = Math.max(1, Number(lineWidth || 1)|0); };
          object.MoveTo = function(px, py) { x = Number(px)|0; y = Number(py)|0; };
          object.LineTo = function(px, py) { globalThis.__beipWindowOperation(object, 'line', [], [x, y, px, py, penColor, penWidth]); x = Number(px)|0; y = Number(py)|0; };
          object.Text = function(px, py, text) { globalThis.__beipWindowOperation(object, 'drawText', [text], [px, py, penColor]); };
          ['Clear','SetPixel','GetPixel','SetPen','MoveTo','LineTo','Text'].forEach(function(name) { object[name.charAt(0).toLowerCase() + name.slice(1)] = object[name]; });
          return object;
        };
        globalThis.app.NewTrigger = function() { return globalThis.__beipTrigger({}); };
        globalThis.app.NewWindow_Text = function(width, height) { return globalThis.__beipNewTextWindow(Number(width === undefined ? 320 : width), Number(height === undefined ? 240 : height)); };
        globalThis.app.NewWindow_FixedText = function(width, height) { return globalThis.__beipNewFixedWindow(Number(width === undefined ? 80 : width), Number(height === undefined ? 25 : height)); };
        globalThis.app.NewWindow_Graphics = function(width, height) { return globalThis.__beipNewGraphicsWindow(Number(width), Number(height)); };
        globalThis.app.NewWindow = function() {
          globalThis.__beipRecordOutput('newMainWindow', '');
          return { Title: '', UserData: null };
        };
        globalThis.app.SetOnNewWindow = function(callback, userdata) {
          if (callback == null) { globalThis.__beipOnNewWindow = null; return; }
          if (typeof callback !== 'function') throw new TypeError('New-window callback must be a function.');
          globalThis.__beipOnNewWindow = { callback: callback, userdata: userdata };
        };
        globalThis.app.CreateInterval = function(milliseconds, callback, userdata) { return globalThis.__beipTimer(milliseconds, callback, userdata, true); };
        globalThis.app.CreateTimeout = function(milliseconds, callback, userdata) { return globalThis.__beipTimer(milliseconds, callback, userdata, false); };
        globalThis.app.ForwardDNSLookup = function(hostname, callback, userdata) { return globalThis.__beipDNSLookup(hostname, callback, userdata, false); };
        globalThis.app.ReverseDNSLookup = function(address, callback, userdata) { return globalThis.__beipDNSLookup(address, callback, userdata, true); };
        globalThis.app.IsAddress = function(address) { return !!globalThis.__beipIsAddress(String(address)); };
        globalThis.app.New_Socket = function() { return globalThis.__beipCreateSocket(); };
        globalThis.app.New_SocketServer = function(port, callback, userdata) { return globalThis.__beipCreateSocketServer(port, callback, userdata); };
        globalThis.app.outputDebugText = globalThis.app.OutputDebugText;
        globalThis.app.outputDebugHTML = globalThis.app.OutputDebugHTML;
        globalThis.app.display = globalThis.app.Display;
        globalThis.app.send = globalThis.app.Send;
        globalThis.app.playSound = globalThis.app.PlaySound;
        globalThis.app.stopSounds = globalThis.app.StopSounds;
        globalThis.app.newTrigger = globalThis.app.NewTrigger;
        globalThis.app.newWindow_Text = globalThis.app.NewWindow_Text;
        globalThis.app.newWindow_FixedText = globalThis.app.NewWindow_FixedText;
        globalThis.app.newWindow_Graphics = globalThis.app.NewWindow_Graphics;
        globalThis.app.newWindow = globalThis.app.NewWindow;
        globalThis.app.setOnNewWindow = globalThis.app.SetOnNewWindow;
        globalThis.app.createInterval = globalThis.app.CreateInterval;
        globalThis.app.createTimeout = globalThis.app.CreateTimeout;
        globalThis.app.forwardDNSLookup = globalThis.app.ForwardDNSLookup;
        globalThis.app.reverseDNSLookup = globalThis.app.ReverseDNSLookup;
        globalThis.app.isAddress = globalThis.app.IsAddress;
        globalThis.app.new_Socket = globalThis.app.New_Socket;
        globalThis.app.new_socket = globalThis.app.New_Socket;
        globalThis.app.new_SocketServer = globalThis.app.New_SocketServer;
        globalThis.app.new_socketserver = globalThis.app.New_SocketServer;
        globalThis.beip.App = globalThis.app;
        globalThis.beip.Window = globalThis.window;
        globalThis.__beipSetHostState(globalThis.__beipState);
        """

    private static let help: [String: String] = [
        "app": "App: BuildNumber, BuildDate, Version, ConfigPath, Worlds, Windows, Triggers, Aliases, timers, DNS, sockets, output, sound, and window factories",
        "arrayuint": "ArrayUInt: Item(index), Count",
        "window_main": "Window_Main: Output, History, Input, Connection, Run, RunFile, Close, Activity, AddImportantActivity, GetVariable, SetVariable, DeleteVariable",
        "window_control_edit": "Window_Control_Edit: SetSel, GetSelStart, GetSelEnd, Length, Set, Get, Prefix, Title",
        "window_events": "Window_Events: OnCommand, OnDisplay, OnSend, OnReceive, OnConnect, OnDisconnect",
        "window_fixedtext": "Window_FixedText: Text, Color, Font, Set, Get",
        "window_graphics": "Window_Graphics: Draw, Clear, Width, Height",
        "window_input": "Window_Input: SetSel, GetSelStart, GetSelEnd, Length, Set, Get, Prefix, Title",
        "window_properties": "Window_Properties: Name, Type, Parent, Visible, Enabled",
        "window_spawntabs": "Window_SpawnTabs: Windows, Add, Remove, Select",
        "window_text": "Window_Text: Write, WriteHTML, Create, Add, Paused",
        "windows": "Windows: Item(index-or-title), Count",
        "connection": "Connection: Send, Transmit, Receive, Display, IsConnected, Reconnect, IsLogging, Log, World, Character, Puppet, Window_Main",
        "world": "World: Name, Info, Host, Characters",
        "worlds": "Worlds: Item(index-or-name), Count",
        "character": "Character: Name, Description",
        "characters": "Characters: Item(index-or-name), Count",
        "findstring": "FindString: MatchText, RegularExpression, MatchCase, StartsWith, EndsWith, WholeWord",
        "alias": "Alias: FindString, StopProcessing, Folder",
        "aliases": "Aliases: Item(index-or-name), Count",
        "trigger": "Trigger: FindString, Disabled, StopProcessing, OncePerLine, Triggers, Aliases",
        "timer": "Timer: Active, UserData, Kill; create one-shot or repeating timers with App.CreateTimeout and App.CreateInterval",
        "socket": "Socket: Connect, Close, IsConnected, Send, SetOnConnect, SetOnDisconnect, SetOnReceive, SetFlag, UserData; create with App.New_Socket",
        "socketserver": "SocketServer: Shutdown; create with App.New_SocketServer(port, callback, userdata)",
        "log": "Log: FileName, Write, WriteLine",
        "puppet": "Puppet: Name, Description (connection routing is exposed by the native client)",
        "puppets": "Puppets: Item(index-or-name), Count",
        "triggers": "Triggers: Item(index-or-name), Count",
        "textwindowline": "TextWindowLine: String, HTMLString, Length, Insert, Delete, Color, BgColor, Bold, Italic, Underline, Strikeout, Flash, FlashMode, Blink",
    ]
}
