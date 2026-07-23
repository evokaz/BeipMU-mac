import AppKit
import BeipPersistence
import Foundation

@MainActor
final class ProfileLibrary {
    enum LibraryError: LocalizedError {
        case noSaveLocation

        var errorDescription: String? {
            switch self {
            case .noSaveLocation: "Choose a location for Config.txt before saving."
            }
        }
    }

    private(set) var workspace: LegacyConfigurationWorkspace
    private var store: LegacyConfigurationStore?
    private let sidecarURL: URL
    var onChange: (() -> Void)?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BeipMU", isDirectory: true)
        sidecarURL = support.appendingPathComponent("Config.mac.json")
        workspace = try! .empty(isDirty: false)

        guard let sidecar = try? MacSidecarStore.load(from: sidecarURL),
              let path = sidecar.selectedConfigPath else { return }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let source = String(data: data, encoding: .utf8),
              let document = try? LegacyConfigurationDocument(source: source),
              let restored = try? LegacyConfigurationWorkspace(document: document, sourceURL: url) else { return }
        workspace = restored
        store = LegacyConfigurationStore(url: url)
    }

    init(workspace: LegacyConfigurationWorkspace) {
        self.workspace = workspace
        sidecarURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU.ProfileLibrary.\(UUID().uuidString).json")
    }

    var displayName: String {
        workspace.sourceURL?.lastPathComponent ?? "Untitled Config"
    }

    var keyEquivalents: [String: String] {
        (try? MacSidecarStore.load(from: sidecarURL).keyEquivalents) ?? [:]
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

    func newConfiguration() throws {
        workspace = try .empty()
        store = nil
        persistSelectedURL(nil)
        onChange?()
    }

    func open(_ url: URL) async throws {
        let nextStore = LegacyConfigurationStore(url: url)
        let recovery = try await nextStore.loadRecoveringFromBackup()
        workspace = try .init(
            document: recovery.document,
            sourceURL: url,
            recoveredFrom: recovery.recoveredFrom
        )
        store = nextStore
        persistSelectedURL(url)
        onChange?()
    }

    func mutate(_ body: (inout LegacyConfigurationWorkspace) throws -> Void) throws {
        try body(&workspace)
        onChange?()
    }

    func save() async throws {
        guard let url = workspace.sourceURL, let store else { throw LibraryError.noSaveLocation }
        let rendered = try workspace.renderedDocument()
        try await store.save(rendered)
        workspace.acceptSavedDocument(rendered, at: url)
        onChange?()
    }

    func save(as url: URL) async throws {
        let nextStore = LegacyConfigurationStore(url: url)
        let rendered = try workspace.renderedDocument()
        try await nextStore.save(rendered)
        workspace.acceptSavedDocument(rendered, at: url)
        store = nextStore
        persistSelectedURL(url)
        onChange?()
    }

    func export(to url: URL) throws {
        let rendered = try workspace.renderedDocument()
        try Data(rendered.serialized().utf8).write(to: url, options: .atomic)
    }

    private func persistSelectedURL(_ url: URL?) {
        do {
            var sidecar = try MacSidecarStore.load(from: sidecarURL)
            sidecar.selectedConfigPath = url?.path
            try FileManager.default.createDirectory(
                at: sidecarURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try MacSidecarStore.save(sidecar, to: sidecarURL)
        } catch {
            NSApplication.shared.presentError(error)
        }
    }
}
