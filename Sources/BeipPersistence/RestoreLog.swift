import BeipCore
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
    public struct RepairResult: Sendable, Equatable {
        public var logs: [[RestoreLogRecord]]
        public var repairedData: Data
        public var repairedBufferIndices: [Int]
    }

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

    /// Salvages the valid prefix of each corrupt ring buffer and rebuilds only
    /// affected buffers. This mirrors the Windows client's clear/truncate
    /// recovery behavior while leaving healthy buffers byte-for-byte intact.
    public static func repair(_ data: Data, bufferSize: Int) throws -> RepairResult {
        guard bufferSize >= 20, data.count.isMultiple(of: bufferSize) else {
            throw RestoreLogError.invalidFileSize
        }
        var logs: [[RestoreLogRecord]] = []
        var repairedData = Data()
        var repairedIndices: [Int] = []
        for (index, offset) in stride(from: 0, to: data.count, by: bufferSize).enumerated() {
            let buffer = Data(data[offset..<(offset + bufferSize)])
            if let records = try? readBuffer(buffer) {
                logs.append(records)
                repairedData.append(buffer)
                continue
            }
            let records = salvageBuffer(buffer)
            logs.append(records)
            repairedData.append(try writeBuffer(records, bufferSize: bufferSize))
            repairedIndices.append(index)
        }
        return .init(logs: logs, repairedData: repairedData, repairedBufferIndices: repairedIndices)
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
        guard cursor == logical.count else { throw RestoreLogError.corruptRecord }
        return records
    }

    private static func salvageBuffer(_ buffer: Data) -> [RestoreLogRecord] {
        let capacity = buffer.count - 8
        let start = Int(readUInt32(buffer, at: 0))
        let count = Int(readUInt32(buffer, at: 4))
        guard start < capacity, count <= capacity else { return [] }
        let ring = Data(buffer.dropFirst(8))
        var logical = Data()
        for index in 0..<count { logical.append(ring[(start + index) % capacity]) }

        var records: [RestoreLogRecord] = []
        var cursor = 0
        while cursor + 12 <= logical.count {
            guard let kind = RestoreLogRecord.Kind(rawValue: logical[cursor]) else { break }
            let size = Int(logical[cursor + 1]) | Int(logical[cursor + 2]) << 8 | Int(logical[cursor + 3]) << 16
            let payloadStart = cursor + 12
            guard payloadStart + size <= logical.count else { break }
            records.append(.init(
                kind: kind,
                windowsFileTime: readUInt64(logical, at: cursor + 4),
                payload: Data(logical[payloadStart..<(payloadStart + size)])
            ))
            cursor = payloadStart + size
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
    public struct BufferInspection: Sendable, Equatable {
        public var index: Int
        public var recordCount: Int
        public var usedBytes: Int
        public var wasRepaired: Bool

        public init(index: Int, recordCount: Int, usedBytes: Int, wasRepaired: Bool) {
            self.index = index
            self.recordCount = recordCount
            self.usedBytes = usedBytes
            self.wasRepaired = wasRepaired
        }
    }

    public struct Inspection: Sendable, Equatable {
        public var bufferSize: Int
        public var buffers: [BufferInspection]

        public init(bufferSize: Int, buffers: [BufferInspection]) {
            self.bufferSize = bufferSize
            self.buffers = buffers
        }
    }

    public static func load(from url: URL, bufferSize: Int) throws -> [[RestoreLogRecord]] {
        try RestoreLogCodec.read(Data(contentsOf: url), bufferSize: bufferSize)
    }

    public static func save(_ logs: [[RestoreLogRecord]], to url: URL, bufferSize: Int) throws {
        let data = try RestoreLogCodec.write(logs, bufferSize: bufferSize)
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    public static func loadRepairing(from url: URL, bufferSize: Int) throws -> RestoreLogCodec.RepairResult {
        let result = try RestoreLogCodec.repair(Data(contentsOf: url), bufferSize: bufferSize)
        if !result.repairedBufferIndices.isEmpty {
            try result.repairedData.write(to: url, options: .atomic)
        }
        return result
    }

    /// Runs the same salvage-and-atomic-rewrite path used for restore playback,
    /// then returns debugger-friendly usage information for every ring buffer.
    @discardableResult
    public static func inspectRepairing(from url: URL, bufferSize: Int) throws -> Inspection {
        let result = try loadRepairing(from: url, bufferSize: bufferSize)
        let repaired = Set(result.repairedBufferIndices)
        return Inspection(
            bufferSize: bufferSize,
            buffers: result.logs.enumerated().map { index, records in
                BufferInspection(
                    index: index,
                    recordCount: records.count,
                    usedBytes: records.reduce(0) { $0 + 12 + $1.payload.count },
                    wasRepaired: repaired.contains(index)
                )
            }
        )
    }
}

public struct RestorePlaybackResult: Sendable, Equatable {
    public var events: [SessionEvent]
    public var sentHistory: [String]

    public init(events: [SessionEvent] = [], sentHistory: [String] = []) {
        self.events = events
        self.sentHistory = sentHistory
    }
}

/// Replays the post-Telnet line records stored by the Windows client through a
/// normal session processor. Start records reset parser state; protocol replies
/// produced while replaying are intentionally discarded.
public enum RestoreLogPlayback {
    public static func replay(
        _ records: [RestoreLogRecord],
        through processor: inout some ByteStreamProcessor,
        localEcho: Bool = true,
        decodeSent: (Data) -> String = { String(decoding: $0, as: UTF8.self) }
    ) -> RestorePlaybackResult {
        var result = RestorePlaybackResult()
        for record in records {
            let timestamp = date(fromWindowsFileTime: record.windowsFileTime)
            switch record.kind {
            case .start:
                processor.reset()
            case .received:
                // Restore.dat stores complete lines after Telnet framing, without
                // their newline terminator. Supplying one flushes the shared line
                // processor while retaining ANSI/Pueblo state across records.
                for output in processor.consume(record.payload + Data([10])) {
                    append(output, timestamp: timestamp, to: &result.events)
                }
            case .receivedGMCP:
                let value = String(decoding: record.payload, as: UTF8.self)
                let split = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                result.events.append(.gmcp(.init(
                    package: split.first.map(String.init) ?? "",
                    payload: split.count > 1 ? String(split[1]) : ""
                )))
            case .sent:
                let text = decodeSent(record.payload)
                result.sentHistory.append(text)
                if localEcho {
                    result.events.append(.renderedLine(.init(
                        text: text,
                        timestamp: timestamp,
                        source: .replay
                    )))
                }
            }
        }
        return result
    }

    private static func append(_ output: ProtocolOutput, timestamp: Date, to events: inout [SessionEvent]) {
        switch output {
        case let .line(line):
            var line = line
            line.timestamp = timestamp
            line.source = .replay
            events.append(.renderedLine(line))
        case let .prompt(line):
            var line = line
            line.timestamp = timestamp
            line.source = .replay
            events.append(.prompt(line))
        case let .gmcp(message): events.append(.gmcp(message))
        case let .mcp(message): events.append(.mcp(message))
        case let .diagnostic(message): events.append(.log(message))
        case .transmit, .encoding, .requestNAWS: break
        }
    }

    private static func date(fromWindowsFileTime value: UInt64) -> Date {
        let secondsSince1601 = Double(value) / 10_000_000
        return Date(timeIntervalSince1970: secondsSince1601 - 11_644_473_600)
    }
}
