import Foundation

public struct AIRequest: Sendable, Hashable, Codable {
    public var prompt: String
    public var model: String

    public init(prompt: String, model: String = "") {
        self.prompt = prompt
        self.model = model
    }
}

/// Effective AI settings for one world. Per-world provider-neutral endpoints
/// override the global Windows Ollama server; a world model overrides the
/// global model independently.
public struct AIConfiguration: Sendable, Equatable {
    public enum Backend: Sendable, Equatable {
        case providerNeutral(endpoint: URL)
        case ollama(server: String)
    }

    public var backend: Backend
    public var model: String

    public init(backend: Backend, model: String) {
        self.backend = backend
        self.model = model
    }

    public static func resolve(
        worldEndpoint: URL?,
        worldModel: String,
        globalOllamaServer: String,
        globalModel: String
    ) -> Self {
        let worldModel = worldModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = worldModel.isEmpty
            ? globalModel.trimmingCharacters(in: .whitespacesAndNewlines)
            : worldModel
        if let worldEndpoint {
            return .init(backend: .providerNeutral(endpoint: worldEndpoint), model: model)
        }
        return .init(backend: .ollama(server: globalOllamaServer), model: model)
    }
}

public enum AIClientError: LocalizedError, Equatable {
    case missingEndpoint
    case missingModel
    case invalidEndpoint
    case invalidResponse
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingEndpoint: "No AI endpoint is configured for this world."
        case .missingModel: "No AI model is configured."
        case .invalidEndpoint: "The AI endpoint must use HTTP or HTTPS."
        case .invalidResponse: "The AI endpoint returned an unreadable response."
        case let .server(status, message):
            message.isEmpty ? "The AI endpoint returned HTTP \(status)." : "The AI endpoint returned HTTP \(status): \(message)"
        }
    }
}

/// AI client for the native window. Explicit per-world endpoints use the
/// provider-neutral request shape; global Windows settings use Ollama's API.
/// Responses accept the common `{response}` and
/// `{choices:[{message:{content}}]}` shapes.
public actor AIClient {
    public init() {}

    public func request(
        _ request: AIRequest,
        configuration: AIConfiguration,
        apiKey: String? = nil
    ) async throws -> String {
        let configuredRequest = AIRequest(prompt: request.prompt, model: configuration.model)
        switch configuration.backend {
        case let .providerNeutral(endpoint):
            return try await self.request(configuredRequest, endpoint: endpoint, apiKey: apiKey)
        case let .ollama(server):
            return try await requestOllama(configuredRequest, server: server)
        }
    }

    public func request(_ request: AIRequest, endpoint: URL?, apiKey: String? = nil) async throws -> String {
        guard let endpoint else { throw AIClientError.missingEndpoint }
        guard let scheme = endpoint.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw AIClientError.invalidEndpoint
        }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let body: [String: Any] = [
            "prompt": request.prompt,
            "model": request.model,
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.decodeText(data) ?? String(decoding: data, as: UTF8.self)
            throw AIClientError.server(status: http.statusCode, message: message)
        }
        guard let text = Self.decodeText(data), !text.isEmpty else { throw AIClientError.invalidResponse }
        return text
    }

    /// Sends a prompt to an Ollama server configured by its base address,
    /// such as `localhost:11434` or `http://localhost:11434`.
    public func requestOllama(_ request: AIRequest, server: String) async throws -> String {
        guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIClientError.missingModel
        }
        let endpoint = try Self.ollamaGenerateEndpoint(for: server)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": request.model,
            "prompt": request.prompt,
            "stream": false,
        ])
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.decodeText(data) ?? String(decoding: data, as: UTF8.self)
            throw AIClientError.server(status: http.statusCode, message: message)
        }
        guard let text = Self.decodeText(data), !text.isEmpty else { throw AIClientError.invalidResponse }
        return text
    }

    /// Converts an Ollama base address to its generate endpoint. A missing
    /// scheme defaults to HTTP, as is common for local Ollama installations.
    public nonisolated static func ollamaGenerateEndpoint(for server: String) throws -> URL {
        var address = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw AIClientError.missingEndpoint }
        if !address.contains("://") { address = "http://" + address }
        guard var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            throw AIClientError.invalidEndpoint
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.hasSuffix("api/generate") {
            components.path = "/" + basePath
        } else if basePath.isEmpty {
            components.path = "/api/generate"
        } else {
            components.path = "/\(basePath)/api/generate"
        }
        guard let endpoint = components.url else { throw AIClientError.invalidEndpoint }
        return endpoint
    }

    public nonisolated static func decodeText(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil {
            return text
        }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return text(in: object)
    }

    private nonisolated static func text(in value: Any) -> String? {
        if let value = value as? String { return value }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["response", "text", "content", "output"] {
            if let value = object[key], let result = text(in: value) { return result }
        }
        if let choices = object["choices"] as? [Any], let first = choices.first, let result = text(in: first) { return result }
        if let message = object["message"], let result = text(in: message) { return result }
        return nil
    }
}

public enum CommandTestFixtures {
    public static func payload(for kind: String) -> String? {
        switch kind.lowercased() {
        case "ansi":
            return "\r\n\u{1B}[0;1;37;44m ANSI color test \r\n\u{1B}[0;31;40m31 - Red \u{1B}[0;32;40m32 - Green \u{1B}[0;34;40m34 - Blue\r\n\u{1B}[0;38;5;208m256-color orange \u{1B}[0;38;2;40;180;255mtrue-color\r\n\u{1B}[0mResetting back to defaults\r\n"
        case "html":
            return "<font face=\"Cambria\" size=\"16\">Text <b><font color='#FF0000'>red</font></b> <icon information>Info"
        case "emoji":
            return "This is a dog face 🐶, a rocket 🚀, and a smile 🙂.\r\n"
        case "international":
            return "English: I can eat glass and it doesn't hurt me.\r\nChinese: 我能吞下玻璃而不伤身体。\r\nGreek: Μπορώ να φάω σπασμένα γυαλιά χωρίς να πάθω τίποτα.\r\n"
        case "utf8":
            return "Valid 2 Octet Sequence \u{00F1}\r\nInvalid 2 Octet Sequence \u{FFFD}(\r\nValid 3 Octet Sequence ₡\r\nValid 4 Octet Sequence 𐌼\r\n"
        default: return nil
        }
    }
}

public struct DiceFairnessReport: Sendable, Equatable {
    public var rollCount: Int
    public var counts: [Int]
    public var average: Double

    public init(rollCount: Int, counts: [Int], average: Double) {
        self.rollCount = rollCount
        self.counts = counts
        self.average = average
    }

    public static func run(rollCount: Int = 1_000_000, seed: UInt64 = 0xB317) -> Self {
        let count = max(1, rollCount)
        var state = seed
        var sides = Array(repeating: 0, count: 6)
        var total = 0
        for _ in 0..<count {
            state = state &* 2862933555777941757 &+ 3037000493
            let side = Int((state >> 32) % 6)
            sides[side] += 1
            total += side + 1
        }
        return .init(rollCount: count, counts: sides, average: Double(total) / Double(count))
    }

    public var displayText: String {
        let expected = Double(rollCount) / 6
        let sides = counts.enumerated().map { index, count in
            "Side \(index + 1) odds: \(String(format: "%.5f", Double(count) / expected))"
        }
        return (["Die fairness test, for \(rollCount) rolls:"] + sides + [
            "Average of all rolls: \(String(format: "%.5f", average))",
        ]).joined(separator: "\n")
    }
}
