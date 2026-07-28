import BeipAutomation
import BeipCore
import BeipPersistence
@testable import BeipUI
import XCTest

@MainActor
final class TriggerLivePropagationTests: XCTestCase {
    func testProfileLibraryNotifiesMultipleObservers() throws {
        let library = ProfileLibrary(workspace: try .empty(isDirty: false))
        var firstCount = 0
        var secondCount = 0
        let first = library.addChangeObserver { firstCount += 1 }
        library.addChangeObserver { secondCount += 1 }

        try library.mutate { _ = $0.addServer(named: "One") }

        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 1)

        library.removeChangeObserver(first)
        try library.mutate { _ = $0.addServer(named: "Two") }

        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 2)
    }

    func testAddingRegexSpawnTriggerAffectsLiveControllerWithoutReconnect() async throws {
        let workspace = try Self.workspace(
            """
            Version=331
            Connections {
              Triggers { Active=true }
              Shortcuts {
                TestServer { Host="testserver.example:8888" }
              }
            }
            """
        )
        let server = try XCTUnwrap(workspace.servers.first?.profile)
        let library = ProfileLibrary(workspace: workspace)
        let controller = ClientWindowController(profileLibrary: library, runsScriptServices: false)
        defer { controller.close() }
        controller.restoreOpenTab(server: server, character: nil)

        await controller.testingReceiveLine("Wizard pages: test")
        XCTAssertEqual(controller.testingSpawnLines(named: "Pages"), [])

        try library.mutate { workspace in
            try workspace.addTrigger(
                in: .global,
                trigger: Trigger(
                    description: "Pages",
                    match: .init(text: "(.+) pages: (.+)", isRegularExpression: true),
                    actions: [.spawn(.init(title: "Pages", copy: true))]
                )
            )
        }
        XCTAssertEqual(controller.testingAutomationSnapshot().triggerCount, 1)
        XCTAssertEqual(controller.testingAutomationSnapshot().activeTriggerGroupCount, 1)

        await controller.testingReceiveLine("Wizard pages: test")

        XCTAssertEqual(controller.testingSpawnLines(named: "Pages"), ["Wizard pages: test"])
    }

    func testUpdateDisableAndDeletePropagateToLiveController() async throws {
        var workspace = try Self.workspace(
            """
            Version=331
            Connections {
              Shortcuts {
                TestServer { Host="testserver.example:8888" }
              }
            }
            """
        )
        try workspace.addTrigger(
            in: .global,
            trigger: Trigger(
                description: "Original",
                match: .init(text: "alert"),
                actions: [.spawn(.init(title: "Original", copy: true))]
            )
        )
        let updatedServer = try XCTUnwrap(workspace.servers.first?.profile)
        let library = ProfileLibrary(workspace: workspace)
        let controller = ClientWindowController(profileLibrary: library, runsScriptServices: false)
        defer { controller.close() }
        controller.restoreOpenTab(server: updatedServer, character: nil)
        XCTAssertEqual(controller.testingAutomationSnapshot().triggerCount, 1)
        XCTAssertEqual(controller.testingAutomationSnapshot().activeTriggerGroupCount, 1)

        await controller.testingReceiveLine("alert")
        XCTAssertEqual(controller.testingSpawnLines(named: "Original"), ["alert"])

        try library.mutate { workspace in
            try workspace.updateTrigger(
                at: 0,
                in: .global,
                trigger: Trigger(
                    description: "Updated",
                    match: .init(text: "notice"),
                    actions: [.spawn(.init(title: "Updated", copy: true))]
                )
            )
        }

        await controller.testingReceiveLine("alert")
        await controller.testingReceiveLine("notice")
        XCTAssertEqual(controller.testingSpawnLines(named: "Original"), ["alert"])
        XCTAssertEqual(controller.testingSpawnLines(named: "Updated"), ["notice"])

        try library.mutate { workspace in
            try workspace.updateTrigger(
                at: 0,
                in: .global,
                trigger: Trigger(
                    description: "Disabled",
                    match: .init(text: "notice"),
                    disabled: true,
                    actions: [.spawn(.init(title: "Disabled", copy: true))]
                )
            )
        }

        await controller.testingReceiveLine("notice")
        XCTAssertEqual(controller.testingSpawnLines(named: "Disabled"), [])

        try library.mutate { workspace in
            try workspace.removeAutomationEntry(at: 0, in: .global, kind: .triggers)
        }

        await controller.testingReceiveLine("notice")
        XCTAssertEqual(controller.testingSpawnLines(named: "Updated"), ["notice"])
    }

    func testGlobalAndScopedMutationsReachApplicableLiveControllers() async throws {
        let workspace = try Self.workspace(
            """
            Version=331
            Connections {
              Shortcuts {
                First { Host="first.example:8888" }
                Second { Host="second.example:8888" }
              }
            }
            """
        )
        let firstServer = try XCTUnwrap(workspace.servers.first { $0.profile.name == "First" }?.profile)
        let secondServer = try XCTUnwrap(workspace.servers.first { $0.profile.name == "Second" }?.profile)
        let library = ProfileLibrary(workspace: workspace)
        let first = ClientWindowController(profileLibrary: library, runsScriptServices: false)
        let second = ClientWindowController(profileLibrary: library, runsScriptServices: false)
        defer {
            first.close()
            second.close()
        }
        first.restoreOpenTab(server: firstServer, character: nil)
        second.restoreOpenTab(server: secondServer, character: nil)

        try library.mutate { workspace in
            try workspace.addTrigger(
                in: .global,
                trigger: Trigger(
                    description: "Global",
                    match: .init(text: "broadcast"),
                    actions: [.spawn(.init(title: "Global", copy: true))]
                )
            )
        }
        XCTAssertEqual(first.testingAutomationSnapshot().triggerCount, 1)
        XCTAssertEqual(second.testingAutomationSnapshot().triggerCount, 1)
        XCTAssertEqual(first.testingAutomationSnapshot().activeTriggerGroupCount, 1)
        XCTAssertEqual(second.testingAutomationSnapshot().activeTriggerGroupCount, 1)

        await first.testingReceiveLine("broadcast")
        await second.testingReceiveLine("broadcast")
        XCTAssertEqual(first.testingSpawnLines(named: "Global"), ["broadcast"])
        XCTAssertEqual(second.testingSpawnLines(named: "Global"), ["broadcast"])

        do {
            try library.mutate { workspace in
                let currentFirstServerID = try XCTUnwrap(
                    workspace.servers.first { $0.profile.name == "First" }?.profile.id
                )
                try workspace.addTrigger(
                    in: .server(currentFirstServerID),
                    trigger: Trigger(
                        description: "Scoped",
                        match: .init(text: "local"),
                        actions: [.spawn(.init(title: "Scoped", copy: true))]
                    )
                )
            }
        } catch {
            XCTFail("Scoped trigger mutation failed: \(error)")
            return
        }

        await first.testingReceiveLine("local")
        await second.testingReceiveLine("local")
        XCTAssertEqual(first.testingSpawnLines(named: "Scoped"), ["local"])
        XCTAssertEqual(second.testingSpawnLines(named: "Scoped"), [])
    }

    func testSpawnCaptureIncludesTerminatingLineAndStopsAfterIt() async throws {
        var workspace = try Self.workspace(
            """
            Version=331
            Connections {
              Shortcuts {
                TestServer { Host="testserver.example:8888" }
              }
            }
            """
        )
        try workspace.addTrigger(
            in: .global,
            trigger: Trigger(
                description: "Capture",
                match: .init(text: "START"),
                actions: [.spawn(.init(title: "Capture", captureUntil: "^END$", copy: true))]
            )
        )
        let server = try XCTUnwrap(workspace.servers.first?.profile)
        let library = ProfileLibrary(workspace: workspace)
        let controller = ClientWindowController(profileLibrary: library, runsScriptServices: false)
        defer { controller.close() }
        controller.restoreOpenTab(server: server, character: nil)

        await controller.testingReceiveLine("START")
        await controller.testingReceiveLine("body")
        await controller.testingReceiveLine("END")
        await controller.testingReceiveLine("after")

        XCTAssertEqual(controller.testingSpawnLines(named: "Capture"), ["START", "body", "END"])
    }

    func testFirstEligibleSpawnWinsWhenMultipleTriggersMatchLine() async throws {
        var workspace = try Self.workspace(
            """
            Version=331
            Connections {
              Shortcuts {
                TestServer { Host="testserver.example:8888" }
              }
            }
            """
        )
        try workspace.addTrigger(
            in: .global,
            trigger: Trigger(
                description: "First Spawn",
                match: .init(text: "SPAWN"),
                actions: [.spawn(.init(title: "First", copy: true))]
            )
        )
        try workspace.addTrigger(
            in: .global,
            trigger: Trigger(
                description: "Second Spawn",
                match: .init(text: "SPAWN"),
                actions: [.spawn(.init(title: "Second", copy: true))]
            )
        )
        let server = try XCTUnwrap(workspace.servers.first?.profile)
        let library = ProfileLibrary(workspace: workspace)
        let controller = ClientWindowController(profileLibrary: library, runsScriptServices: false)
        defer { controller.close() }
        controller.restoreOpenTab(server: server, character: nil)

        await controller.testingReceiveLine("SPAWN")

        XCTAssertEqual(controller.testingSpawnLines(named: "First"), ["SPAWN"])
        XCTAssertEqual(controller.testingSpawnLines(named: "Second"), [])
    }

    func testOnlyChildrenDuringSpawnCaptureProcessesChildrenInsteadOfUnrelatedTriggers() async throws {
        var workspace = try Self.workspace(
            """
            Version=331
            Connections {
              Shortcuts {
                TestServer { Host="testserver.example:8888" }
              }
            }
            """
        )
        let capturing = Trigger(
            description: "Capture",
            match: .init(text: "START"),
            actions: [.spawn(.init(title: "Capture", captureUntil: "^END$", onlyChildrenDuringCapture: true, copy: true))],
            children: [
                Trigger(
                    description: "Child Filter",
                    match: .init(text: "child"),
                    actions: [.replace("child-only", expandVariables: false)]
                ),
            ]
        )
        let unrelated = Trigger(
            description: "Unrelated Filter",
            match: .init(text: "child"),
            actions: [.replace("global-only", expandVariables: false)]
        )
        try workspace.addTrigger(in: .global, trigger: capturing)
        try workspace.addTrigger(in: .global, trigger: unrelated)
        let server = try XCTUnwrap(workspace.servers.first?.profile)
        let library = ProfileLibrary(workspace: workspace)
        let controller = ClientWindowController(profileLibrary: library, runsScriptServices: false)
        defer { controller.close() }
        controller.restoreOpenTab(server: server, character: nil)

        await controller.testingReceiveLine("START")
        await controller.testingReceiveLine("child")
        await controller.testingReceiveLine("END")

        XCTAssertEqual(controller.testingSpawnLines(named: "Capture"), ["START", "child-only", "END"])
    }

    func testSpawnClearOptionClearsExistingSpawnWindowBeforeDeliveringNewLine() async throws {
        var workspace = try Self.workspace(
            """
            Version=331
            Connections {
              Shortcuts {
                TestServer { Host="testserver.example:8888" }
              }
            }
            """
        )
        try workspace.addTrigger(
            in: .global,
            trigger: Trigger(
                description: "Clear Spawn",
                match: .init(text: "SPAWN"),
                actions: [.spawn(.init(title: "Panel", clear: true, copy: true))]
            )
        )
        let server = try XCTUnwrap(workspace.servers.first?.profile)
        let library = ProfileLibrary(workspace: workspace)
        let controller = ClientWindowController(profileLibrary: library, runsScriptServices: false)
        defer { controller.close() }
        controller.restoreOpenTab(server: server, character: nil)

        await controller.testingReceiveLine("SPAWN one")
        XCTAssertEqual(controller.testingSpawnLines(named: "Panel"), ["SPAWN one"])

        await controller.testingReceiveLine("SPAWN two")
        XCTAssertEqual(controller.testingSpawnLines(named: "Panel"), ["SPAWN two"])
    }

    func testActiveSpawnCaptureIsClearedWhenTriggerConfigurationChanges() async throws {
        var workspace = try Self.workspace(
            """
            Version=331
            Connections {
              Shortcuts {
                TestServer { Host="testserver.example:8888" }
              }
            }
            """
        )
        try workspace.addTrigger(
            in: .global,
            trigger: Trigger(
                description: "Capture",
                match: .init(text: "START"),
                actions: [.spawn(.init(title: "Capture", captureUntil: "^END$", copy: true))]
            )
        )
        let server = try XCTUnwrap(workspace.servers.first?.profile)
        let library = ProfileLibrary(workspace: workspace)
        let controller = ClientWindowController(profileLibrary: library, runsScriptServices: false)
        defer { controller.close() }
        controller.restoreOpenTab(server: server, character: nil)

        await controller.testingReceiveLine("START")
        XCTAssertEqual(controller.testingSpawnLines(named: "Capture"), ["START"])

        try library.mutate { workspace in
            try workspace.removeAutomationEntry(at: 0, in: .global, kind: .triggers)
        }

        await controller.testingReceiveLine("body")
        await controller.testingReceiveLine("END")
        XCTAssertEqual(controller.testingSpawnLines(named: "Capture"), ["START"])
    }

    func testEditingTriggersWhileOutputArrivesUsesNextSavedDefinition() async throws {
        let workspace = try Self.workspace(
            """
            Version=331
            Connections {
              Shortcuts {
                TestServer { Host="testserver.example:8888" }
              }
            }
            """
        )
        let server = try XCTUnwrap(workspace.servers.first?.profile)
        let library = ProfileLibrary(workspace: workspace)
        let controller = ClientWindowController(profileLibrary: library, runsScriptServices: false)
        defer { controller.close() }
        controller.restoreOpenTab(server: server, character: nil)

        for index in 0..<20 {
            await controller.testingReceiveLine("noise \(index)")
        }

        try library.mutate { workspace in
            try workspace.addTrigger(
                in: .global,
                trigger: Trigger(
                    description: "Arriving",
                    match: .init(text: "arriving"),
                    actions: [.spawn(.init(title: "Arriving", copy: true))]
                )
            )
        }

        for index in 20..<40 {
            await controller.testingReceiveLine(index == 25 ? "arriving while editing" : "noise \(index)")
        }

        XCTAssertEqual(controller.testingSpawnLines(named: "Arriving"), ["arriving while editing"])
    }

    func testSimultaneousCharacterAndPuppetWindowsResolveDifferentTriggerScopes() async throws {
        let workspace = try Self.workspace(
            """
            Version=331
            Connections {
              Triggers { Active=true }
              Shortcuts {
                World {
                  Host="world.example:8888"
                  Triggers { Active=true }
                  Characters {
                    Hero {
                      Triggers {
                        Active=true
                        { Description="Hero Trigger" FindString { MatchText="hero-line" } }
                      }
                      Puppets {
                        Bot {
                          ReceivePrefix="Bot> "
                          SendPrefix="tell Bot "
                          Triggers {
                            Active=true
                            { Description="Bot Trigger" FindString { MatchText="bot-line" } }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
            """
        )
        let server = try XCTUnwrap(workspace.servers.first?.profile)
        let character = try XCTUnwrap(workspace.servers.first?.characters.first)
        let puppet = try XCTUnwrap(character.puppets.first)
        let library = ProfileLibrary(workspace: workspace)
        XCTAssertEqual(
            library.workspace.projection.automationGroups(for: server, character: character)
                .triggers.flatMap(\.triggers).map(\.description),
            ["Hero Trigger"]
        )
        let characterWindow = ClientWindowController(profileLibrary: library, runsScriptServices: false)
        let puppetWindow = ClientWindowController(profileLibrary: library, runsScriptServices: false)
        defer {
            characterWindow.close()
            puppetWindow.close()
        }

        characterWindow.restoreOpenTab(server: server, character: character)
        puppetWindow.startPuppetSession(master: characterWindow, server: server, character: character, puppet: puppet)

        XCTAssertEqual(characterWindow.testingAutomationSnapshot().triggerCount, 1)
        XCTAssertEqual(puppetWindow.testingAutomationSnapshot().triggerCount, 2)
    }

    func testCharacterTriggerRunsWithoutScopeActiveFlags() async throws {
        let workspace = try Self.workspace(
            """
            Version=331
            Connections {
              Shortcuts {
                MyRhost {
                  Host="example.test:4201"
                  Characters {
                    "#1" {
                      Triggers {
                        {
                          Description="They page"
                          FindString {
                            MatchText="(.+) pages: (.+)"
                            RegularExpression=true
                          }
                          Spawn {
                            Active=true
                            Title="Pages1"
                            Copy=true
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
            """
        )
        let server = try XCTUnwrap(workspace.servers.first?.profile)
        let character = try XCTUnwrap(workspace.servers.first?.characters.first)
        let controller = ClientWindowController(
            profileLibrary: ProfileLibrary(workspace: workspace),
            runsScriptServices: false
        )
        defer { controller.close() }
        controller.restoreOpenTab(server: server, character: character)

        await controller.testingReceiveLine("Wizard pages: test")

        XCTAssertEqual(controller.testingSpawnLines(named: "Pages1"), ["Wizard pages: test"])
    }

    private static func workspace(_ source: String) throws -> LegacyConfigurationWorkspace {
        try LegacyConfigurationWorkspace(document: LegacyConfigurationDocument(source: source))
    }
}
