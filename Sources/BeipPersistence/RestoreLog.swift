import Foundation

public struct RestoreLogRecord: Sendable, Equatable {
    public enum Kind: UInt8, Sendable { case received = 0, sent = 1, start = 2, receivedGMCP = 4 }
    public var kind: Kind
    public var windowsFileTime: UInt64
    public var payload: Data
}

public enum RestoreLogCodec {
    public static func read(_ data: Data, bufferSize: Int) throws -> [[RestoreLogRecord]] {
        guard bufferSize >= 20, data.count.isMultiple(of: bufferSize) else {
            throw RestoreLogError.invalidFileSize
        }
        return try stride(from: 0, to: data.count, by: bufferSize).map { offset in
            try readBuffer(Data(data[offset..<(offset + bufferSize)]))
        }
    }

    private static func readBuffer(_ buffer: Data) throws -> [RestoreLogRecord] {
        let start = Int(readUInt32(buffer, at: 0))
        let count = Int(readUInt32(buffer, at: 4))
        let capacity = buffer.count - 8
        guard start <= capacity, count <= capacity else { throw RestoreLogError.corruptBuffer }
        let ring = Data(buffer.dropFirst(8))
        var logical = Data()
        logical.reserveCapacity(count)
        for index in 0..<count { logical.append(ring[(start + index) % capacity]) }

        var records: [RestoreLogRecord] = []
        var cursor = 0
        while cursor + 12 <= logical.count {
            guard let kind = RestoreLogRecord.Kind(rawValue: logical[cursor]) else {
                throw RestoreLogError.unknownRecord(logical[cursor])
            }
            let size = Int(logical[cursor + 1]) | Int(logical[cursor + 2]) << 8 | Int(logical[cursor + 3]) << 16
            let timestamp = readUInt64(logical, at: cursor + 4)
            cursor += 12
            guard cursor + size <= logical.count else { throw RestoreLogError.corruptRecord }
            records.append(.init(kind: kind, windowsFileTime: timestamp, payload: Data(logical[cursor..<(cursor + size)])))
            cursor += size
        }
        return records
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << UInt32(8 * $1) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(data[offset + $1]) << UInt64(8 * $1) }
    }
}

public enum RestoreLogError: LocalizedError {
    case invalidFileSize, corruptBuffer, corruptRecord, unknownRecord(UInt8)
    public var errorDescription: String? {
        switch self {
        case .invalidFileSize: "Restore.dat size is not a multiple of its configured buffer size."
        case .corruptBuffer: "Restore.dat contains an invalid ring-buffer header."
        case .corruptRecord: "Restore.dat contains a truncated record."
        case let .unknownRecord(type): "Restore.dat contains unknown record type \(type)."
        }
    }
}

