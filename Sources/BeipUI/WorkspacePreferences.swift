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
    var checksSpelling = true
    var speechVoiceIdentifier: String?
    var theme = WorkspaceThemeSettings()
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
        checksSpelling: Bool = true,
        speechVoiceIdentifier: String? = nil,
        theme: WorkspaceThemeSettings = .init(),
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
        self.checksSpelling = checksSpelling
        self.speechVoiceIdentifier = speechVoiceIdentifier
        self.theme = theme
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
        checksSpelling = try values.decodeIfPresent(Bool.self, forKey: .checksSpelling) ?? true
        speechVoiceIdentifier = try values.decodeIfPresent(String.self, forKey: .speechVoiceIdentifier)
        theme = try values.decodeIfPresent(WorkspaceThemeSettings.self, forKey: .theme) ?? .init()
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
        result.dockThickness = max(160, min(600, result.dockThickness))
        if ![.left, .right, .top, .bottom].contains(result.lastDockedPlacement) {
            result.lastDockedPlacement = .right
        }
        result.workspaceLayout = result.workspaceLayout?.normalized
        result.workspaceLayouts = result.workspaceLayouts.mapValues(\.normalized)
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
