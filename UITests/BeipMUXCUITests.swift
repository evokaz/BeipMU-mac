import AppKit
import XCTest

private final class UITestStateSandbox: NSObject, XCTestObservation, @unchecked Sendable {
    static let shared = UITestStateSandbox()

    let directory: URL
    let defaultsSuiteName: String

    private override init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeipMU-UI-Test-\(UUID().uuidString)", isDirectory: true)
        defaultsSuiteName = "org.beipmu.BeipMU.UITests.\(UUID().uuidString)"
        super.init()
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    @MainActor
    func configure(_ app: XCUIApplication, reset: Bool = true) {
        if !app.launchArguments.contains("-ApplePersistenceIgnoreState") {
            app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        }
        app.launchEnvironment["BEIPMU_UI_TESTING"] = "1"
        app.launchEnvironment["BEIPMU_UI_TEST_RESET"] = reset ? "1" : "0"
        app.launchEnvironment["BEIPMU_UI_TEST_STATE_DIRECTORY"] = directory.path
        app.launchEnvironment["BEIPMU_UI_TEST_DEFAULTS_SUITE"] = defaultsSuiteName
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
final class BeipMUXCUITests: XCTestCase {
    func testPermanentTabBarNavigationControls() {
        let app = launchApplication()
        defer { app.terminate() }
        let window = app.windows["mainWindow"]
        let applicationMenu = window.buttons["tabBarApplicationMenu"]
        let quickConnect = window.buttons["tabBarQuickConnect"]
        let worldsAndCharacters = window.buttons["tabBarWorldsAndCharacters"]

        XCTAssertTrue(applicationMenu.waitForExistence(timeout: 3))
        XCTAssertTrue(quickConnect.exists)
        XCTAssertTrue(worldsAndCharacters.exists)
        XCTAssertLessThan(applicationMenu.frame.minX, quickConnect.frame.minX)
        XCTAssertLessThan(quickConnect.frame.minX, worldsAndCharacters.frame.minX)
        XCTAssertLessThan(worldsAndCharacters.frame.minX, window.buttons["activeSessionTab"].frame.minX)

        applicationMenu.click()
        for title in [
            "Windows", "Tools", "Logging…", "Settings…", "Help",
            "Close all Windows and Exit",
        ] {
            XCTAssertTrue(app.menuItems[title].exists, "Missing application-menu item: \(title)")
        }
        app.typeKey(.escape, modifierFlags: [])

        app.menuBars.menuBarItems["Tools"].click()
        for title in [
            "Triggers…", "Macros…", "Aliases…", "Smart Paste…",
        ] {
            XCTAssertTrue(app.menuItems[title].exists, "Missing native application-menu item: \(title)")
        }
        app.typeKey(.escape, modifierFlags: [])

        app.menuBars.menuBarItems["Window"].click()
        for title in [
            "Toggle Map Window", "Toggle Character Notes Window",
            "Copy all window settings", "Paste all window settings", "Show Hidden Captions",
        ] {
            XCTAssertTrue(app.menuItems[title].exists, "Missing native window-menu item: \(title)")
        }
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(waitUntil { quickConnect.isHittable })
        quickConnect.click()
        XCTAssertTrue(app.menus.firstMatch.waitForExistence(timeout: 2))
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(waitUntil { worldsAndCharacters.isHittable })
        worldsAndCharacters.click()
        XCTAssertTrue(app.windows["configurationManager"].waitForExistence(timeout: 3))
    }

    func testMainWindowResizesMaximizesAndEntersFullScreen() {
        let app = launchApplication()
        defer { app.terminate() }
        let window = app.windows["mainWindow"]

        let initialFrame = window.frame
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Zoom"].click()
        XCTAssertTrue(
            waitUntil { reportedHeight(of: window) > initialFrame.height + 100 },
            "Zoom did not expand \(initialFrame) on \(NSScreen.main!.frame); value: \(String(describing: window.value))"
        )
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Zoom"].click()
        XCTAssertTrue(waitUntil { reportedHeight(of: window) <= initialFrame.height + 2 })

        let resizeHandle = window.descendants(matching: .any)["mainWindowVerticalResizeHandle"]
        XCTAssertTrue(resizeHandle.waitForExistence(timeout: 2))
        let bottomEdge = resizeHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let tallerPosition = bottomEdge.withOffset(CGVector(dx: 0, dy: 160))
        bottomEdge.press(forDuration: 0.2, thenDragTo: tallerPosition)
        XCTAssertGreaterThan(
            reportedHeight(of: window),
            initialFrame.height + 100,
            "Initial frame: \(initialFrame); reported value: \(String(describing: window.value))"
        )

        let tallerHeight = reportedHeight(of: window)
        let newBottomEdge = resizeHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let shorterPosition = newBottomEdge.withOffset(CGVector(dx: 0, dy: -120))
        newBottomEdge.press(forDuration: 0.2, thenDragTo: shorterPosition)
        XCTAssertLessThan(reportedHeight(of: window), tallerHeight - 80)

        app.typeKey("f", modifierFlags: [.command, .control])
        XCTAssertTrue(waitUntil(timeout: 5) {
            reportedHeight(of: window) >= NSScreen.main!.visibleFrame.height - 2
        }, "Full screen did not fill the usable screen; value: \(String(describing: window.value))")
        app.typeKey("f", modifierFlags: [.command, .control])
    }

    func testMainWorkspaceAccessibilityKeyboardAndBaseline() throws {
        let app = launchApplication()
        defer { app.terminate() }
        let window = app.windows["mainWindow"]
        let output = window.descendants(matching: .textView)["MU star output"]
        let input = window.descendants(matching: .textView)["Command input"]
        XCTAssertTrue(output.exists)
        XCTAssertTrue(input.exists)
        XCTAssertTrue((output.value as? String)?.contains("Welcome to BeipMU") == true)
        try assertScreenshotBaseline(named: "workspace-main", element: window)

        input.click()
        input.typeText("look")
        input.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil { (output.value as? String)?.contains("Not connected.") == true })
        try assertScreenshotBaseline(named: "workspace-command-error", element: window)
        input.typeKey(.upArrow, modifierFlags: [])
        XCTAssertEqual(input.value as? String, "look")
    }

    func testSplitSidebarsPersistsAcrossRelaunchAndMatchesBaseline() throws {
        let app = launchApplication()
        defer { app.terminate() }
        chooseWorkspaceMenuItem("Split Sidebars", in: app)
        let window = app.windows["mainWindow"]
        XCTAssertTrue(window.textViews["Character notes"].waitForExistence(timeout: 3))
        XCTAssertTrue(window.textViews["Session diagnostics"].exists)
        XCTAssertEqual(window.splitGroups.matching(identifier: "workspaceSplit.").count, 1)
        XCTAssertEqual(window.splitGroups.matching(identifier: "workspaceSplit.second").count, 1)
        try assertScreenshotBaseline(named: "workspace-split-sidebars", element: window)

        app.terminate()
        app.launchEnvironment["BEIPMU_UI_TEST_RESET"] = "0"
        app.launch()
        let restored = app.windows["mainWindow"]
        XCTAssertTrue(restored.textViews["Character notes"].waitForExistence(timeout: 5))
        XCTAssertTrue(restored.textViews["Session diagnostics"].exists)
        XCTAssertEqual(restored.splitGroups.matching(identifier: "workspaceSplit.second").count, 1)
    }

    func testSettingsAppearanceAccessibilityAndBaseline() throws {
        let app = launchApplication()
        defer { app.terminate() }
        app.menuBars.menuBarItems["BeipMU"].click()
        app.menuItems["Theme…"].click()
        let settings = app.windows["settingsWindow"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertTrue(settings.popUpButtons["themeMode"].exists)
        XCTAssertEqual(settings.colorWells.matching(identifier: "themeForeground").count, 1)
        XCTAssertEqual(settings.colorWells.matching(identifier: "themeBackground").count, 1)
        XCTAssertEqual(settings.colorWells.matching(identifier: "themeAccent").count, 1)
        try assertScreenshotBaseline(named: "settings-window", element: settings)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
    }

    func testTextWindowContextMenuAndGlobalSettingsAreAccessible() {
        let app = launchApplication()
        defer { app.terminate() }
        let output = app.windows["mainWindow"].descendants(matching: .textView)["MU star output"]
        output.rightClick()
        for title in [
            "Find…", "Pause", "Split", "Copy screen to clipboard", "Clear",
            "Delete Line", "Inherit default settings", "Settings…",
        ] {
            XCTAssertTrue(app.menuItems[title].exists, "Missing output context-menu command: \(title)")
        }
        app.typeKey(.escape, modifierFlags: [])

        let input = app.windows["mainWindow"].descendants(matching: .textView)["Command input"]
        input.rightClick()
        for title in ["Inherit default settings", "Settings…", "Conversion"] {
            XCTAssertTrue(app.menuItems[title].exists, "Missing input context-menu command: \(title)")
        }
        app.typeKey(.escape, modifierFlags: [])

        app.menuBars.menuBarItems["BeipMU"].click()
        app.menuItems["Global Input Settings…"].click()
        let inputWindow = app.windows["settingsWindow"]
        XCTAssertTrue(inputWindow.waitForExistence(timeout: 3))
        XCTAssertTrue(inputWindow.popUpButtons["inputSettingsFont"].exists)
        XCTAssertTrue(inputWindow.textFields["inputSettingsFontSize"].exists)
        XCTAssertTrue(inputWindow.checkBoxes["inputSettingsResizeToFit"].exists)
        XCTAssertTrue(inputWindow.textFields["inputSettingsMinimumLines"].exists)
        XCTAssertTrue(inputWindow.textFields["inputSettingsMaximumLines"].exists)
        XCTAssertTrue(inputWindow.checkBoxes["inputSettingsKeepText"].exists)
        XCTAssertTrue(inputWindow.checkBoxes["inputSettingsLocalEcho"].exists)

        app.menuBars.menuBarItems["BeipMU"].click()
        app.menuItems["Global Output Settings…"].click()
        let outputWindow = app.windows["settingsWindow"]
        XCTAssertTrue(outputWindow.waitForExistence(timeout: 3))
        XCTAssertTrue(outputWindow.popUpButtons["outputSettingsScope"].exists)
        XCTAssertTrue(outputWindow.popUpButtons["outputSettingsFont"].exists)
        XCTAssertTrue(outputWindow.textFields["outputSettingsFontSize"].exists)
        XCTAssertTrue(outputWindow.textFields["outputSettingsHistory"].exists)
        XCTAssertTrue(outputWindow.textFields["outputSettingsWrappedIndent"].exists)
        XCTAssertTrue(outputWindow.textFields["outputSettingsFixedWidthCharacters"].exists)
    }

    func testStatisticsPanelAccessibilityAndBaseline() throws {
        let app = launchApplication()
        defer { app.terminate() }
        app.menuBars.menuBarItems["Connection"].click()
        app.menuItems["Statistics…"].click()
        let panel = app.windows["statisticsWindow"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        XCTAssertEqual(panel.staticTexts["statisticsServer"].value as? String, "None")
        XCTAssertEqual(panel.staticTexts["statisticsState"].value as? String, "Disconnected")
        XCTAssertEqual(panel.staticTexts["statisticsConnections"].value as? String, "0")
        XCTAssertEqual(panel.staticTexts["statisticsBytesSent"].value as? String, "0 bytes")
        XCTAssertEqual(panel.staticTexts["statisticsBytesReceived"].value as? String, "0 bytes")
        XCTAssertEqual(panel.staticTexts["statisticsOnlineTime"].value as? String, "00:00:00")
        try assertScreenshotBaseline(named: "statistics-panel", element: panel)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
    }

    func testDebuggerPanelsSupportKeyboardOnlyControls() throws {
        let app = launchApplication(environment: [
            "BEIPMU_FORCE_REDUCE_MOTION": "1",
            "BEIPMU_FORCE_INCREASE_CONTRAST": "1",
            "BEIPMU_FORCE_DIFFERENTIATE_WITHOUT_COLOR": "1",
        ])
        defer { app.terminate() }
        openDebugger("Network…", in: app)
        let network = app.windows["networkDebugger"]
        XCTAssertTrue(network.waitForExistence(timeout: 3))
        let hex = network.checkBoxes["networkDebuggerShowHex"]
        let telnet = network.checkBoxes["networkDebuggerShowTelnet"]
        XCTAssertTrue(hex.exists)
        XCTAssertTrue(telnet.exists)
        XCTAssertEqual(hex.value as? Int, 0)
        XCTAssertEqual(telnet.value as? Int, 1)

        network.typeKey(.space, modifierFlags: [])
        XCTAssertEqual(hex.value as? Int, 1)
        network.typeKey(.tab, modifierFlags: [])
        network.typeKey(.space, modifierFlags: [])
        XCTAssertEqual(telnet.value as? Int, 0)
        network.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(network.waitForNonExistence(timeout: 3))

        openDebugger("Scripts…", in: app)
        let scripts = app.windows["scriptDebugger"]
        XCTAssertTrue(scripts.waitForExistence(timeout: 3))
        XCTAssertTrue(scripts.buttons["scriptDebuggerReset"].exists)
        XCTAssertTrue(scripts.buttons["scriptDebuggerClear"].exists)
        scripts.typeKey(.tab, modifierFlags: [])
        scripts.typeKey(.space, modifierFlags: [])
        scripts.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(scripts.waitForNonExistence(timeout: 3))
    }

    private func launchApplication(environment: [String: String] = [:]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        UITestStateSandbox.shared.configure(app)
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        XCTAssertTrue(app.windows["mainWindow"].waitForExistence(timeout: 5))
        return app
    }

    private func chooseWorkspaceMenuItem(_ title: String, in app: XCUIApplication) {
        app.menuBars.menuBarItems["View"].click()
        let parent = app.menuItems["Workspace Panes"]
        XCTAssertTrue(parent.waitForExistence(timeout: 2))
        parent.hover()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 2))
        item.click()
    }

    private func openDebugger(_ title: String, in app: XCUIApplication) {
        app.menuBars.menuBarItems["Connection"].click()
        let parent = app.menuItems["Debuggers"]
        XCTAssertTrue(parent.waitForExistence(timeout: 2))
        parent.hover()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 2))
        item.click()
    }

    private func assertScreenshotBaseline(
        named name: String,
        element: XCUIElement,
        tolerance: Double = 0.08,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let screenshot = element.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let directory = sourceDirectory.appendingPathComponent("Baselines", isDirectory: true)
        let baselineURL = directory.appendingPathComponent(name).appendingPathExtension("png")
        let recordMarker = sourceDirectory.appendingPathComponent(".record-baselines")
        if FileManager.default.fileExists(atPath: recordMarker.path) {
            return
        }

        guard let baseline = try? Data(contentsOf: baselineURL) else {
            XCTFail("Missing baseline \(baselineURL.path). Record with BEIPMU_RECORD_BASELINES=1 ./Scripts/test-ui.sh.", file: file, line: line)
            return
        }
        let difference = try normalizedImageDifference(baseline, screenshot.pngRepresentation)
        XCTAssertLessThanOrEqual(
            difference,
            tolerance,
            "Screenshot difference \(difference) exceeded \(tolerance) for \(name)",
            file: file,
            line: line
        )
    }

    private func normalizedImageDifference(_ lhs: Data, _ rhs: Data) throws -> Double {
        let left = try normalizedRGBA(lhs)
        let right = try normalizedRGBA(rhs)
        precondition(left.count == right.count)
        let total = zip(left, right).reduce(0.0) { partial, pair in
            partial + abs(Double(pair.0) - Double(pair.1)) / 255
        }
        return total / Double(left.count)
    }

    private func normalizedRGBA(_ data: Data) throws -> [UInt8] {
        guard let image = NSImage(data: data),
              let representation = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 160,
                pixelsHigh: 120,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 160 * 4,
                bitsPerPixel: 32
              ) else { throw BaselineError.invalidImage }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        image.draw(
            in: NSRect(x: 0, y: 0, width: 160, height: 120),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let bytes = representation.bitmapData else { throw BaselineError.invalidImage }
        return Array(UnsafeBufferPointer(start: bytes, count: 160 * 120 * 4))
    }

    private func waitUntil(timeout: TimeInterval = 3, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return condition()
    }

    private func reportedHeight(of window: XCUIElement) -> CGFloat {
        guard let value = window.value as? String,
              let height = value.split(separator: "x").last.flatMap({ Double($0) }) else {
            return window.frame.height
        }
        return CGFloat(height)
    }
}

private enum BaselineError: Error {
    case invalidImage
}

@MainActor
final class WorkspaceScaleUITests: XCTestCase {
    func testWorkspaceScaleInteractiveResponsivenessRSSAndCleanup() throws {
        continueAfterFailure = false
        let resultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("beipmu-scale-ui-result.json")
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: resultURL)

        let app = XCUIApplication()
        UITestStateSandbox.shared.configure(app)
        app.launchEnvironment["BEIPMU_SCALE_TEST"] = "1"
        app.launchEnvironment["BEIPMU_SCALE_TEST_RESULT"] = resultURL.path
        app.launch()
        defer { app.terminate() }

        let window = app.windows["mainWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let output = window.descendants(matching: .textView)["MU star output"]
        let input = window.descendants(matching: .textView)["Command input"]
        XCTAssertTrue(waitUntil(timeout: 30) {
            (output.value as? String)?.contains("BEIPMU_SCALE_TEST_COMPLETE") == true
        })

        input.click()
        input.typeText("scale-responsive")
        input.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 3) {
            (output.value as? String)?.contains("Not connected.") == true
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path))
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: resultURL)) as? [String: Any]
        XCTAssertEqual(report?["result"] as? String, "pass")
        XCTAssertEqual(report?["activeSessionsAfterClose"] as? Int, 0)
        XCTAssertEqual(report?["openLogsAfterClose"] as? Int, 0)
        XCTAssertLessThanOrEqual(report?["peakRSSBytes"] as? Int ?? .max, 268_435_456)
        XCTAssertLessThanOrEqual(report?["retainedRendererRows"] as? Int ?? .max, 10_000)

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "scale-responsive"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return condition()
    }

}

@MainActor
private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
