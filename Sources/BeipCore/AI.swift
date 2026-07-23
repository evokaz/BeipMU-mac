import Foundation

public struct AIRequest: Sendable, Hashable, Codable {
    public var prompt: String
    public var model: String

    public init(prompt: String, model: String = "") {
        self.prompt = prompt
        self.model = model
    }
}

public enum AIClientError: LocalizedError, Equatable {
    case missingEndpoint
    case invalidEndpoint
    case invalidResponse
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingEndpoint: "No AI endpoint is configured for this world."
        case .invalidEndpoint: "The AI endpoint must use HTTP or HTTPS."
        case .invalidResponse: "The AI endpoint returned an unreadable response."
        case let .server(status, message):
            message.isEmpty ? "The AI endpoint returned HTTP \(status)." : "The AI endpoint returned HTTP \(status): \(message)"
        }
    }
}

/// Small, provider-neutral client for the v331 AI window.  The endpoint is
/// intentionally configured per server.  It accepts the common `{response}`
/// and `{choices:[{message:{content}}]}` shapes and otherwise displays a
/// plain JSON/string response without binding the UI to one provider.
public actor AIClient {
    public init() {}

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
