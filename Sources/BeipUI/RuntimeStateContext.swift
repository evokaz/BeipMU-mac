import AppKit
import Foundation

/// The implicit state owned by one BeipMU process.
///
/// Configuration files, macOS preferences, and AppKit's saved window state
/// must all be selected from the same launch identity.  In particular, a
/// UI-test override is accepted only when the process explicitly identifies
/// itself as a UI-test launch.
struct RuntimeStateContext {
    enum Configuration: Equatable {
        case release
        case debug
        case uiTest
    }

    static let releaseBundleIdentifier = "org.beipmu.BeipMU"
    static let debugBundleIdentifier = "org.beipmu.BeipMU.Debug"

    static let uiTestingKey = "BEIPMU_UI_TESTING"
    static let uiTestResetKey = "BEIPMU_UI_TEST_RESET"
    static let uiTestStateDirectoryKey = "BEIPMU_UI_TEST_STATE_DIRECTORY"
    static let uiTestDefaultsSuiteKey = "BEIPMU_UI_TEST_DEFAULTS_SUITE"

    /// The application process has one immutable launch context.  Keeping the
    /// resolver result centralized prevents a later component from silently
    /// selecting a different persistence root.
    static let current = resolve()

    let configuration: Configuration
    let applicationSupportDirectory: URL
    let releaseConfigurationDirectory: URL
    let configurationDirectory: URL
    let defaultsSuiteName: String?
    let isUITesting: Bool

    var defaults: UserDefaults {
        guard let defaultsSuiteName,
              let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            return .standard
        }
        return defaults
    }

    @MainActor
    static func setFrameAutosaveName(_ name: String, for window: NSWindow) {
        guard !current.isUITesting else { return }
        window.setFrameAutosaveName(name)
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        applicationSupportDirectory suppliedSupportDirectory: URL? = nil
    ) -> Self {
        let supportDirectory = (suppliedSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
            .standardizedFileURL
        let releaseDirectory = supportDirectory.appendingPathComponent("BeipMU", isDirectory: true)
        let debugDirectory = supportDirectory.appendingPathComponent("BeipMU-Debug", isDirectory: true)
        let isUITesting = environment[uiTestingKey] == "1"
        let isDebug = bundleIdentifier == debugBundleIdentifier
            || environment["BEIPMU_RUNTIME_CONFIGURATION"]?.caseInsensitiveCompare("Debug") == .orderedSame

        if isUITesting {
            let fallbackDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BeipMU-UI-Test-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            let requestedDirectory = environment[uiTestStateDirectoryKey]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            let selectedDirectory = requestedDirectory
                .map { $0.standardizedFileURL }
                .flatMap { $0 == releaseDirectory ? nil : $0 }
                ?? fallbackDirectory.standardizedFileURL
            let requestedSuite = environment[uiTestDefaultsSuiteKey]
                .flatMap { $0.isEmpty ? nil : $0 }
            let suiteName = requestedSuite ?? "org.beipmu.BeipMU.UITests.\(ProcessInfo.processInfo.processIdentifier)"
            return Self(
                configuration: .uiTest,
                applicationSupportDirectory: supportDirectory,
                releaseConfigurationDirectory: releaseDirectory,
                configurationDirectory: selectedDirectory,
                defaultsSuiteName: suiteName,
                isUITesting: true
            )
        }

        return Self(
            configuration: isDebug ? .debug : .release,
            applicationSupportDirectory: supportDirectory,
            releaseConfigurationDirectory: releaseDirectory,
            configurationDirectory: isDebug ? debugDirectory : releaseDirectory,
            defaultsSuiteName: nil,
            isUITesting: false
        )
    }

    /// Removes only the temporary state explicitly assigned to this UI-test
    /// launch.  Release and Debug contexts cannot invoke this operation.
    func resetUITestState() throws {
        guard isUITesting else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: configurationDirectory.path) {
            try fileManager.removeItem(at: configurationDirectory)
        }
        try fileManager.createDirectory(
            at: configurationDirectory,
            withIntermediateDirectories: true
        )
        if let defaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }
    }
}
