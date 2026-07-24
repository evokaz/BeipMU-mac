import BeipAutomation
import BeipPersistence
import Foundation

private struct OperationFile: Decodable {
    var schemaVersion: Int
    var id: String
    var operations: [Operation]
}

private struct Operation: Decodable {
    struct Selector: Decodable {
        var description: String?
        var name: String?
        var map: String?
    }

    struct Effect: Decodable {
        var type: String
        var value: String
    }

    struct Record: Decodable {
        var type: String
        var windowsFileTime: UInt64
        var payloadUTF8: String
    }

    var id: String
    var artifact: String
    var scope: String
    var owner: [String]?
    var action: String
    var kind: String
    var description: String?
    var match: String?
    var replacement: String?
    var selector: Selector?
    var effect: Effect?
    var value: String?
    var key: String?
    var typeIntoInput: Bool?
    var name: String?
    var bufferIndex: Int?
    var record: Record?
}

private enum ToolError: LocalizedError {
    case usage
    case outputExists(String)
    case missingOwner(String)
    case unsupportedOperation(String)
    case selectorNotFound(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "usage: BeipM9PortableEdits <windows-baseline-directory> <operations.json> <output-directory>"
        case let .outputExists(path):
            "output directory already exists: \(path)"
        case let .missingOwner(operation):
            "operation \(operation) has no matching owner"
        case let .unsupportedOperation(operation):
            "operation \(operation) is unsupported"
        case let .selectorNotFound(operation):
            "operation \(operation) did not match its required selector"
        }
    }
}

@main
private enum M9PortableEdits {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { throw ToolError.usage }
        let baseline = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let operationsURL = URL(fileURLWithPath: arguments[2])
        let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: output.path) else { throw ToolError.outputExists(output.path) }
        try manager.createDirectory(at: output, withIntermediateDirectories: true)
        for source in try manager.contentsOfDirectory(
            at: baseline,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) where source.lastPathComponent != "Config.txt" {
            try manager.copyItem(at: source, to: output.appendingPathComponent(source.lastPathComponent))
        }

        let decoder = JSONDecoder()
        let operationFile = try decoder.decode(OperationFile.self, from: Data(contentsOf: operationsURL))
        let configOperations = operationFile.operations.filter { $0.artifact == "config" }
        let configURL = output.appendingPathComponent("Config.txt")
        let baselineStore = LegacyConfigurationStore(url: baseline.appendingPathComponent("Config.txt"))
        let document = try await baselineStore.load()
        var workspace = try LegacyConfigurationWorkspace(document: document, sourceURL: configURL)
        for operation in configOperations {
            try apply(operation, to: &workspace)
        }
        let rendered = try workspace.renderedDocument()
        try await LegacyConfigurationStore(url: configURL).save(rendered)
        let referencedRestoreIndices = workspace.projection.servers.flatMap {
            $0.restoreLogAssignments.keys
        }

        var archive = try AtlasReader.readArchive(from: output.appendingPathComponent("RoundTrip.atlas"))
        for operation in operationFile.operations where operation.artifact == "atlas" {
            guard operation.action == "update", operation.kind == "room",
                  let mapName = operation.selector?.map,
                  let roomName = operation.selector?.name,
                  let replacement = operation.name,
                  let mapIndex = archive.atlas.maps.firstIndex(where: {
                      $0.name.caseInsensitiveCompare(mapName) == .orderedSame
                  }),
                  let roomIndex = archive.atlas.maps[mapIndex].rooms.firstIndex(where: {
                      $0.name.caseInsensitiveCompare(roomName) == .orderedSame
                  }) else {
                throw ToolError.selectorNotFound(operation.id)
            }
            var editor = AtlasEditor(atlas: archive.atlas)
            editor.renameRoom(at: .init(mapIndex: mapIndex, roomIndex: roomIndex), to: replacement)
            archive.atlas = editor.atlas
        }
        try AtlasWriter.write(archive, to: output.appendingPathComponent("RoundTrip.atlas"))

        let restoreURL = output.appendingPathComponent("Restore.dat")
        let bufferSize = 256 * 1024
        var logs = try RestoreLogStore.load(from: restoreURL, bufferSize: bufferSize)
        var restoreSelections: [[String: Any]] = []
        for operation in operationFile.operations where operation.artifact == "restore" {
            guard operation.action == "append", operation.kind == "record",
                  let requestedBufferIndex = operation.bufferIndex,
                  let record = operation.record,
                  record.type == "received" else {
                throw ToolError.unsupportedOperation(operation.id)
            }
            guard let bufferIndex = RestoreLogStore.v331AppendBufferIndex(
                requestedIndex: requestedBufferIndex,
                referencedIndices: referencedRestoreIndices
            ) else {
                throw ToolError.unsupportedOperation("\(operation.id): no v331-referenced restore buffer")
            }
            while logs.count <= bufferIndex { logs.append([]) }
            logs[bufferIndex].append(.init(
                kind: .received,
                windowsFileTime: record.windowsFileTime,
                payload: Data(record.payloadUTF8.utf8)
            ))
            restoreSelections.append([
                "operationId": operation.id,
                "requestedBufferIndex": requestedBufferIndex,
                "v331RetainedBufferIndex": bufferIndex,
            ])
        }
        try RestoreLogStore.save(logs, to: restoreURL, bufferSize: bufferSize)
        try MacSidecarStore.save(.init(), to: output.appendingPathComponent("Config.mac.json"))

        let result: [String: Any] = [
            "schemaVersion": operationFile.schemaVersion,
            "operationSet": operationFile.id,
            "appliedOperationIds": operationFile.operations.map(\.id),
            "restoreBufferSize": bufferSize,
            "restoreBufferCount": logs.count,
            "restoreSelections": restoreSelections,
        ]
        let resultData = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try resultData.write(to: output.appendingPathComponent("generation.json"), options: .atomic)
    }

    private static func apply(
        _ operation: Operation,
        to workspace: inout LegacyConfigurationWorkspace
    ) throws {
        let scope = try automationScope(for: operation, in: workspace)
        switch (operation.action, operation.kind) {
        case ("add", "alias"):
            _ = try workspace.addAlias(
                in: scope,
                description: operation.description ?? "",
                match: .init(text: operation.match ?? ""),
                replacement: operation.replacement ?? ""
            )
        case ("update", "alias"):
            guard let index = workspace.aliases(in: scope).firstIndex(where: {
                $0.description == operation.selector?.description
            }) else { throw ToolError.selectorNotFound(operation.id) }
            try workspace.updateAlias(
                at: index,
                in: scope,
                description: operation.description ?? "",
                match: .init(text: operation.match ?? ""),
                replacement: operation.replacement ?? ""
            )
        case ("delete", "alias"):
            guard let index = workspace.aliases(in: scope).firstIndex(where: {
                $0.description == operation.selector?.description
            }) else { throw ToolError.selectorNotFound(operation.id) }
            try workspace.removeAutomationEntry(at: index, in: scope, kind: .aliases)
        case ("add", "trigger"):
            guard operation.effect?.type == "send" else { throw ToolError.unsupportedOperation(operation.id) }
            _ = try workspace.addTrigger(
                in: scope,
                description: operation.description ?? "",
                match: .init(text: operation.match ?? ""),
                action: .send(operation.effect?.value ?? "")
            )
        case ("add", "macro"):
            _ = try workspace.addMacro(
                in: scope,
                description: operation.description ?? "",
                key: operation.key ?? "",
                macro: operation.value ?? "",
                typeIntoInput: operation.typeIntoInput ?? false
            )
        case ("delete", "macro"):
            if let index = workspace.macros(in: scope).firstIndex(where: {
                $0.description == operation.selector?.description
            }) {
                try workspace.removeAutomationEntry(at: index, in: scope, kind: .macros)
            }
        case ("update", "variable"):
            guard let name = operation.selector?.name, let value = operation.value else {
                throw ToolError.unsupportedOperation(operation.id)
            }
            try workspace.setVariable(named: name, value: value, in: scope)
        case ("delete", "variable"):
            guard let name = operation.selector?.name else { throw ToolError.unsupportedOperation(operation.id) }
            _ = try workspace.removeVariable(named: name, in: scope)
        default:
            throw ToolError.unsupportedOperation(operation.id)
        }
    }

    private static func automationScope(
        for operation: Operation,
        in workspace: LegacyConfigurationWorkspace
    ) throws -> LegacyConfigurationWorkspace.AutomationScope {
        let owner = operation.owner ?? []
        switch operation.scope {
        case "global":
            return .global
        case "world":
            guard let server = workspace.servers.first(where: { $0.profile.name == owner.first }) else {
                throw ToolError.missingOwner(operation.id)
            }
            return .server(server.profile.id)
        case "character":
            guard owner.count == 2,
                  let server = workspace.servers.first(where: { $0.profile.name == owner[0] }),
                  let character = server.characters.first(where: { $0.name == owner[1] }) else {
                throw ToolError.missingOwner(operation.id)
            }
            return .character(server: server.profile.id, character: character.id)
        case "puppet":
            guard owner.count == 3,
                  let server = workspace.servers.first(where: { $0.profile.name == owner[0] }),
                  let character = server.characters.first(where: { $0.name == owner[1] }),
                  let puppet = character.puppets.first(where: { $0.name == owner[2] }) else {
                throw ToolError.missingOwner(operation.id)
            }
            return .puppet(server: server.profile.id, character: character.id, puppet: puppet.id)
        default:
            throw ToolError.unsupportedOperation(operation.id)
        }
    }
}
