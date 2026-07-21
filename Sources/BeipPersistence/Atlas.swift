import Foundation

public struct Atlas: Sendable, Equatable {
    public struct Font: Sendable, Equatable {
        public var name: String
        public var size: Double

        public init(name: String, size: Double) {
            self.name = name
            self.size = size
        }
    }

    public struct Rect: Sendable, Equatable {
        public var x1: Double
        public var y1: Double
        public var x2: Double
        public var y2: Double

        public init(_ value: String) {
            let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            x1 = parts.indices.contains(0) ? parts[0] : 0
            y1 = parts.indices.contains(1) ? parts[1] : 0
            x2 = parts.indices.contains(2) ? parts[2] : 0
            y2 = parts.indices.contains(3) ? parts[3] : 0
        }
    }

    public struct Room: Sendable, Equatable {
        public var name: String
        public var rect: Rect
        public var color: String?
    }

    public struct Exit: Sendable, Equatable {
        public var nameFrom: String?
        public var nameTo: String?
        public var from: String?
        public var to: String?
        public var mapFrom: String?
        public var mapTo: String?
        public var points: [Point]
        public var attributes: [String: String]
    }

    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Rectangle: Sendable, Equatable {
        public var rect: Rect
        public var color: String?
        public var attributes: [String: String]
    }

    public struct Map: Sendable, Equatable {
        public var name: String
        public var rooms: [Room]
        public var exits: [Exit]
        public var rectangles: [Rectangle]
    }

    public var version: Int
    public var roomFont: Font?
    public var exitFont: Font?
    public var labelFont: Font?
    public var maps: [Map]
    public var farExits: [Exit]
}

public enum AtlasReader {
    public static func read(from url: URL) throws -> Atlas {
        let data = try Data(contentsOf: url)
        guard data.starts(with: [0x50, 0x4b]) else { return try read(from: data) }
        return try read(from: extractAtlasXML(from: url))
    }

    public static func read(from data: Data) throws -> Atlas {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? AtlasError.invalidXML
        }
        return Atlas(
            version: delegate.version,
            roomFont: delegate.roomFont,
            exitFont: delegate.exitFont,
            labelFont: delegate.labelFont,
            maps: delegate.maps,
            farExits: delegate.farExits
        )
    }

    private static func extractAtlasXML(from url: URL) throws -> Data {
        let listing = try runUnzip(arguments: ["-Z1", url.path])
        guard let entry = String(data: listing, encoding: .utf8)?
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .first(where: { URL(fileURLWithPath: $0).lastPathComponent.lowercased() == "atlas.xml" }) else {
            throw AtlasError.missingAtlasXML
        }
        return try runUnzip(arguments: ["-p", url.path, entry])
    }

    private static func runUnzip(arguments: [String]) throws -> Data {
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
        var version = 1
        var maps: [Atlas.Map] = []
        var roomFont: Atlas.Font?
        var exitFont: Atlas.Font?
        var labelFont: Atlas.Font?
        var farExits: [Atlas.Exit] = []
        var insideFarExits = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName.lowercased() {
            case "atlas": version = Int(attributeDict["version"] ?? "1") ?? 1
            case "font_rooms": roomFont = font(attributeDict)
            case "font_exits": exitFont = font(attributeDict)
            case "font_labels": labelFont = font(attributeDict)
            case "map": maps.append(.init(name: attributeDict["name"] ?? "Map", rooms: [], exits: [], rectangles: []))
            case "room":
                guard !maps.isEmpty else { return }
                maps[maps.count - 1].rooms.append(.init(
                    name: attributeDict["name"] ?? "",
                    rect: .init(attributeDict["rect"] ?? "0,0,0,0"),
                    color: attributeDict["color"]
                ))
            case "exit":
                let value = exit(attributeDict)
                if insideFarExits { farExits.append(value) }
                else if !maps.isEmpty { maps[maps.count - 1].exits.append(value) }
            case "rectangle":
                guard !maps.isEmpty else { return }
                maps[maps.count - 1].rectangles.append(.init(
                    rect: .init(attributeDict["rect"] ?? "0,0,0,0"),
                    color: attributeDict["color"],
                    attributes: attributeDict
                ))
            case "far_exits": insideFarExits = true
            default: break
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            if elementName.caseInsensitiveCompare("far_exits") == .orderedSame { insideFarExits = false }
        }

        private func font(_ attributes: [String: String]) -> Atlas.Font {
            .init(name: attributes["name"] ?? "Arial", size: Double(attributes["size"] ?? "9") ?? 9)
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
                attributes: attributes
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
    }
}

public enum AtlasError: LocalizedError {
    case invalidXML
    case missingAtlasXML
    case archiveFailure(String)
    public var errorDescription: String? {
        switch self {
        case .invalidXML: "The atlas file is not valid XML."
        case .missingAtlasXML: "The atlas archive does not contain Atlas.xml."
        case let .archiveFailure(message): "The atlas archive could not be read: \(message)"
        }
    }
}
