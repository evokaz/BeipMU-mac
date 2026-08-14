import BeipCore
import Foundation

/// A value captured while a session is live. Recovery deliberately stores the
/// final rendered value rather than the input that produced it. This makes
/// replay a passive presentation operation: no trigger, script, sound, media,
/// or network behavior is needed to reconstruct the user's screen.
public enum SessionRecoveryEvent: Sendable, Codable, Equatable {
    case renderedLine(RenderedLine)
    case prompt(RenderedLine)
    case spawnOutput(title: String, tabGroup: String?, line: RenderedLine)
    case sentInput(String)
    case inputHistory([String])
    case gmcp(GMCPMessage)
}

public struct SessionRecoveryRecord: Sendable, Codable, Equatable {
    public var timestamp: Date
    public var event: SessionRecoveryEvent

    public init(timestamp: Date = Date(), event: SessionRecoveryEvent) {
        self.timestamp = timestamp
        self.event = event
    }
}

public struct SessionRecoverySession: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public var serverID: UUID?
    public var characterID: UUID?
    public var serverName: String
    public var characterName: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var records: [SessionRecoveryRecord]

    public init(
        id: UUID = UUID(),
        serverID: UUID? = nil,
        characterID: UUID? = nil,
        serverName: String,
        characterName: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        records: [SessionRecoveryRecord] = []
    ) {
        self.id = id
        self.serverID = serverID
        self.characterID = characterID
        self.serverName = serverName
        self.characterName = characterName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.records = records
    }

    public var events: [SessionRecoveryRecord] { records }
}

public struct SessionRecoveryStatistics: Sendable, Equatable {
    public var bufferCount: Int
    public var fileSize: Int

    public init(bufferCount: Int, fileSize: Int) {
        self.bufferCount = bufferCount
        self.fileSize = fileSize
    }
}

public enum SessionRecoveryStoreError: LocalizedError, Equatable {
    case invalidCapacity
    case invalidFileHeader
    case sessionNotFound(UUID)
    case recordTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidCapacity: "Recovery.dat has an invalid Restore Log capacity."
        case .invalidFileHeader: "Recovery.dat has an invalid file header."
        case .sessionNotFound(let id): "Restore Log buffer " + id.uuidString + " was not found."
        case .recordTooLarge: "The Restore Log record is too large for the configured capacity."
        }
    }
}

/// Durable local Restore Logs journal.
///
/// The on-disk stream is intentionally simple:
///
///     magic | little-endian frame length | checksum | JSON frame
///
/// A process crash can leave only the final frame incomplete. Loading stops at
/// that frame, keeps the valid prefix, and atomically rewrites the prefix
/// before accepting new appends. A compacted file contains one begin frame and
/// the live records for each session, so old append history cannot defeat the
/// configured size bound.
public final class SessionRecoveryStore: @unchecked Sendable {
    public static let defaultCapacity = 256 * 1_024

    private static let magic = Data("BeipMU Recovery 1\n".utf8)
    private static let frameHeaderSize = 8
    private static let minimumCapacity = 512

    public let url: URL
    /// Compatibility name. Capacity is now enforced independently for every
    /// saved-character buffer, rather than as one allowance shared by a file.
    private var storedCapacity: Int
    private var storedPerSessionCapacity: Int
    private var storedIsEnabled: Bool

    public var capacity: Int { executionQueue.sync { storedCapacity } }
    public var perSessionCapacity: Int { executionQueue.sync { storedPerSessionCapacity } }
    public var perCharacterCapacity: Int { perSessionCapacity }
    public var isEnabled: Bool { executionQueue.sync { storedIsEnabled } }

    private enum Frame: Codable {
        case begin(SessionRecoverySession)
        case event(UUID, SessionRecoveryRecord)
        case remove(UUID)

        private enum CodingKeys: String, CodingKey { case kind, session, id, record }
        private enum Kind: String, Codable { case begin, event, remove }

        private var kind: Kind {
            switch self {
            case .begin: .begin
            case .event: .event
            case .remove: .remove
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            switch self {
            case .begin(let session):
                try container.encode(session, forKey: .session)
            case .event(let id, let record):
                try container.encode(id, forKey: .id)
                try container.encode(record, forKey: .record)
            case .remove(let id):
                try container.encode(id, forKey: .id)
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .begin: self = .begin(try container.decode(SessionRecoverySession.self, forKey: .session))
            case .event:
                self = .event(
                    try container.decode(UUID.self, forKey: .id),
                    try container.decode(SessionRecoveryRecord.self, forKey: .record)
                )
            case .remove: self = .remove(try container.decode(UUID.self, forKey: .id))
            }
        }
    }

    private var sessionsByID: [UUID: SessionRecoverySession] = [:]
    private var fileHandle: FileHandle?
    private var statisticsObservers: [UUID: @Sendable (SessionRecoveryStatistics) -> Void] = [:]
    private let executionQueue = DispatchQueue(label: "com.beipmu.session-recovery")
    private let pendingLock = NSLock()
    private var pendingEvents: [(SessionRecoveryEvent, UUID, Date)] = []
    private var drainScheduled = false
    private var recordFrameSizes: [UUID: [Int]] = [:]
    private var recordByteCounts: [UUID: Int] = [:]
    private var metadataByteCounts: [UUID: Int] = [:]
    private var physicalByteCount = 0
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public convenience init(
        url: URL,
        maxBytes: Int = SessionRecoveryStore.defaultCapacity,
        perSessionBytes: Int? = nil
    ) throws {
        try self.init(
            url: url,
            capacity: maxBytes,
            perSessionCapacity: perSessionBytes
        )
    }

    public init(
        url: URL,
        capacity: Int = SessionRecoveryStore.defaultCapacity,
        perSessionCapacity: Int? = nil,
        enabled: Bool = true
    ) throws {
        let requestedCapacity = perSessionCapacity ?? capacity
        guard requestedCapacity >= Self.minimumCapacity else { throw SessionRecoveryStoreError.invalidCapacity }
        self.url = url
        storedCapacity = capacity
        storedPerSessionCapacity = requestedCapacity
        storedIsEnabled = enabled
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try loadExistingFile()
        rebuildByteCaches()
        normalizeCharacterBuffers()
        rebuildByteCaches()
        for id in Array(sessionsByID.keys) { trimSession(id) }
        if !enabled { try resetFileWithoutNotification() }
        try openForAppend()
        if enabled { try compactIfNeeded() }
    }

    deinit { try? fileHandle?.close() }

    public var sessionCount: Int { executionQueue.sync { sessionsByID.count } }

    public var statistics: SessionRecoveryStatistics {
        executionQueue.sync { currentStatistics }
    }

    public var sessions: [SessionRecoverySession] {
        executionQueue.sync { sortedSessions() }
    }

    public func session(id: UUID) -> SessionRecoverySession? { executionQueue.sync { sessionsByID[id] } }

    /// Finds the persistent buffer belonging to a saved character. Stable IDs
    /// win; names are a migration fallback for journals written before IDs
    /// were available.
    public func buffer(
        serverID: UUID?,
        characterID: UUID?,
        serverName: String,
        characterName: String
    ) -> SessionRecoverySession? {
        executionQueue.sync {
            findBuffer(serverID: serverID, characterID: characterID, serverName: serverName, characterName: characterName)
        }
    }

    public func addStatisticsObserver(
        _ observer: @escaping @Sendable (SessionRecoveryStatistics) -> Void
    ) -> UUID {
        executionQueue.sync {
            let id = UUID()
            statisticsObservers[id] = observer
            observer(currentStatistics)
            return id
        }
    }

    public func removeStatisticsObserver(_ id: UUID?) {
        guard let id else { return }
        executionQueue.sync { _ = statisticsObservers.removeValue(forKey: id) }
    }

    public func setEnabled(_ enabled: Bool) throws {
        try executionQueue.sync {
            guard storedIsEnabled != enabled else {
                notifyStatisticsChanged()
                return
            }
            storedIsEnabled = enabled
            if !enabled { try resetFileWithoutNotification() }
            notifyStatisticsChanged()
        }
    }

    public func setPerCharacterCapacity(_ bytes: Int) throws {
        guard bytes >= Self.minimumCapacity else { throw SessionRecoveryStoreError.invalidCapacity }
        try executionQueue.sync {
            guard bytes != storedPerSessionCapacity else {
                notifyStatisticsChanged()
                return
            }
            storedPerSessionCapacity = bytes
            storedCapacity = bytes
            rebuildByteCaches()
            for id in Array(sessionsByID.keys) { trimSession(id) }
            try compactLocked()
        }
    }

    public func updateIdentity(
        characterID: UUID,
        serverID: UUID,
        serverName: String,
        characterName: String
    ) throws {
        try executionQueue.sync {
            guard var session = sortedSessions().first(where: { $0.characterID == characterID }) else { return }
            session.serverID = serverID
            session.characterID = characterID
            session.serverName = serverName
            session.characterName = characterName
            sessionsByID[session.id] = session
            rebuildByteCaches()
            try compactLocked()
        }
    }

    public func updateIdentity(
        sessionID: UUID,
        characterID: UUID,
        serverID: UUID,
        serverName: String,
        characterName: String
    ) throws {
        try executionQueue.sync {
            try updateSessionIdentity(sessionID, serverID: serverID, characterID: characterID,
                                      serverName: serverName, characterName: characterName, at: Date())
        }
    }

    public func removeBuffer(characterID: UUID) throws {
        try executionQueue.sync {
            let ids = sortedSessions().filter { $0.characterID == characterID }.map(\.id)
            for id in ids { try removeLocked(sessionID: id) }
        }
    }

    public func removeBuffer(
        serverID: UUID?,
        characterID: UUID?,
        serverName: String,
        characterName: String
    ) throws {
        try executionQueue.sync {
            guard let match = findBuffer(serverID: serverID, characterID: characterID,
                                         serverName: serverName, characterName: characterName) else { return }
            try removeLocked(sessionID: match.id)
        }
    }

    @discardableResult
    public func beginSession(
        id: UUID = UUID(),
        serverID: UUID? = nil,
        characterID: UUID? = nil,
        serverName: String,
        characterName: String? = nil,
        at date: Date = Date()
    ) throws -> UUID {
        try executionQueue.sync {
            guard storedIsEnabled else { return id }
            if let characterName,
               let existing = findBuffer(serverID: serverID, characterID: characterID,
                                         serverName: serverName, characterName: characterName) {
                try updateSessionIdentity(existing.id, serverID: serverID, characterID: characterID,
                                          serverName: serverName, characterName: characterName, at: date)
                return existing.id
            }
            let session = SessionRecoverySession(id: id, serverID: serverID, characterID: characterID,
                                                  serverName: serverName, characterName: characterName,
                                                  createdAt: date, updatedAt: date)
            let data = try Self.frameData(.begin(session), encoder: encoder)
            try write(data, synchronize: true)
            sessionsByID[id] = session
            recordFrameSizes[id] = []
            recordByteCounts[id] = 0
            metadataByteCounts[id] = data.count
            try compactIfNeeded()
            notifyStatisticsChanged()
            return id
        }
    }

    /// Enqueues a live recovery event without blocking the caller on encoding
    /// or filesystem I/O. Events are drained on the journal's serial executor.
    public func enqueue(
        _ event: SessionRecoveryEvent,
        to sessionID: UUID,
        at date: Date = Date()
    ) {
        pendingLock.lock()
        pendingEvents.append((event, sessionID, date))
        let shouldSchedule = !drainScheduled
        drainScheduled = true
        pendingLock.unlock()
        if shouldSchedule {
            executionQueue.async { [self] in drainPendingEvents() }
        }
    }

    public func append(
        _ event: SessionRecoveryEvent,
        to sessionID: UUID,
        at date: Date = Date()
    ) throws {
        try executionQueue.sync {
            try appendEvent(event, to: sessionID, at: date, synchronize: true)
            try compactIfNeeded()
            notifyStatisticsChanged()
        }
    }

    public func remove(sessionID: UUID) throws {
        try executionQueue.sync { try removeLocked(sessionID: sessionID) }
    }

    public func discard(_ sessionID: UUID) throws { try remove(sessionID: sessionID) }

    /// Rewrites the live state even when the journal has not reached its limit.
    public func compact() throws {
        try executionQueue.sync { try compactLocked() }
    }

    private func compactLocked() throws {
        let live = sessionsForCompaction()
        let frames = try Self.encodeCompacted(live, encoder: encoder)
        try fileHandle?.synchronize()
        try fileHandle?.close()
        fileHandle = nil
        try replaceDurably(with: frames)
        sessionsByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        physicalByteCount = frames.count
        rebuildByteCaches()
        try openForAppend()
        notifyStatisticsChanged()
    }

    /// Removes every recovery session and durably replaces the currently open
    /// journal with an empty, valid journal header.
    public func reset() throws {
        try executionQueue.sync {
            try resetFileWithoutNotification()
            notifyStatisticsChanged()
        }
    }

    private func resetFileWithoutNotification() throws {
        try fileHandle?.synchronize()
        try fileHandle?.close()
        fileHandle = nil
        try replaceDurably(with: Self.magic)
        sessionsByID.removeAll(keepingCapacity: false)
        recordFrameSizes.removeAll(keepingCapacity: false)
        recordByteCounts.removeAll(keepingCapacity: false)
        metadataByteCounts.removeAll(keepingCapacity: false)
        physicalByteCount = Self.magic.count
        try openForAppend()
    }

    /// Waits for all earlier enqueued events, then synchronizes the journal.
    public func flush() throws {
        try executionQueue.sync { try fileHandle?.synchronize() }
    }

    private func loadExistingFile() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try replaceDurably(with: Self.magic)
            physicalByteCount = Self.magic.count
            return
        }
        let data = try Data(contentsOf: url)
        guard data.count >= Self.magic.count,
              data.prefix(Self.magic.count) == Self.magic else {
            try replaceDurably(with: Self.magic)
            physicalByteCount = Self.magic.count
            return
        }

        var offset = Self.magic.count
        var validEnd = offset
        while offset + Self.frameHeaderSize <= data.count {
            let length = Int(Self.readUInt32(data, at: offset))
            let checksum = Self.readUInt32(data, at: offset + 4)
            offset += Self.frameHeaderSize
            guard length >= 0, offset + length <= data.count else { break }
            let payload = Data(data[offset..<(offset + length)])
            guard Self.checksum(payload) == checksum,
                  let frame = try? decoder.decode(Frame.self, from: payload) else { break }
            apply(frame)
            offset += length
            validEnd = offset
        }

        if validEnd != data.count {
            try replaceDurably(with: Data(data[..<validEnd]))
        }
        physicalByteCount = validEnd
    }

    private func openForAppend() throws {
        try fileHandle?.close()
        fileHandle = try FileHandle(forWritingTo: url)
        try fileHandle?.seekToEnd()
    }

    private func write(_ data: Data, synchronize: Bool) throws {
        if fileHandle == nil { try openForAppend() }
        try fileHandle?.write(contentsOf: data)
        physicalByteCount += data.count
        if synchronize { try fileHandle?.synchronize() }
    }

    private func apply(_ frame: Frame) {
        switch frame {
        case .begin(let session):
            sessionsByID[session.id] = session
        case .event(let id, let record):
            guard var session = sessionsByID[id] else { return }
            session.records.append(record)
            session.updatedAt = max(session.updatedAt, record.timestamp)
            sessionsByID[id] = session
        case .remove(let id): sessionsByID.removeValue(forKey: id)
        }
    }

    private func compactIfNeeded() throws {
        let estimated = compactedByteCount
        let currentSize = physicalByteCount
        let aggregateBound = compactedAggregateBound
        if currentSize > aggregateBound || currentSize > max(estimated * 2, Self.magic.count) {
            try compactLocked()
        }
    }

    private func sessionsForCompaction() -> [SessionRecoverySession] {
        sortedSessions()
    }

    private static func encodeCompacted(
        _ sessions: [SessionRecoverySession],
        encoder: JSONEncoder
    ) throws -> Data {
        var data = magic
        for session in sessions {
            var metadata = session
            metadata.records = []
            data.append(try frameData(.begin(metadata), encoder: encoder))
            for record in session.records {
                data.append(try frameData(.event(session.id, record), encoder: encoder))
            }
        }
        return data
    }

    private static func frameData(_ frame: Frame, encoder: JSONEncoder) throws -> Data {
        let payload = try encoder.encode(frame)
        guard payload.count <= Int(UInt32.max) else { throw SessionRecoveryStoreError.recordTooLarge }
        var result = Data()
        result.append(contentsOf: uint32(UInt32(payload.count)))
        result.append(contentsOf: uint32(checksum(payload)))
        result.append(payload)
        return result
    }

    private var compactedAggregateBound: Int {
        var bound = Self.magic.count
        for session in sessionsByID.values {
            bound += metadataByteCounts[session.id] ?? 0
            bound += storedPerSessionCapacity
        }
        return bound
    }

    private func updateSessionIdentity(
        _ id: UUID,
        serverID: UUID?,
        characterID: UUID?,
        serverName: String,
        characterName: String?,
        at date: Date
    ) throws {
        guard var session = sessionsByID[id] else { return }
        session.serverID = serverID
        session.characterID = characterID
        session.serverName = serverName
        session.characterName = characterName
        session.updatedAt = max(session.updatedAt, date)
        sessionsByID[id] = session
        normalizeCharacterBuffers()
        rebuildByteCaches()
        try compactLocked()
    }

    private func normalizeCharacterBuffers() {
        var normalized: [String: SessionRecoverySession] = [:]
        for session in sessionsByID.values {
            let key: String
            if let characterID = session.characterID {
                key = "id:" + characterID.uuidString
            } else if let characterName = session.characterName {
                key = "name:" + session.serverName.lowercased() + "/" + characterName.lowercased()
            } else {
                // Characterless legacy entries remain distinct long enough
                // for the application configuration reconciler to remove
                // them. New UI sessions never create these entries.
                key = "legacy:" + session.id.uuidString
            }
            guard var existing = normalized[key] else {
                normalized[key] = session
                continue
            }
            let newest = existing.updatedAt >= session.updatedAt ? existing : session
            existing.serverID = newest.serverID
            existing.characterID = newest.characterID
            existing.serverName = newest.serverName
            existing.characterName = newest.characterName
            existing.updatedAt = max(existing.updatedAt, session.updatedAt)
            existing.records = (existing.records + session.records).sorted { $0.timestamp < $1.timestamp }
            normalized[key] = existing
        }
        sessionsByID = Dictionary(uniqueKeysWithValues: normalized.values.map { ($0.id, $0) })
    }

    private func notifyStatisticsChanged() {
        let value = currentStatistics
        statisticsObservers.values.forEach { $0(value) }
    }

    private var currentStatistics: SessionRecoveryStatistics {
        SessionRecoveryStatistics(bufferCount: sessionsByID.count, fileSize: physicalByteCount)
    }

    private func sortedSessions() -> [SessionRecoverySession] {
        sessionsByID.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func findBuffer(
        serverID: UUID?, characterID: UUID?, serverName: String, characterName: String
    ) -> SessionRecoverySession? {
        let values = sortedSessions()
        if let characterID, let match = values.first(where: { $0.characterID == characterID }) {
            return match
        }
        return values.first {
            ($0.serverID == serverID || $0.serverName.caseInsensitiveCompare(serverName) == .orderedSame)
                && $0.characterName?.caseInsensitiveCompare(characterName) == .orderedSame
        }
    }

    private func appendEvent(
        _ event: SessionRecoveryEvent, to sessionID: UUID, at date: Date, synchronize: Bool
    ) throws {
        let previousSession = sessionsByID[sessionID]
        let previousSizes = recordFrameSizes[sessionID]
        let previousBytes = recordByteCounts[sessionID]
        guard let data = try stageEvent(event, to: sessionID, at: date) else { return }
        do {
            try write(data, synchronize: synchronize)
        } catch {
            sessionsByID[sessionID] = previousSession
            recordFrameSizes[sessionID] = previousSizes
            recordByteCounts[sessionID] = previousBytes
            throw error
        }
    }

    private func stageEvent(
        _ event: SessionRecoveryEvent, to sessionID: UUID, at date: Date
    ) throws -> Data? {
        guard storedIsEnabled, var session = sessionsByID[sessionID] else {
            throw SessionRecoveryStoreError.sessionNotFound(sessionID)
        }
        let record = SessionRecoveryRecord(timestamp: date, event: event)
        let data = try Self.frameData(.event(sessionID, record), encoder: encoder)
        if data.count > storedPerSessionCapacity { return nil }
        session.records.append(record)
        session.updatedAt = date
        sessionsByID[sessionID] = session
        recordFrameSizes[sessionID, default: []].append(data.count)
        recordByteCounts[sessionID, default: 0] += data.count
        trimSession(sessionID)
        return data
    }

    private func trimSession(_ id: UUID) {
        guard var session = sessionsByID[id] else { return }
        var sizes = recordFrameSizes[id] ?? []
        var bytes = recordByteCounts[id] ?? 0
        while session.records.count > 1 && bytes > storedPerSessionCapacity {
            session.records.removeFirst()
            if !sizes.isEmpty { bytes -= sizes.removeFirst() }
        }
        if bytes > storedPerSessionCapacity {
            session.records.removeAll(keepingCapacity: true)
            sizes.removeAll(keepingCapacity: true)
            bytes = 0
        }
        sessionsByID[id] = session
        recordFrameSizes[id] = sizes
        recordByteCounts[id] = bytes
    }

    private func rebuildByteCaches() {
        recordFrameSizes.removeAll(keepingCapacity: true)
        recordByteCounts.removeAll(keepingCapacity: true)
        metadataByteCounts.removeAll(keepingCapacity: true)
        for session in sessionsByID.values {
            var metadata = session
            metadata.records = []
            metadataByteCounts[session.id] = (try? Self.frameData(.begin(metadata), encoder: encoder).count) ?? 0
            let sizes = session.records.map {
                (try? Self.frameData(.event(session.id, $0), encoder: encoder).count) ?? Int.max
            }
            recordFrameSizes[session.id] = sizes
            recordByteCounts[session.id] = sizes.reduce(0) { partial, value in
                partial > Int.max - value ? Int.max : partial + value
            }
        }
    }

    private var compactedByteCount: Int {
        Self.magic.count + sessionsByID.keys.reduce(0) {
            $0 + (metadataByteCounts[$1] ?? 0) + (recordByteCounts[$1] ?? 0)
        }
    }

    private func removeLocked(sessionID: UUID) throws {
        guard sessionsByID[sessionID] != nil else { return }
        let data = try Self.frameData(.remove(sessionID), encoder: encoder)
        try write(data, synchronize: true)
        sessionsByID.removeValue(forKey: sessionID)
        recordFrameSizes.removeValue(forKey: sessionID)
        recordByteCounts.removeValue(forKey: sessionID)
        metadataByteCounts.removeValue(forKey: sessionID)
        try compactIfNeeded()
        notifyStatisticsChanged()
    }

    private func drainPendingEvents() {
        while true {
            pendingLock.lock()
            if pendingEvents.isEmpty {
                drainScheduled = false
                pendingLock.unlock()
                return
            }
            let batch = pendingEvents
            pendingEvents.removeAll(keepingCapacity: true)
            pendingLock.unlock()

            var frames = Data()
            for (event, id, date) in batch {
                if let data = try? stageEvent(event, to: id, at: date) { frames.append(data) }
            }
            if !frames.isEmpty {
                do {
                    try write(frames, synchronize: true)
                } catch {
                    // The in-memory state already reflects the batch. An
                    // atomic rewrite is the safest recovery from append I/O
                    // failure and keeps later barriers deterministic.
                    try? compactLocked()
                }
            }
            try? compactIfNeeded()
            notifyStatisticsChanged()
        }
    }

    private func replaceDurably(with data: Data) throws {
        try AtomicFileWriter.live.write(data, to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    private static func checksum(_ data: Data) -> UInt32 {
        // FNV-1a is sufficient here: it detects torn/partial frames and keeps
        // the format dependency-free.
        data.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
    }

    private static func uint32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ]
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << UInt32($1 * 8) }
    }
}
