import BeipAutomation
import BeipCore
import BeipPersistence
import Foundation
import XCTest

final class WindowsAICompatibilityTests: XCTestCase {
    func testV332WindowsAISettingsProjectAndSurviveWorldAndTriggerEdits() throws {
        let source = try String(
            contentsOf: LegacyConfigurationTestSupport.fixtureURL("v332-ai-config.txt"),
            encoding: .utf8
        )
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))

        XCTAssertEqual(workspace.projection.sourceVersion, 332)
        XCTAssertEqual(workspace.projection.globalAI.server, "localhost:11434")
        XCTAssertEqual(workspace.projection.globalAI.model, "llama3.2")
        XCTAssertTrue(workspace.checkForUpdates)

        let world = try XCTUnwrap(workspace.servers.first)
        try workspace.updateServer(id: world.profile.id) {
            $0.profile.host = "changed.example:7777"
        }
        var trigger = try XCTUnwrap(workspace.globalTriggers.first)
        trigger.description = "Edited trigger"
        try workspace.updateTrigger(at: 0, in: .global, trigger: trigger)

        let saved = try workspace.renderedDocument()
        XCTAssertEqual(saved.value(at: ["Version"]), "332")
        XCTAssertEqual(saved.value(at: ["AI", "Server"]), "localhost:11434")
        XCTAssertEqual(saved.value(at: ["AI", "Model"]), "llama3.2")
        XCTAssertEqual(saved.value(at: ["CheckForUpdates"]), "true")
        XCTAssertEqual(saved.value(at: ["DockedCaptionFontName"]), "Segoe UI")
        XCTAssertEqual(saved.value(at: ["DockedCaptionHeight"]), "24")
        XCTAssertEqual(saved.value(at: ["FutureRoot"]), "preserve root extension")
        XCTAssertEqual(saved.value(at: ["Connections", "FutureConnections"]), "preserve connection extension")
        XCTAssertEqual(
            saved.value(at: ["Connections", "Shortcuts", "LambdaMOO", "FutureWorld"]),
            "preserve world extension"
        )
        XCTAssertEqual(
            saved.value(at: ["Connections", "Shortcuts", "LambdaMOO", "Characters", "Guest", "FutureCharacter"]),
            "preserve character extension"
        )
        XCTAssertTrue(saved.serialized().contains("FutureTrigger=\"preserve trigger extension\""))
        XCTAssertTrue(saved.serialized().contains("Description=\"Edited trigger\""))
        XCTAssertNil(saved.value(at: ["Connections", "Shortcuts", "LambdaMOO", "AIEndpoint"]))
        XCTAssertNil(saved.value(at: ["Connections", "Shortcuts", "LambdaMOO", "AIModel"]))
    }

    func testNewConfigurationsAndExportsUseV332() throws {
        let empty = try LegacyConfigurationWorkspace.empty()
        XCTAssertEqual(try empty.renderedDocument().value(at: ["Version"]), "332")

        let source = try String(
            contentsOf: LegacyConfigurationTestSupport.fixtureURL("v332-ai-config.txt"),
            encoding: .utf8
        )
        let workspace = try LegacyConfigurationWorkspace(document: .init(source: source))
        let world = try XCTUnwrap(workspace.servers.first)
        let profileExport = try workspace.exportProfileHierarchy(.world(world.profile.id))
        XCTAssertEqual(profileExport.value(at: ["Version"]), "332")

        let automationExport = try workspace.exportAutomation(
            kind: .triggers,
            selection: .item(.init(scope: .global, path: [0]))
        )
        XCTAssertEqual(automationExport.value(at: ["Version"]), "332")
    }

    func testV332WorldHierarchyImportsWithoutDroppingWindowsFields() throws {
        let source = try String(
            contentsOf: LegacyConfigurationTestSupport.fixtureURL("v332-ai-config.txt"),
            encoding: .utf8
        )
        var destination = try LegacyConfigurationWorkspace.empty()
        _ = try destination.mergeProfileHierarchy(from: .init(source: source))

        let imported = try destination.renderedDocument()
        XCTAssertEqual(imported.value(at: ["Version"]), "332")
        XCTAssertEqual(
            imported.value(at: ["Connections", "Shortcuts", "LambdaMOO", "FutureWorld"]),
            "preserve world extension"
        )
        XCTAssertEqual(
            imported.value(at: ["Connections", "Shortcuts", "LambdaMOO", "Characters", "Guest", "FutureCharacter"]),
            "preserve character extension"
        )
    }

    func testWindowsGlobalAIProvidesOllamaDefaultsAndWorldSettingsOverride() throws {
        let global = AIConfiguration.resolve(
            worldEndpoint: nil,
            worldModel: "",
            globalOllamaServer: "localhost:11434",
            globalModel: "llama3.2"
        )
        XCTAssertEqual(global, .init(backend: .ollama(server: "localhost:11434"), model: "llama3.2"))

        let worldEndpoint = try XCTUnwrap(URL(string: "https://ai.example.test/generate"))
        let world = AIConfiguration.resolve(
            worldEndpoint: worldEndpoint,
            worldModel: "world-model",
            globalOllamaServer: "localhost:11434",
            globalModel: "llama3.2"
        )
        XCTAssertEqual(world, .init(backend: .providerNeutral(endpoint: worldEndpoint), model: "world-model"))

        let worldEndpointWithGlobalModel = AIConfiguration.resolve(
            worldEndpoint: worldEndpoint,
            worldModel: " ",
            globalOllamaServer: "localhost:11434",
            globalModel: "llama3.2"
        )
        XCTAssertEqual(worldEndpointWithGlobalModel.model, "llama3.2")
    }

    func testOllamaAddressBuildsGenerateEndpointAndDecodesResponse() throws {
        XCTAssertEqual(
            try AIClient.ollamaGenerateEndpoint(for: "localhost:11434").absoluteString,
            "http://localhost:11434/api/generate"
        )
        XCTAssertEqual(
            try AIClient.ollamaGenerateEndpoint(for: "https://ollama.example.test/ollama/").absoluteString,
            "https://ollama.example.test/ollama/api/generate"
        )
        XCTAssertEqual(AIClient.decodeText(Data(#"{"response":"generated text","done":true}"#.utf8)), "generated text")
        XCTAssertThrowsError(try AIClient.ollamaGenerateEndpoint(for: "ftp://localhost:11434")) {
            XCTAssertEqual($0 as? AIClientError, .invalidEndpoint)
        }
    }
}
