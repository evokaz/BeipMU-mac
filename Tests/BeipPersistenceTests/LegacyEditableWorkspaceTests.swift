import BeipCore
import BeipAutomation
import BeipPersistence
import Foundation
import XCTest

final class LegacyEditableWorkspaceTests: XCTestCase {
    func testWorkspaceEditsNestedTriggersByPathAndPreservesUnknownChildFields() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            Active=true
            { Description="Parent" FindString { MatchText="parent" }
              Triggers {
                Active=true
                { Description="Child" UnknownChild="keep me" FindString { MatchText="child" }
                  Send { Active=true Send="old" }
                }
              }
            }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))
        let updatedChild = Trigger(
            description: "Updated Child",
            match: .init(text: "child ([0-9]+)", isRegularExpression: true),
            actions: [.send("score $1", captureIndex: 1, expandVariables: true)]
        )

        try workspace.updateTrigger(at: [0, 0], in: .global, trigger: updatedChild)
        let rendered = try workspace.renderedDocument()
        let serialized = rendered.serialized()
        let reloaded = try LegacyConfigurationProjection(document: rendered)
        let child = try XCTUnwrap(reloaded.automation.triggers.triggers.first?.children.first)

        XCTAssertTrue(serialized.contains("UnknownChild=\"keep me\""))
        XCTAssertEqual(child.description, "Updated Child")
        XCTAssertEqual(child.match.text, "child ([0-9]+)")
        XCTAssertEqual(child.actions, [.send("score $1", captureIndex: 1, expandVariables: true)])
    }

    func testWorkspaceAddsAndRemovesNestedTriggersByPath() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            Active=true
            { Description="Parent" FindString { MatchText="parent" } }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))

        let addedPath = try workspace.addTrigger(
            in: .global,
            parentPath: [0],
            trigger: Trigger(description: "Child", match: .init(text: "child"), actions: [.gag(display: true, log: false)])
        )
        XCTAssertEqual(addedPath, [0, 0])
        XCTAssertEqual(workspace.trigger(at: [0, 0], in: .global)?.description, "Child")

        try workspace.removeTrigger(at: [0, 0], in: .global)
        XCTAssertTrue(workspace.triggers(in: .global).first?.children.isEmpty == true)
    }

    func testWorkspaceMovesTriggersWithinAndAcrossNestedParentsPreservingUnknownFields() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            Active=true
            { Description="First" FutureFirst="keep first" FindString { MatchText="first" } }
            { Description="Folder" Folder=true FindString { MatchText="folder" }
              Triggers {
                Active=true
                { Description="Child" FutureChild="keep child" FindString { MatchText="child" } }
              }
            }
            { Description="Third" FutureThird="keep third" FindString { MatchText="third" } }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))

        let reorderedPath = try workspace.moveTrigger(at: [2], in: .global, toParentPath: [], index: 0)
        XCTAssertEqual(reorderedPath, [0])
        XCTAssertEqual(workspace.triggers(in: .global).map(\.description), ["Third", "First", "Folder"])

        let nestedPath = try workspace.moveTrigger(at: [1], in: .global, toParentPath: [2], index: 1)
        XCTAssertEqual(nestedPath, [1, 1])
        XCTAssertEqual(workspace.triggers(in: .global).map(\.description), ["Third", "Folder"])
        XCTAssertEqual(workspace.trigger(at: [1], in: .global)?.children.map(\.description), ["Child", "First"])

        let outdentedPath = try workspace.moveTrigger(at: [1, 0], in: .global, toParentPath: [], index: 2)
        XCTAssertEqual(outdentedPath, [2])
        XCTAssertEqual(workspace.triggers(in: .global).map(\.description), ["Third", "Folder", "Child"])
        XCTAssertEqual(workspace.trigger(at: [1], in: .global)?.children.map(\.description), ["First"])

        let serialized = (try workspace.renderedDocument()).serialized()
        XCTAssertTrue(serialized.contains("FutureFirst=\"keep first\""))
        XCTAssertTrue(serialized.contains("FutureChild=\"keep child\""))
        XCTAssertTrue(serialized.contains("FutureThird=\"keep third\""))
    }

    func testWorkspaceRejectsMovingTriggerIntoItsOwnDescendant() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            { Description="Parent" FindString { MatchText="parent" }
              Triggers { { Description="Child" FindString { MatchText="child" } } }
            }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))

        XCTAssertThrowsError(try workspace.moveTrigger(at: [0], in: .global, toParentPath: [0, 0], index: 0)) {
            XCTAssertEqual(
                $0 as? LegacyConfigurationWorkspace.WorkspaceError,
                .automationEntryNotFound
            )
        }
    }

    func testWorkspaceUpdatesTriggerGroupActiveAndAfterCount() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            Active=true
            AfterCount=1
            { Description="One" FindString { MatchText="one" } }
            { Description="Two" FindString { MatchText="two" } }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))

        try workspace.updateTriggerGroupSettings(in: .global, active: false, afterCount: 2)
        let rendered = try workspace.renderedDocument()
        let reloaded = try LegacyConfigurationProjection(document: rendered)

        XCTAssertFalse(reloaded.automation.triggers.active)
        XCTAssertEqual(reloaded.automation.triggers.afterCount, 2)
        XCTAssertTrue(rendered.serialized().contains("Active=false"))
        XCTAssertTrue(rendered.serialized().contains("AfterCount=2"))
    }

    func testWorkspaceReadsAndWritesTriggerFolderFlag() throws {
        let source = """
        Version=331
        Connections {
          Triggers {
            Active=true
            { Description="Container" Folder=true FindString { MatchText="" }
              Triggers { Active=true { Description="Child" FindString { MatchText="child" } } }
            }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: source))
        var folder = try XCTUnwrap(workspace.trigger(at: [0], in: .global))

        XCTAssertTrue(folder.folder)
        folder.folder = false
        try workspace.updateTrigger(at: [0], in: .global, trigger: folder)
        XCTAssertFalse(workspace.trigger(at: [0], in: .global)?.folder == true)
        XCTAssertTrue((try workspace.renderedDocument()).serialized().contains("Folder=false"))
    }

    func testWorkspaceWritesNestedChildrenWhenAddingFullTriggerTree() throws {
        var workspace = try LegacyConfigurationWorkspace.empty()
        let parent = Trigger(
            description: "Parent",
            match: .init(text: "parent"),
            actions: [.activity(important: false)],
            children: [
                Trigger(description: "Child", match: .init(text: "child"), actions: [.gag(display: true, log: true)]),
            ]
        )

        try workspace.addTrigger(in: .global, trigger: parent)
        let rendered = try workspace.renderedDocument()
        let reloaded = try LegacyConfigurationProjection(document: rendered)

        XCTAssertEqual(reloaded.automation.triggers.triggers.first?.children.first?.description, "Child")
        XCTAssertEqual(reloaded.automation.triggers.triggers.first?.children.first?.actions, [.gag(display: true, log: true)])
    }

    func testScriptingStartupPathWritesBackLosslessly() throws {
        let source = """
        Version=331
        ScriptStartup="old.js"
        Connections { Shortcuts { } }
        Future="keep"
        """
        let document = try LegacyConfigurationDocument(source: source)
        var projection = try LegacyConfigurationProjection(document: document)
        projection.scripting.startupPath = "scripts/startup.js"
        projection.scripting.debugEnabled = true

        let updated = try projection.applying(to: document)

        XCTAssertEqual(updated.value(at: ["ScriptStartup"]), "scripts/startup.js")
        XCTAssertEqual(updated.value(at: ["ScriptDebug"]), "true")
        XCTAssertEqual(updated.value(at: ["Future"]), "keep")
    }

    func testEditableConfigurationWorkspaceAddsRenamesAndRemovesProfiles() throws {
        let source = """
        Version=331
        Connections {
          Shortcuts {
            Existing {
              Host="existing.example:7777"
              WindowsOnly="preserve"
              Characters { Hero { Connect="connect hero" } }
            }
          }
        }
        """
        var workspace = try LegacyConfigurationWorkspace(
            document: LegacyConfigurationDocument(source: source)
        )
        let existingID = try XCTUnwrap(workspace.servers.first?.profile.id)
        let newID = workspace.addServer(named: "Existing")
        XCTAssertEqual(workspace.servers.map(\.profile.name), ["Existing", "Existing 2"])
        XCTAssertEqual(workspace.servers.last?.profile.encoding, .utf8)

        try workspace.updateServer(id: newID) {
            $0.profile.name = "New World"
            $0.profile.host = "new.example"
            $0.profile.port = 4321
            $0.profile.usesTLS = true
        }
        let characterID = try workspace.addCharacter(toServerID: newID, named: "Player")
        try workspace.updateCharacter(id: characterID, inServerID: newID) {
            $0.connectText = "connect player"
            $0.info = "Primary character"
            $0.autoConnect = true
            $0.logFilename = "logs/player.html"
            $0.logAppendsDate = true
        }
        let puppetID = try workspace.addPuppet(
            toCharacterID: characterID,
            inServerID: newID,
            named: "Helper"
        )
        try workspace.updatePuppet(
            id: puppetID,
            inCharacterID: characterID,
            serverID: newID
        ) {
            $0.receivePrefix = "Helper> "
            $0.sendPrefix = "tell Helper "
        }
        try workspace.removeServer(id: existingID)

        XCTAssertTrue(workspace.isDirty)
        let rendered = try workspace.renderedDocument()
        let reparsed = try LegacyConfigurationProjection(document: rendered)
        XCTAssertEqual(reparsed.servers.map(\.profile.name), ["New World"])
        XCTAssertEqual(reparsed.servers[0].profile.host, "new.example")
        XCTAssertEqual(reparsed.servers[0].characters[0].connectText, "connect player")
        XCTAssertEqual(reparsed.servers[0].characters[0].info, "Primary character")
        XCTAssertEqual(reparsed.servers[0].characters[0].logFilename, "logs/player.html")
        XCTAssertTrue(reparsed.servers[0].characters[0].logAppendsDate)
        XCTAssertEqual(reparsed.servers[0].characters[0].puppets[0].sendPrefix, "tell Helper ")
        XCTAssertFalse(rendered.serialized().contains("WindowsOnly=\"preserve\""))

        let destination = URL(fileURLWithPath: "/tmp/Config.txt")
        workspace.acceptSavedDocument(rendered, at: destination)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(workspace.sourceURL, destination)
    }

    func testEditableConfigurationWorkspaceRejectsDuplicateSiblingNames() throws {
        var workspace = try LegacyConfigurationWorkspace.empty()
        let first = workspace.addServer(named: "Alpha")
        let second = workspace.addServer(named: "Beta")

        XCTAssertThrowsError(try workspace.updateServer(id: second) { $0.profile.name = "alpha" }) {
            XCTAssertEqual(
                $0 as? LegacyConfigurationWorkspace.WorkspaceError,
                .duplicateName("alpha")
            )
        }
        XCTAssertEqual(workspace.servers.first { $0.profile.id == first }?.profile.name, "Alpha")
        XCTAssertEqual(workspace.servers.first { $0.profile.id == second }?.profile.name, "Beta")
    }

    func testEditableConfigurationWorkspaceUpdatesStartupScript() throws {
        var workspace = try LegacyConfigurationWorkspace.empty()
        workspace.updateScripting { $0.startupPath = "Scripts/startup.js" }

        XCTAssertTrue(workspace.isDirty)
        let rendered = try workspace.renderedDocument()
        XCTAssertEqual(try LegacyConfigurationProjection(document: rendered).scripting.startupPath, "Scripts/startup.js")
    }

    func testEditableConfigurationWorkspaceUpdatesConnectionSettings() throws {
        var workspace = try LegacyConfigurationWorkspace.empty()
        workspace.updateSettings {
            $0.connectTimeoutMilliseconds = 12_000
            $0.connectRetryCount = 3
            $0.retryForever = true
            $0.tcpKeepAlive = false
            $0.tcpNoDelay = false
        }

        XCTAssertTrue(workspace.isDirty)
        let rendered = try workspace.renderedDocument()
        let settings = try LegacyConfigurationProjection(document: rendered).settings
        XCTAssertEqual(settings.connectTimeoutMilliseconds, 12_000)
        XCTAssertEqual(settings.connectRetryCount, 3)
        XCTAssertTrue(settings.retryForever)
        XCTAssertFalse(settings.tcpKeepAlive)
        XCTAssertFalse(settings.tcpNoDelay)
    }

    func testEditableConfigurationWorkspaceRoundTripsScopedVariables() throws {
        var workspace = try LegacyConfigurationWorkspace(document: .init(source: """
        Version=331
        Connections { Shortcuts { World { Characters { Hero { } } } } }
        """))
        let server = try XCTUnwrap(workspace.servers.first)
        let character = try XCTUnwrap(server.characters.first)
        let scope = LegacyConfigurationWorkspace.AutomationScope.character(
            server: server.profile.id,
            character: character.id
        )

        try workspace.setVariable(named: "Mood", value: "quiet", in: scope)
        try workspace.setVariable(named: "mood", value: "focused", in: scope)
        XCTAssertEqual(try workspace.variables(in: scope), ["Mood": "focused"])

        let rendered = try workspace.renderedDocument()
        let reparsed = try LegacyConfigurationWorkspace(document: rendered)
        let reparsedServer = try XCTUnwrap(reparsed.servers.first)
        let reparsedCharacter = try XCTUnwrap(reparsedServer.characters.first)
        XCTAssertEqual(
            reparsed.projection.variables(
                for: reparsedServer.profile,
                character: reparsedCharacter,
                puppet: nil
            )["Mood"],
            "focused"
        )

        XCTAssertTrue(try workspace.removeVariable(named: "MOOD", in: scope))
        XCTAssertFalse(try workspace.removeVariable(named: "missing", in: scope))
        XCTAssertEqual(try workspace.variables(in: scope), [:])
    }

    func testUnnamedCollectionEntriesCanBeEditedWithoutRewritingNeighbors() throws {
        var document = try LegacyConfigurationDocument(source: """
        Connections {
          Aliases {
            // retained comment
            { FindString { MatchText="north" } Replace="n" WindowsOnly="keep" }
          }
        }
        """)
        try document.upsertValue("northward", inUnnamedBlockAt: 0, collectionPath: ["Connections", "Aliases"], relativePath: ["Replace"])
        let newIndex = try document.appendUnnamedBlock(at: ["Connections", "Aliases"])
        try document.upsertValue("south", inUnnamedBlockAt: newIndex, collectionPath: ["Connections", "Aliases"], relativePath: ["FindString", "MatchText"])
        try document.upsertValue("s", inUnnamedBlockAt: newIndex, collectionPath: ["Connections", "Aliases"], relativePath: ["Replace"])
        XCTAssertTrue(try document.removeUnnamedBlock(at: newIndex, collectionPath: ["Connections", "Aliases"]))

        let serialized = document.serialized()
        XCTAssertTrue(serialized.contains("// retained comment"))
        XCTAssertTrue(serialized.contains("MatchText=\"north\""))
        XCTAssertTrue(serialized.contains("Replace=\"northward\""))
        XCTAssertTrue(serialized.contains("WindowsOnly=\"keep\""))
        XCTAssertFalse(serialized.contains("MatchText=\"south\""))
    }
}
