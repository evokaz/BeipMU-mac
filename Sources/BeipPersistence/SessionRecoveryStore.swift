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

public enum SessionRecoveryStoreError: LocalizedError, Equatable {
    case invalidCapacity
    case invalidFileHeader
    case sessionNotFound(UUID)
    case recordTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidCapacity: "Recovery.dat has an invalid capacity."
        case .invalidFileHeader: "Recovery.dat has an invalid file header."
        case .sessionNotFound(let id): "Recovery session " + id.uuidString + " was not found."
        case .recordTooLarge: "The recovery record is too large for the configured capacity."
        }
    }
}

/// Durable local recovery journal.
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
    public static let defaultCapacity = 10 * 1_024 * 1_024

    private static let magic = Data("BeipMU Recovery 1\n".utf8)
    private static let frameHeaderSize = 8
    private static let minimumCapacity = 512

    public let url: URL
    public let capacity: Int
    public let perSessionCapacity: Int

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
        perSessionCapacity: Int? = nil
    ) throws {
        guard capacity >= Self.minimumCapacity else { throw SessionRecoveryStoreError.invalidCapacity }
        self.url = url
        self.capacity = capacity
        self.perSessionCapacity = max(
            256,
            min(perSessionCapacity ?? capacity / 2, max(256, capacity - Self.magic.count - 32))
        )
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
        try openForAppend()
    }

    deinit { try? fileHandle?.close() }

    public var sessionCount: Int { sessionsByID.count }

    public var sessions: [SessionRecoverySession] {
        sessionsByID.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func session(id: UUID) -> SessionRecoverySession? { sessionsByID[id] }

    @discardableResult
    public func beginSession(
        id: UUID = UUID(),
        serverID: UUID? = nil,
        characterID: UUID? = nil,
        serverName: String,
        characterName: String? = nil,
        at date: Date = Date()
    ) throws -> UUID {
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
    }

    public func remove(sessionID: UUID) throws {
        guard sessionsByID[sessionID] != nil else { return }
        try append(.remove(sessionID))
        sessionsByID.removeValue(forKey: sessionID)
        try compactIfNeeded()
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
    }

    /// Removes every recovery session and durably replaces the currently open
    /// journal with an empty, valid journal header.
    public func reset() throws {
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
        let currentSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if currentSize >= capacity || estimated > capacity || currentSize > capacity / 2 {
            try compact()
        }
    }

    private func sessionsForCompaction() -> [SessionRecoverySession] {
        var live = sessions
        while !live.isEmpty {
            let data = (try? Self.encodeCompacted(live, encoder: encoder))
                ?? Data(repeating: 0, count: capacity + 1)
            if data.count <= capacity { return live }

            // Keep the newest sessions first. If one session is itself too
            // large, discard its oldest record and try again before evicting a
            // whole unrelated session.
            if let index = live.indices.min(by: {
                if live[$0].updatedAt != live[$1].updatedAt {
                    return live[$0].updatedAt < live[$1].updatedAt
                }
                return live[$0].id.uuidString < live[$1].id.uuidString
            }) {
                if live[index].records.count > 1 {
                    live[index].records.removeFirst()
                    continue
                }
                live.remove(at: index)
            }
        }
        return []
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
        (try? Self.encodeCompacted([session], encoder: encoder).count) ?? Int.max
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
