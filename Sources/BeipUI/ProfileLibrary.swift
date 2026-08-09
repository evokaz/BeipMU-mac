import AppKit
import BeipPersistence
import Foundation

@MainActor
final class ProfileLibrary {
    private(set) var workspace: LegacyConfigurationWorkspace
    private(set) var workspaceRevision: UInt64 = 0
    private let persistentConfigURL: URL?
    private let sidecarURL: URL
    private(set) var storageDirectory: URL?
    private var changeObservers: [UUID: () -> Void] = [:]

    convenience init() {
        let context = RuntimeStateContext.current
        try! self.init(
            storageDirectory: context.configurationDirectory,
            allowsExternalConfigurationMigration: context.configuration == .release
        )
    }

    init(
        storageDirectory: URL,
        allowsExternalConfigurationMigration: Bool = false
    ) throws {
        self.storageDirectory = storageDirectory
        let configURL = storageDirectory.appendingPathComponent("Config.txt")
        persistentConfigURL = configURL
        sidecarURL = storageDirectory.appendingPathComponent("Config.mac.json")
        workspace = try .empty(isDirty: false)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        if !restore(from: configURL) {
            if restore(from: backupURL(for: configURL), sourceURL: configURL) {
                try persistCurrentWorkspace(backingUpCurrent: false)
            } else if allowsExternalConfigurationMigration,
                      let sidecar = try? MacSidecarStore.load(from: sidecarURL),
                      let path = sidecar.selectedConfigPath,
                      restore(from: URL(fileURLWithPath: path)) {
                // One-time migration for Release builds that remembered an
                // external Config.txt as their live database. Debug and
                // UI-test contexts never enter this branch.
                try persistCurrentWorkspace()
                clearLegacySelectedPath()
            } else {
                try persistCurrentWorkspace()
            }
        }
    }

    init(workspace: LegacyConfigurationWorkspace) {
        self.workspace = workspace
        persistentConfigURL = nil
        sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.ProfileLibrary.\(UUID().uuidString).json")
        storageDirectory = nil
    }

    var displayName: String { "BeipMU Configuration" }

    struct WorkspaceEditorSnapshot {
        let workspace: LegacyConfigurationWorkspace
        let revision: UInt64
    }

    enum WorkspaceCommitError: LocalizedError {
        case staleWorkspace

        var errorDescription: String? {
            switch self {
            case .staleWorkspace:
                "The configuration changed elsewhere. Reload it before applying these edits."
            }
        }
    }

    func beginWorkspaceEditor() -> WorkspaceEditorSnapshot {
        .init(workspace: workspace, revision: workspaceRevision)
    }

    /// Commits a staged workspace only if the live library is still the
    /// revision from which the editor started. This keeps Apply atomic and
    /// prevents a stale macro window from overwriting another editor/session.
    func commit(
        _ candidate: LegacyConfigurationWorkspace,
        expectedRevision: UInt64
    ) throws {
        guard expectedRevision == workspaceRevision else {
            throw WorkspaceCommitError.staleWorkspace
        }
        if let persistentConfigURL,
           let currentData = try? Data(contentsOf: persistentConfigURL),
           let currentSource = String(data: currentData, encoding: .utf8),
           currentSource != workspace.document.serialized() {
            throw WorkspaceCommitError.staleWorkspace
        }
        var saved = candidate
        if let persistentConfigURL {
            let rendered = try saved.renderedDocument()
            try writePersistent(rendered, to: persistentConfigURL)
            saved.acceptSavedDocument(rendered, at: persistentConfigURL)
        }
        workspace = saved
        workspaceRevision &+= 1
        notifyChangeObservers()
    }

    var keyEquivalents: [String: String] {
        (try? MacSidecarStore.load(from: sidecarURL).keyEquivalents) ?? [:]
    }

    var openTabGroups: [MacConfigurationSidecar.OpenTabGroup]? {
        try? MacSidecarStore.load(from: sidecarURL).openTabGroups
    }

    func saveKeyEquivalents(_ values: [String: String]) throws {
        var sidecar = try MacSidecarStore.load(from: sidecarURL)
        sidecar.keyEquivalents = values
        try FileManager.default.createDirectory(
            at: sidecarURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try MacSidecarStore.save(sidecar, to: sidecarURL)
    }

    func saveOpenTabGroups(_ groups: [MacConfigurationSidecar.OpenTabGroup]) throws {
        var sidecar = try MacSidecarStore.load(from: sidecarURL)
        sidecar.openTabGroups = groups
        try FileManager.default.createDirectory(
            at: sidecarURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try MacSidecarStore.save(sidecar, to: sidecarURL)
    }

    func clearOpenTabGroups() throws {
        var sidecar = try MacSidecarStore.load(from: sidecarURL)
        sidecar.openTabGroups = nil
        try FileManager.default.createDirectory(
            at: sidecarURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try MacSidecarStore.save(sidecar, to: sidecarURL)
    }

    func newConfiguration() throws {
        workspace = try .empty(isDirty: persistentConfigURL == nil)
        if persistentConfigURL != nil { try persistCurrentWorkspace() }
        workspaceRevision &+= 1
        notifyChangeObservers()
    }

    /// Imports a plaintext backup and atomically replaces the app-owned
    /// configuration. Parsing and projection happen before the live state is
    /// touched, so an invalid backup cannot damage the current configuration.
    func importConfiguration(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let source = String(data: data, encoding: .utf8) else {
            throw LegacyConfigurationError.notUTF8
        }
        let document = try LegacyConfigurationDocument(source: source)
        let imported = try LegacyConfigurationWorkspace(document: document)
        if let persistentConfigURL {
            try writePersistent(document, to: persistentConfigURL)
            workspace = try LegacyConfigurationWorkspace(
                document: document,
                sourceURL: persistentConfigURL,
                isDirty: false
            )
        } else {
            workspace = imported
        }
        workspaceRevision &+= 1
        notifyChangeObservers()
    }

    func mutate(_ body: (inout LegacyConfigurationWorkspace) throws -> Void) throws {
        var candidate = workspace
        try body(&candidate)
        if let persistentConfigURL {
            let rendered = try candidate.renderedDocument()
            try writePersistent(rendered, to: persistentConfigURL)
            candidate.acceptSavedDocument(rendered, at: persistentConfigURL)
        }
        workspace = candidate
        workspaceRevision &+= 1
        notifyChangeObservers()
    }

    func save() throws {
        try persistCurrentWorkspace()
        notifyChangeObservers()
    }

    func export(to url: URL) throws {
        let rendered = try workspace.renderedDocument()
        try Self.write(rendered, to: url)
    }

    private func restore(from url: URL, sourceURL: URL? = nil) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let source = String(data: data, encoding: .utf8),
              let document = try? LegacyConfigurationDocument(source: source),
              let restored = try? LegacyConfigurationWorkspace(
                document: document,
                sourceURL: sourceURL ?? url
              ) else { return false }
        workspace = restored
        return true
    }

    private func persistCurrentWorkspace(backingUpCurrent: Bool = true) throws {
        guard let persistentConfigURL else { return }
        let rendered = try workspace.renderedDocument()
        if backingUpCurrent {
            try writePersistent(rendered, to: persistentConfigURL)
        } else {
            try Self.write(rendered, to: persistentConfigURL)
        }
        workspace.acceptSavedDocument(rendered, at: persistentConfigURL)
    }

    private func clearLegacySelectedPath() {
        guard var sidecar = try? MacSidecarStore.load(from: sidecarURL) else { return }
        sidecar.selectedConfigPath = nil
        try? MacSidecarStore.save(sidecar, to: sidecarURL)
    }

    private static func write(_ document: LegacyConfigurationDocument, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(document.serialized().utf8).write(to: url, options: .atomic)
    }

    private func writePersistent(_ document: LegacyConfigurationDocument, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path),
           let current = try? Data(contentsOf: url) {
            try current.write(to: backupURL(for: url), options: .atomic)
        }
        try Self.write(document, to: url)
    }

    private func backupURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("backup.txt")
    }

    @discardableResult
    func addChangeObserver(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        changeObservers[id] = handler
        return id
    }

    func removeChangeObserver(_ id: UUID?) {
        guard let id else { return }
        changeObservers[id] = nil
    }

    private func notifyChangeObservers() {
        for observer in changeObservers.values {
            observer()
        }
    }
}
