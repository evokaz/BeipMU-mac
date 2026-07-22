import BeipCore
import BeipScriptRuntime
import Foundation

private final class EvaluationReply: @unchecked Sendable {
    let call: (NSString?, NSString?, NSString?) -> Void

    init(_ call: @escaping (NSString?, NSString?, NSString?) -> Void) {
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

final class ScriptService: NSObject, ScriptServiceProtocol, @unchecked Sendable {
    private let runtime = ScriptRuntime()

    func evaluate(_ source: NSString, hostJSON: NSString, reply: @escaping (NSString?, NSString?, NSString?) -> Void) {
        let source = source as String
        let host = decodeHost(hostJSON as String)
        let reply = EvaluationReply(reply)
        Task {
            let result = await runtime.evaluate(source, host: host)
            reply.call(result.value as NSString?, result.error as NSString?, encodedOutputs(result.outputs))
        }
    }

    func call(_ function: NSString, arguments: [NSString], hostJSON: NSString, reply: @escaping (NSString?, NSString?, NSString?) -> Void) {
        let function = function as String
        let arguments = arguments.map { $0 as String }
        let host = decodeHost(hostJSON as String)
        let reply = EvaluationReply(reply)
        Task {
            let result = await runtime.call(function, arguments: arguments, host: host)
            reply.call(result.value as NSString?, result.error as NSString?, encodedOutputs(result.outputs))
        }
    }


    func callTrigger(_ function: NSString, ranges: [NSNumber], lineJSON: NSString, hostJSON: NSString, reply: @escaping (NSString?, NSString?, NSString?) -> Void) {
        let function = function as String
        let ranges = ranges.map(\.intValue)
        let line = decodeLine(lineJSON as String)
        let host = decodeHost(hostJSON as String)
        let reply = EvaluationReply(reply)
        Task {
            let result = await runtime.callTrigger(function, ranges: ranges, line: line, host: host)
            reply.call(result.value as NSString?, result.error as NSString?, encodedOutputs(result.outputs))
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

    private func encodedOutputs(_ outputs: [ScriptOutput]) -> NSString? {
        guard let data = try? JSONEncoder().encode(outputs), let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string as NSString
    }

    private func decodeHost(_ source: String) -> ScriptHostSnapshot {
        guard let data = source.data(using: .utf8),
              let host = try? JSONDecoder().decode(ScriptHostSnapshot.self, from: data) else { return .init() }
        return host
    }


    private func decodeLine(_ source: String) -> RenderedLine {
        guard let data = source.data(using: .utf8),
              let line = try? JSONDecoder().decode(RenderedLine.self, from: data) else { return .init(text: "") }
        return line
    }
}

/// Each accepted connection owns an independent JavaScriptCore virtual
/// machine. Invalidating a wedged connection therefore makes the next client
/// request usable immediately, even if the service process itself remains
/// alive while an old JavaScript thread winds down.
final class ScriptServiceListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ScriptServiceProtocol.self)
        connection.exportedObject = ScriptService()
        connection.resume()
        return true
    }
}

let listener = NSXPCListener.service()
let serviceListener = ScriptServiceListener()
listener.delegate = serviceListener
listener.resume()
