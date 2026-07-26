import AppKit
import XCTest

@MainActor
final class BeipMUXCUITests: XCTestCase {
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
            reportedHeight(of: window) >= NSScreen.main!.frame.height - 2
        })
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

    func testWindowsGoldenSessionSemanticsAndBaseline() throws {
        let app = launchApplication(environment: ["BEIPMU_UI_GOLDEN_SESSION": "1"])
        defer { app.terminate() }
        let window = app.windows["mainWindow"]
        let output = window.descendants(matching: .textView)["MU star output"]
        XCTAssertTrue((output.value as? String)?.contains("Golden prompt> Golden room") == true)
        XCTAssertTrue((output.value as? String)?.contains("Remote connection closed.") == true)
        XCTAssertEqual(window.staticTexts["connectionState"].value as? String, "Disconnected")
        XCTAssertEqual(window.buttons["sessionTaskButton"].title, "Untitled")
        try assertScreenshotBaseline(named: "workspace-golden-session", element: window)
    }

    func testThemeDialogAccessibilityAndBaseline() throws {
        let app = launchApplication()
        defer { app.terminate() }
        app.menuBars.menuBarItems["BeipMU"].click()
        app.menuItems["Theme…"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        XCTAssertTrue(sheet.popUpButtons["themeMode"].exists)
        XCTAssertEqual(sheet.colorWells.matching(identifier: "themeForeground").count, 1)
        XCTAssertEqual(sheet.colorWells.matching(identifier: "themeBackground").count, 1)
        XCTAssertEqual(sheet.colorWells.matching(identifier: "themeAccent").count, 1)
        try assertScreenshotBaseline(named: "theme-dialog", element: sheet)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
    }

    func testTextWindowContextMenuAndGlobalSettingsAreAccessible() {
        let app = launchApplication()
        defer { app.terminate() }
        let output = app.windows["mainWindow"].descendants(matching: .textView)["MU star output"]
        output.rightClick()
        for title in [
            "Find…", "Pause", "Split", "Copy screen to clipboard", "Clear",
            "Delete Line", "Use global settings", "Settings…",
        ] {
            XCTAssertTrue(app.menuItems[title].exists, "Missing output context-menu command: \(title)")
        }
        app.typeKey(.escape, modifierFlags: [])

        app.menuBars.menuBarItems["BeipMU"].click()
        app.menuItems["Global Text Window Settings…"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 3))
        XCTAssertTrue(sheet.popUpButtons["textSettingsScope"].exists)
        XCTAssertTrue(sheet.popUpButtons["textSettingsFont"].exists)
        XCTAssertTrue(sheet.textFields["textSettingsFontSize"].exists)
        XCTAssertTrue(sheet.textFields["textSettingsHistory"].exists)
        XCTAssertTrue(sheet.textFields["textSettingsWrappedIndent"].exists)
        XCTAssertTrue(sheet.textFields["textSettingsFixedWidthCharacters"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 3))
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
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["BEIPMU_UI_TESTING"] = "1"
        app.launchEnvironment["BEIPMU_UI_TEST_RESET"] = "1"
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
final class M10ScaleUITests: XCTestCase {
    func testM10ScaleInteractiveResponsivenessRSSAndCleanup() throws {
        continueAfterFailure = false
        let resultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("beipmu-m10-scale-ui-result.json")
        try FileManager.default.createDirectory(
            at: resultURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: resultURL)

        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["BEIPMU_UI_TESTING"] = "1"
        app.launchEnvironment["BEIPMU_UI_TEST_RESET"] = "1"
        app.launchEnvironment["BEIPMU_M10_SCALE"] = "1"
        app.launchEnvironment["BEIPMU_M10_SCALE_RESULT"] = resultURL.path
        app.launch()
        defer { app.terminate() }

        let window = app.windows["mainWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let output = window.descendants(matching: .textView)["MU star output"]
        let input = window.descendants(matching: .textView)["Command input"]
        XCTAssertTrue(waitUntil(timeout: 30) {
            (output.value as? String)?.contains("M10_SCALE_COMPLETE") == true
        })

        input.click()
        input.typeText("m10-responsive")
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
        attachment.name = "m10-scale-responsive"
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
