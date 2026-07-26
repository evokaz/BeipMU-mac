import AppKit
import BeipPersistence
import Foundation

@MainActor
final class ProfileLibrary {
    private(set) var workspace: LegacyConfigurationWorkspace
    private let persistentConfigURL: URL?
    private let sidecarURL: URL
    var onChange: (() -> Void)?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeipMU", isDirectory: true)
        persistentConfigURL = support.appendingPathComponent("Config.txt")
        sidecarURL = support.appendingPathComponent("Config.mac.json")
        workspace = try! .empty(isDirty: false)

        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if restore(from: persistentConfigURL!) { return }
        if restore(from: backupURL(for: persistentConfigURL!), sourceURL: persistentConfigURL!) {
            try? persistCurrentWorkspace(backingUpCurrent: false)
            return
        }

        // One-time migration for builds that remembered an external Config.txt
        // as their live database. The source remains untouched.
        if let sidecar = try? MacSidecarStore.load(from: sidecarURL),
           let path = sidecar.selectedConfigPath,
           restore(from: URL(fileURLWithPath: path)) {
            try? persistCurrentWorkspace()
            clearLegacySelectedPath()
            return
        }
        try? persistCurrentWorkspace()
    }

    init(storageDirectory: URL) throws {
        persistentConfigURL = storageDirectory.appendingPathComponent("Config.txt")
        sidecarURL = storageDirectory.appendingPathComponent("Config.mac.json")
        workspace = try .empty(isDirty: false)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        if !restore(from: persistentConfigURL!) {
            if restore(from: backupURL(for: persistentConfigURL!), sourceURL: persistentConfigURL!) {
                try persistCurrentWorkspace(backingUpCurrent: false)
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
    }

    var displayName: String { "BeipMU Configuration" }

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

    func newConfiguration() throws {
        workspace = try .empty(isDirty: persistentConfigURL == nil)
        if persistentConfigURL != nil { try persistCurrentWorkspace() }
        onChange?()
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
        onChange?()
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
        onChange?()
    }

    func save() throws {
        try persistCurrentWorkspace()
        onChange?()
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
}
