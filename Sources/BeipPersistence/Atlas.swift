import Foundation

public struct Atlas: Sendable, Equatable {
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
        public var name: String?
        public var from: String?
        public var to: String?
        public var attributes: [String: String]
    }

    public struct Map: Sendable, Equatable {
        public var name: String
        public var rooms: [Room]
        public var exits: [Exit]
    }

    public var version: Int
    public var maps: [Map]
}

public enum AtlasReader {
    public static func read(from data: Data) throws -> Atlas {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? AtlasError.invalidXML
        }
        return Atlas(version: delegate.version, maps: delegate.maps)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var version = 1
        var maps: [Atlas.Map] = []

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName.lowercased() {
            case "atlas": version = Int(attributeDict["version"] ?? "1") ?? 1
            case "map": maps.append(.init(name: attributeDict["name"] ?? "Map", rooms: [], exits: []))
            case "room":
                guard !maps.isEmpty else { return }
                maps[maps.count - 1].rooms.append(.init(
                    name: attributeDict["name"] ?? "",
                    rect: .init(attributeDict["rect"] ?? "0,0,0,0"),
                    color: attributeDict["color"]
                ))
            case "exit":
                guard !maps.isEmpty else { return }
                maps[maps.count - 1].exits.append(.init(
                    name: attributeDict["name"],
                    from: attributeDict["from"],
                    to: attributeDict["to"],
                    attributes: attributeDict
                ))
            default: break
            }
        }
    }
}

public enum AtlasError: LocalizedError {
    case invalidXML
    public var errorDescription: String? { "The atlas file is not valid XML." }
}

