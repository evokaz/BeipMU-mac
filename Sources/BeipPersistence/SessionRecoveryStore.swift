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
    public private(set) var capacity: Int
    public private(set) var perSessionCapacity: Int
    public var perCharacterCapacity: Int { perSessionCapacity }
    public private(set) var isEnabled: Bool

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
        self.capacity = capacity
        self.perSessionCapacity = requestedCapacity
        self.isEnabled = enabled
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
        normalizeCharacterBuffers()
        if !enabled { try resetFileWithoutNotification() }
        try openForAppend()
        if enabled { try compactIfNeeded() }
    }

    deinit { try? fileHandle?.close() }

    public var sessionCount: Int { sessionsByID.count }

    public var statistics: SessionRecoveryStatistics {
        SessionRecoveryStatistics(bufferCount: sessionsByID.count, fileSize: physicalFileSize)
    }

    public var sessions: [SessionRecoverySession] {
        sessionsByID.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func session(id: UUID) -> SessionRecoverySession? { sessionsByID[id] }

    /// Finds the persistent buffer belonging to a saved character. Stable IDs
    /// win; names are a migration fallback for journals written before IDs
    /// were available.
    public func buffer(
        serverID: UUID?,
        characterID: UUID?,
        serverName: String,
        characterName: String
    ) -> SessionRecoverySession? {
        if let characterID,
           let match = sessions.first(where: { $0.characterID == characterID }) {
            return match
        }
        return sessions.first {
            ($0.serverID == serverID || $0.serverName.caseInsensitiveCompare(serverName) == .orderedSame)
                && $0.characterName?.caseInsensitiveCompare(characterName) == .orderedSame
        }
    }

    public func addStatisticsObserver(
        _ observer: @escaping @Sendable (SessionRecoveryStatistics) -> Void
    ) -> UUID {
        let id = UUID()
        statisticsObservers[id] = observer
        observer(statistics)
        return id
    }

    public func removeStatisticsObserver(_ id: UUID?) {
        guard let id else { return }
        statisticsObservers.removeValue(forKey: id)
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard isEnabled != enabled else {
            notifyStatisticsChanged()
            return
        }
        isEnabled = enabled
        if !enabled { try reset() }
        else { notifyStatisticsChanged() }
    }

    public func setPerCharacterCapacity(_ bytes: Int) throws {
        guard bytes >= Self.minimumCapacity else { throw SessionRecoveryStoreError.invalidCapacity }
        guard bytes != perSessionCapacity else {
            notifyStatisticsChanged()
            return
        }
        perSessionCapacity = bytes
        capacity = bytes
        var trimmed: [UUID: SessionRecoverySession] = [:]
        for var session in sessionsByID.values {
            trim(&session)
            trimmed[session.id] = session
        }
        sessionsByID = trimmed
        try compact()
    }

    public func updateIdentity(
        characterID: UUID,
        serverID: UUID,
        serverName: String,
        characterName: String
    ) throws {
        guard var session = sessions.first(where: { $0.characterID == characterID }) else { return }
        session.serverID = serverID
        session.characterID = characterID
        session.serverName = serverName
        session.characterName = characterName
        sessionsByID[session.id] = session
        try compact()
    }

    public func updateIdentity(
        sessionID: UUID,
        characterID: UUID,
        serverID: UUID,
        serverName: String,
        characterName: String
    ) throws {
        try updateSessionIdentity(
            sessionID,
            serverID: serverID,
            characterID: characterID,
            serverName: serverName,
            characterName: characterName,
            at: Date()
        )
    }

    public func removeBuffer(characterID: UUID) throws {
        let ids = sessions.filter { $0.characterID == characterID }.map(\.id)
        for id in ids { try remove(sessionID: id) }
    }

    public func removeBuffer(
        serverID: UUID?,
        characterID: UUID?,
        serverName: String,
        characterName: String
    ) throws {
        guard let match = buffer(
            serverID: serverID,
            characterID: characterID,
            serverName: serverName,
            characterName: characterName
        ) else { return }
        try remove(sessionID: match.id)
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
        guard isEnabled else { return id }
        if let characterName,
           let existing = buffer(
               serverID: serverID,
               characterID: characterID,
               serverName: serverName,
               characterName: characterName
           ) {
            try updateSessionIdentity(
                existing.id,
                serverID: serverID,
                characterID: characterID,
                serverName: serverName,
                characterName: characterName,
                at: date
            )
            return existing.id
        }
        let session = SessionRecoverySession(
            id: id,
            serverID: serverID,
            characterID: characterID,
            serverName: serverName,
            characterName: characterName,
            createdAt: date,
            updatedAt: date
        )
        try append(.begin(session))
        let previous = sessionsByID[id]
        sessionsByID[id] = session
        do {
            try compactIfNeeded()
        } catch {
            if let previous { sessionsByID[id] = previous }
            else { sessionsByID.removeValue(forKey: id) }
            throw error
        }
        notifyStatisticsChanged()
        return id
    }

    public func append(
        _ event: SessionRecoveryEvent,
        to sessionID: UUID,
        at date: Date = Date()
    ) throws {
        guard var session = sessionsByID[sessionID] else {
            throw SessionRecoveryStoreError.sessionNotFound(sessionID)
        }
        let record = SessionRecoveryRecord(timestamp: date, event: event)
        let previous = session
        session.records.append(record)
        session.updatedAt = date
        trim(&session)
        guard session.records.last == record else { return }
        do {
            try append(.event(sessionID, record))
        } catch {
            sessionsByID[sessionID] = previous
            throw error
        }
        sessionsByID[sessionID] = session
        try compactIfNeeded()
        notifyStatisticsChanged()
    }

    public func remove(sessionID: UUID) throws {
        guard sessionsByID[sessionID] != nil else { return }
        try append(.remove(sessionID))
        sessionsByID.removeValue(forKey: sessionID)
        try compactIfNeeded()
        notifyStatisticsChanged()
    }

    public func discard(_ sessionID: UUID) throws { try remove(sessionID: sessionID) }

    /// Rewrites the live state even when the journal has not reached its limit.
    public func compact() throws {
        let live = sessionsForCompaction()
        let frames = try Self.encodeCompacted(live, encoder: encoder)
        try fileHandle?.synchronize()
        try fileHandle?.close()
        fileHandle = nil
        try replaceDurably(with: frames)
        sessionsByID = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        try openForAppend()
        notifyStatisticsChanged()
    }

    /// Removes every recovery session and durably replaces the currently open
    /// journal with an empty, valid journal header.
    public func reset() throws {
        try resetFileWithoutNotification()
        notifyStatisticsChanged()
    }

    private func resetFileWithoutNotification() throws {
        try fileHandle?.synchronize()
        try fileHandle?.close()
        fileHandle = nil
        try replaceDurably(with: Self.magic)
        sessionsByID.removeAll(keepingCapacity: false)
        try openForAppend()
    }

    /// Synchronizes the append handle. Each append already calls this method;
    /// exposing it makes normal-quit handling explicit and testable.
    public func flush() throws { try fileHandle?.synchronize() }

    private func loadExistingFile() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try replaceDurably(with: Self.magic)
            return
        }
        let data = try Data(contentsOf: url)
        guard data.count >= Self.magic.count,
              data.prefix(Self.magic.count) == Self.magic else {
            try replaceDurably(with: Self.magic)
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
    }

    private func openForAppend() throws {
        try fileHandle?.close()
        fileHandle = try FileHandle(forWritingTo: url)
        try fileHandle?.seekToEnd()
    }

    private func append(_ frame: Frame) throws {
        let payload = try encoder.encode(frame)
        guard payload.count <= Int(UInt32.max) else { throw SessionRecoveryStoreError.recordTooLarge }
        var data = Data()
        data.append(contentsOf: Self.uint32(UInt32(payload.count)))
        data.append(contentsOf: Self.uint32(Self.checksum(payload)))
        data.append(payload)
        if fileHandle == nil { try openForAppend() }
        try fileHandle?.write(contentsOf: data)
        try fileHandle?.synchronize()
    }

    private func apply(_ frame: Frame) {
        switch frame {
        case .begin(let session): sessionsByID[session.id] = session
        case .event(let id, let record):
            guard var session = sessionsByID[id] else { return }
            session.records.append(record)
            session.updatedAt = max(session.updatedAt, record.timestamp)
            trim(&session)
            sessionsByID[id] = session
        case .remove(let id): sessionsByID.removeValue(forKey: id)
        }
    }

    private func trim(_ session: inout SessionRecoverySession) {
        while session.records.count > 1,
              encodedSize(of: session) > perSessionCapacity {
            session.records.removeFirst()
        }
        if encodedSize(of: session) > perSessionCapacity, let last = session.records.last {
            // A single oversized event cannot be made useful by retaining an
            // older event. Drop it instead of allowing one session to defeat
            // the configured bound.
            session.records.removeAll(keepingCapacity: true)
            if encodedSize(of: session) > perSessionCapacity {
                _ = last
            }
        }
    }

    private func compactIfNeeded() throws {
        let estimated = try Self.encodeCompacted(sessionsForCompaction(), encoder: encoder).count
        let currentSize = physicalFileSize
        let aggregateBound = compactedAggregateBound
        if currentSize > aggregateBound || currentSize > max(estimated * 2, Self.magic.count) {
            try compact()
        }
    }

    private func sessionsForCompaction() -> [SessionRecoverySession] {
        var live = sessions
        for index in live.indices {
            trim(&live[index])
        }
        return live
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
        var result = Data()
        result.append(contentsOf: uint32(UInt32(payload.count)))
        result.append(contentsOf: uint32(checksum(payload)))
        result.append(payload)
        return result
    }

    private func encodedSize(of session: SessionRecoverySession) -> Int {
        guard let data = try? Self.encodeCompacted([session], encoder: encoder) else { return Int.max }
        var metadata = session
        metadata.records = []
        let metadataSize = (try? Self.frameData(.begin(metadata), encoder: encoder).count) ?? 0
        return max(0, data.count - Self.magic.count - metadataSize)
    }

    private var physicalFileSize: Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    private var compactedAggregateBound: Int {
        var bound = Self.magic.count
        for session in sessionsByID.values {
            var metadata = session
            metadata.records = []
            bound += (try? Self.frameData(.begin(metadata), encoder: encoder).count) ?? 0
            bound += perSessionCapacity
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
        try compact()
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
            trim(&existing)
            normalized[key] = existing
        }
        sessionsByID = Dictionary(uniqueKeysWithValues: normalized.values.map { ($0.id, $0) })
    }

    private func notifyStatisticsChanged() {
        let value = statistics
        statisticsObservers.values.forEach { $0(value) }
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
