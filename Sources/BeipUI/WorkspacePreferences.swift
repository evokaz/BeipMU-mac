import Foundation
import BeipCore
import BeipPersistence

enum WorkspaceDockPlacement: String, Codable, CaseIterable {
    case hidden, left, right, top, bottom, floating
}

enum WorkspaceThemeMode: String, Codable, CaseIterable {
    case system, light, dark, custom

    var title: String { rawValue.capitalized }
}

struct WorkspaceThemeSettings: Codable, Equatable {
    var mode: WorkspaceThemeMode = .system
    var foregroundHex = "#E6E6E6"
    var backgroundHex = "#0D0D0D"
    var accentHex = "#32A8FF"
}

struct TextWindowSettings: Codable, Equatable {
    var fontName = "Menlo"
    var fontSize = 13.0
    var foregroundHex = "#E6E6E6"
    var backgroundHex = "#0D0D0D"
    var webLinkHex = "#32A8FF"
    var invertBrightness = false
    var usesFanFoldBackgrounds = false
    var fanFoldFirstHex = "#0D0D0D"
    var fanFoldSecondHex = "#151515"
    var historyLimit = 10_000
    var wrappedLineIndent = 10
    var paragraphSpacing = 0
    var usesFixedWidth = false
    var fixedWidthCharacters = 80
    var smoothScrolling = false
    var scrollsToBottomOnNewText = true
    var splitsOnPageUp = true
    var marginLeft = 0
    var marginRight = 0
    var marginTop = 0
    var marginBottom = 0
    var showsTime = false
    var uses24HourTime = true
    var showsDate = false
    var showsDateTimeToolTip = true
    var showsSelectionCopiedPopup = true
    var showsNewContentMarkers = true

    var normalized: Self {
        var value = self
        value.fontSize = max(6, min(96, value.fontSize))
        value.historyLimit = max(100, value.historyLimit)
        value.wrappedLineIndent = max(0, min(500, value.wrappedLineIndent))
        value.paragraphSpacing = max(0, min(100, value.paragraphSpacing))
        value.fixedWidthCharacters = max(20, min(1_000, value.fixedWidthCharacters))
        value.marginLeft = max(0, min(500, value.marginLeft))
        value.marginRight = max(0, min(500, value.marginRight))
        value.marginTop = max(0, min(500, value.marginTop))
        value.marginBottom = max(0, min(500, value.marginBottom))
        return value
    }
}

struct TextWindowSettingsOverride: Codable, Equatable {
    var usesGlobalSettings = true
    var settings = TextWindowSettings()
}

struct InputWindowSettings: Codable, Equatable {
    var fontName = "Menlo"
    var fontSize = 13.0
    var foregroundHex = "#E6E6E6"
    var backgroundHex = "#0D0D0D"
    var resizesToFitContents = false
    var minimumLines = 1
    var maximumLines = 5
    var marginLeft = 5
    var marginTop = 6
    var marginRight = 5
    var marginBottom = 6
    var keepsTextOnSubmit = false
    var localEcho = true
    var localEchoHex = "#00CDCD"

    var normalized: Self {
        var value = self
        value.fontSize = max(6, min(96, value.fontSize))
        value.minimumLines = max(1, min(100, value.minimumLines))
        value.maximumLines = max(value.minimumLines, min(100, value.maximumLines))
        value.marginLeft = max(0, min(500, value.marginLeft))
        value.marginTop = max(0, min(500, value.marginTop))
        value.marginRight = max(0, min(500, value.marginRight))
        value.marginBottom = max(0, min(500, value.marginBottom))
        return value
    }
}

struct InputWindowSettingsOverride: Codable, Equatable {
    var usesGlobalSettings = true
    var settings = InputWindowSettings()
}

struct TextWindowSettingsIdentity: Equatable {
    var world: String?
    var character: String?
    var tab: String?

    private static func key(_ components: [String?]) -> String? {
        let values = components.compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        return values.isEmpty ? nil : values.joined(separator: "/")
    }

    var worldKey: String? { Self.key([world]) }
    var characterKey: String? { Self.key([world, character]) }
    var tabKey: String? { Self.key([world, character, tab]) }
}

struct SpawnTabGroupPreferences: Codable, Equatable {
    var title: String
    var tabs: [String]
    var selectedTab: String?
}

struct SpawnSurfacePreferences: Codable, Equatable {
    var standaloneWindows: [String] = []
    var tabGroups: [SpawnTabGroupPreferences] = []
}

struct SavedWebViewPane: Codable, Equatable {
    var id: String
    var url: URL
    var dock: WebViewDockSide
    var width: Int?
    var height: Int?
    var caption: Bool?
    var frame: WebViewFrame?
    var maximized: Bool

    init?(_ request: WebViewOpenRequest) {
        guard !request.id.isEmpty, let url = request.url, request.source == nil, let dock = request.dock else { return nil }
        id = request.id
        self.url = url
        self.dock = dock
        width = request.width
        height = request.height
        caption = request.caption
        frame = request.frame
        maximized = request.maximized
    }

    var request: WebViewOpenRequest {
        .init(
            id: id,
            url: url,
            dock: dock,
            width: width,
            height: height,
            caption: caption,
            frame: frame,
            maximized: maximized
        )
    }
}

struct AtlasSurfacePreferences: Codable, Equatable {
    var filePath: String?
    var mapIndex = 0
    var currentMapIndex: Int?
    var currentRoomIndex: Int?
    var scale = 1.0
    var originX = 0.0
    var originY = 0.0
    var selectionFilterRaw = AtlasSelectionFilter.all.rawValue
    var liveTracking = false
}

struct WorkspacePreferences: Codable, Equatable {
    var outputHistoryLimit = 10_000
    var showsTimestamps = false
    var usesFanFoldBackgrounds = false
    var outputSplit = false
    var stickyInput = false
    var inputPrefix = ""
    var inputHeight: Double = 64
    var checksSpelling = true
    var speechVoiceIdentifier: String?
    var theme = WorkspaceThemeSettings()
    var globalTextWindowSettings = TextWindowSettings()
    var worldTextWindowSettings: [String: TextWindowSettingsOverride] = [:]
    var characterTextWindowSettings: [String: TextWindowSettingsOverride] = [:]
    var tabTextWindowSettings: [String: TextWindowSettingsOverride] = [:]
    var globalInputWindowSettings = InputWindowSettings()
    var worldInputWindowSettings: [String: InputWindowSettingsOverride] = [:]
    var characterInputWindowSettings: [String: InputWindowSettingsOverride] = [:]
    var tabInputWindowSettings: [String: InputWindowSettingsOverride] = [:]
    var logging = SessionLogOptions()
    var dockPlacement: WorkspaceDockPlacement = .hidden
    var lastDockedPlacement: WorkspaceDockPlacement = .right
    var dockThickness: Double = 280
    var workspaceLayout: WorkspaceLayoutNode?
    var workspaceLayouts: [String: WorkspaceLayoutNode] = [:]
    var characterNotes: [String: String] = [:]
    var spawnSurfaces: [String: SpawnSurfacePreferences] = [:]
    var atlasSurfaces: [String: AtlasSurfacePreferences] = [:]
    var webViewPanes: [String: [SavedWebViewPane]] = [:]
    var tileMapEdits: [String: [String: GMCPTileMap]] = [:]

    init(
        outputHistoryLimit: Int = 10_000,
        showsTimestamps: Bool = false,
        usesFanFoldBackgrounds: Bool = false,
        outputSplit: Bool = false,
        stickyInput: Bool = false,
        inputPrefix: String = "",
        inputHeight: Double = 64,
        checksSpelling: Bool = true,
        speechVoiceIdentifier: String? = nil,
        theme: WorkspaceThemeSettings = .init(),
        globalTextWindowSettings: TextWindowSettings = .init(),
        worldTextWindowSettings: [String: TextWindowSettingsOverride] = [:],
        characterTextWindowSettings: [String: TextWindowSettingsOverride] = [:],
        tabTextWindowSettings: [String: TextWindowSettingsOverride] = [:],
        globalInputWindowSettings: InputWindowSettings = .init(),
        worldInputWindowSettings: [String: InputWindowSettingsOverride] = [:],
        characterInputWindowSettings: [String: InputWindowSettingsOverride] = [:],
        tabInputWindowSettings: [String: InputWindowSettingsOverride] = [:],
        logging: SessionLogOptions = .init(),
        dockPlacement: WorkspaceDockPlacement = .hidden,
        lastDockedPlacement: WorkspaceDockPlacement = .right,
        dockThickness: Double = 280,
        workspaceLayout: WorkspaceLayoutNode? = nil,
        workspaceLayouts: [String: WorkspaceLayoutNode] = [:],
        characterNotes: [String: String] = [:],
        spawnSurfaces: [String: SpawnSurfacePreferences] = [:],
        atlasSurfaces: [String: AtlasSurfacePreferences] = [:],
        webViewPanes: [String: [SavedWebViewPane]] = [:],
        tileMapEdits: [String: [String: GMCPTileMap]] = [:]
    ) {
        self.outputHistoryLimit = outputHistoryLimit
        self.showsTimestamps = showsTimestamps
        self.usesFanFoldBackgrounds = usesFanFoldBackgrounds
        self.outputSplit = outputSplit
        self.stickyInput = stickyInput
        self.inputPrefix = inputPrefix
        self.inputHeight = inputHeight
        self.checksSpelling = checksSpelling
        self.speechVoiceIdentifier = speechVoiceIdentifier
        self.theme = theme
        self.globalTextWindowSettings = globalTextWindowSettings
        self.worldTextWindowSettings = worldTextWindowSettings
        self.characterTextWindowSettings = characterTextWindowSettings
        self.tabTextWindowSettings = tabTextWindowSettings
        self.globalInputWindowSettings = globalInputWindowSettings
        self.worldInputWindowSettings = worldInputWindowSettings
        self.characterInputWindowSettings = characterInputWindowSettings
        self.tabInputWindowSettings = tabInputWindowSettings
        self.logging = logging
        self.dockPlacement = dockPlacement
        self.lastDockedPlacement = lastDockedPlacement
        self.dockThickness = dockThickness
        self.workspaceLayout = workspaceLayout
        self.workspaceLayouts = workspaceLayouts
        self.characterNotes = characterNotes
        self.spawnSurfaces = spawnSurfaces
        self.atlasSurfaces = atlasSurfaces
        self.webViewPanes = webViewPanes
        self.tileMapEdits = tileMapEdits
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outputHistoryLimit = try values.decodeIfPresent(Int.self, forKey: .outputHistoryLimit) ?? 10_000
        showsTimestamps = try values.decodeIfPresent(Bool.self, forKey: .showsTimestamps) ?? false
        usesFanFoldBackgrounds = try values.decodeIfPresent(Bool.self, forKey: .usesFanFoldBackgrounds) ?? false
        outputSplit = try values.decodeIfPresent(Bool.self, forKey: .outputSplit) ?? false
        stickyInput = try values.decodeIfPresent(Bool.self, forKey: .stickyInput) ?? false
        inputPrefix = try values.decodeIfPresent(String.self, forKey: .inputPrefix) ?? ""
        inputHeight = try values.decodeIfPresent(Double.self, forKey: .inputHeight) ?? 64
        checksSpelling = try values.decodeIfPresent(Bool.self, forKey: .checksSpelling) ?? true
        speechVoiceIdentifier = try values.decodeIfPresent(String.self, forKey: .speechVoiceIdentifier)
        theme = try values.decodeIfPresent(WorkspaceThemeSettings.self, forKey: .theme) ?? .init()
        if let saved = try values.decodeIfPresent(TextWindowSettings.self, forKey: .globalTextWindowSettings) {
            globalTextWindowSettings = saved
        } else {
            globalTextWindowSettings = .init(
                foregroundHex: theme.foregroundHex,
                backgroundHex: theme.backgroundHex,
                webLinkHex: theme.accentHex,
                usesFanFoldBackgrounds: usesFanFoldBackgrounds,
                historyLimit: outputHistoryLimit,
                showsTime: showsTimestamps
            )
        }
        worldTextWindowSettings = try values.decodeIfPresent(
            [String: TextWindowSettingsOverride].self,
            forKey: .worldTextWindowSettings
        ) ?? [:]
        characterTextWindowSettings = try values.decodeIfPresent(
            [String: TextWindowSettingsOverride].self,
            forKey: .characterTextWindowSettings
        ) ?? [:]
        tabTextWindowSettings = try values.decodeIfPresent(
            [String: TextWindowSettingsOverride].self,
            forKey: .tabTextWindowSettings
        ) ?? [:]
        globalInputWindowSettings = try values.decodeIfPresent(
            InputWindowSettings.self,
            forKey: .globalInputWindowSettings
        ) ?? .init(
            foregroundHex: theme.foregroundHex,
            backgroundHex: theme.backgroundHex,
            keepsTextOnSubmit: stickyInput
        )
        worldInputWindowSettings = try values.decodeIfPresent(
            [String: InputWindowSettingsOverride].self,
            forKey: .worldInputWindowSettings
        ) ?? [:]
        characterInputWindowSettings = try values.decodeIfPresent(
            [String: InputWindowSettingsOverride].self,
            forKey: .characterInputWindowSettings
        ) ?? [:]
        tabInputWindowSettings = try values.decodeIfPresent(
            [String: InputWindowSettingsOverride].self,
            forKey: .tabInputWindowSettings
        ) ?? [:]
        logging = try values.decodeIfPresent(SessionLogOptions.self, forKey: .logging) ?? .init()
        dockPlacement = try values.decodeIfPresent(WorkspaceDockPlacement.self, forKey: .dockPlacement) ?? .hidden
        lastDockedPlacement = try values.decodeIfPresent(WorkspaceDockPlacement.self, forKey: .lastDockedPlacement) ?? .right
        dockThickness = try values.decodeIfPresent(Double.self, forKey: .dockThickness) ?? 280
        workspaceLayout = try values.decodeIfPresent(WorkspaceLayoutNode.self, forKey: .workspaceLayout)
        workspaceLayouts = try values.decodeIfPresent([String: WorkspaceLayoutNode].self, forKey: .workspaceLayouts) ?? [:]
        characterNotes = try values.decodeIfPresent([String: String].self, forKey: .characterNotes) ?? [:]
        spawnSurfaces = try values.decodeIfPresent([String: SpawnSurfacePreferences].self, forKey: .spawnSurfaces) ?? [:]
        atlasSurfaces = try values.decodeIfPresent([String: AtlasSurfacePreferences].self, forKey: .atlasSurfaces) ?? [:]
        webViewPanes = try values.decodeIfPresent([String: [SavedWebViewPane]].self, forKey: .webViewPanes) ?? [:]
        tileMapEdits = try values.decodeIfPresent([String: [String: GMCPTileMap]].self, forKey: .tileMapEdits) ?? [:]
    }
}

enum WorkspacePreferencesStore {
    private static let key = "BeipMU.WorkspacePreferences.v1"
    private static let uiTestSuiteName = "org.beipmu.BeipMU.UITests"

    static func load(defaults suppliedDefaults: UserDefaults? = nil) -> WorkspacePreferences {
        let defaults = suppliedDefaults ?? activeDefaults
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(WorkspacePreferences.self, from: data) else {
            return .init()
        }
        var result = decoded
        result.outputHistoryLimit = max(100, result.outputHistoryLimit)
        result.inputHeight = max(30, min(1_000, result.inputHeight))
        result.dockThickness = max(160, min(600, result.dockThickness))
        if ![.left, .right, .top, .bottom].contains(result.lastDockedPlacement) {
            result.lastDockedPlacement = .right
        }
        result.workspaceLayout = result.workspaceLayout?.normalized
        result.workspaceLayouts = result.workspaceLayouts.mapValues(\.normalized)
        result.globalTextWindowSettings = result.globalTextWindowSettings.normalized
        result.worldTextWindowSettings = result.worldTextWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        result.characterTextWindowSettings = result.characterTextWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        result.tabTextWindowSettings = result.tabTextWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        result.globalInputWindowSettings = result.globalInputWindowSettings.normalized
        result.worldInputWindowSettings = result.worldInputWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        result.characterInputWindowSettings = result.characterInputWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        result.tabInputWindowSettings = result.tabInputWindowSettings.mapValues {
            .init(usesGlobalSettings: $0.usesGlobalSettings, settings: $0.settings.normalized)
        }
        return result
    }

    static func save(_ preferences: WorkspacePreferences, defaults suppliedDefaults: UserDefaults? = nil) {
        let defaults = suppliedDefaults ?? activeDefaults
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }

    static func resetUITestDefaults() {
        guard ProcessInfo.processInfo.environment["BEIPMU_UI_TESTING"] == "1" else { return }
        activeDefaults.removePersistentDomain(forName: uiTestSuiteName)
    }

    private static var activeDefaults: UserDefaults {
        guard ProcessInfo.processInfo.environment["BEIPMU_UI_TESTING"] == "1",
              let defaults = UserDefaults(suiteName: uiTestSuiteName) else { return .standard }
        return defaults
    }
}

extension WorkspacePreferences {
    func inputWindowSettings(for identity: TextWindowSettingsIdentity) -> InputWindowSettings {
        if let key = identity.tabKey, let override = tabInputWindowSettings[key] {
            return (override.usesGlobalSettings ? globalInputWindowSettings : override.settings).normalized
        }
        if let key = identity.characterKey, let override = characterInputWindowSettings[key] {
            return (override.usesGlobalSettings ? globalInputWindowSettings : override.settings).normalized
        }
        if let key = identity.worldKey, let override = worldInputWindowSettings[key] {
            return (override.usesGlobalSettings ? globalInputWindowSettings : override.settings).normalized
        }
        return globalInputWindowSettings.normalized
    }

    func textWindowSettings(for identity: TextWindowSettingsIdentity) -> TextWindowSettings {
        var resolved = globalTextWindowSettings
        if let key = identity.tabKey, let override = tabTextWindowSettings[key] {
            resolved = override.usesGlobalSettings ? globalTextWindowSettings : override.settings
        } else if let key = identity.characterKey, let override = characterTextWindowSettings[key] {
            resolved = override.usesGlobalSettings ? globalTextWindowSettings : override.settings
        } else if let key = identity.worldKey, let override = worldTextWindowSettings[key] {
            resolved = override.usesGlobalSettings ? globalTextWindowSettings : override.settings
        }
        // These helper behaviors are intentionally global, matching the original
        // Text Window Settings contract.
        resolved.showsDateTimeToolTip = globalTextWindowSettings.showsDateTimeToolTip
        resolved.showsSelectionCopiedPopup = globalTextWindowSettings.showsSelectionCopiedPopup
        resolved.showsNewContentMarkers = globalTextWindowSettings.showsNewContentMarkers
        return resolved
    }
}
