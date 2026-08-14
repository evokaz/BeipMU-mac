import BeipCore
import BeipAutomation
import BeipPersistence
import Foundation
import XCTest

final class LegacyAutomationWorkspaceTests: XCTestCase {
    func testEditableWorkspaceAddsUpdatesAndRemovesGlobalAutomation() throws {
        var workspace = try LegacyConfigurationWorkspace.empty()
        let alias = try workspace.addGlobalAlias(
            description: "Go north",
            match: .init(text: "n", startsWith: true),
            replacement: "north"
        )
        let trigger = try workspace.addGlobalTrigger(
            description: "Score",
            match: .init(text: "score", matchCase: true),
            action: .send("score")
        )
        let macro = try workspace.addGlobalMacro(
            description: "Quick score",
            key: "Control+Alt+S",
            macro: "score",
            typeIntoInput: true
        )
        try workspace.updateGlobalMacro(
            at: macro,
            description: "Quick inventory",
            key: "Control+Alt+I",
            macro: "inventory",
            typeIntoInput: false
        )
        try workspace.updateGlobalAlias(
            at: alias,
            description: "Go south",
            match: .init(text: "s", startsWith: true),
            replacement: "south"
        )
        try workspace.updateGlobalTrigger(
            at: trigger,
            description: "Hide score",
            match: .init(text: "score"),
            action: .gag(display: true, log: true)
        )

        XCTAssertEqual(workspace.globalAliases.map(\.description), ["Go south"])
        XCTAssertEqual(workspace.globalAliases.first?.replacement, "south")
        XCTAssertEqual(workspace.globalTriggers.map(\.description), ["Hide score"])
        XCTAssertTrue(workspace.globalTriggers.first?.actions.contains(.gag(display: true, log: true)) == true)
        XCTAssertEqual(workspace.globalMacros.first?.description, "Quick inventory")
        XCTAssertEqual(workspace.globalMacros.first?.key, "Control+Alt+I")
        XCTAssertEqual(workspace.globalMacros.first?.macro, "inventory")
        XCTAssertFalse(workspace.globalMacros.first?.typeIntoInput == true)

        try workspace.removeGlobalAlias(at: alias)
        try workspace.removeGlobalTrigger(at: trigger)
        try workspace.removeGlobalMacro(at: macro)
        XCTAssertTrue(workspace.globalAliases.isEmpty)
        XCTAssertTrue(workspace.globalTriggers.isEmpty)
        XCTAssertTrue(workspace.globalMacros.isEmpty)
    }

    func testKeyboardMacroNestedCRUDMovesAndRawImportExport() throws {
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: """
        Version=331
        Connections {
          KeyboardMacros2 { Active=true
            // retained macro comment
            { Description="Folder" Folder=true Custom="keep"
              KeyboardMacros2 { Active=true
                { Description="Child" Macro="north" key=?Control+Alt+N Type=true Unknown="keep" }
              }
            }
            { Description="Second" Macro="south" key=F1 }
          }
        }
        """))

        XCTAssertEqual(workspace.macro(at: [0, 0], in: .global)?.macro, "north")
        let indented = try workspace.indentMacro(at: [1], in: .global)
        XCTAssertEqual(indented, [0, 1])
        XCTAssertEqual(workspace.macro(at: indented, in: .global)?.description, "Second")
        let outdented = try workspace.outdentMacro(at: indented, in: .global)
        XCTAssertEqual(outdented, [1])
        XCTAssertEqual(workspace.macro(at: outdented, in: .global)?.description, "Second")
        var copied = try workspace.copyMacro(
            at: [0, 0],
            in: .global,
            to: .global,
            parentPath: [],
            index: 2
        )
        XCTAssertEqual(copied, [2])
        copied = try workspace.moveMacro(
            at: [1],
            in: .global,
            to: .global,
            parentPath: [0],
            index: 1
        )
        XCTAssertEqual(copied, [0, 1])
        var edited = try XCTUnwrap(workspace.macro(at: [0, 0], in: .global))
        edited.description = "Edited"
        edited.macro = "east"
        edited.key = "Control+E"
        try workspace.updateMacro(at: [0, 0], in: .global, macro: edited)
        XCTAssertEqual(workspace.macro(at: [0, 0], in: .global)?.description, "Edited")
        let rendered = try workspace.renderedDocument().serialized()
        XCTAssertTrue(rendered.contains("retained macro comment"))
        XCTAssertTrue(rendered.contains("Custom=\"keep\""))
        XCTAssertTrue(rendered.contains("Unknown=\"keep\""))

        let imported = try LegacyConfigurationDocument(source: """
        Version=331
        Connections {
          KeyboardMacros2 {
            { Description="Imported" Macro="west" key=NumPad4 Vendor="preserve" }
          }
        }
        """)
        XCTAssertEqual(try workspace.importMacros(from: imported, into: .global), 1)
        XCTAssertEqual(workspace.globalMacros.last?.description, "Imported")
        let exported = try workspace.exportMacros(in: .global, path: [2])
        XCTAssertTrue(exported.serialized().contains("Vendor=\"preserve\""))
    }

    func testAliasWindowsFieldsAndNestedCRUDPreserveUnknownPayloads() throws {
        let source = """
        Version=331
        Connections {
          Aliases {
            Active=true Echo=false ProcessCommands=true AfterCount=1
            { Description="First" Example="go north" Replace="north" Custom="keep"
              FindString { MatchText="go" RegularExpression=false }
            }
            { Description="Folder" Folder=true FindString.MatchText=""
              Aliases { Active=true AfterCount=1
                { Description="Child" Example="x" Replace="y" UnknownChild="keep"
                  FindString { MatchText="x" } }
              }
            }
          }
          Shortcuts {
            World {
              Host="world.example:8888"
              Aliases { Active=true { Description="World alias" Replace="world" FindString.MatchText="w" } }
            }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))
        XCTAssertEqual(workspace.aliasGroup(in: .global).afterCount, 1)
        XCTAssertFalse(workspace.aliasGroup(in: .global).echo)
        XCTAssertTrue(workspace.alias(at: [1], in: .global)?.folder == true)
        XCTAssertEqual(workspace.alias(at: [1, 0], in: .global)?.example, "x")
        let first = try XCTUnwrap(workspace.alias(at: [0], in: .global))
        var updated = first
        updated.example = "updated"
        updated.replacement = "northward"
        try workspace.updateAlias(at: [0], in: .global, alias: updated)
        XCTAssertTrue(try workspace.renderedDocument().serialized().contains("Custom=\"keep\""))

        let added = try workspace.addAlias(
            in: .global,
            parentPath: [1],
            alias: .init(description: "Added", match: .init(text: "a"), replacement: "b")
        )
        XCTAssertEqual(workspace.alias(at: added, in: .global)?.description, "Added")
        _ = try workspace.copyAlias(at: [1, 0], in: .global)
        XCTAssertEqual(workspace.alias(at: [1], in: .global)?.children.count, 3)
        _ = try workspace.removeAlias(at: added, in: .global)
        XCTAssertEqual(workspace.alias(at: [1], in: .global)?.children.count, 2)
        XCTAssertTrue(try workspace.renderedDocument().serialized().contains("UnknownChild=\"keep\""))

        let world = try XCTUnwrap(workspace.servers.first)
        _ = try workspace.moveAlias(at: [0], in: .global, to: .server(world.profile.id), toParentPath: [], index: 0)
        XCTAssertEqual(workspace.aliases(in: .global).count, 1)
        XCTAssertEqual(workspace.aliases(in: .server(world.profile.id)).first?.description, "First")
        XCTAssertTrue(try workspace.renderedDocument().serialized().contains("Custom=\"keep\""))
    }

    func testAliasScopeOrderingAndImportExportRoundTrip() throws {
        let source = """
        Version=331
        Connections {
          Aliases { Active=true AfterCount=1
            { Description="Global pre" FindString.MatchText="global-pre" }
            { Description="Global post" FindString.MatchText="global-post" }
          }
          Shortcuts {
            World {
              Host="world.example:8888"
              Aliases { Active=true AfterCount=1
                { Description="World pre" FindString.MatchText="world-pre" }
                { Description="World post" FindString.MatchText="world-post" }
              }
              Characters {
                Hero {
                  Aliases { Active=true { Description="Character" FindString.MatchText="character" } }
                  Puppets {
                    Scout { Aliases { Active=true { Description="Puppet" FindString.MatchText="puppet" } } }
                  }
                }
              }
            }
          }
        }
        """
        let projection = try LegacyConfigurationProjection(document: .init(source: source))
        let server = try XCTUnwrap(projection.servers.first)
        let character = try XCTUnwrap(server.characters.first)
        let puppet = try XCTUnwrap(character.puppets.first)
        let groups = projection.automationGroups(
            for: server.profile,
            character: character,
            puppet: puppet
        )
        XCTAssertEqual(
            groups.aliases.flatMap(\AliasGroup.aliases).map(\.description),
            ["Global pre", "World pre", "Character", "Puppet", "World post", "Global post"]
        )

        let importSource = try LegacyConfigurationDocument(source: """
        Version=331
        Connections {
          Aliases { Active=true
            { Description="Imported folder" Folder=true FindString.MatchText=""
              Aliases { { Description="Imported child" Example="test" Replace="done" FindString.MatchText="test" } }
            }
          }
        }
        """)
        var target = try LegacyConfigurationWorkspace.empty()
        XCTAssertEqual(try target.importAliases(from: importSource, into: .global), [[0]])
        let exported = try target.exportAliases(in: .global, path: [0])
        let reparsed = try LegacyConfigurationProjection(document: exported)
        XCTAssertEqual(reparsed.automation.aliases.aliases.first?.description, "Imported folder")
        XCTAssertEqual(reparsed.automation.aliases.aliases.first?.children.first?.example, "test")
    }

    func testAliasExampleCodableRemainsBackwardCompatible() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "description": "Legacy",
          "match": {
            "text": "old",
            "isRegularExpression": false,
            "matchCase": false,
            "startsWith": false,
            "endsWith": false,
            "wholeWord": false
          },
          "replacement": "new",
          "folder": false,
          "stopProcessing": false,
          "expandVariables": false,
          "children": []
        }
        """
        let alias = try JSONDecoder().decode(Alias.self, from: Data(json.utf8))
        XCTAssertEqual(alias.example, "")
    }
}
