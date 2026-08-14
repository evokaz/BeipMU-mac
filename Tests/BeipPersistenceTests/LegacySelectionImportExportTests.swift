import BeipPersistence
import Foundation
import XCTest

final class LegacySelectionImportExportTests: XCTestCase {
    func testWindowsTriggerGoldenRoundTripsAsOneRawGlobalItem() throws {
        let source = try String(
            contentsOf: LegacyConfigurationTestSupport.fixtureURL("windows-v331-trigger-export.txt"),
            encoding: .utf8
        )
        let importedDocument = try LegacyConfigurationDocument(source: source)
        let imported = try LegacyConfigurationWorkspace(document: importedDocument)
        XCTAssertEqual(imported.globalTriggers.count, 1)

        let exported = try imported.exportAutomation(
            kind: .triggers,
            selection: .item(.init(scope: .global, path: [0]))
        )
        let text = exported.serialized()
        XCTAssertTrue(text.contains("\"UseIndent_Left\"=true"))
        XCTAssertTrue(text.contains("Filter.Replace=\"<b>$2</b>\""))
        XCTAssertTrue(text.contains("Fore=RGB(12,34,56)"))
        XCTAssertTrue(text.contains("Paragraph"))
        XCTAssertTrue(text.contains("Spawn"))
        XCTAssertTrue(text.contains("child\\\\s+pattern"))
        XCTAssertFalse(text.contains("Shortcuts"))
        XCTAssertEqual(exported.namedBlockNames(at: ["Connections"]), ["Triggers"])
        XCTAssertEqual(exported.rawUnnamedBlockSources(at: ["Connections", "Triggers"]).count, 1)

        var target = try LegacyConfigurationWorkspace.empty()
        let result = try target.importAutomation(
            from: exported,
            kind: .triggers,
            destination: .scope(.global)
        )
        XCTAssertEqual(result.paths, [[0]])
        let reexported = try target.exportAutomation(
            kind: .triggers,
            selection: .item(.init(scope: .global, path: [0]))
        ).serialized()
        XCTAssertTrue(reexported.contains("\"UseIndent_Left\"=true"))
        XCTAssertTrue(reexported.contains("Triggers.Active=false"))
    }

    func testAliasAndMacroRawFoldersRoundTripAndImportPlacement() throws {
        let source = try LegacyConfigurationDocument(source: """
        Version=331
        Connections {
          Aliases {
            { Description="Existing" FindString.MatchText="x" }
            { Description="Folder" Folder=true Vendor="alias-vendor"
              Aliases { Active=false { Description="Child" Replace="north" FindString.MatchText="n" } }
            }
          }
          KeyboardMacros2 {
            { Description="Macro folder" Folder=true Vendor="macro-vendor"
              KeyboardMacros2 { Active=false { Description="Child macro" Macro="look" key=F1 } }
            }
          }
        }
        """)
        let workspace = try LegacyConfigurationWorkspace(document: source)
        let aliasExport = try workspace.exportAutomation(
            kind: .aliases,
            selection: .item(.init(scope: .global, path: [1]))
        )
        XCTAssertTrue(aliasExport.serialized().contains("Vendor=\"alias-vendor\""))
        XCTAssertTrue(aliasExport.serialized().contains("Aliases { Active=false"))
        let macroExport = try workspace.exportAutomation(
            kind: .macros,
            selection: .item(.init(scope: .global, path: [0]))
        )
        XCTAssertTrue(macroExport.serialized().contains("Vendor=\"macro-vendor\""))

        var destination = try LegacyConfigurationWorkspace(document: source)
        let after = try destination.importAutomation(
            from: aliasExport,
            kind: .aliases,
            destination: .afterItem(.init(scope: .global, path: [0]))
        )
        XCTAssertEqual(after.paths, [[1]])
        XCTAssertEqual(destination.alias(at: [1], in: .global)?.description, "Folder 2")
        XCTAssertEqual(destination.alias(at: [1, 0], in: .global)?.description, "Child")

        let inside = try destination.importAutomation(
            from: aliasExport,
            kind: .aliases,
            destination: .folder(.init(scope: .global, path: [2]))
        )
        XCTAssertEqual(inside.paths, [[2, 1]])
    }

    func testContextualScopeExportsPopulateOnlySelectedAutomationScope() throws {
        let workspace = try makeHierarchyWorkspace()
        let world = try XCTUnwrap(workspace.servers.first)
        let character = try XCTUnwrap(world.characters.first)
        _ = try XCTUnwrap(character.puppets.first)
        let scope: LegacyConfigurationWorkspace.AutomationScope = .character(
            server: world.profile.id,
            character: character.id
        )
        let exported = try workspace.exportAutomation(kind: .triggers, selection: .scope(scope))
        let text = exported.serialized()
        XCTAssertTrue(text.contains("Character trigger"))
        XCTAssertFalse(text.contains("Global trigger"))
        XCTAssertFalse(text.contains("World trigger"))
        XCTAssertFalse(text.contains("Puppet trigger"))
        XCTAssertFalse(text.contains("Character alias"))
        XCTAssertTrue(text.contains("CharacterUnknown=\"keep\""))
        XCTAssertTrue(text.contains("PuppetUnknown=\"keep\""))

        let parsed = try LegacyConfigurationWorkspace(document: exported)
        let parsedWorld = try XCTUnwrap(parsed.servers.first)
        let parsedCharacter = try XCTUnwrap(parsedWorld.characters.first)
        let parsedPuppet = try XCTUnwrap(parsedCharacter.puppets.first)
        XCTAssertTrue(parsed.triggers(in: .server(parsedWorld.profile.id)).isEmpty)
        XCTAssertEqual(
            parsed.triggers(in: .character(server: parsedWorld.profile.id, character: parsedCharacter.id)).map(\.description),
            ["Character trigger"]
        )
        XCTAssertTrue(parsed.triggers(in: .puppet(
            server: parsedWorld.profile.id,
            character: parsedCharacter.id,
            puppet: parsedPuppet.id
        )).isEmpty)
    }

    func testProfileSelectionsPreserveRawHierarchyAndExcludeSiblings() throws {
        let workspace = try makeHierarchyWorkspace()
        let world = try XCTUnwrap(workspace.servers.first)
        let character = try XCTUnwrap(world.characters.first)
        let puppet = try XCTUnwrap(character.puppets.first)

        let worldExport = try workspace.exportProfileHierarchy(.world(world.profile.id)).serialized()
        XCTAssertTrue(worldExport.contains("Sibling"))
        XCTAssertTrue(worldExport.contains("World trigger"))
        XCTAssertFalse(worldExport.contains("Global trigger"))
        XCTAssertFalse(worldExport.contains("TaskbarOnTop"))

        let characterExport = try workspace.exportProfileHierarchy(
            .character(world: world.profile.id, character: character.id)
        ).serialized()
        XCTAssertFalse(characterExport.contains("Sibling"))
        XCTAssertFalse(characterExport.contains("World trigger"))
        XCTAssertTrue(characterExport.contains("Character trigger"))
        XCTAssertTrue(characterExport.contains("Puppet trigger"))

        let puppetExport = try workspace.exportProfileHierarchy(
            .puppet(world: world.profile.id, character: character.id, puppet: puppet.id)
        ).serialized()
        XCTAssertFalse(puppetExport.contains("World trigger"))
        XCTAssertFalse(puppetExport.contains("Character trigger"))
        XCTAssertTrue(puppetExport.contains("Puppet trigger"))
        XCTAssertTrue(puppetExport.contains("Password=\"secret\""))
    }

    func testContextualImportMergesParentsAndRejectsAmbiguousDocumentsAtomically() throws {
        let source = try makeHierarchyWorkspace()
        let world = try XCTUnwrap(source.servers.first)
        let contextual = try source.exportAutomation(
            kind: .triggers,
            selection: .scope(.server(world.profile.id))
        )

        var target = try LegacyConfigurationWorkspace(document: .init(source: """
        Version=331
        Connections { Shortcuts { WORLD { Host="existing.example:9999" Triggers { { Description="World trigger" } } } } }
        """))
        let imported = try target.importAutomation(
            from: contextual,
            kind: .triggers,
            destination: .scope(.global)
        )
        let targetWorld = try XCTUnwrap(target.servers.first)
        XCTAssertEqual(targetWorld.profile.host, "existing.example")
        XCTAssertEqual(target.triggers(in: .server(targetWorld.profile.id)).map(\.description), ["World trigger", "World trigger 2"])
        XCTAssertEqual(imported.scope, .server(targetWorld.profile.id))
        XCTAssertFalse(targetWorld.characters.isEmpty)

        let ambiguous = try LegacyConfigurationDocument(source: """
        Version=331
        Connections { Shortcuts {
          One { Host="one:1" Triggers { { Description="One" } } }
          Two { Host="two:2" Triggers { { Description="Two" } } }
        } }
        """)
        let before = target.document.serialized()
        XCTAssertThrowsError(try target.importAutomation(
            from: ambiguous,
            kind: .triggers,
            destination: .scope(.global)
        )) { error in
            XCTAssertEqual(error as? LegacyConfigurationWorkspace.WorkspaceError, .multipleContextualScopes)
        }
        XCTAssertEqual(target.document.serialized(), before)

        XCTAssertThrowsError(try target.mergeProfileHierarchy(from: ambiguous)) { error in
            XCTAssertEqual(error as? LegacyConfigurationWorkspace.WorkspaceError, .multipleWorlds)
        }
        XCTAssertEqual(target.document.serialized(), before)
    }

    private func makeHierarchyWorkspace() throws -> LegacyConfigurationWorkspace {
        try LegacyConfigurationWorkspace(document: .init(source: """
        Version=331
        TaskbarOnTop=false
        Connections {
          Triggers { { Description="Global trigger" FindString.MatchText="global" } }
          Shortcuts {
            World {
              Host="world.example:8888"
              WorldUnknown="keep"
              Triggers { { Description="World trigger" FindString.MatchText="world" } }
              Characters {
                Hero {
                  Password="secret"
                  CharacterUnknown="keep"
                  Aliases { { Description="Character alias" FindString.MatchText="c" } }
                  Triggers { { Description="Character trigger" FindString.MatchText="character" } }
                  Puppets {
                    Scout {
                      ReceivePrefix="Scout> "
                      PuppetUnknown="keep"
                      Triggers { { Description="Puppet trigger" FindString.MatchText="puppet" } }
                    }
                  }
                }
                Sibling { Password="other" }
              }
            }
          }
        }
        """))
    }
}
