import Foundation

public struct RestoreLogRecord: Sendable, Equatable {
    public enum Kind: UInt8, Sendable { case received = 0, sent = 1, start = 2, receivedGMCP = 4 }
    public var kind: Kind
    public var windowsFileTime: UInt64
    public var payload: Data

    public init(kind: Kind, windowsFileTime: UInt64, payload: Data) {
        self.kind = kind
        self.windowsFileTime = windowsFileTime
        self.payload = payload
    }
}

public enum RestoreLogCodec {
    /// Encodes one fixed-size ring buffer for each log. Records that cannot fit in a
    /// buffer are omitted, matching the Windows client's restore-log writer.
    public static func write(_ logs: [[RestoreLogRecord]], bufferSize: Int) throws -> Data {
        guard bufferSize >= 20 else { throw RestoreLogError.invalidFileSize }
        var result = Data()
        result.reserveCapacity(logs.count * bufferSize)
        for records in logs {
            result.append(try writeBuffer(records, bufferSize: bufferSize))
        }
        return result
    }

    public static func read(_ data: Data, bufferSize: Int) throws -> [[RestoreLogRecord]] {
        guard bufferSize >= 20, data.count.isMultiple(of: bufferSize) else {
            throw RestoreLogError.invalidFileSize
        }
        return try stride(from: 0, to: data.count, by: bufferSize).map { offset in
            try readBuffer(Data(data[offset..<(offset + bufferSize)]))
        }
    }

    private static func writeBuffer(_ records: [RestoreLogRecord], bufferSize: Int) throws -> Data {
        let capacity = bufferSize - 8
        var ring = Data(repeating: 0, count: capacity)
        var start = 0
        var count = 0

        func byte(at logicalOffset: Int) -> UInt8 {
            ring[(start + logicalOffset) % capacity]
        }

        func readRecordSize(at logicalOffset: Int) throws -> Int {
            guard logicalOffset + 12 <= count else { throw RestoreLogError.corruptBuffer }
            let payloadSize = Int(byte(at: logicalOffset + 1))
                | Int(byte(at: logicalOffset + 2)) << 8
                | Int(byte(at: logicalOffset + 3)) << 16
            let total = 12 + payloadSize
            guard total <= count else { throw RestoreLogError.corruptBuffer }
            return total
        }

        func append(_ data: Data) {
            var index = (start + count) % capacity
            for value in data {
                ring[index] = value
                index = (index + 1) % capacity
            }
            count += data.count
        }

        for record in records {
            guard record.payload.count <= 0xFF_FFFF else { throw RestoreLogError.recordTooLarge }
            let total = 12 + record.payload.count
            guard total <= capacity else { continue }
            while count + total > capacity {
                let oldestSize = try readRecordSize(at: 0)
                start = (start + oldestSize) % capacity
                count -= oldestSize
            }
            var encoded = Data([
                record.kind.rawValue,
                UInt8(record.payload.count & 0xFF),
                UInt8((record.payload.count >> 8) & 0xFF),
                UInt8((record.payload.count >> 16) & 0xFF),
            ])
            encoded.append(contentsOf: (0..<8).map { UInt8((record.windowsFileTime >> UInt64(8 * $0)) & 0xFF) })
            encoded.append(record.payload)
            append(encoded)
        }

        var result = Data()
        appendUInt32(UInt32(start), to: &result)
        appendUInt32(UInt32(count), to: &result)
        result.append(ring)
        return result
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

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: (0..<4).map { UInt8((value >> UInt32(8 * $0)) & 0xFF) })
    }
}

public enum RestoreLogError: LocalizedError {
    case invalidFileSize, corruptBuffer, corruptRecord, unknownRecord(UInt8), recordTooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidFileSize: "Restore.dat size is not a multiple of its configured buffer size."
        case .corruptBuffer: "Restore.dat contains an invalid ring-buffer header."
        case .corruptRecord: "Restore.dat contains a truncated record."
        case let .unknownRecord(type): "Restore.dat contains unknown record type \(type)."
        case .recordTooLarge: "Restore.dat contains a record larger than its 24-bit size field."
        }
    }
}

public enum RestoreLogStore {
    public static func load(from url: URL, bufferSize: Int) throws -> [[RestoreLogRecord]] {
        try RestoreLogCodec.read(Data(contentsOf: url), bufferSize: bufferSize)
    }

    public static func save(_ logs: [[RestoreLogRecord]], to url: URL, bufferSize: Int) throws {
        let data = try RestoreLogCodec.write(logs, bufferSize: bufferSize)
        try data.write(to: url, options: .atomic)
    }
}
