import Foundation

public enum ServerWebViewPolicy: Int, Sendable, Hashable, Codable, CaseIterable {
    case ignore = 0
    case allow = 1
    case ask = 2

    public var title: String {
        switch self {
        case .ignore: "Ignore"
        case .allow: "Allow"
        case .ask: "Ask Every Time"
        }
    }
}

public enum WebViewDockSide: String, Sendable, Hashable, Codable, CaseIterable {
    case left, right, top, bottom
}

public struct WebViewFrame: Sendable, Hashable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct WebViewOpenRequest: Sendable, Hashable, Codable {
    public var id: String
    public var url: URL?
    public var source: String?
    public var headers: [String: String]
    public var dock: WebViewDockSide?
    public var width: Int?
    public var height: Int?
    public var caption: Bool?
    public var frame: WebViewFrame?
    public var maximized: Bool

    public init(
        id: String = "",
        url: URL? = nil,
        source: String? = nil,
        headers: [String: String] = [:],
        dock: WebViewDockSide? = nil,
        width: Int? = nil,
        height: Int? = nil,
        caption: Bool? = nil,
        frame: WebViewFrame? = nil,
        maximized: Bool = false
    ) {
        self.id = id
        self.url = url
        self.source = source
        self.headers = headers
        self.dock = dock
        self.width = width
        self.height = height
        self.caption = caption
        self.frame = frame
        self.maximized = maximized
    }

    public var permissionSummary: String {
        if let url { return url.absoluteString }
        if let source { return String(source.prefix(50)) }
        return id.isEmpty ? "a blank web view" : "web view '\(id)'"
    }
}

public enum WebViewProtocolEvent: Sendable, Hashable {
    case open(WebViewOpenRequest)
    case close(id: String)
}

public struct WebViewProtocolState: Sendable {
    public init() {}

    public mutating func consume(_ message: GMCPMessage) throws -> WebViewProtocolEvent? {
        let package = message.package.lowercased()
        guard package == "webview.open" || package == "webview.close" else { return nil }
        let object = try Self.object(message.payload)
        if package == "webview.close" {
            return .close(id: Self.string("id", object) ?? "")
        }

        let id = Self.string("id", object) ?? ""
        guard id.utf8.count <= 512 else { throw WebViewProtocolError.valueTooLarge("id") }
        let source = Self.string("source", object)
        guard (source?.utf8.count ?? 0) <= 2 * 1_024 * 1_024 else { throw WebViewProtocolError.valueTooLarge("source") }
        let url: URL?
        if source != nil {
            url = nil
        } else if let value = Self.string("url", object), !value.isEmpty {
            guard let parsed = URL(string: value), let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
                throw WebViewProtocolError.invalidServerURL(value)
            }
            url = parsed
        } else {
            url = nil
        }
        let dock: WebViewDockSide?
        if let value = Self.string("dock", object) {
            guard let parsed = WebViewDockSide(rawValue: value.lowercased()) else { throw WebViewProtocolError.invalidDock(value) }
            dock = parsed
        } else {
            dock = nil
        }
        let width = try Self.dimension("width", object)
        let height = try Self.dimension("height", object)
        var headers: [String: String] = [:]
        if let rawHeaders = Self.value("http-request-headers", object) as? [String: Any] {
            guard rawHeaders.count <= 64 else { throw WebViewProtocolError.valueTooLarge("http-request-headers") }
            for (name, rawValue) in rawHeaders {
                guard let value = rawValue as? String, Self.validHeader(name: name, value: value) else {
                    throw WebViewProtocolError.invalidHeader(name)
                }
                headers[name] = value
            }
        }
        return .open(.init(
            id: id,
            url: url,
            source: source,
            headers: headers,
            dock: dock,
            width: width,
            height: height,
            caption: Self.value("caption", object) as? Bool
        ))
    }

    private static func object(_ payload: String) throws -> [String: Any] {
        guard let data = payload.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebViewProtocolError.expectedObject
        }
        return value
    }

    private static func value(_ name: String, _ object: [String: Any]) -> Any? {
        object.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func string(_ name: String, _ object: [String: Any]) -> String? {
        value(name, object) as? String
    }

    private static func dimension(_ name: String, _ object: [String: Any]) throws -> Int? {
        guard let number = value(name, object) as? NSNumber else { return nil }
        let value = number.intValue
        guard (100...4096).contains(value) else { throw WebViewProtocolError.invalidDimension(name) }
        return value
    }

    private static func validHeader(name: String, value: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 256 && value.utf8.count <= 8_192 &&
            !name.contains(where: { $0 == "\r" || $0 == "\n" || $0 == ":" }) &&
            !value.contains(where: { $0 == "\r" || $0 == "\n" })
    }
}

public enum WebViewProtocolError: LocalizedError, Equatable {
    case expectedObject
    case invalidServerURL(String)
    case invalidDock(String)
    case invalidDimension(String)
    case invalidHeader(String)
    case valueTooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .expectedObject: "WebView expected a JSON object"
        case let .invalidServerURL(url): "Server WebView URL must use HTTP or HTTPS: \(url)"
        case let .invalidDock(value): "Unknown WebView dock side: \(value)"
        case let .invalidDimension(name): "WebView \(name) must be between 100 and 4096"
        case let .invalidHeader(name): "Invalid WebView request header: \(name)"
        case let .valueTooLarge(name): "WebView \(name) exceeds its safety limit"
        }
    }
}
