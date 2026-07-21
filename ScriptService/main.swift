import BeipScriptRuntime
import Foundation

private final class EvaluationReply: @unchecked Sendable {
    let call: (NSString?, NSString?) -> Void

    init(_ call: @escaping (NSString?, NSString?) -> Void) {
        self.call = call
    }
}

private final class ResetReply: @unchecked Sendable {
    let call: () -> Void

    init(_ call: @escaping () -> Void) {
        self.call = call
    }
}

private final class HelpReply: @unchecked Sendable {
    let call: ([NSString]) -> Void

    init(_ call: @escaping ([NSString]) -> Void) {
        self.call = call
    }
}

final class ScriptService: NSObject, NSXPCListenerDelegate, ScriptServiceProtocol, @unchecked Sendable {
    private let runtime = ScriptRuntime()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ScriptServiceProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func evaluate(_ source: NSString, reply: @escaping (NSString?, NSString?) -> Void) {
        let source = source as String
        let reply = EvaluationReply(reply)
        Task {
            let result = await runtime.evaluate(source)
            reply.call(result.value as NSString?, result.error as NSString?)
        }
    }

    func reset(reply: @escaping () -> Void) {
        let reply = ResetReply(reply)
        Task {
            await runtime.reset()
            reply.call()
        }
    }

    func helpTypes(reply: @escaping ([NSString]) -> Void) {
        let reply = HelpReply(reply)
        Task {
            let types = await runtime.helpTypes()
            reply.call(types.map { $0 as NSString })
        }
    }
}

let listener = NSXPCListener.service()
let service = ScriptService()
listener.delegate = service
listener.resume()
