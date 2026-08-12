import CryptoKit
import Foundation

/// The common file-level persistence implementation used by both the public
/// configuration actor and the AppKit profile library.
///
/// The engine deliberately does not keep a mutable snapshot. Callers retain
/// the fingerprint returned by a load (or write) and pass it back to
/// ``checkedSave``. This keeps the engine synchronous while allowing an actor
/// or a main-actor owner to provide the appropriate isolation for its in-memory
/// model.
package struct LegacyConfigurationPersistenceEngine: Sendable {
    package enum BackupStrategy: Sendable, Equatable {
        case none
        case fixed
        case timestamped
    }

    package struct LoadedConfiguration: Sendable {
        package let document: LegacyConfigurationDocument
        /// The fingerprint of the primary file, rather than the recovered
        /// backup. This is what protects the primary when a recovered config
        /// is subsequently explicitly replaced.
        package let primaryFingerprint: String?
        package let recoveredFrom: URL?

        fileprivate init(
            document: LegacyConfigurationDocument,
            primaryFingerprint: String?,
            recoveredFrom: URL?
        ) {
            self.document = document
            self.primaryFingerprint = primaryFingerprint
            self.recoveredFrom = recoveredFrom
        }
    }

    private let url: URL
    private let backupStrategy: BackupStrategy

    private let writer: AtomicFileWriter
    private let backupWriter: AtomicFileWriter
    private let conflictWriter: AtomicFileWriter

    package init(
        url: URL,
        backupStrategy: BackupStrategy = .timestamped
    ) {
        self.url = url
        self.backupStrategy = backupStrategy
        writer = .live
        backupWriter = .live
        conflictWriter = .live
    }

    // Injection is intentionally kept internal. Production callers use the
    // package initializer above, while persistence tests can exercise atomic
    // failure and replace-boundary behavior without exposing test seams in the
    // public API.
    init(
        url: URL,
        backupStrategy: BackupStrategy = .timestamped,
        writer: AtomicFileWriter = .live,
        backupWriter: AtomicFileWriter = .live,
        conflictWriter: AtomicFileWriter = .live
    ) {
        self.url = url
        self.backupStrategy = backupStrategy
        self.writer = writer
        self.backupWriter = backupWriter
        self.conflictWriter = conflictWriter
    }

    /// Loads and validates the primary configuration without touching any
    /// backup or the primary file.
    package func load() throws -> LoadedConfiguration {
        let data = try Data(contentsOf: url)
        let document = try Self.readableDocument(data: data)
        return LoadedConfiguration(
            document: document,
            primaryFingerprint: Self.digest(data),
            recoveredFrom: nil
        )
    }

    /// Loads the primary configuration, falling back to the newest readable
    /// backup selected by ``backupStrategy``. Recovery never writes either
    /// file; callers decide whether and when to explicitly replace the
    /// primary with the recovered document.
    package func loadRecoveringFromBackup() throws -> LoadedConfiguration {
        do {
            return try load()
        } catch {
            let primaryData = try? Data(contentsOf: url)
            for backup in backupCandidates() {
                guard let data = try? Data(contentsOf: backup),
                      let document = try? Self.readableDocument(data: data) else {
                    continue
                }
                return LoadedConfiguration(
                    document: document,
                    primaryFingerprint: primaryData.map(Self.digest),
                    recoveredFrom: backup
                )
            }
            throw error
        }
    }

    /// Saves an editor-produced document only if the primary still has the
    /// fingerprint observed by the caller. The same check is repeated at the
    /// writer's replace boundary, immediately before the atomic replacement.
    /// A mismatch preserves the primary and writes the candidate to a conflict
    /// copy before throwing ``LegacyConfigurationError.externalChange``.
    @discardableResult
    package func checkedSave(
        _ document: LegacyConfigurationDocument,
        expectedPrimaryFingerprint: String?
    ) throws -> String {
        let currentData = try currentDataForCheckedSave(
            document: document,
            expectedPrimaryFingerprint: expectedPrimaryFingerprint
        )

        if let currentData {
            try writeBackup(currentData)
        }

        let data = Data(document.serialized().utf8)
        try ensureParentDirectory()
        try writer.write(data, to: url) { [self] in
            guard FileManager.default.fileExists(atPath: url.path) else {
                // A first save has no current primary. AtomicFileWriter will
                // move the temporary file into place after this callback, so
                // an absent destination is the expected nil baseline. If a
                // file appeared, however, the existence check below observes
                // it and reports the external change.
                guard expectedPrimaryFingerprint == nil else {
                    throw LegacyConfigurationError.externalChange(try writeConflict(document))
                }
                return
            }
            do {
                let latest = try Data(contentsOf: url)
                guard Self.digest(latest) == expectedPrimaryFingerprint else {
                    throw LegacyConfigurationError.externalChange(try writeConflict(document))
                }
            } catch let error as LegacyConfigurationError {
                throw error
            } catch {
                throw LegacyConfigurationError.externalChange(try writeConflict(document))
            }
        }
        return Self.digest(data)
    }

    /// Explicitly replaces the primary, bypassing snapshot conflict checks.
    /// This is used for imports, resets, new configurations, and deliberate
    /// backup restores. Existing data is backed up according to the selected
    /// strategy unless ``backingUpCurrent`` is false.
    @discardableResult
    package func replace(
        _ document: LegacyConfigurationDocument,
        backingUpCurrent: Bool = true
    ) throws -> String {
        if backingUpCurrent,
           let currentData = try? Data(contentsOf: url) {
            try writeBackup(currentData)
        }
        let data = Data(document.serialized().utf8)
        try ensureParentDirectory()
        try writer.write(data, to: url)
        return Self.digest(data)
    }

    /// The fixed backup path used by ``BackupStrategy.fixed``.
    package var fixedBackupURL: URL? {
        guard backupStrategy == .fixed else { return nil }
        return Self.fixedBackupURL(for: url)
    }

    /// Reads and validates a configuration at an arbitrary URL. This is used
    /// for the one-time external-config migration in the profile library.
    package static func readDocument(from url: URL) throws -> LegacyConfigurationDocument {
        try readableDocument(data: Data(contentsOf: url))
    }

    private func currentDataForCheckedSave(
        document: LegacyConfigurationDocument,
        expectedPrimaryFingerprint: String?
    ) throws -> Data? {
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard exists else {
            guard expectedPrimaryFingerprint == nil else {
                throw LegacyConfigurationError.externalChange(try writeConflict(document))
            }
            return nil
        }

        do {
            let current = try Data(contentsOf: url)
            guard Self.digest(current) == expectedPrimaryFingerprint else {
                throw LegacyConfigurationError.externalChange(try writeConflict(document))
            }
            return current
        } catch let error as LegacyConfigurationError {
            throw error
        } catch {
            // An unreadable primary is itself an external change from any
            // usable snapshot. Preserve the candidate in a conflict copy;
            // never overwrite the unreadable primary during a checked save.
            throw LegacyConfigurationError.externalChange(try writeConflict(document))
        }
    }

    private func writeBackup(_ currentData: Data) throws {
        guard let backupURL = backupURLForCurrentStrategy() else { return }
        try ensureParentDirectory()
        try backupWriter.write(currentData, to: backupURL)
    }

    private func backupURLForCurrentStrategy() -> URL? {
        switch backupStrategy {
        case .none: nil
        case .fixed: Self.fixedBackupURL(for: url)
        case .timestamped:
            url.deletingPathExtension().appendingPathExtension(
                "backup-\(Self.timestamp()).txt"
            )
        }
    }

    private func backupCandidates() -> [URL] {
        switch backupStrategy {
        case .none:
            return []
        case .fixed:
            guard let backupURL = fixedBackupURL else { return [] }
            return [backupURL]
        case .timestamped:
            let directory = url.deletingLastPathComponent()
            let stem = url.deletingPathExtension().lastPathComponent + ".backup-"
            let values = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            return values.filter {
                $0.lastPathComponent.hasPrefix(stem) &&
                    $0.pathExtension.lowercased() == "txt"
            }.sorted { lhs, rhs in
                let leftDate = try? lhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                let rightDate = try? rhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                if leftDate != rightDate {
                    return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
                }
                return lhs.lastPathComponent > rhs.lastPathComponent
            }
        }
    }

    private func ensureParentDirectory() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func writeConflict(_ document: LegacyConfigurationDocument) throws -> URL {
        let conflict = url.deletingPathExtension().appendingPathExtension(
            "conflict-\(Self.timestamp()).txt"
        )
        try ensureParentDirectory()
        try conflictWriter.write(Data(document.serialized().utf8), to: conflict)
        return conflict
    }

    private static func readableDocument(data: Data) throws -> LegacyConfigurationDocument {
        guard let source = String(data: data, encoding: .utf8) else {
            throw LegacyConfigurationError.notUTF8
        }
        let document = try LegacyConfigurationDocument(source: source)
        _ = try LegacyConfigurationProjection(document: document)
        return document
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fixedBackupURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("backup.txt")
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }
}
