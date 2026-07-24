import Foundation

/// Shared atomic replacement primitive for persistence stores.
///
/// The failure mode is internal so tests can exercise the two boundaries that
/// cannot otherwise be triggered deterministically. Product callers always use
/// `live`.
struct AtomicFileWriter: Sendable {
    enum Stage: String, Sendable, CaseIterable {
        case beforeReplace
        case replace
    }

    enum WriterError: LocalizedError, Equatable {
        case injectedFailure(Stage)

        var errorDescription: String? {
            switch self {
            case let .injectedFailure(stage):
                "Injected atomic-write failure at \(stage.rawValue)."
            }
        }
    }

    static let live = Self()

    private var injectedFailure: Stage?
    private var beforeReplace: (@Sendable (URL) throws -> Void)?

    init(
        failingAt injectedFailure: Stage? = nil,
        beforeReplace: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.injectedFailure = injectedFailure
        self.beforeReplace = beforeReplace
    }

    func write(
        _ data: Data,
        to destination: URL,
        validatingCurrentFile: () throws -> Void = {}
    ) throws {
        let fileManager = FileManager.default
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporary) }

        try data.write(to: temporary, options: .withoutOverwriting)
        if injectedFailure == .beforeReplace {
            throw WriterError.injectedFailure(.beforeReplace)
        }
        try beforeReplace?(destination)
        try validatingCurrentFile()
        if injectedFailure == .replace {
            throw WriterError.injectedFailure(.replace)
        }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }
}
