import BeipCore
import Foundation

public struct Atlas: Sendable, Equatable {
    public struct Font: Sendable, Equatable {
        public var name: String
        public var size: Double
        public var attributes: [String: String]

        public init(name: String, size: Double, attributes: [String: String] = [:]) {
            self.name = name
            self.size = size
            self.attributes = attributes
        }
    }

    public struct Rect: Sendable, Equatable {
        public var x1: Double
        public var y1: Double
        public var x2: Double
        public var y2: Double

        public init(x1: Double, y1: Double, x2: Double, y2: Double) {
            self.x1 = x1
            self.y1 = y1
            self.x2 = x2
            self.y2 = y2
        }

        public init(_ value: String) {
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
            self.init(
                x1: parts.indices.contains(0) ? parts[0] : 0,
                y1: parts.indices.contains(1) ? parts[1] : 0,
                x2: parts.indices.contains(2) ? parts[2] : 0,
                y2: parts.indices.contains(3) ? parts[3] : 0
            )
        }

        public var width: Double { abs(x2 - x1) }
        public var height: Double { abs(y2 - y1) }
        public var center: Point { .init(x: (x1 + x2) / 2, y: (y1 + y2) / 2) }
        public var standardized: Rect {
            .init(x1: min(x1, x2), y1: min(y1, y2), x2: max(x1, x2), y2: max(y1, y2))
        }

        public func offsetBy(dx: Double, dy: Double) -> Rect {
            .init(x1: x1 + dx, y1: y1 + dy, x2: x2 + dx, y2: y2 + dy)
        }

        public func contains(_ point: Point) -> Bool {
            let value = standardized
            return point.x >= value.x1 && point.x <= value.x2 && point.y >= value.y1 && point.y <= value.y2
        }

        public func intersects(_ other: Rect) -> Bool {
            let lhs = standardized
            let rhs = other.standardized
            return lhs.x1 < rhs.x2 && lhs.x2 > rhs.x1 && lhs.y1 < rhs.y2 && lhs.y2 > rhs.y1
        }
    }

    public struct Point: Sendable, Equatable, Hashable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Room: Sendable, Equatable {
        public var name: String
        public var rect: Rect
        public var color: String?
        public var outlineColor: String?
        public var textAngle: Double?
        public var isUnderConstruction: Bool
        public var attributes: [String: String]

        public init(
            name: String,
            rect: Rect,
            color: String? = nil,
            outlineColor: String? = nil,
            textAngle: Double? = nil,
            isUnderConstruction: Bool = false,
            attributes: [String: String] = [:]
        ) {
            self.name = name
            self.rect = rect
            self.color = color
            self.outlineColor = outlineColor
            self.textAngle = textAngle
            self.isUnderConstruction = isUnderConstruction
            self.attributes = attributes
        }
    }

    public struct Exit: Sendable, Equatable {
        public var nameFrom: String?
        public var nameTo: String?
        public var from: String?
        public var to: String?
        public var mapFrom: String?
        public var mapTo: String?
        public var points: [Point]
        public var pointsSplit: Int?
        public var attributes: [String: String]

        public init(
            nameFrom: String? = nil,
            nameTo: String? = nil,
            from: String? = nil,
            to: String? = nil,
            mapFrom: String? = nil,
            mapTo: String? = nil,
            points: [Point] = [],
            pointsSplit: Int? = nil,
            attributes: [String: String] = [:]
        ) {
            self.nameFrom = nameFrom
            self.nameTo = nameTo
            self.from = from
            self.to = to
            self.mapFrom = mapFrom
            self.mapTo = mapTo
            self.points = points
            self.pointsSplit = pointsSplit
            self.attributes = attributes
        }
    }

    public struct Rectangle: Sendable, Equatable {
        public var rect: Rect
        public var color: String?
        public var attributes: [String: String]

        public init(rect: Rect, color: String? = nil, attributes: [String: String] = [:]) {
            self.rect = rect
            self.color = color
            self.attributes = attributes
        }
    }

    public struct Image: Sendable, Equatable {
        public var source: String
        public var rect: Rect
        public var attributes: [String: String]

        public init(source: String, rect: Rect, attributes: [String: String] = [:]) {
            self.source = source
            self.rect = rect
            self.attributes = attributes
        }
    }

    public struct Label: Sendable, Equatable {
        public var text: String
        public var rect: Rect
        public var color: String?
        public var attributes: [String: String]

        public init(text: String, rect: Rect, color: String? = nil, attributes: [String: String] = [:]) {
            self.text = text
            self.rect = rect
            self.color = color
            self.attributes = attributes
        }
    }

    public struct Palette: Sendable, Equatable {
        public var attributes: [String: String]
        public init(attributes: [String: String] = [:]) { self.attributes = attributes }
    }

    public struct UnknownElement: Sendable, Equatable {
        public var name: String
        public var attributes: [String: String]

        public init(name: String, attributes: [String: String] = [:]) {
            self.name = name
            self.attributes = attributes
        }
    }

    public enum MapElement: Sendable, Equatable {
        case room(Room)
        case exit(Exit)
        case rectangle(Rectangle)
        case image(Image)
        case label(Label)
        case unknown(UnknownElement)
    }

    public struct Map: Sendable, Equatable {
        public var name: String
        public var attributes: [String: String]
        public var elements: [MapElement]

        public init(
            name: String,
            rooms: [Room] = [],
            exits: [Exit] = [],
            rectangles: [Rectangle] = [],
            images: [Image] = [],
            labels: [Label] = [],
            attributes: [String: String] = [:],
            unknownElements: [UnknownElement] = []
        ) {
            self.name = name
            self.attributes = attributes
            elements = rectangles.map(MapElement.rectangle)
                + images.map(MapElement.image)
                + labels.map(MapElement.label)
                + rooms.map(MapElement.room)
                + exits.map(MapElement.exit)
                + unknownElements.map(MapElement.unknown)
        }

        public init(name: String, attributes: [String: String] = [:], elements: [MapElement]) {
            self.name = name
            self.attributes = attributes
            self.elements = elements
        }

        public var rooms: [Room] {
            get { elements.compactMap { if case let .room(value) = $0 { value } else { nil } } }
            set { replaceElements(of: .room, with: newValue.map(MapElement.room)) }
        }

        public var exits: [Exit] {
            get { elements.compactMap { if case let .exit(value) = $0 { value } else { nil } } }
            set { replaceElements(of: .exit, with: newValue.map(MapElement.exit)) }
        }

        public var rectangles: [Rectangle] {
            get { elements.compactMap { if case let .rectangle(value) = $0 { value } else { nil } } }
            set { replaceElements(of: .rectangle, with: newValue.map(MapElement.rectangle)) }
        }

        public var images: [Image] {
            get { elements.compactMap { if case let .image(value) = $0 { value } else { nil } } }
            set { replaceElements(of: .image, with: newValue.map(MapElement.image)) }
        }

        public var labels: [Label] {
            get { elements.compactMap { if case let .label(value) = $0 { value } else { nil } } }
            set { replaceElements(of: .label, with: newValue.map(MapElement.label)) }
        }

        public var unknownElements: [UnknownElement] {
            get { elements.compactMap { if case let .unknown(value) = $0 { value } else { nil } } }
            set { replaceElements(of: .unknown, with: newValue.map(MapElement.unknown)) }
        }

        fileprivate enum ElementKind { case room, exit, rectangle, image, label, unknown }

        private mutating func replaceElements(of kind: ElementKind, with replacements: [MapElement]) {
            let first = elements.firstIndex { $0.isKind(kind) } ?? elements.endIndex
            elements.removeAll { $0.isKind(kind) }
            elements.insert(contentsOf: replacements, at: min(first, elements.endIndex))
        }
    }

    public var version: Int
    public var roomFont: Font?
    public var exitFont: Font?
    public var labelFont: Font?
    public var maps: [Map]
    public var farExits: [Exit]
    public var palettes: [Palette]
    public var attributes: [String: String]
    public var unknownElements: [UnknownElement]

    public init(
        version: Int = 2,
        roomFont: Font? = .init(name: "Arial", size: 9),
        exitFont: Font? = .init(name: "Arial", size: 5),
        labelFont: Font? = .init(name: "Arial", size: 9),
        maps: [Map] = [.init(name: "Map")],
        farExits: [Exit] = [],
        palettes: [Palette] = [],
        attributes: [String: String] = [:],
        unknownElements: [UnknownElement] = []
    ) {
        self.version = version
        self.roomFont = roomFont
        self.exitFont = exitFont
        self.labelFont = labelFont
        self.maps = maps
        self.farExits = farExits
        self.palettes = palettes
        self.attributes = attributes
        self.unknownElements = unknownElements
    }
}

fileprivate extension Atlas.MapElement {
    func isKind(_ kind: Atlas.Map.ElementKind) -> Bool {
        switch (self, kind) {
        case (.room, .room), (.exit, .exit), (.rectangle, .rectangle),
             (.image, .image), (.label, .label), (.unknown, .unknown): true
        default: false
        }
    }
}

public struct AtlasArchive: Sendable, Equatable {
    public var atlas: Atlas
    public var resources: [String: Data]

    public init(atlas: Atlas, resources: [String: Data] = [:]) {
        self.atlas = atlas
        self.resources = resources
    }
}

public enum AtlasReader {
    public static func read(from url: URL) throws -> Atlas { try readArchive(from: url).atlas }

    public static func readArchive(from url: URL) throws -> AtlasArchive {
        let data = try Data(contentsOf: url)
        guard data.starts(with: [0x50, 0x4b]) else { return .init(atlas: try read(from: data)) }
        let entries = try archiveEntries(at: url)
        if let unsafe = entries.first(where: { !isSafeArchivePath($0) }) {
            throw AtlasError.unsafeResourcePath(unsafe)
        }
        guard let xmlEntry = entries.first(where: {
            URL(fileURLWithPath: $0).lastPathComponent.caseInsensitiveCompare("Atlas.xml") == .orderedSame
        }) else { throw AtlasError.missingAtlasXML }
        var resources: [String: Data] = [:]
        for entry in entries where entry != xmlEntry && !entry.hasSuffix("/") {
            resources[entry] = try runUnzip(arguments: ["-p", url.path, entry])
        }
        return .init(
            atlas: try read(from: runUnzip(arguments: ["-p", url.path, xmlEntry])),
            resources: resources
        )
    }

    public static func read(from data: Data) throws -> Atlas {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? AtlasError.invalidXML }
        guard delegate.sawAtlas else { throw AtlasError.invalidXML }
        return Atlas(
            version: delegate.version,
            roomFont: delegate.roomFont,
            exitFont: delegate.exitFont,
            labelFont: delegate.labelFont,
            maps: delegate.maps,
            farExits: delegate.farExits,
            palettes: delegate.palettes,
            attributes: delegate.atlasAttributes,
            unknownElements: delegate.unknownElements
        )
    }

    private static func archiveEntries(at url: URL) throws -> [String] {
        let listing = try runUnzip(arguments: ["-Z1", url.path])
        return String(decoding: listing, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        var parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        if parts.last == "" { parts.removeLast() }
        return !normalized.hasPrefix("/") && !parts.isEmpty
            && !parts.contains("..") && !parts.contains("")
    }

    fileprivate static func runUnzip(arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw AtlasError.archiveFailure(message)
        }
        return data
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var sawAtlas = false
        var version = 1
        var atlasAttributes: [String: String] = [:]
        var maps: [Atlas.Map] = []
        var roomFont: Atlas.Font?
        var exitFont: Atlas.Font?
        var labelFont: Atlas.Font?
        var palettes: [Atlas.Palette] = []
        var farExits: [Atlas.Exit] = []
        var unknownElements: [Atlas.UnknownElement] = []
        var insideFarExits = false
        var insideMap = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let tag = elementName.lowercased()
            switch tag {
            case "atlas":
                sawAtlas = true
                version = Int(attributeDict["version"] ?? "1") ?? 1
                atlasAttributes = Self.extras(attributeDict, excluding: ["version"])
            case "font_rooms": roomFont = font(attributeDict)
            case "font_exits": exitFont = font(attributeDict)
            case "font_labels": labelFont = font(attributeDict)
            case "palette": palettes.append(.init(attributes: attributeDict))
            case "map":
                insideMap = true
                maps.append(.init(
                    name: attributeDict["name"] ?? "Map",
                    attributes: Self.extras(attributeDict, excluding: ["name"]),
                    elements: []
                ))
            case "room": append(.room(.init(
                name: attributeDict["name"] ?? "",
                rect: .init(attributeDict["rect"] ?? "0,0,0,0"),
                color: attributeDict["color"],
                outlineColor: attributeDict["color_outline"],
                textAngle: attributeDict["text_angle"].flatMap(Double.init),
                isUnderConstruction: Self.boolean(attributeDict["under_construction"]),
                attributes: Self.extras(attributeDict, excluding: [
                    "name", "rect", "color", "color_outline", "text_angle", "under_construction",
                ])
            )))
            case "exit":
                let value = exit(attributeDict)
                if insideFarExits { farExits.append(value) } else { append(.exit(value)) }
            case "rectangle": append(.rectangle(.init(
                rect: .init(attributeDict["rect"] ?? "0,0,0,0"),
                color: attributeDict["color"],
                attributes: Self.extras(attributeDict, excluding: ["rect", "color"])
            )))
            case "image": append(.image(.init(
                source: attributeDict["source"] ?? attributeDict["src"] ?? attributeDict["file"] ?? "",
                rect: .init(attributeDict["rect"] ?? "0,0,0,0"),
                attributes: Self.extras(attributeDict, excluding: ["source", "src", "file", "rect"])
            )))
            case "label": append(.label(.init(
                text: attributeDict["text"] ?? attributeDict["name"] ?? "",
                rect: .init(attributeDict["rect"] ?? "0,0,0,0"),
                color: attributeDict["color"],
                attributes: Self.extras(attributeDict, excluding: ["text", "name", "rect", "color"])
            )))
            case "far_exits": insideFarExits = true
            default:
                guard tag != "font_rooms", tag != "font_exits", tag != "font_labels" else { return }
                let value = Atlas.UnknownElement(name: elementName, attributes: attributeDict)
                if insideMap { append(.unknown(value)) } else { unknownElements.append(value) }
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if elementName.caseInsensitiveCompare("far_exits") == .orderedSame { insideFarExits = false }
            if elementName.caseInsensitiveCompare("map") == .orderedSame { insideMap = false }
        }

        private func append(_ element: Atlas.MapElement) {
            guard !maps.isEmpty else { return }
            maps[maps.count - 1].elements.append(element)
        }

        private func font(_ attributes: [String: String]) -> Atlas.Font {
            .init(
                name: attributes["name"] ?? "Arial",
                size: Double(attributes["size"] ?? "9") ?? 9,
                attributes: Self.extras(attributes, excluding: ["name", "size"])
            )
        }

        private func exit(_ attributes: [String: String]) -> Atlas.Exit {
            .init(
                nameFrom: attributes["name_from"],
                nameTo: attributes["name_to"],
                from: attributes["from"],
                to: attributes["to"],
                mapFrom: attributes["map_from"],
                mapTo: attributes["map_to"],
                points: points(attributes["points"]),
                pointsSplit: attributes["points_split"].flatMap(Int.init),
                attributes: Self.extras(attributes, excluding: [
                    "name_from", "name_to", "from", "to", "map_from", "map_to", "points", "points_split",
                ])
            )
        }

        private func points(_ value: String?) -> [Atlas.Point] {
            guard let value else { return [] }
            return value.split(separator: "|").compactMap { pair in
                let values = pair.split(separator: ",").compactMap { Double($0) }
                guard values.count == 2 else { return nil }
                return .init(x: values[0], y: values[1])
            }
        }

        private static func boolean(_ value: String?) -> Bool {
            guard let value else { return false }
            return ["1", "t", "true", "yes", "on"].contains(value.lowercased())
        }

        private static func extras(_ values: [String: String], excluding keys: Set<String>) -> [String: String] {
            values.filter { !keys.contains($0.key) }
        }
    }
}

public enum AtlasWriter {
    public static func data(for atlas: Atlas) -> Data {
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>"]
        var root = atlas.attributes
        root["version"] = String(atlas.version)
        lines.append("<atlas\(attributes(root))>")
        appendFont(atlas.roomFont, tag: "font_rooms", to: &lines)
        appendFont(atlas.exitFont, tag: "font_exits", to: &lines)
        appendFont(atlas.labelFont, tag: "font_labels", to: &lines)
        for palette in atlas.palettes { lines.append("<palette\(attributes(palette.attributes))/>") }
        for unknown in atlas.unknownElements { lines.append(element(unknown)) }
        for map in atlas.maps {
            var mapAttributes = map.attributes
            mapAttributes["name"] = map.name
            lines.append("<map\(attributes(mapAttributes))>")
            for value in map.elements { lines.append(element(value)) }
            lines.append("</map>")
        }
        if !atlas.farExits.isEmpty {
            lines.append("<far_exits>")
            lines += atlas.farExits.map { element(.exit($0)) }
            lines.append("</far_exits>")
        }
        lines.append("</atlas>")
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    public static func write(
        _ archive: AtlasArchive,
        to url: URL,
        zipped: Bool? = nil
    ) throws {
        try write(archive, to: url, zipped: zipped, writer: .live)
    }

    static func write(
        _ archive: AtlasArchive,
        to url: URL,
        zipped: Bool? = nil,
        writer: AtomicFileWriter
    ) throws {
        let useArchive = zipped ?? (archive.atlas.version >= 2 || !archive.resources.isEmpty)
        guard useArchive else {
            try writer.write(data(for: archive.atlas), to: url)
            return
        }
        try writer.write(archiveData(for: archive), to: url)
    }

    /// Builds an uncompressed ZIP with fixed metadata and sorted entries.
    /// Atlas resources are already compressed media in normal use, and the
    /// stable byte representation is important for cross-host evidence and
    /// conflict detection.
    public static func archiveData(for archive: AtlasArchive) throws -> Data {
        var entries = [("Atlas.xml", data(for: archive.atlas))]
        for path in archive.resources.keys.sorted() {
            guard safeRelativePath(path) else { throw AtlasError.unsafeResourcePath(path) }
            entries.append((path, archive.resources[path] ?? Data()))
        }

        struct CentralEntry {
            var name: Data
            var crc32: UInt32
            var size: UInt32
            var offset: UInt32
        }

        var result = Data()
        var central: [CentralEntry] = []
        for (path, contents) in entries {
            let name = Data(path.utf8)
            guard name.count <= Int(UInt16.max),
                  contents.count <= Int(UInt32.max),
                  result.count <= Int(UInt32.max) else {
                throw AtlasError.archiveFailure("The atlas archive exceeds ZIP32 limits.")
            }
            let checksum = crc32(contents)
            let offset = UInt32(result.count)
            appendUInt32(0x0403_4B50, to: &result)
            appendUInt16(20, to: &result)
            appendUInt16(0x0800, to: &result)
            appendUInt16(0, to: &result)
            appendUInt16(0, to: &result)
            appendUInt16(0x0021, to: &result)
            appendUInt32(checksum, to: &result)
            appendUInt32(UInt32(contents.count), to: &result)
            appendUInt32(UInt32(contents.count), to: &result)
            appendUInt16(UInt16(name.count), to: &result)
            appendUInt16(0, to: &result)
            result.append(name)
            result.append(contents)
            central.append(.init(name: name, crc32: checksum, size: UInt32(contents.count), offset: offset))
        }

        guard result.count <= Int(UInt32.max), central.count <= Int(UInt16.max) else {
            throw AtlasError.archiveFailure("The atlas archive exceeds ZIP32 limits.")
        }
        let centralOffset = UInt32(result.count)
        for entry in central {
            appendUInt32(0x0201_4B50, to: &result)
            appendUInt16(20, to: &result)
            appendUInt16(20, to: &result)
            appendUInt16(0x0800, to: &result)
            appendUInt16(0, to: &result)
            appendUInt16(0, to: &result)
            appendUInt16(0x0021, to: &result)
            appendUInt32(entry.crc32, to: &result)
            appendUInt32(entry.size, to: &result)
            appendUInt32(entry.size, to: &result)
            appendUInt16(UInt16(entry.name.count), to: &result)
            appendUInt16(0, to: &result)
            appendUInt16(0, to: &result)
            appendUInt16(0, to: &result)
            appendUInt16(0, to: &result)
            appendUInt32(0, to: &result)
            appendUInt32(entry.offset, to: &result)
            result.append(entry.name)
        }
        let centralSize = UInt32(result.count) - centralOffset
        appendUInt32(0x0605_4B50, to: &result)
        appendUInt16(0, to: &result)
        appendUInt16(0, to: &result)
        appendUInt16(UInt16(central.count), to: &result)
        appendUInt16(UInt16(central.count), to: &result)
        appendUInt32(centralSize, to: &result)
        appendUInt32(centralOffset, to: &result)
        appendUInt16(0, to: &result)
        return result
    }

    private static func appendFont(_ font: Atlas.Font?, tag: String, to lines: inout [String]) {
        guard let font else { return }
        var values = font.attributes
        values["name"] = font.name
        values["size"] = number(font.size)
        lines.append("<\(tag)\(attributes(values))/>")
    }

    private static func element(_ value: Atlas.MapElement) -> String {
        switch value {
        case let .room(room):
            var values = room.attributes
            values["name"] = room.name
            values["rect"] = rect(room.rect)
            set(room.color, key: "color", in: &values)
            set(room.outlineColor, key: "color_outline", in: &values)
            set(room.textAngle.map(number), key: "text_angle", in: &values)
            if room.isUnderConstruction { values["under_construction"] = values["under_construction"] ?? "t" }
            else { values.removeValue(forKey: "under_construction") }
            return "<room\(attributes(values))/>"
        case let .exit(exit):
            var values = exit.attributes
            set(exit.nameFrom, key: "name_from", in: &values)
            set(exit.nameTo, key: "name_to", in: &values)
            set(exit.from, key: "from", in: &values)
            set(exit.to, key: "to", in: &values)
            set(exit.mapFrom, key: "map_from", in: &values)
            set(exit.mapTo, key: "map_to", in: &values)
            set(exit.points.isEmpty ? nil : exit.points.map { "\(number($0.x)),\(number($0.y))" }.joined(separator: "|"), key: "points", in: &values)
            set(exit.pointsSplit.map(String.init), key: "points_split", in: &values)
            return "<exit\(attributes(values))/>"
        case let .rectangle(rectangle):
            var values = rectangle.attributes
            values["rect"] = rect(rectangle.rect)
            set(rectangle.color, key: "color", in: &values)
            return "<rectangle\(attributes(values))/>"
        case let .image(image):
            var values = image.attributes
            let sourceKey = values["source"] != nil ? "source" : values["file"] != nil ? "file" : "src"
            values[sourceKey] = image.source
            values["rect"] = rect(image.rect)
            return "<image\(attributes(values))/>"
        case let .label(label):
            var values = label.attributes
            let textKey = values["name"] != nil && values["text"] == nil ? "name" : "text"
            values[textKey] = label.text
            values["rect"] = rect(label.rect)
            set(label.color, key: "color", in: &values)
            return "<label\(attributes(values))/>"
        case let .unknown(value): return element(value)
        }
    }

    private static func element(_ value: Atlas.UnknownElement) -> String {
        "<\(value.name)\(attributes(value.attributes))/>"
    }

    private static func attributes(_ values: [String: String]) -> String {
        guard !values.isEmpty else { return "" }
        return values.keys.sorted().map { " \($0)='\(escape(values[$0] ?? ""))'" }.joined()
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r", with: "&#13;")
            .replacingOccurrences(of: "\n", with: "&#10;")
    }

    private static func rect(_ value: Atlas.Rect) -> String {
        [value.x1, value.y1, value.x2, value.y2].map(number).joined(separator: ",")
    }

    private static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.8g", value)
    }

    private static func set(_ value: String?, key: String, in values: inout [String: String]) {
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }

    private static func safeRelativePath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return !normalized.hasPrefix("/")
            && !normalized.isEmpty
            && !parts.contains("..")
            && !parts.contains("")
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                value = (value >> 1) ^ ((value & 1) == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return value ^ UInt32.max
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: (0..<4).map { UInt8((value >> UInt32(8 * $0)) & 0xFF) })
    }
}

public enum AtlasObjectKind: String, Sendable, Hashable, CaseIterable {
    case room, exit, rectangle, image, label
}

public struct AtlasObjectID: Sendable, Hashable {
    public var mapIndex: Int
    public var elementIndex: Int

    public init(mapIndex: Int, elementIndex: Int) {
        self.mapIndex = mapIndex
        self.elementIndex = elementIndex
    }
}

public struct AtlasSelectionFilter: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let rooms = Self(rawValue: 1 << 0)
    public static let exits = Self(rawValue: 1 << 1)
    public static let rectangles = Self(rawValue: 1 << 2)
    public static let images = Self(rawValue: 1 << 3)
    public static let labels = Self(rawValue: 1 << 4)
    public static let all: Self = [.rooms, .exits, .rectangles, .images, .labels]

    public func contains(_ kind: AtlasObjectKind) -> Bool {
        switch kind {
        case .room: contains(.rooms)
        case .exit: contains(.exits)
        case .rectangle: contains(.rectangles)
        case .image: contains(.images)
        case .label: contains(.labels)
        }
    }
}

public struct AtlasViewport: Sendable, Equatable {
    public var scale: Double
    public var origin: Atlas.Point

    public init(scale: Double = 1, origin: Atlas.Point = .init(x: 0, y: 0)) {
        self.scale = min(max(scale, 0.1), 8)
        self.origin = origin
    }

    public mutating func zoom(by factor: Double, around anchor: Atlas.Point) {
        let old = scale
        scale = min(max(scale * factor, 0.1), 8)
        guard old != scale else { return }
        let ratio = scale / old
        origin.x = anchor.x - (anchor.x - origin.x) * ratio
        origin.y = anchor.y - (anchor.y - origin.y) * ratio
    }
}

public struct AtlasLocation: Sendable, Hashable, Equatable {
    public var mapIndex: Int
    public var roomIndex: Int
    public init(mapIndex: Int, roomIndex: Int) { self.mapIndex = mapIndex; self.roomIndex = roomIndex }
}

public struct AtlasPathStep: Sendable, Equatable {
    public var command: String
    public var destination: AtlasLocation
    public init(command: String, destination: AtlasLocation) { self.command = command; self.destination = destination }
}

public struct AtlasSearchResult: Sendable, Equatable {
    public var location: AtlasLocation
    public var name: String
    public init(location: AtlasLocation, name: String) { self.location = location; self.name = name }
}

public struct AtlasEditor: Sendable {
    public private(set) var atlas: Atlas
    public var mapIndex: Int
    public var currentLocation: AtlasLocation?
    public var selection: Set<AtlasObjectID>
    public var selectionFilter: AtlasSelectionFilter
    public var viewport: AtlasViewport
    public var liveTracking: Bool {
        didSet {
            if !liveTracking { pendingTraversal = nil }
        }
    }
    public private(set) var typedExitNames: Set<String>
    public private(set) var seenExitNames: Set<String>
    private var pendingTraversal: PendingTraversal?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private let historyLimit = 100

    public init(atlas: Atlas = .init()) {
        self.atlas = atlas
        mapIndex = atlas.maps.isEmpty ? -1 : 0
        currentLocation = nil
        selection = []
        selectionFilter = .all
        viewport = .init()
        liveTracking = false
        typedExitNames = []
        seenExitNames = []
        pendingTraversal = nil
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var currentMap: Atlas.Map? { atlas.maps.indices.contains(mapIndex) ? atlas.maps[mapIndex] : nil }

    public mutating func replaceAtlas(_ value: Atlas) {
        saveUndo()
        atlas = value
        mapIndex = value.maps.isEmpty ? -1 : min(max(0, mapIndex), value.maps.count - 1)
        currentLocation = nil
        selection = []
    }

    @discardableResult
    public mutating func addMap(named name: String) -> Int {
        saveUndo()
        atlas.maps.append(.init(name: name.isEmpty ? "Map \(atlas.maps.count + 1)" : name))
        mapIndex = atlas.maps.count - 1
        selection = []
        return mapIndex
    }

    public mutating func removeMap(at index: Int) {
        guard atlas.maps.indices.contains(index) else { return }
        saveUndo()
        atlas.maps.remove(at: index)
        atlas.farExits = atlas.farExits.compactMap { exit in
            guard let from = Int(exit.mapFrom ?? ""), let to = Int(exit.mapTo ?? ""), from != index, to != index else { return nil }
            var value = exit
            if from > index { value.mapFrom = String(from - 1) }
            if to > index { value.mapTo = String(to - 1) }
            return value
        }
        mapIndex = atlas.maps.isEmpty ? -1 : min(mapIndex, atlas.maps.count - 1)
        currentLocation = nil
        selection = []
    }

    @discardableResult
    public mutating func addRoom(name: String, rect: Atlas.Rect, color: String? = nil, map: Int? = nil) -> AtlasObjectID? {
        append(.room(.init(name: name, rect: rect, color: color)), to: map)
    }

    @discardableResult
    public mutating func addRectangle(rect: Atlas.Rect, color: String? = nil, map: Int? = nil) -> AtlasObjectID? {
        append(.rectangle(.init(rect: rect, color: color)), to: map)
    }

    @discardableResult
    public mutating func addImage(source: String, rect: Atlas.Rect, map: Int? = nil) -> AtlasObjectID? {
        append(.image(.init(source: source, rect: rect)), to: map)
    }

    @discardableResult
    public mutating func addLabel(text: String, rect: Atlas.Rect, color: String? = nil, map: Int? = nil) -> AtlasObjectID? {
        append(.label(.init(text: text, rect: rect, color: color)), to: map)
    }

    @discardableResult
    public mutating func addExit(
        from: Int,
        to: Int?,
        nameFrom: String?,
        nameTo: String? = nil,
        points: [Atlas.Point] = [],
        map: Int? = nil,
        destinationMap: Int? = nil
    ) -> AtlasObjectID? {
        let sourceMap = map ?? mapIndex
        guard atlas.maps.indices.contains(sourceMap), atlas.maps[sourceMap].rooms.indices.contains(from) else { return nil }
        if let destinationMap, destinationMap != sourceMap {
            guard let to, atlas.maps.indices.contains(destinationMap), atlas.maps[destinationMap].rooms.indices.contains(to) else { return nil }
            saveUndo()
            atlas.farExits.append(.init(
                nameFrom: nameFrom, nameTo: nameTo,
                from: String(from), to: String(to),
                mapFrom: String(sourceMap), mapTo: String(destinationMap), points: points
            ))
            return nil
        }
        if let to, !atlas.maps[sourceMap].rooms.indices.contains(to) { return nil }
        return append(.exit(.init(
            nameFrom: nameFrom, nameTo: nameTo,
            from: String(from), to: to.map(String.init), points: points
        )), to: sourceMap)
    }

    public mutating func renameRoom(at location: AtlasLocation, to name: String) {
        guard let elementIndex = roomElementIndex(location) else { return }
        saveUndo()
        guard case var .room(room) = atlas.maps[location.mapIndex].elements[elementIndex] else { return }
        room.name = name
        atlas.maps[location.mapIndex].elements[elementIndex] = .room(room)
    }

    public mutating func deleteSelection() {
        let valid = selection.filter { atlas.maps.indices.contains($0.mapIndex) && atlas.maps[$0.mapIndex].elements.indices.contains($0.elementIndex) }
        guard !valid.isEmpty else { return }
        var removedRooms: [Int: Set<Int>] = [:]
        for group in Dictionary(grouping: valid, by: \.mapIndex) {
            let selectedElements = Set(group.value.map(\.elementIndex))
            var roomIndex = 0
            for (elementIndex, element) in atlas.maps[group.key].elements.enumerated() {
                if case .room = element {
                    if selectedElements.contains(elementIndex) { removedRooms[group.key, default: []].insert(roomIndex) }
                    roomIndex += 1
                }
            }
        }
        saveUndo()
        for group in Dictionary(grouping: valid, by: \.mapIndex) {
            let selectedElements = Set(group.value.map(\.elementIndex))
            let removed = removedRooms[group.key] ?? []
            atlas.maps[group.key].elements = atlas.maps[group.key].elements.enumerated().compactMap { index, element in
                guard !selectedElements.contains(index) else { return nil }
                guard case var .exit(exit) = element else { return element }
                if let from = Int(exit.from ?? ""), removed.contains(from) { return nil }
                if let to = Int(exit.to ?? ""), removed.contains(to) { return nil }
                if let from = Int(exit.from ?? "") { exit.from = String(from - removed.filter { $0 < from }.count) }
                if let to = Int(exit.to ?? "") { exit.to = String(to - removed.filter { $0 < to }.count) }
                return .exit(exit)
            }
        }
        atlas.farExits = atlas.farExits.compactMap { exit in
            guard let mapFrom = Int(exit.mapFrom ?? ""), let mapTo = Int(exit.mapTo ?? ""),
                  let from = Int(exit.from ?? ""), let to = Int(exit.to ?? "") else { return exit }
            let fromRemoved = removedRooms[mapFrom] ?? []
            let toRemoved = removedRooms[mapTo] ?? []
            guard !fromRemoved.contains(from), !toRemoved.contains(to) else { return nil }
            var value = exit
            value.from = String(from - fromRemoved.filter { $0 < from }.count)
            value.to = String(to - toRemoved.filter { $0 < to }.count)
            return value
        }
        if let current = currentLocation, let removed = removedRooms[current.mapIndex] {
            if removed.contains(current.roomIndex) { currentLocation = nil }
            else { currentLocation?.roomIndex -= removed.filter { $0 < current.roomIndex }.count }
        }
        selection = []
    }

    public mutating func moveSelection(dx: Double, dy: Double, snap: Double? = nil) {
        guard !selection.isEmpty else { return }
        let movement: Atlas.Point
        if let snap, snap > 0 {
            let rects = selection.compactMap { element(at: $0)?.rect }
            if let anchor = rects.first {
                let x = rects.dropFirst().reduce(anchor.standardized.x1) { min($0, $1.standardized.x1) }
                let y = rects.dropFirst().reduce(anchor.standardized.y1) { min($0, $1.standardized.y1) }
                movement = .init(
                    x: ((x + dx) / snap).rounded() * snap - x,
                    y: ((y + dy) / snap).rounded() * snap - y
                )
            } else {
                movement = .init(x: (dx / snap).rounded() * snap, y: (dy / snap).rounded() * snap)
            }
        } else {
            movement = .init(x: dx, y: dy)
        }
        guard movement.x != 0 || movement.y != 0 else { return }
        saveUndo()
        for id in selection where atlas.maps.indices.contains(id.mapIndex) && atlas.maps[id.mapIndex].elements.indices.contains(id.elementIndex) {
            atlas.maps[id.mapIndex].elements[id.elementIndex].offset(dx: movement.x, dy: movement.y, snap: nil)
        }
    }

    public func element(at id: AtlasObjectID) -> Atlas.MapElement? {
        guard atlas.maps.indices.contains(id.mapIndex), atlas.maps[id.mapIndex].elements.indices.contains(id.elementIndex) else { return nil }
        return atlas.maps[id.mapIndex].elements[id.elementIndex]
    }

    public mutating func updateElement(at id: AtlasObjectID, to element: Atlas.MapElement) {
        guard atlas.maps.indices.contains(id.mapIndex), atlas.maps[id.mapIndex].elements.indices.contains(id.elementIndex) else { return }
        saveUndo()
        atlas.maps[id.mapIndex].elements[id.elementIndex] = element
    }

    public mutating func resizeElement(at id: AtlasObjectID, to rect: Atlas.Rect, minimumSize: Double = 10) {
        guard atlas.maps.indices.contains(id.mapIndex), atlas.maps[id.mapIndex].elements.indices.contains(id.elementIndex) else { return }
        let standardized = rect.standardized
        guard standardized.width >= minimumSize, standardized.height >= minimumSize else { return }
        var element = atlas.maps[id.mapIndex].elements[id.elementIndex]
        guard element.setRect(standardized) else { return }
        saveUndo()
        atlas.maps[id.mapIndex].elements[id.elementIndex] = element
    }

    /// Produces a self-contained map fragment suitable for clipboard transfer.
    /// Exits are included only when both endpoint rooms are selected and are
    /// rewritten to fragment-local room indices.
    public func selectionFragment() -> Atlas.Map? {
        guard let map = currentMap else { return nil }
        let selectedIndices = Set(selection.filter { $0.mapIndex == mapIndex }.map(\.elementIndex))
        guard !selectedIndices.isEmpty else { return nil }
        var originalRoomForElement: [Int: Int] = [:]
        var roomIndex = 0
        for (elementIndex, element) in map.elements.enumerated() {
            if case .room = element {
                originalRoomForElement[elementIndex] = roomIndex
                roomIndex += 1
            }
        }
        let selectedRooms = map.elements.indices.compactMap { index -> Int? in
            guard selectedIndices.contains(index) else { return nil }
            return originalRoomForElement[index]
        }
        let roomRemap = Dictionary(uniqueKeysWithValues: selectedRooms.enumerated().map { ($0.element, $0.offset) })
        let elements = map.elements.enumerated().compactMap { index, element -> Atlas.MapElement? in
            guard selectedIndices.contains(index) else { return nil }
            guard case var .exit(value) = element else { return element }
            guard let from = Int(value.from ?? ""), let to = Int(value.to ?? ""),
                  let newFrom = roomRemap[from], let newTo = roomRemap[to] else { return nil }
            value.from = String(newFrom)
            value.to = String(newTo)
            return .exit(value)
        }
        return elements.isEmpty ? nil : .init(name: map.name, elements: elements)
    }

    @discardableResult
    public mutating func paste(_ fragment: Atlas.Map, offset: Atlas.Point = .init(x: 20, y: 20)) -> [AtlasObjectID] {
        guard atlas.maps.indices.contains(mapIndex), !fragment.elements.isEmpty else { return [] }
        saveUndo()
        let existingRooms = atlas.maps[mapIndex].rooms.count
        let firstIndex = atlas.maps[mapIndex].elements.count
        var inserted = fragment.elements
        for index in inserted.indices {
            inserted[index].offset(dx: offset.x, dy: offset.y, snap: nil)
            if case var .exit(value) = inserted[index] {
                if let from = Int(value.from ?? "") { value.from = String(existingRooms + from) }
                if let to = Int(value.to ?? "") { value.to = String(existingRooms + to) }
                inserted[index] = .exit(value)
            }
        }
        atlas.maps[mapIndex].elements.append(contentsOf: inserted)
        let ids = inserted.indices.map { AtlasObjectID(mapIndex: mapIndex, elementIndex: firstIndex + $0) }
        selection = Set(ids)
        return ids
    }

    public mutating func bringSelectionToFront() { reorderSelection(toFront: true) }
    public mutating func sendSelectionToBack() { reorderSelection(toFront: false) }

    public mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        restore(previous)
    }

    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        restore(next)
    }

    public func findRooms(_ query: String, caseSensitive: Bool = false) -> [AtlasSearchResult] {
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        return atlas.maps.enumerated().flatMap { mapIndex, map in
            map.rooms.enumerated().compactMap { roomIndex, room in
                room.name.range(of: query, options: options) == nil ? nil : .init(
                    location: .init(mapIndex: mapIndex, roomIndex: roomIndex), name: room.name
                )
            }
        }
    }

    public func objectID(for location: AtlasLocation) -> AtlasObjectID? {
        roomElementIndex(location).map { .init(mapIndex: location.mapIndex, elementIndex: $0) }
    }

    public mutating func updatePalette(background: String?, exit: String?) {
        saveUndo()
        if let background, !background.isEmpty { atlas.attributes["color_background"] = background }
        else { atlas.attributes.removeValue(forKey: "color_background") }
        if let exit, !exit.isEmpty { atlas.attributes["color_exit"] = exit }
        else { atlas.attributes.removeValue(forKey: "color_exit") }
    }

    public mutating func setCurrentLocation(_ location: AtlasLocation?) {
        guard let location else { currentLocation = nil; return }
        guard atlas.maps.indices.contains(location.mapIndex), atlas.maps[location.mapIndex].rooms.indices.contains(location.roomIndex) else { return }
        currentLocation = location
        mapIndex = location.mapIndex
    }

    public func shortestPath(to destination: AtlasLocation) -> [AtlasPathStep]? {
        guard let start = currentLocation, start != destination else { return [] }
        var queue = [start]
        var cursor = 0
        var previous: [AtlasLocation: (AtlasLocation, String)] = [:]
        var visited: Set<AtlasLocation> = [start]
        while cursor < queue.count {
            let node = queue[cursor]
            cursor += 1
            for edge in edges(from: node) where visited.insert(edge.destination).inserted {
                previous[edge.destination] = (node, edge.command)
                if edge.destination == destination {
                    var result: [AtlasPathStep] = []
                    var current = destination
                    while current != start, let value = previous[current] {
                        result.append(.init(command: value.1, destination: current))
                        current = value.0
                    }
                    return result.reversed()
                }
                queue.append(edge.destination)
            }
        }
        return nil
    }

    public func exitsFromCurrentRoom() -> [(command: String, destinationName: String)] {
        guard let currentLocation else { return [] }
        return edges(from: currentLocation).map { edge in
            (edge.command, atlas.maps[edge.destination.mapIndex].rooms[edge.destination.roomIndex].name)
        }
    }

    public mutating func recordTypedExit(_ command: String) -> AtlasLocation? {
        guard let currentLocation else { return nil }
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let edge = edges(from: currentLocation).first(where: {
            $0.command.caseInsensitiveCompare(normalized) == .orderedSame
        })
        if liveTracking, edge != nil || Self.directionVector(normalized) != nil {
            pendingTraversal = .init(source: currentLocation, command: normalized)
        }
        guard let edge else { return nil }
        typedExitNames.insert(normalized.lowercased())
        setCurrentLocation(edge.destination)
        return edge.destination
    }

    public mutating func observeOutput(_ text: String) -> AtlasLocation? {
        guard liveTracking else { return nil }
        if let traversal = pendingTraversal, Self.indicatesMovementFailure(text) {
            pendingTraversal = nil
            setCurrentLocation(traversal.source)
            return traversal.source
        }
        var candidateSources: [AtlasLocation] = []
        if let source = pendingTraversal?.source ?? currentLocation { candidateSources.append(source) }
        if let currentLocation, !candidateSources.contains(currentLocation) { candidateSources.append(currentLocation) }
        for source in candidateSources {
            let candidates = edges(from: source).sorted {
                room(at: $0.destination).name.count > room(at: $1.destination).name.count
            }
            for edge in candidates {
                let room = room(at: edge.destination)
                if !room.name.isEmpty, text.range(of: room.name, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    seenExitNames.insert(edge.command.lowercased())
                    pendingTraversal = nil
                    setCurrentLocation(edge.destination)
                    return edge.destination
                }
            }
        }

        guard let name = Self.roomNameCandidate(from: text) else { return nil }
        if let traversal = pendingTraversal {
            let location = integrateObservedRoom(named: name, from: traversal.source, command: traversal.command)
            pendingTraversal = nil
            return location
        }

        if let currentLocation {
            let currentRoom = room(at: currentLocation)
            if Self.roomIdentity(currentRoom.name) == Self.roomIdentity(name) { return currentLocation }
            return nil
        }

        if let existing = location(ofRoomNamed: name, preferredMap: mapIndex) {
            setCurrentLocation(existing)
            return existing
        }
        if atlas.maps.isEmpty { _ = addMap(named: "Map") }
        guard let id = addRoom(name: name, rect: .init(x1: 0, y1: 0, x2: 100, y2: 70), map: mapIndex) else { return nil }
        let location = AtlasLocation(mapIndex: mapIndex, roomIndex: roomIndex(forElement: id.elementIndex, in: mapIndex) ?? 0)
        setCurrentLocation(location)
        return location
    }

    private mutating func integrateObservedRoom(named name: String, from source: AtlasLocation, command: String) -> AtlasLocation? {
        guard atlas.maps.indices.contains(source.mapIndex), atlas.maps[source.mapIndex].rooms.indices.contains(source.roomIndex) else { return nil }
        let destination: AtlasLocation
        if let existing = location(ofRoomNamed: name, preferredMap: source.mapIndex) {
            destination = existing
        } else {
            let rect = automaticRoomRect(from: source, command: command)
            guard let id = addRoom(name: name, rect: rect, map: source.mapIndex),
                  let roomIndex = roomIndex(forElement: id.elementIndex, in: source.mapIndex) else { return nil }
            destination = .init(mapIndex: source.mapIndex, roomIndex: roomIndex)
        }

        if destination != source,
           !edges(from: source).contains(where: { $0.command.caseInsensitiveCompare(command) == .orderedSame }) {
            _ = addExit(
                from: source.roomIndex,
                to: destination.roomIndex,
                nameFrom: command,
                nameTo: Self.oppositeDirection(command),
                map: source.mapIndex,
                destinationMap: destination.mapIndex
            )
        }
        typedExitNames.insert(command.lowercased())
        seenExitNames.insert(command.lowercased())
        setCurrentLocation(destination)
        return destination
    }

    private func location(ofRoomNamed name: String, preferredMap: Int) -> AtlasLocation? {
        let identity = Self.roomIdentity(name)
        if atlas.maps.indices.contains(preferredMap),
           let room = atlas.maps[preferredMap].rooms.firstIndex(where: { Self.roomIdentity($0.name) == identity }) {
            return .init(mapIndex: preferredMap, roomIndex: room)
        }
        for (map, value) in atlas.maps.enumerated() where map != preferredMap {
            if let room = value.rooms.firstIndex(where: { Self.roomIdentity($0.name) == identity }) {
                return .init(mapIndex: map, roomIndex: room)
            }
        }
        return nil
    }

    private func room(at location: AtlasLocation) -> Atlas.Room {
        atlas.maps[location.mapIndex].rooms[location.roomIndex]
    }

    private func roomIndex(forElement elementIndex: Int, in mapIndex: Int) -> Int? {
        guard atlas.maps.indices.contains(mapIndex), atlas.maps[mapIndex].elements.indices.contains(elementIndex) else { return nil }
        return atlas.maps[mapIndex].elements[..<elementIndex].reduce(0) { count, element in
            if case .room = element { count + 1 } else { count }
        }
    }

    private func automaticRoomRect(from source: AtlasLocation, command: String) -> Atlas.Rect {
        let room = room(at: source)
        let width = max(80, room.rect.width)
        let height = max(50, room.rect.height)
        let vector = Self.directionVector(command) ?? .init(x: 1, y: 0)
        let spacing = max(40, max(width, height) * 1.5)
        let existing = atlas.maps[source.mapIndex].rooms.map(\.rect)
        for multiplier in 1...50 {
            let center = Atlas.Point(
                x: room.rect.center.x + vector.x * spacing * Double(multiplier),
                y: room.rect.center.y + vector.y * spacing * Double(multiplier)
            )
            let candidate = Atlas.Rect(
                x1: center.x - width / 2, y1: center.y - height / 2,
                x2: center.x + width / 2, y2: center.y + height / 2
            )
            if !existing.contains(where: { $0.intersects(candidate) }) { return candidate }
        }
        return room.rect.offsetBy(dx: vector.x * spacing, dy: vector.y * spacing)
    }

    private static func roomNameCandidate(from text: String) -> String? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2, name.count <= 100, name.split(whereSeparator: \.isWhitespace).count <= 12,
              name.unicodeScalars.contains(where: CharacterSet.letters.contains),
              !name.contains("://") else { return nil }
        let lower = name.lowercased()
        let rejectedPrefixes = [
            "you ", "your ", "there ", "obvious exit", "visible exit", "exits", "welcome ",
            "health", "hit points", "hp:", "mana", "score", "time:", "connected", "disconnected"
        ]
        guard !rejectedPrefixes.contains(where: lower.hasPrefix) else { return nil }
        if let last = name.last, ".!?".contains(last) { return nil }
        return name
    }

    private static func indicatesMovementFailure(_ text: String) -> Bool {
        let value = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return [
            "cannot go", "can't go", "cant go", "couldn't go", "could not go", "no exit",
            "not a valid exit", "not an exit", "can't move", "cannot move", "way is blocked"
        ].contains(where: value.contains)
    }

    private static func roomIdentity(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func oppositeDirection(_ value: String) -> String? {
        switch value.lowercased().replacingOccurrences(of: "-", with: "") {
        case "n": "s"
        case "north": "south"
        case "ne": "sw"
        case "northeast": "southwest"
        case "e": "w"
        case "east": "west"
        case "se": "nw"
        case "southeast": "northwest"
        case "s": "n"
        case "south": "north"
        case "sw": "ne"
        case "southwest": "northeast"
        case "w": "e"
        case "west": "east"
        case "nw": "se"
        case "northwest": "southeast"
        case "u": "d"
        case "up": "down"
        case "d": "u"
        case "down": "up"
        default: nil
        }
    }

    private struct PendingTraversal: Sendable {
        var source: AtlasLocation
        var command: String
    }

    public mutating func guessLocation(in recentLines: [String]) -> AtlasLocation? {
        for line in recentLines.reversed() {
            let matches = atlas.maps.enumerated().flatMap { mapIndex, map in
                map.rooms.enumerated().compactMap { roomIndex, room -> AtlasSearchResult? in
                    guard !room.name.isEmpty,
                          line.range(of: room.name, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return nil }
                    return .init(location: .init(mapIndex: mapIndex, roomIndex: roomIndex), name: room.name)
                }
            }.sorted { $0.name.count > $1.name.count }
            if let location = matches.first?.location { setCurrentLocation(location); return location }
        }
        return nil
    }

    @discardableResult
    public mutating func integrate(_ info: GMCPRoomInfo) -> AtlasLocation {
        let targetMap: Int
        if let index = atlas.maps.firstIndex(where: { $0.name.caseInsensitiveCompare(info.area) == .orderedSame }) {
            targetMap = index
        } else {
            targetMap = addMap(named: info.area.isEmpty ? "Map" : info.area)
        }
        let rooms = atlas.maps[targetMap].rooms
        let roomIndex: Int
        if let index = rooms.firstIndex(where: {
            $0.attributes["gmcp_id"] == info.id || $0.name.caseInsensitiveCompare(info.name) == .orderedSame
        }) {
            roomIndex = index
            if let elementIndex = roomElementIndex(.init(mapIndex: targetMap, roomIndex: index)) {
                saveUndo()
                guard case var .room(room) = atlas.maps[targetMap].elements[elementIndex] else {
                    return .init(mapIndex: targetMap, roomIndex: index)
                }
                room.name = info.name
                room.rect = Self.rect(for: info)
                room.attributes["gmcp_id"] = info.id
                atlas.maps[targetMap].elements[elementIndex] = .room(room)
            }
        } else {
            let id = addRoom(name: info.name, rect: Self.rect(for: info), map: targetMap)!
            if case var .room(room) = atlas.maps[targetMap].elements[id.elementIndex] {
                room.attributes["gmcp_id"] = info.id
                atlas.maps[targetMap].elements[id.elementIndex] = .room(room)
            }
            roomIndex = atlas.maps[targetMap].rooms.count - 1
        }
        let location = AtlasLocation(mapIndex: targetMap, roomIndex: roomIndex)
        setCurrentLocation(location)
        ensureGMCPExits(info.exits, from: location)
        resolvePendingGMCPExits()
        return location
    }

    @discardableResult
    public mutating func addRoomAndExit(name: String, outward: String, returnCommand: String) -> AtlasLocation? {
        guard let current = currentLocation else { return nil }
        let source = atlas.maps[current.mapIndex].rooms[current.roomIndex]
        let vector = Self.directionVector(outward) ?? .init(x: 1, y: 0)
        let spacing = max(30, max(source.rect.width, source.rect.height) * 1.5)
        let rect = source.rect.offsetBy(dx: vector.x * spacing, dy: vector.y * spacing)
        guard addRoom(name: name, rect: rect, map: current.mapIndex) != nil else { return nil }
        let destination = AtlasLocation(mapIndex: current.mapIndex, roomIndex: atlas.maps[current.mapIndex].rooms.count - 1)
        _ = addExit(from: current.roomIndex, to: destination.roomIndex, nameFrom: outward, nameTo: returnCommand, map: current.mapIndex)
        return destination
    }

    @discardableResult
    public mutating func addExitToDirectionalRoom(outward: String, returnCommand: String) -> Bool {
        guard let current = currentLocation, let direction = Self.directionVector(outward) else { return false }
        let source = atlas.maps[current.mapIndex].rooms[current.roomIndex].rect.center
        let candidate = atlas.maps[current.mapIndex].rooms.enumerated().filter { index, room in
            guard index != current.roomIndex else { return false }
            let delta = Atlas.Point(x: room.rect.center.x - source.x, y: room.rect.center.y - source.y)
            let length = hypot(delta.x, delta.y)
            guard length > 0 else { return false }
            return (delta.x / length) * direction.x + (delta.y / length) * direction.y > 0.8
        }.min { lhs, rhs in
            hypot(lhs.element.rect.center.x - source.x, lhs.element.rect.center.y - source.y)
                < hypot(rhs.element.rect.center.x - source.x, rhs.element.rect.center.y - source.y)
        }
        guard let candidate else { return false }
        return addExit(
            from: current.roomIndex, to: candidate.offset,
            nameFrom: outward, nameTo: returnCommand, map: current.mapIndex
        ) != nil
    }

    private struct Snapshot: Sendable {
        var atlas: Atlas
        var mapIndex: Int
        var currentLocation: AtlasLocation?
        var selection: Set<AtlasObjectID>
    }

    private var snapshot: Snapshot { .init(atlas: atlas, mapIndex: mapIndex, currentLocation: currentLocation, selection: selection) }

    private mutating func saveUndo() {
        undoStack.append(snapshot)
        if undoStack.count > historyLimit { undoStack.removeFirst(undoStack.count - historyLimit) }
        redoStack.removeAll()
    }

    private mutating func restore(_ value: Snapshot) {
        atlas = value.atlas
        mapIndex = value.mapIndex
        currentLocation = value.currentLocation
        selection = value.selection
    }

    @discardableResult
    private mutating func append(_ element: Atlas.MapElement, to requestedMap: Int?) -> AtlasObjectID? {
        let index = requestedMap ?? mapIndex
        guard atlas.maps.indices.contains(index) else { return nil }
        saveUndo()
        atlas.maps[index].elements.append(element)
        return .init(mapIndex: index, elementIndex: atlas.maps[index].elements.count - 1)
    }

    private mutating func reorderSelection(toFront: Bool) {
        let ids = selection.filter { $0.mapIndex == mapIndex }.sorted { $0.elementIndex < $1.elementIndex }
        guard !ids.isEmpty, atlas.maps.indices.contains(mapIndex) else { return }
        saveUndo()
        let selected = ids.map { atlas.maps[mapIndex].elements[$0.elementIndex] }
        let indices = Set(ids.map(\.elementIndex))
        let remainder = atlas.maps[mapIndex].elements.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
        atlas.maps[mapIndex].elements = toFront ? remainder + selected : selected + remainder
        let offset = toFront ? remainder.count : 0
        selection = Set(selected.indices.map { .init(mapIndex: mapIndex, elementIndex: offset + $0) })
    }

    private func roomElementIndex(_ location: AtlasLocation) -> Int? {
        guard atlas.maps.indices.contains(location.mapIndex) else { return nil }
        var room = 0
        for (index, element) in atlas.maps[location.mapIndex].elements.enumerated() {
            if case .room = element {
                if room == location.roomIndex { return index }
                room += 1
            }
        }
        return nil
    }

    private func edges(from location: AtlasLocation) -> [(destination: AtlasLocation, command: String)] {
        guard atlas.maps.indices.contains(location.mapIndex), atlas.maps[location.mapIndex].rooms.indices.contains(location.roomIndex) else { return [] }
        var result: [(AtlasLocation, String)] = []
        for exit in atlas.maps[location.mapIndex].exits {
            if Int(exit.from ?? "") == location.roomIndex,
               let to = Int(exit.to ?? ""), atlas.maps[location.mapIndex].rooms.indices.contains(to),
               let command = exit.nameFrom, !command.isEmpty {
                result.append((.init(mapIndex: location.mapIndex, roomIndex: to), command))
            }
            if Int(exit.to ?? "") == location.roomIndex,
               let from = Int(exit.from ?? ""), atlas.maps[location.mapIndex].rooms.indices.contains(from),
               let command = exit.nameTo, !command.isEmpty {
                result.append((.init(mapIndex: location.mapIndex, roomIndex: from), command))
            }
        }
        for exit in atlas.farExits {
            guard let mapFrom = Int(exit.mapFrom ?? ""), let mapTo = Int(exit.mapTo ?? ""),
                  let from = Int(exit.from ?? ""), let to = Int(exit.to ?? "") else { continue }
            if mapFrom == location.mapIndex, from == location.roomIndex,
               atlas.maps.indices.contains(mapTo), atlas.maps[mapTo].rooms.indices.contains(to),
               let command = exit.nameFrom, !command.isEmpty {
                result.append((.init(mapIndex: mapTo, roomIndex: to), command))
            }
            if mapTo == location.mapIndex, to == location.roomIndex,
               atlas.maps.indices.contains(mapFrom), atlas.maps[mapFrom].rooms.indices.contains(from),
               let command = exit.nameTo, !command.isEmpty {
                result.append((.init(mapIndex: mapFrom, roomIndex: from), command))
            }
        }
        return result
    }

    private mutating func ensureGMCPExits(_ exits: [GMCPRoomInfo.Exit], from location: AtlasLocation) {
        for info in exits {
            let destination = atlas.maps.enumerated().compactMap { mapIndex, map -> AtlasLocation? in
                guard let roomIndex = map.rooms.firstIndex(where: { $0.attributes["gmcp_id"] == info.destination }) else { return nil }
                return .init(mapIndex: mapIndex, roomIndex: roomIndex)
            }.first
            let command = info.direction.isEmpty ? info.name : info.direction
            guard !command.isEmpty else { continue }
            let exists = edges(from: location).contains { $0.command.caseInsensitiveCompare(command) == .orderedSame }
            guard !exists else { continue }
            if let destination {
                _ = addExit(
                    from: location.roomIndex, to: destination.roomIndex,
                    nameFrom: command, map: location.mapIndex, destinationMap: destination.mapIndex
                )
            } else if let element = roomElementIndex(location) {
                saveUndo()
                guard case var .room(room) = atlas.maps[location.mapIndex].elements[element] else { continue }
                room.attributes["gmcp_exit_\(info.id)"] = [command, info.destination, info.name, info.description].joined(separator: "|")
                atlas.maps[location.mapIndex].elements[element] = .room(room)
            }
        }
    }

    private mutating func resolvePendingGMCPExits() {
        struct Pending {
            var source: AtlasLocation
            var attribute: String
            var command: String
            var destination: AtlasLocation
        }
        var destinations: [String: AtlasLocation] = [:]
        for (mapIndex, map) in atlas.maps.enumerated() {
            for (roomIndex, room) in map.rooms.enumerated() {
                if let id = room.attributes["gmcp_id"] {
                    destinations[id] = .init(mapIndex: mapIndex, roomIndex: roomIndex)
                }
            }
        }
        var pending: [Pending] = []
        for (mapIndex, map) in atlas.maps.enumerated() {
            for (roomIndex, room) in map.rooms.enumerated() {
                for (key, value) in room.attributes where key.hasPrefix("gmcp_exit_") {
                    let fields = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    guard fields.count >= 2, let destination = destinations[fields[1]] else { continue }
                    pending.append(.init(
                        source: .init(mapIndex: mapIndex, roomIndex: roomIndex),
                        attribute: key,
                        command: fields[0],
                        destination: destination
                    ))
                }
            }
        }
        for value in pending {
            _ = addExit(
                from: value.source.roomIndex,
                to: value.destination.roomIndex,
                nameFrom: value.command,
                map: value.source.mapIndex,
                destinationMap: value.destination.mapIndex
            )
            if let element = roomElementIndex(value.source), case var .room(room) = atlas.maps[value.source.mapIndex].elements[element] {
                room.attributes.removeValue(forKey: value.attribute)
                atlas.maps[value.source.mapIndex].elements[element] = .room(room)
            }
        }
    }

    private static func rect(for info: GMCPRoomInfo) -> Atlas.Rect {
        let width = max(1, info.size.x)
        let height = max(1, info.size.y)
        return .init(
            x1: Double(info.coordinates.x), y1: Double(info.coordinates.y),
            x2: Double(info.coordinates.x + width), y2: Double(info.coordinates.y + height)
        )
    }

    private static func directionVector(_ value: String) -> Atlas.Point? {
        switch value.lowercased().replacingOccurrences(of: "-", with: "") {
        case "n", "north", "u", "up": .init(x: 0, y: -1)
        case "ne", "northeast": .init(x: 0.707, y: -0.707)
        case "e", "east": .init(x: 1, y: 0)
        case "se", "southeast": .init(x: 0.707, y: 0.707)
        case "s", "south", "d", "down": .init(x: 0, y: 1)
        case "sw", "southwest": .init(x: -0.707, y: 0.707)
        case "w", "west": .init(x: -1, y: 0)
        case "nw", "northwest": .init(x: -0.707, y: -0.707)
        default: nil
        }
    }
}

private extension Atlas.MapElement {
    var kind: AtlasObjectKind? {
        switch self {
        case .room: .room
        case .exit: .exit
        case .rectangle: .rectangle
        case .image: .image
        case .label: .label
        case .unknown: nil
        }
    }

    mutating func offset(dx: Double, dy: Double, snap: Double?) {
        func value(_ input: Double) -> Double {
            let moved = input
            guard let snap, snap > 0 else { return moved }
            return (moved / snap).rounded() * snap
        }
        switch self {
        case var .room(item):
            item.rect = item.rect.offsetBy(dx: dx, dy: dy)
            item.rect = .init(x1: value(item.rect.x1), y1: value(item.rect.y1), x2: value(item.rect.x2), y2: value(item.rect.y2))
            self = .room(item)
        case var .rectangle(item):
            item.rect = item.rect.offsetBy(dx: dx, dy: dy)
            item.rect = .init(x1: value(item.rect.x1), y1: value(item.rect.y1), x2: value(item.rect.x2), y2: value(item.rect.y2))
            self = .rectangle(item)
        case var .image(item):
            item.rect = item.rect.offsetBy(dx: dx, dy: dy)
            item.rect = .init(x1: value(item.rect.x1), y1: value(item.rect.y1), x2: value(item.rect.x2), y2: value(item.rect.y2))
            self = .image(item)
        case var .label(item):
            item.rect = item.rect.offsetBy(dx: dx, dy: dy)
            item.rect = .init(x1: value(item.rect.x1), y1: value(item.rect.y1), x2: value(item.rect.x2), y2: value(item.rect.y2))
            self = .label(item)
        case var .exit(item):
            item.points = item.points.map { .init(x: value($0.x + dx), y: value($0.y + dy)) }
            self = .exit(item)
        case .unknown: break
        }
    }

    var rect: Atlas.Rect? {
        switch self {
        case let .room(value): value.rect
        case let .rectangle(value): value.rect
        case let .image(value): value.rect
        case let .label(value): value.rect
        case .exit, .unknown: nil
        }
    }

    mutating func setRect(_ rect: Atlas.Rect) -> Bool {
        switch self {
        case var .room(value): value.rect = rect; self = .room(value)
        case var .rectangle(value): value.rect = rect; self = .rectangle(value)
        case var .image(value): value.rect = rect; self = .image(value)
        case var .label(value): value.rect = rect; self = .label(value)
        case .exit, .unknown: return false
        }
        return true
    }
}

public enum AtlasError: LocalizedError {
    case invalidXML
    case missingAtlasXML
    case archiveFailure(String)
    case unsafeResourcePath(String)

    public var errorDescription: String? {
        switch self {
        case .invalidXML: "The atlas file is not valid XML."
        case .missingAtlasXML: "The atlas archive does not contain Atlas.xml."
        case let .archiveFailure(message): "The atlas archive could not be read: \(message)"
        case let .unsafeResourcePath(path): "The atlas resource path is unsafe: \(path)"
        }
    }
}
