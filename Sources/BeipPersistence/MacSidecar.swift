import Foundation

public struct MacConfigurationSidecar: Sendable, Codable, Equatable {
    public struct WindowState: Sendable, Codable, Equatable {
        public var frame: String
        public var dockLayout: Data?

        public init(frame: String, dockLayout: Data? = nil) {
            self.frame = frame
            self.dockLayout = dockLayout
        }
    }

    public var version: Int
    public var windows: [String: WindowState]
    public var keyEquivalents: [String: String]
    public var pathMappings: [String: String]
    public var selectedConfigPath: String?

    public init(
        version: Int = 1,
        windows: [String: WindowState] = [:],
        keyEquivalents: [String: String] = [:],
        pathMappings: [String: String] = [:],
        selectedConfigPath: String? = nil
    ) {
        self.version = version
        self.windows = windows
        self.keyEquivalents = keyEquivalents
        self.pathMappings = pathMappings
        self.selectedConfigPath = selectedConfigPath
    }
}

public enum MacSidecarStore {
    public static func load(from url: URL) throws -> MacConfigurationSidecar {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(MacConfigurationSidecar.self, from: Data(contentsOf: url))
    }

    public static func save(_ sidecar: MacConfigurationSidecar, to url: URL) throws {
        try save(sidecar, to: url, writer: .live)
    }

    static func save(
        _ sidecar: MacConfigurationSidecar,
        to url: URL,
        writer: AtomicFileWriter
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writer.write(encoder.encode(sidecar), to: url)
    }
}
