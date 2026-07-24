import BeipPersistence
import Foundation
import XCTest

final class Milestone9ContractTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixture: URL {
        repository.appendingPathComponent("Tests/Fixtures/M9")
    }

    private var windowsBaseline: URL {
        repository.appendingPathComponent("Documentation/Evidence/M9/win11-dev/baseline")
    }

    private var failedMacReloadCorpus: URL {
        repository.appendingPathComponent("Documentation/Evidence/M9/macos")
    }

    private var remediationCandidate: URL {
        repository.appendingPathComponent("Documentation/Evidence/M9/macos-reload-remediation")
    }

    private var failedWindowsReload: URL {
        repository.appendingPathComponent("Documentation/Evidence/M9/win11-dev/reload")
    }

    private var windowsRemediationOutput: URL {
        repository.appendingPathComponent(
            "Documentation/Evidence/M9/win11-dev/reload-remediation/post-reload"
        )
    }

    private var finalAcceptance: URL {
        repository.appendingPathComponent("Documentation/Evidence/M9/macos-final-acceptance")
    }

    func testSeedCorpusLoadsThroughProductionPersistenceAPIs() throws {
        let configURL = fixture.appendingPathComponent("seed/Config.txt")
        let source = try String(contentsOf: configURL, encoding: .utf8)
        let workspace = try LegacyConfigurationWorkspace(
            document: LegacyConfigurationDocument(source: source),
            sourceURL: configURL
        )
        XCTAssertEqual(workspace.servers.map(\.profile.name), ["Round Trip World", "Delete Me World"])
        XCTAssertEqual(workspace.servers[0].characters.map(\.name), ["Round Trip Hero"])
        XCTAssertEqual(workspace.servers[0].characters[0].puppets.map(\.name), ["Round Trip Puppet"])
        XCTAssertTrue(source.contains("M9UnknownPuppet=\"preserve-puppet-exactly\""))

        let archive = try AtlasReader.readArchive(from: fixture.appendingPathComponent("seed/RoundTrip.atlas"))
        XCTAssertEqual(archive.atlas.maps.map(\.name), ["Ground", "Upper"])
        XCTAssertEqual(archive.atlas.farExits.count, 1)
        XCTAssertEqual(archive.resources["assets/map-marker.svg"]?.prefix(4), Data("<svg".utf8))
        XCTAssertEqual(archive.atlas.unknownElements.first?.name, "m9_extension")

        let restore = try RestoreLogStore.load(
            from: fixture.appendingPathComponent("seed/Restore.dat"),
            bufferSize: 256
        )
        XCTAssertEqual(restore.count, 3)
        XCTAssertEqual(restore.map(\.count), [2, 2, 1])
        XCTAssertEqual(String(decoding: restore[1][1].payload, as: UTF8.self), "You see an observatory.\r\n")
    }

    func testOperationSetCoversEveryPortableScopeAndMutation() throws {
        let data = try Data(contentsOf: fixture.appendingPathComponent("operations.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let operations = try XCTUnwrap(root["operations"] as? [[String: Any]])
        let requiredActions = Set(["add", "update", "delete"])
        for scope in ["global", "world", "character", "puppet"] {
            let actions = Set(operations.compactMap {
                $0["scope"] as? String == scope ? $0["action"] as? String : nil
            })
            XCTAssertTrue(requiredActions.isSubset(of: actions), "\(scope) lacks portable mutations")
        }
        XCTAssertTrue(operations.contains { $0["scope"] as? String == "atlas" })
        XCTAssertTrue(operations.contains { $0["scope"] as? String == "restore" })
    }

    func testRemediationCandidateContainsEveryPortableEdit() throws {
        let configURL = remediationCandidate.appendingPathComponent("Config.txt")
        let configData = try Data(contentsOf: configURL)
        XCTAssertEqual(configData.filter { $0 == 0x0A }.count, configData.windows(of: [0x0D, 0x0A]).count)
        let source = try XCTUnwrap(String(data: configData, encoding: .utf8))
        let workspace = try LegacyConfigurationWorkspace(
            document: LegacyConfigurationDocument(source: source),
            sourceURL: configURL
        )
        let server = try XCTUnwrap(workspace.servers.first { $0.profile.name == "Round Trip World" })
        let character = try XCTUnwrap(server.characters.first { $0.name == "Round Trip Hero" })
        let puppet = try XCTUnwrap(character.puppets.first { $0.name == "Round Trip Puppet" })
        let worldScope = LegacyConfigurationWorkspace.AutomationScope.server(server.profile.id)
        let characterScope = LegacyConfigurationWorkspace.AutomationScope.character(
            server: server.profile.id,
            character: character.id
        )
        let puppetScope = LegacyConfigurationWorkspace.AutomationScope.puppet(
            server: server.profile.id,
            character: character.id,
            puppet: puppet.id
        )

        XCTAssertEqual(workspace.globalAliases.first { $0.description == "M9 global added" }?.replacement, "say global added")
        XCTAssertEqual(workspace.globalAliases.first { $0.description == "Global updated" }?.replacement, "say hello from macOS")
        XCTAssertFalse(workspace.globalAliases.contains { $0.description == "Global delete" })
        XCTAssertEqual(workspace.triggers(in: worldScope).first { $0.description == "M9 world added" }?.match.text, "WORLD:")
        XCTAssertEqual(try workspace.variables(in: worldScope)["world_update"], "mac-world")
        XCTAssertNil(try workspace.variables(in: worldScope)["world_delete"])
        let addedMacro = workspace.macros(in: characterScope).first { $0.description == "M9 character added" }
        XCTAssertEqual(addedMacro?.key, "Control+Alt+H")
        XCTAssertEqual(addedMacro?.macro, "health")
        XCTAssertEqual(addedMacro?.typeIntoInput, true)
        XCTAssertEqual(try workspace.variables(in: characterScope)["character_update"], "mac-character")
        XCTAssertNil(try workspace.variables(in: characterScope)["character_delete"])
        XCTAssertEqual(workspace.aliases(in: puppetScope).first { $0.description == "M9 puppet added" }?.replacement, "say guard new")
        XCTAssertEqual(workspace.aliases(in: puppetScope).first { $0.description == "Puppet updated" }?.replacement, "say guard mac")
        XCTAssertFalse(workspace.macros(in: puppetScope).contains { $0.description == "Puppet macro delete" })
        XCTAssertFalse(source.contains("keyEquivalents"))

        let archive = try AtlasReader.readArchive(from: remediationCandidate.appendingPathComponent("RoundTrip.atlas"))
        XCTAssertEqual(archive.atlas.maps.first { $0.name == "Ground" }?.rooms.map(\.name), ["Atrium", "Workshop — Mac Edit"])
        XCTAssertEqual(archive.atlas.unknownElements.first?.attributes["payload"], "preserve-unknown-xml")
        XCTAssertEqual(
            archive.resources["assets/map-marker.svg"],
            try AtlasReader.readArchive(from: windowsBaseline.appendingPathComponent("RoundTrip.atlas"))
                .resources["assets/map-marker.svg"]
        )

        let restore = try RestoreLogStore.load(
            from: remediationCandidate.appendingPathComponent("Restore.dat"),
            bufferSize: 256 * 1024
        )
        XCTAssertEqual(restore.count, 1)
        XCTAssertEqual(restore[0].last?.windowsFileTime, 133_984_368_000_000_000)
        XCTAssertEqual(String(decoding: restore[0].last?.payload ?? Data(), as: UTF8.self), "M9 macOS append\r\n")
    }

    func testRemediationCandidatePreservesEveryWindowsOnlyValueAndUntouchedFile() throws {
        let baseline = try String(
            contentsOf: windowsBaseline.appendingPathComponent("Config.txt"),
            encoding: .utf8
        )
        let edited = try String(
            contentsOf: remediationCandidate.appendingPathComponent("Config.txt"),
            encoding: .utf8
        )
        for marker in [
            "MDIPosition=(120,80,1280,760)",
            "Position=(120,80,1280,760)",
            "ActiveTab=1",
            "BytesSent=153",
            "BytesReceived=288",
            "SecondsConnected=78",
            "ConnectionCount=3",
            "LastUsed=2026-7-24-21-11-49-366",
            "Docking.ClientSize={1258,669}",
            "FileName=\"C:\\\\M9Audit\\\\RoundTrip.atlas\"",
            "Sound=\"C:\\\\M9Audit\\\\Assets\\\\notify.wav\"",
            "Password=\"fixture-only-password\"",
            "Connect=\"connect hero %PASSWORD%\"",
        ] {
            XCTAssertTrue(baseline.contains(marker), "baseline lacks \(marker)")
            XCTAssertTrue(edited.contains(marker), "Mac edit lost \(marker)")
        }
        for relative in [
            "Assets/marker.svg", "Assets/notify.wav", "Assets/roundtrip.js",
            "Logs/roundtrip.html", "Logs/seed.log",
        ] {
            XCTAssertEqual(
                try Data(contentsOf: windowsBaseline.appendingPathComponent(relative)),
                try Data(contentsOf: remediationCandidate.appendingPathComponent(relative)),
                relative
            )
        }
        XCTAssertEqual(
            try MacSidecarStore.load(from: remediationCandidate.appendingPathComponent("Config.mac.json")),
            MacConfigurationSidecar()
        )
    }

    func testAtlasArchiveWriterIsDeterministic() throws {
        let archive = try AtlasReader.readArchive(from: remediationCandidate.appendingPathComponent("RoundTrip.atlas"))
        let first = try AtlasWriter.archiveData(for: archive)
        let second = try AtlasWriter.archiveData(for: archive)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, try Data(contentsOf: remediationCandidate.appendingPathComponent("RoundTrip.atlas")))
    }

    func testRemediationConfigUsesOnlyV331LoadableSyntaxAndIntroducesNoDefaults() throws {
        let data = try Data(contentsOf: remediationCandidate.appendingPathComponent("Config.txt"))
        let source = try XCTUnwrap(String(data: data, encoding: .utf8))
        try assertV331LexicalKeys(source)

        XCTAssertTrue(source.contains("\"KeyboardMacros2\""))
        XCTAssertTrue(source.contains("key=Control+Alt+H"))
        XCTAssertFalse(source.contains("key=\"Control+Alt+H\""))
        for unsupportedOrUnwantedDefault in [
            "AIEndpoint=", "AIModel=", "GMCP_WebView=",
            "TCP_KeepAlive=", "TCP_NoDelay=",
            "ConnectTimeout=30000", "ConnectRetry=5", "RetryForever=false",
            "ScriptStartup=\"\"", "ScriptDebug=false",
            "Encoding=CP1252", "ConnectAtStartup=false", "IdleEnabled=false",
            "LogFileName=\"\"", "LogFileNameTimeFormat=0", "CharacterLogPrefix=\"\"",
            "RegularExpression=false", "MatchCase=false", "StartsWith=false",
            "EndsWith=false", "WholeWord=false",
        ] {
            XCTAssertFalse(
                source.contains(unsupportedOrUnwantedDefault),
                "introduced unsupported/default field \(unsupportedOrUnwantedDefault)"
            )
        }

        let parsed = try LegacyConfigurationDocument(source: source)
        let variableBlocks = blocks(named: "Variables", in: parsed.nodes)
        XCTAssertEqual(variableBlocks.count, 1)
        XCTAssertFalse(variableBlocks[0].contains {
            if case let .assignment(name, _, _, _) = $0 {
                return name.caseInsensitiveCompare("Active") == .orderedSame
            }
            return false
        })
        XCTAssertNotNil(parsed.value(at: [
            "Connections", "Shortcuts", "Round Trip World", "Host",
        ]))
    }

    func testNonDefaultFieldsWithV331SpecialCharactersAreQuoted() throws {
        var workspace = try LegacyConfigurationWorkspace(
            document: .init(source: """
            Version=331
            Connections
            {
              Shortcuts
              {
                World
                {
                  Host="example.test:8888"
                  Characters
                  {
                    Hero
                    {
                      Connect="connect hero"
                    }
                  }
                }
              }
            }
            """)
        )
        workspace.updateSettings {
            $0.tcpKeepAlive = false
            $0.tcpNoDelay = false
        }
        let serverID = try XCTUnwrap(workspace.servers.first?.profile.id)
        try workspace.updateServer(id: serverID) {
            $0.profile.gmcpWebViewPolicy = .allow
        }
        let rendered = try workspace.renderedDocument().serialized()
        XCTAssertTrue(rendered.contains("\"TCP_KeepAlive\"=false"))
        XCTAssertTrue(rendered.contains("\"TCP_NoDelay\"=false"))
        XCTAssertTrue(rendered.contains("\"GMCP_WebView\"=1"))
        try assertV331LexicalKeys(rendered.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    func testRestoreAppendTargetsAndSurvivesV331SelectedBuffer() throws {
        let config = try LegacyConfigurationProjection(document: .init(
            source: String(
                contentsOf: remediationCandidate.appendingPathComponent("Config.txt"),
                encoding: .utf8
            )
        ))
        let referenced = config.servers.flatMap { $0.restoreLogAssignments.keys }
        XCTAssertEqual(Set(referenced), Set([0]))
        XCTAssertEqual(
            RestoreLogStore.v331AppendBufferIndex(requestedIndex: 1, referencedIndices: referenced),
            0
        )

        let logs = try RestoreLogStore.load(
            from: remediationCandidate.appendingPathComponent("Restore.dat"),
            bufferSize: 256 * 1024
        )
        let selected = RestoreLogStore.simulatingV331Selection(logs, referencedIndices: referenced)
        XCTAssertEqual(selected.count, 1)
        XCTAssertTrue(selected[0].contains {
            String(decoding: $0.payload, as: UTF8.self) == "M9 macOS append\r\n"
        })

        let generationData = try Data(contentsOf: remediationCandidate.appendingPathComponent("generation.json"))
        let generation = try XCTUnwrap(JSONSerialization.jsonObject(with: generationData) as? [String: Any])
        let selections = try XCTUnwrap(generation["restoreSelections"] as? [[String: Any]])
        XCTAssertEqual(selections.first?["requestedBufferIndex"] as? Int, 1)
        XCTAssertEqual(selections.first?["v331RetainedBufferIndex"] as? Int, 0)
    }

    func testFailedSprint93LossesAreCorrectedWithoutAllowlisting() throws {
        let inventoryData = try Data(contentsOf: failedWindowsReload.appendingPathComponent("semantic-inventory.json"))
        let inventory = try XCTUnwrap(
            JSONSerialization.jsonObject(with: inventoryData) as? [String: Any]
        )
        let failures = try XCTUnwrap(inventory["failures"] as? [[String: Any]])
        XCTAssertEqual(
            Array(failures.compactMap { $0["id"] as? String }.prefix(3)),
            ["world-update-variable", "character-add-macro", "restore-append"]
        )
        XCTAssertEqual(try XCTUnwrap(inventory["unexplainedMutations"] as? [Any]).count, 0)

        let failedConfig = try String(
            contentsOf: failedWindowsReload.appendingPathComponent("post-reload/Config.txt"),
            encoding: .utf8
        )
        let fixedConfig = try String(
            contentsOf: remediationCandidate.appendingPathComponent("Config.txt"),
            encoding: .utf8
        )
        XCTAssertFalse(failedConfig.contains("Name=\"world_update\""))
        XCTAssertFalse(failedConfig.contains("Description=\"M9 character added\""))
        XCTAssertTrue(fixedConfig.contains("Name=\"world_update\""))
        XCTAssertTrue(fixedConfig.contains("Value=\"mac-world\""))
        XCTAssertTrue(fixedConfig.contains("Description=\"M9 character added\""))
        XCTAssertTrue(fixedConfig.contains("key=Control+Alt+H"))

        let failedRestore = try RestoreLogStore.load(
            from: failedWindowsReload.appendingPathComponent("post-reload/Restore.dat"),
            bufferSize: 256 * 1024
        )
        XCTAssertFalse(failedRestore.joined().contains {
            String(decoding: $0.payload, as: UTF8.self) == "M9 macOS append\r\n"
        })
        let candidateRestore = try RestoreLogStore.load(
            from: remediationCandidate.appendingPathComponent("Restore.dat"),
            bufferSize: 256 * 1024
        )
        XCTAssertTrue(candidateRestore.joined().contains {
            String(decoding: $0.payload, as: UTF8.self) == "M9 macOS append\r\n"
        })

        // The failed Sprint 9.2 input remains an immutable diagnostic input.
        XCTAssertTrue(
            try String(
                contentsOf: failedMacReloadCorpus.appendingPathComponent("Config.txt"),
                encoding: .utf8
            ).contains("GMCP_WebView=2")
        )
    }

    func testCandidateHasNoUnexplainedArtifactDifferences() throws {
        let expected = Set([
            "Assets/marker.svg", "Assets/notify.wav", "Assets/roundtrip.js",
            "Config.mac.json", "Config.txt", "generation.json",
            "Logs/roundtrip.html", "Logs/seed.log", "README.md", "SHA256SUMS",
            "Restore.dat", "RoundTrip.atlas", ".gitattributes",
        ])
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: remediationCandidate,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        let actual = Set(enumerator.compactMap { item -> String? in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            return String(url.path.dropFirst(remediationCandidate.path.count + 1))
        })
        XCTAssertEqual(actual, expected)

        for relative in [
            "Assets/marker.svg", "Assets/notify.wav", "Assets/roundtrip.js",
            "Logs/roundtrip.html", "Logs/seed.log",
        ] {
            XCTAssertEqual(
                try Data(contentsOf: remediationCandidate.appendingPathComponent(relative)),
                try Data(contentsOf: windowsBaseline.appendingPathComponent(relative)),
                "unexplained mutation in \(relative)"
            )
        }
    }

    func testWindowsResavedConfigPreservesPortableAndHostSpecificSemantics() throws {
        let outputURL = windowsRemediationOutput.appendingPathComponent("Config.txt")
        let outputData = try Data(contentsOf: outputURL)
        XCTAssertEqual(
            outputData.filter { $0 == 0x0A }.count,
            outputData.windows(of: [0x0D, 0x0A]).count,
            "the v331 resave introduced non-CRLF syntax"
        )
        let outputSource = try XCTUnwrap(String(data: outputData, encoding: .utf8))
        try assertV331LexicalKeys(outputSource)
        try assertPortableEdits(in: loadWorkspace(from: outputURL))

        for marker in [
            "MDIPosition=(120,80,1280,760)",
            "Position=(120,80,1280,760)",
            "ActiveTab=1",
            "Docking.ClientSize={1258,669}",
            "Password=\"fixture-only-password\"",
            "Connect=\"connect hero %PASSWORD%\"",
            "FileName=\"C:\\\\M9Audit\\\\RoundTrip.atlas\"",
            "Sound=\"C:\\\\M9Audit\\\\Assets\\\\notify.wav\"",
        ] {
            XCTAssertTrue(outputSource.contains(marker), "v331 resave lost \(marker)")
        }
        for unwanted in [
            "Description=\"Global delete\"",
            "Name=\"world_delete\"",
            "Name=\"character_delete\"",
            "Description=\"Puppet macro delete\"",
            "AIModel=",
            "GMCP_WebView=",
        ] {
            XCTAssertFalse(outputSource.contains(unwanted), "v331 resave introduced \(unwanted)")
        }
    }

    func testWindowsResavedAtlasAndUntouchedAssetsRemainExact() throws {
        let candidateAtlasURL = remediationCandidate.appendingPathComponent("RoundTrip.atlas")
        let outputAtlasURL = windowsRemediationOutput.appendingPathComponent("RoundTrip.atlas")
        XCTAssertEqual(
            try Data(contentsOf: outputAtlasURL),
            try Data(contentsOf: candidateAtlasURL),
            "v331 changed atlas archive bytes"
        )
        let candidateAtlas = try AtlasReader.readArchive(from: candidateAtlasURL)
        let outputAtlas = try AtlasReader.readArchive(from: outputAtlasURL)
        XCTAssertEqual(outputAtlas, candidateAtlas)
        XCTAssertEqual(
            outputAtlas.atlas.maps.first { $0.name == "Ground" }?.rooms.map(\.name),
            ["Atrium", "Workshop — Mac Edit"]
        )

        for relative in [
            "Assets/marker.svg", "Assets/notify.wav", "Assets/roundtrip.js",
            "Logs/roundtrip.html", "Logs/seed.log",
        ] {
            XCTAssertEqual(
                try Data(contentsOf: windowsRemediationOutput.appendingPathComponent(relative)),
                try Data(contentsOf: remediationCandidate.appendingPathComponent(relative)),
                "v331 changed untouched \(relative)"
            )
        }
    }

    func testWindowsResavedRestorePreservesAllInputRecordsAndAuditLogIsComplete() throws {
        let input = try RestoreLogStore.load(
            from: remediationCandidate.appendingPathComponent("Restore.dat"),
            bufferSize: 256 * 1024
        )
        let output = try RestoreLogStore.load(
            from: windowsRemediationOutput.appendingPathComponent("Restore.dat"),
            bufferSize: 256 * 1024
        )
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(input[0].count, 28)
        XCTAssertEqual(output[0].count, 65)
        XCTAssertEqual(Array(output[0].prefix(input[0].count)), input[0])
        XCTAssertTrue(output[0].contains {
            $0.windowsFileTime == 133_984_368_000_000_000
                && String(decoding: $0.payload, as: UTF8.self) == "M9 macOS append\r\n"
        })

        let auditLog = try String(
            contentsOf: windowsRemediationOutput.appendingPathComponent(
                "Logs/reload-remediation.html"
            ),
            encoding: .utf8
        )
        XCTAssertEqual(auditLog.components(separatedBy: "class='startlog'").count - 1, 1)
        XCTAssertEqual(auditLog.components(separatedBy: "class='stoplog'").count - 1, 1)
    }

    func testEveryRoundTripDifferenceUsesTheSprint94Vocabulary() throws {
        let data = try Data(
            contentsOf: finalAcceptance.appendingPathComponent("classified-differences.json")
        )
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let vocabulary = Set(try XCTUnwrap(document["classificationVocabulary"] as? [String]))
        XCTAssertEqual(vocabulary, Set([
            "intended portable edit",
            "documented Windows canonicalization",
            "allowed host-specific sidecar state",
            "failure",
        ]))

        let differences = try XCTUnwrap(
            document["currentRemediationDifferences"] as? [[String: Any]]
        )
        let ids = differences.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertTrue(differences.allSatisfy {
            guard let classification = $0["classification"] as? String else { return false }
            return vocabulary.contains(classification) && classification != "failure"
        })
        XCTAssertEqual(
            differences.filter {
                $0["classification"] as? String == "allowed host-specific sidecar state"
            }.compactMap { $0["id"] as? String },
            ["macos-config-sidecar"]
        )
        XCTAssertEqual(
            try XCTUnwrap(document["currentFailureOrUnexplainedDifferences"] as? [Any]).count,
            0
        )
    }
}

private extension Data {
    func windows(of bytes: [UInt8]) -> [Range<Data.Index>] {
        guard !bytes.isEmpty else { return [] }
        var result: [Range<Data.Index>] = []
        var cursor = startIndex
        while cursor < endIndex,
              let range = self[cursor...].range(of: Data(bytes)) {
            result.append(range)
            cursor = range.upperBound
        }
        return result
    }
}

private extension Milestone9ContractTests {
    func loadWorkspace(from configURL: URL) throws -> LegacyConfigurationWorkspace {
        try LegacyConfigurationWorkspace(
            document: LegacyConfigurationDocument(
                source: String(contentsOf: configURL, encoding: .utf8)
            ),
            sourceURL: configURL
        )
    }

    func assertPortableEdits(
        in workspace: LegacyConfigurationWorkspace,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let server = try XCTUnwrap(
            workspace.servers.first { $0.profile.name == "Round Trip World" },
            file: file,
            line: line
        )
        let character = try XCTUnwrap(
            server.characters.first { $0.name == "Round Trip Hero" },
            file: file,
            line: line
        )
        let puppet = try XCTUnwrap(
            character.puppets.first { $0.name == "Round Trip Puppet" },
            file: file,
            line: line
        )
        let worldScope = LegacyConfigurationWorkspace.AutomationScope.server(server.profile.id)
        let characterScope = LegacyConfigurationWorkspace.AutomationScope.character(
            server: server.profile.id,
            character: character.id
        )
        let puppetScope = LegacyConfigurationWorkspace.AutomationScope.puppet(
            server: server.profile.id,
            character: character.id,
            puppet: puppet.id
        )

        XCTAssertEqual(
            workspace.globalAliases.first { $0.description == "M9 global added" }?.replacement,
            "say global added",
            file: file,
            line: line
        )
        XCTAssertEqual(
            workspace.globalAliases.first { $0.description == "Global updated" }?.replacement,
            "say hello from macOS",
            file: file,
            line: line
        )
        XCTAssertFalse(
            workspace.globalAliases.contains { $0.description == "Global delete" },
            file: file,
            line: line
        )
        XCTAssertEqual(
            workspace.triggers(in: worldScope)
                .first { $0.description == "M9 world added" }?.match.text,
            "WORLD:",
            file: file,
            line: line
        )
        XCTAssertEqual(try workspace.variables(in: worldScope)["world_update"], "mac-world")
        XCTAssertNil(try workspace.variables(in: worldScope)["world_delete"])
        let macro = workspace.macros(in: characterScope)
            .first { $0.description == "M9 character added" }
        XCTAssertEqual(macro?.key, "Control+Alt+H", file: file, line: line)
        XCTAssertEqual(macro?.macro, "health", file: file, line: line)
        XCTAssertEqual(macro?.typeIntoInput, true, file: file, line: line)
        XCTAssertEqual(
            try workspace.variables(in: characterScope)["character_update"],
            "mac-character"
        )
        XCTAssertNil(try workspace.variables(in: characterScope)["character_delete"])
        XCTAssertEqual(
            workspace.aliases(in: puppetScope)
                .first { $0.description == "M9 puppet added" }?.replacement,
            "say guard new",
            file: file,
            line: line
        )
        XCTAssertEqual(
            workspace.aliases(in: puppetScope)
                .first { $0.description == "Puppet updated" }?.replacement,
            "say guard mac",
            file: file,
            line: line
        )
        XCTAssertFalse(
            workspace.macros(in: puppetScope)
                .contains { $0.description == "Puppet macro delete" },
            file: file,
            line: line
        )
    }

    func blocks(
        named name: String,
        in nodes: [LegacyConfigurationDocument.Node]
    ) -> [[LegacyConfigurationDocument.Node]] {
        nodes.flatMap { node -> [[LegacyConfigurationDocument.Node]] in
            guard case let .block(candidate, children, _, _) = node else { return [] }
            let match = candidate?.caseInsensitiveCompare(name) == .orderedSame ? [children] : []
            return match + blocks(named: name, in: children)
        }
    }

    func assertV331LexicalKeys(
        _ source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let lines = source.components(separatedBy: "\r\n")
        for (offset, rawLine) in lines.enumerated() {
            let text = rawLine.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text != "{", text != "}" else { continue }
            let key = text.split(separator: "=", maxSplits: 1).first.map(String.init) ?? text
            if key.first == "\"" {
                XCTAssertNotNil(
                    key.dropFirst().firstIndex(of: "\""),
                    "unterminated quoted v331 key on line \(offset + 1)",
                    file: file,
                    line: line
                )
            } else {
                XCTAssertTrue(
                    key.split(separator: ".").allSatisfy {
                        !$0.isEmpty && $0.unicodeScalars.allSatisfy {
                            (65...90).contains($0.value) || (97...122).contains($0.value)
                        }
                    },
                    "v331 requires non-letter keys to be quoted: \(key) on line \(offset + 1)",
                    file: file,
                    line: line
                )
            }
        }
    }
}
