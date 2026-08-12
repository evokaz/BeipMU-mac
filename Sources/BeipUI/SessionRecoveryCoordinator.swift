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
        guard let store else {
            sessionID = nil
            resumesSessionOnReconnect = false
            return
        }
        if shouldResume,
           let existingSessionID,
           store.session(id: existingSessionID) != nil {
            sessionID = existingSessionID
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
        if let store, let sessionID, sessionID != snapshotID {
            try? store.remove(sessionID: sessionID)
        }
        sessionID = store?.session(id: snapshotID) == nil ? nil : snapshotID
        resumesSessionOnReconnect = sessionID != nil
    }

    func append(_ event: SessionRecoveryEvent, at timestamp: Date = Date()) {
        guard !isReplaying,
              let store,
              let sessionID else { return }
        try? store.append(event, to: sessionID, at: timestamp)
    }

    func discard() {
        if let store, let sessionID { try? store.remove(sessionID: sessionID) }
        sessionID = nil
        resumesSessionOnReconnect = false
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
