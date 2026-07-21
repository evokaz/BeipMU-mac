import Foundation

@objc public protocol ScriptServiceProtocol {
    func evaluate(_ source: NSString, reply: @escaping (NSString?, NSString?) -> Void)
    func reset(reply: @escaping () -> Void)
    func helpTypes(reply: @escaping ([NSString]) -> Void)
}

public actor ScriptServiceClient {
    private var connection: NSXPCConnection?

    public init() {}

    public func evaluate(_ source: String) async -> ScriptEvaluation {
        let connection = activeConnection()
        return await withCheckedContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(returning: .init(error: error.localizedDescription))
            }
            guard let service = proxy as? ScriptServiceProtocol else {
                continuation.resume(returning: .init(error: "Unable to create the BeipMU script service proxy."))
                return
            }
            service.evaluate(source as NSString) { value, error in
                continuation.resume(returning: .init(value: value as String?, error: error as String?))
            }
        }
    }

    public func reset() async {
        let connection = activeConnection()
        await withCheckedContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in continuation.resume() }
            guard let service = proxy as? ScriptServiceProtocol else { continuation.resume(); return }
            service.reset { continuation.resume() }
        }
    }

    public func invalidate() {
        connection?.invalidate()
        connection = nil
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(serviceName: "org.beipmu.BeipMU.ScriptService")
        connection.remoteObjectInterface = NSXPCInterface(with: ScriptServiceProtocol.self)
        connection.resume()
        self.connection = connection
        return connection
    }
}

