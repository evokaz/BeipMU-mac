import Compression
import Foundation

public enum GMCPDisplayColor: Sendable, Hashable, Codable {
    case rgb(RGBColor)
    case transparent

    public static func parse(_ value: String) -> Self? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "transparent" { return .transparent }
        if normalized.hasPrefix("ansi256("), normalized.hasSuffix(")"),
           let index = Int(normalized.dropFirst(8).dropLast()), (0...255).contains(index) {
            return .rgb(ansi256(index))
        }
        let hex = normalized.hasPrefix("#") ? String(normalized.dropFirst()) : normalized
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return nil }
        return .rgb(.init(
            red: UInt8((number >> 16) & 0xff),
            green: UInt8((number >> 8) & 0xff),
            blue: UInt8(number & 0xff)
        ))
    }

    private static func ansi256(_ index: Int) -> RGBColor {
        let base: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0),
            (0, 0, 128), (128, 0, 128), (0, 128, 128), (192, 192, 192),
            (128, 128, 128), (255, 0, 0), (0, 255, 0), (255, 255, 0),
            (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
        ]
        if index < 16 {
            let value = base[index]
            return .init(red: value.0, green: value.1, blue: value.2)
        }
        if index < 232 {
            let value = index - 16
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            return .init(
                red: levels[value / 36],
                green: levels[(value / 6) % 6],
                blue: levels[value % 6]
            )
        }
        let gray = UInt8(8 + (index - 232) * 10)
        return .init(red: gray, green: gray, blue: gray)
    }
}

public struct GMCPBarStyle: Sendable, Hashable, Codable {
    public var fill: GMCPDisplayColor?
    public var empty: GMCPDisplayColor?
    public var outline: GMCPDisplayColor?

    public init(fill: GMCPDisplayColor? = nil, empty: GMCPDisplayColor? = nil, outline: GMCPDisplayColor? = nil) {
        self.fill = fill
        self.empty = empty
        self.outline = outline
    }
}

public struct GMCPRange: Sendable, Hashable, Codable {
    public var value: Double
    public var lower: Double
    public var upper: Double
    public var style: GMCPBarStyle

    public init(value: Double = 0, lower: Double = 0, upper: Double = 0, style: GMCPBarStyle = .init()) {
        self.value = value
        self.lower = lower
        self.upper = upper
        self.style = style
    }
}

public struct GMCPProgress: Sendable, Hashable, Codable {
    public var label: String
    public var value: Double
    public var style: GMCPBarStyle

    public init(label: String = "", value: Double = 0, style: GMCPBarStyle = .init()) {
        self.label = label
        self.value = value
        self.style = style
    }
}

public enum GMCPStatisticValue: Sendable, Hashable, Codable {
    case integer(Int)
    case string(String)
    case range(GMCPRange)
    case progress(GMCPProgress)
}

public struct GMCPStatistic: Sendable, Hashable, Codable {
    public enum Alignment: String, Sendable, Hashable, Codable { case left, center, right }

    public var key: String
    public var prefixLength: Int
    public var value: GMCPStatisticValue
    public var nameAlignment: Alignment
    public var nameColor: GMCPDisplayColor?
    public var valueColor: GMCPDisplayColor?

    public init(
        key: String,
        prefixLength: Int = 0,
        value: GMCPStatisticValue = .string(""),
        nameAlignment: Alignment = .left,
        nameColor: GMCPDisplayColor? = nil,
        valueColor: GMCPDisplayColor? = nil
    ) {
        self.key = key
        self.prefixLength = min(max(0, prefixLength), key.count)
        self.value = value
        self.nameAlignment = nameAlignment
        self.nameColor = nameColor
        self.valueColor = valueColor
    }

    public var name: String { String(key.dropFirst(prefixLength)) }
}

public struct GMCPStatisticsPane: Sendable, Hashable, Codable {
    public var title: String
    public var background: GMCPDisplayColor?
    public var values: [String: GMCPStatistic]

    public init(title: String, background: GMCPDisplayColor? = nil, values: [String: GMCPStatistic] = [:]) {
        self.title = title
        self.background = background
        self.values = values
    }

    public var orderedValues: [GMCPStatistic] {
        values.sorted { $0.key < $1.key }.map(\.value)
    }
}

public struct GMCPAvatar: Sendable, Hashable, Codable {
    public var id: String
    public var imageURL: URL?
    public var clickURL: URL?
    public var hoverText: String

    public init(id: String, imageURL: URL? = nil, clickURL: URL? = nil, hoverText: String = "") {
        self.id = id
        self.imageURL = imageURL
        self.clickURL = clickURL
        self.hoverText = hoverText
    }
}

public struct GMCPRoomInfo: Sendable, Hashable, Codable {
    public struct Coordinates: Sendable, Hashable, Codable {
        public var floor: Int
        public var x: Int
        public var y: Int

        public init(floor: Int, x: Int, y: Int) {
            self.floor = floor
            self.x = x
            self.y = y
        }
    }

    public struct Size: Sendable, Hashable, Codable {
        public var x: Int
        public var y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    public struct Exit: Sendable, Hashable, Codable {
        public var id: String
        public var destination: String
        public var direction: String
        public var name: String
        public var description: String

        public init(id: String, destination: String, direction: String, name: String, description: String) {
            self.id = id
            self.destination = destination
            self.direction = direction
            self.name = name
            self.description = description
        }
    }

    public var id: String
    public var area: String
    public var name: String
    public var description: String
    public var coordinates: Coordinates
    public var size: Size
    public var exits: [Exit]

    public init(
        id: String,
        area: String,
        name: String,
        description: String = "",
        coordinates: Coordinates,
        size: Size,
        exits: [Exit] = []
    ) {
        self.id = id
        self.area = area
        self.name = name
        self.description = description
        self.coordinates = coordinates
        self.size = size
        self.exits = exits
    }
}

public struct GMCPTileMap: Sendable, Hashable, Codable {
    public enum Encoding: String, Sendable, Hashable, Codable {
        case hex4
        case hex8
        case base64_8
        case zbase64_8

        init?(_ value: String) {
            switch value.lowercased() {
            case "hex_4", "hex4": self = .hex4
            case "hex_8", "hex8": self = .hex8
            case "base64_8", "base64": self = .base64_8
            case "zbase64_8", "zbase64": self = .zbase64_8
            default: return nil
            }
        }
    }

    public var name: String
    public var tileURL: URL?
    public var tileWidth: Int
    public var tileHeight: Int
    public var columns: Int
    public var rows: Int
    public var encoding: Encoding
    public var tiles: [UInt8]

    public init(
        name: String,
        tileURL: URL? = nil,
        tileWidth: Int = 16,
        tileHeight: Int = 16,
        columns: Int = 1,
        rows: Int = 1,
        encoding: Encoding = .hex4,
        tiles: [UInt8] = [0]
    ) {
        self.name = name
        self.tileURL = tileURL
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.columns = columns
        self.rows = rows
        self.encoding = encoding
        self.tiles = tiles
    }
}

public enum AdvancedGMCPEvent: Sendable, Hashable {
    case statisticsPane(String)
    case tileMap(String)
    case avatarsChanged([String])
    case roomInfo(GMCPRoomInfo)
    case transmit(GMCPMessage)
}

public struct AdvancedGMCPState: Sendable {
    public private(set) var statisticsPanes: [String: GMCPStatisticsPane] = [:]
    public private(set) var avatars: [String: GMCPAvatar] = [:]
    public private(set) var tileMaps: [String: GMCPTileMap] = [:]
    public private(set) var currentRoom: GMCPRoomInfo?
    private var requestedAvatarIDs: Set<String> = []
    private var pendingAvatarID: String?
    private var pendingImageURL: URL?

    public init() {}

    public mutating func reset() {
        self = .init()
    }

    public mutating func consume(_ message: GMCPMessage) throws -> [AdvancedGMCPEvent] {
        switch message.package.lowercased() {
        case "beip.stats": return try consumeStatistics(message.payload)
        case "beip.ids": return try consumeAvatars(message.payload)
        case "beip.line.id": return try consumeLineID(message.payload)
        case "beip.line.image-url":
            pendingImageURL = URL(string: try jsonString(message.payload))
            return []
        case "beip.tilemap.info": return try consumeTileMapInfo(message.payload)
        case "beip.tilemap.data": return try consumeTileMapData(message.payload)
        case "room.info":
            let room = try JSONDecoder().decode(GMCPRoomInfo.self, from: normalizedRoomData(message.payload))
            currentRoom = room
            return [.roomInfo(room)]
        default: return []
        }
    }

    public mutating func decorate(_ source: RenderedLine) -> RenderedLine {
        var line = source
        defer { pendingAvatarID = nil; pendingImageURL = nil }
        if let id = pendingAvatarID, let avatar = avatars[id], let url = avatar.imageURL {
            line.assets.append(.init(
                kind: .avatar,
                source: url,
                altText: avatar.hoverText.isEmpty ? "Avatar \(id)" : avatar.hoverText,
                characterOffset: 0
            ))
        }
        if let url = pendingImageURL {
            line.assets.append(.init(kind: .avatar, source: url, altText: "Server avatar", characterOffset: 0))
        }
        return line
    }

    private mutating func consumeStatistics(_ payload: String) throws -> [AdvancedGMCPEvent] {
        let root = try jsonObject(payload)
        var events: [AdvancedGMCPEvent] = []
        for (title, rawPane) in root {
            guard let update = rawPane as? [String: Any] else { continue }
            var pane = statisticsPanes[title] ?? .init(title: title)
            if let background = update["background-color"] as? String {
                pane.background = GMCPDisplayColor.parse(background)
            }
            if update.keys.contains("values") {
                if update["values"] is NSNull {
                    pane.values.removeAll()
                } else if let values = update["values"] as? [String: Any] {
                    for (key, rawValue) in values {
                        if rawValue is NSNull {
                            pane.values.removeValue(forKey: key)
                        } else if let patch = rawValue as? [String: Any] {
                            if patch.isEmpty {
                                pane.values.removeValue(forKey: key)
                            } else {
                                var statistic = pane.values[key] ?? .init(key: key)
                                applyStatistic(patch, to: &statistic)
                                pane.values[key] = statistic
                            }
                        }
                    }
                }
            }
            statisticsPanes[title] = pane
            events.append(.statisticsPane(title))
        }
        return events
    }

    private func applyStatistic(_ patch: [String: Any], to statistic: inout GMCPStatistic) {
        if let prefix = number(patch["prefix-length"]) {
            statistic.prefixLength = min(max(0, Int(prefix)), statistic.key.count)
        }
        if let alignment = (patch["name-alignment"] as? String).flatMap(GMCPStatistic.Alignment.init(rawValue:)) {
            statistic.nameAlignment = alignment
        }
        if let value = patch["color"] as? String, let color = GMCPDisplayColor.parse(value) {
            statistic.nameColor = color
            statistic.valueColor = color
        }
        if let value = patch["name-color"] as? String { statistic.nameColor = GMCPDisplayColor.parse(value) }
        if let value = patch["value-color"] as? String { statistic.valueColor = GMCPDisplayColor.parse(value) }

        // JSON object order is intentionally irrelevant here. Prefer the same
        // precedence used by the documented examples: progress, range, string, int.
        if let value = number(patch["int"]) { statistic.value = .integer(Int(value)) }
        if let value = patch["string"] as? String { statistic.value = .string(value) }
        if let value = patch["range"] as? [String: Any] {
            var range = if case let .range(existing) = statistic.value { existing } else { GMCPRange() }
            applyBar(value, value: &range.value, style: &range.style)
            if let lower = number(value["min"]) { range.lower = lower }
            if let upper = number(value["max"]) { range.upper = upper }
            statistic.value = .range(range)
        }
        if let value = patch["progress"] as? [String: Any] {
            var progress = if case let .progress(existing) = statistic.value { existing } else { GMCPProgress() }
            applyBar(value, value: &progress.value, style: &progress.style)
            if let label = value["label"] as? String { progress.label = label }
            statistic.value = .progress(progress)
        }
    }

    private func applyBar(_ patch: [String: Any], value: inout Double, style: inout GMCPBarStyle) {
        if let number = number(patch["value"]) { value = number }
        if let color = (patch["fill-color"] ?? patch["bar-fill"]) as? String { style.fill = GMCPDisplayColor.parse(color) }
        if let color = patch["empty-color"] as? String { style.empty = GMCPDisplayColor.parse(color) }
        if let color = patch["outline-color"] as? String { style.outline = GMCPDisplayColor.parse(color) }
    }

    private mutating func consumeAvatars(_ payload: String) throws -> [AdvancedGMCPEvent] {
        let root = try jsonObject(payload)
        var changed: [String] = []
        for (id, raw) in root {
            guard let patch = raw as? [String: Any] else { continue }
            var avatar = avatars[id] ?? .init(id: id)
            if let value = patch["url"] as? String { avatar.imageURL = URL(string: value) }
            if let value = patch["click-url"] as? String { avatar.clickURL = URL(string: value) }
            if let value = patch["hover-text"] as? String { avatar.hoverText = value }
            avatars[id] = avatar
            changed.append(id)
        }
        return changed.isEmpty ? [] : [.avatarsChanged(changed.sorted())]
    }

    private mutating func consumeLineID(_ payload: String) throws -> [AdvancedGMCPEvent] {
        let id = try jsonString(payload)
        pendingAvatarID = id
        guard avatars[id] == nil, requestedAvatarIDs.insert(id).inserted else { return [] }
        avatars[id] = .init(id: id)
        let encoded = try JSONEncoder().encode(id)
        return [.transmit(.init(package: "beip.id.request", payload: String(decoding: encoded, as: UTF8.self)))]
    }

    private mutating func consumeTileMapInfo(_ payload: String) throws -> [AdvancedGMCPEvent] {
        let root = try jsonObject(payload)
        var events: [AdvancedGMCPEvent] = []
        for (name, raw) in root {
            guard let patch = raw as? [String: Any] else { continue }
            var map = tileMaps[name] ?? .init(name: name)
            if let value = patch["tile-url"] as? String { map.tileURL = URL(string: value) }
            if let value = patch["tile-size"] as? String {
                let size = try parseSize(value, field: "tile-size")
                guard size.0 <= 256, size.1 <= 256 else { throw AdvancedGMCPError.sizeTooLarge("tile-size") }
                map.tileWidth = size.0
                map.tileHeight = size.1
            }
            if let value = patch["map-size"] as? String {
                let size = try parseSize(value, field: "map-size")
                guard size.0 <= 256, size.1 <= 256 else { throw AdvancedGMCPError.sizeTooLarge("map-size") }
                map.columns = size.0
                map.rows = size.1
                map.tiles = Array(repeating: 0, count: size.0 * size.1)
            }
            if let value = (patch["encoding"] ?? patch["enc"]) as? String {
                guard let encoding = GMCPTileMap.Encoding(value) else { throw AdvancedGMCPError.unknownTileEncoding(value) }
                map.encoding = encoding
            }
            tileMaps[name] = map
            events.append(.tileMap(name))
        }
        return events
    }

    private mutating func consumeTileMapData(_ payload: String) throws -> [AdvancedGMCPEvent] {
        let root = try jsonObject(payload)
        var events: [AdvancedGMCPEvent] = []
        for (name, raw) in root {
            guard let encoded = raw as? String else { continue }
            guard var map = tileMaps[name] else { throw AdvancedGMCPError.missingTileMap(name) }
            map.tiles = try decodeTiles(encoded, encoding: map.encoding, expectedCount: map.columns * map.rows)
            tileMaps[name] = map
            events.append(.tileMap(name))
        }
        return events
    }

    private func decodeTiles(_ encoded: String, encoding: GMCPTileMap.Encoding, expectedCount: Int) throws -> [UInt8] {
        let values: [UInt8]
        switch encoding {
        case .hex4:
            guard encoded.count == expectedCount else { throw AdvancedGMCPError.invalidTileCount(expected: expectedCount, actual: encoded.count) }
            values = try encoded.map {
                guard let value = UInt8(String($0), radix: 16) else { throw AdvancedGMCPError.invalidTileData }
                return value
            }
        case .hex8:
            guard encoded.count == expectedCount * 2 else { throw AdvancedGMCPError.invalidTileCount(expected: expectedCount * 2, actual: encoded.count) }
            values = try stride(from: 0, to: encoded.count, by: 2).map { offset in
                let lower = encoded.index(encoded.startIndex, offsetBy: offset)
                let upper = encoded.index(lower, offsetBy: 2)
                guard let value = UInt8(encoded[lower..<upper], radix: 16) else { throw AdvancedGMCPError.invalidTileData }
                return value
            }
        case .base64_8:
            guard let data = Data(base64Encoded: encoded) else { throw AdvancedGMCPError.invalidTileData }
            values = Array(data)
        case .zbase64_8:
            guard let compressed = Data(base64Encoded: encoded) else { throw AdvancedGMCPError.invalidTileData }
            var output = [UInt8](repeating: 0, count: expectedCount)
            let decoded = compressed.withUnsafeBytes { source in
                output.withUnsafeMutableBytes { destination in
                    compression_decode_buffer(
                        destination.bindMemory(to: UInt8.self).baseAddress!, expectedCount,
                        source.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            guard decoded == expectedCount else { throw AdvancedGMCPError.invalidCompressedTileData }
            values = output
        }
        guard values.count == expectedCount else {
            throw AdvancedGMCPError.invalidTileCount(expected: expectedCount, actual: values.count)
        }
        return values
    }

    private func jsonObject(_ payload: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw AdvancedGMCPError.expectedObject
        }
        return value
    }

    private func jsonString(_ payload: String) throws -> String {
        guard let value = try JSONSerialization.jsonObject(with: Data(payload.utf8), options: [.fragmentsAllowed]) as? String else {
            throw AdvancedGMCPError.expectedString
        }
        return value
    }

    private func parseSize(_ value: String, field: String) throws -> (Int, Int) {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
            throw AdvancedGMCPError.invalidSize(field)
        }
        return (width, height)
    }

    private func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private func normalizedRoomData(_ payload: String) throws -> Data {
        let root = try jsonObject(payload)
        let coordinates = root["coords"] as? [String: Any] ?? [:]
        let size = root["size"] as? [String: Any] ?? [:]
        let exits = (root["exits"] as? [[String: Any]] ?? []).map { exit in
            [
                "id": exit["id"] as? String ?? "",
                "destination": exit["destination"] as? String ?? "",
                "direction": exit["direction"] as? String ?? "",
                "name": exit["name"] as? String ?? "",
                "description": exit["description"] as? String ?? "",
            ]
        }
        let normalized: [String: Any] = [
            "id": root["id"] as? String ?? "",
            "area": root["area"] as? String ?? "",
            "name": root["name"] as? String ?? "",
            "description": root["description"] as? String ?? "",
            "coordinates": [
                "floor": number(coordinates["floor"]).map(Int.init) ?? 0,
                "x": number(coordinates["x"]).map(Int.init) ?? 0,
                "y": number(coordinates["y"]).map(Int.init) ?? 0,
            ],
            "size": [
                "x": number(size["x"]).map(Int.init) ?? 0,
                "y": number(size["y"]).map(Int.init) ?? 0,
            ],
            "exits": exits,
        ]
        return try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys])
    }
}

public enum AdvancedGMCPError: LocalizedError, Equatable {
    case expectedObject
    case expectedString
    case invalidSize(String)
    case sizeTooLarge(String)
    case unknownTileEncoding(String)
    case missingTileMap(String)
    case invalidTileCount(expected: Int, actual: Int)
    case invalidTileData
    case invalidCompressedTileData

    public var errorDescription: String? {
        switch self {
        case .expectedObject: "Expected a JSON object."
        case .expectedString: "Expected a JSON string."
        case let .invalidSize(field): "Invalid \(field); expected two positive comma-separated integers."
        case let .sizeTooLarge(field): "\(field) exceeds the 256 × 256 compatibility limit."
        case let .unknownTileEncoding(value): "Unknown tile-map encoding: \(value)."
        case let .missingTileMap(name): "Received data for unknown tile map: \(name)."
        case let .invalidTileCount(expected, actual): "Expected \(expected) tile values but received \(actual)."
        case .invalidTileData: "Tile-map data is malformed."
        case .invalidCompressedTileData: "Compressed tile-map data could not be expanded to the configured map size."
        }
    }
}
