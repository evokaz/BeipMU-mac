import BeipPersistence
import Foundation

/// Owns the durable recovery journal handle and the small amount of lifecycle
/// state needed to distinguish a live session from a passive replay.
@MainActor
final class SessionRecoveryCoordinator {
    private let store: SessionRecoveryStore?
    private(set) var sessionID: UUID?
    private(set) var resumesSessionOnReconnect = false
    private(set) var isReplaying = false

    init(store: SessionRecoveryStore?) {
        self.store = store
    }

    func setSessionID(_ id: UUID?) {
        sessionID = id
    }

    func beginOrResume(
        shouldResume: Bool,
        serverID: UUID,
        characterID: UUID?,
        serverName: String,
        characterName: String?,
        existingSessionID: UUID?
    ) {
        guard let store, let characterID, let characterName else {
            sessionID = nil
            resumesSessionOnReconnect = false
            return
        }
        if let existing = store.buffer(
            serverID: serverID,
            characterID: characterID,
            serverName: serverName,
            characterName: characterName
        ) {
            sessionID = existing.id
            resumesSessionOnReconnect = false
            return
        }
        sessionID = try? store.beginSession(
            serverID: serverID,
            characterID: characterID,
            serverName: serverName,
            characterName: characterName
        )
        resumesSessionOnReconnect = false
    }

    func markResumeOnReconnect() {
        resumesSessionOnReconnect = sessionID != nil
    }

    func consumeResumeFlag() -> Bool {
        defer { resumesSessionOnReconnect = false }
        return resumesSessionOnReconnect
    }

    func prepareForReplay(_ snapshotID: UUID) {
        sessionID = store?.session(id: snapshotID) == nil ? nil : snapshotID
        resumesSessionOnReconnect = sessionID != nil
    }

    func append(_ event: SessionRecoveryEvent, at timestamp: Date = Date()) {
        guard !isReplaying,
              let store,
              let sessionID else { return }
        try? store.append(event, to: sessionID, at: timestamp)
    }

    /// Detaches the tab from its buffer. Persistent Restore Logs deliberately
    /// survive disconnection, tab closure, and process termination.
    func discard() {
        sessionID = nil
        resumesSessionOnReconnect = false
    }

    func snapshot(
        serverID: UUID,
        characterID: UUID,
        serverName: String,
        characterName: String
    ) -> SessionRecoverySession? {
        store?.buffer(
            serverID: serverID,
            characterID: characterID,
            serverName: serverName,
            characterName: characterName
        )
    }

    func flush() {
        try? store?.flush()
    }

    func withPassiveReplay<T>(_ body: () throws -> T) rethrows -> T {
        isReplaying = true
        defer { isReplaying = false }
        return try body()
    }
}
