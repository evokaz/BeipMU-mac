import AppKit
import AVFoundation
import BeipCore

@MainActor
final class MCPStatusWindowController: NSWindowController, NSWindowDelegate {
    private let status = NSTextField(wrappingLabelWithString: "")
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 100),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        window.title = "MCP Status"
        window.minSize = NSSize(width: 260, height: 80)
        status.font = .systemFont(ofSize: 13)
        status.setAccessibilityIdentifier("mcpStatusText")
        status.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            status.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12),
        ])
        window.contentView = content
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func update(_ value: String) {
        status.stringValue = value
        status.setAccessibilityLabel("MCP status: \(value)")
    }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        window?.appearance = palette.appearance
        window?.backgroundColor = palette.chrome
        status.textColor = palette.foreground
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

@MainActor
final class ClientMediaController: NSObject, AVAudioPlayerDelegate {
    private final class Asset {
        var item: ClientMediaItem
        var data: Data?
        var player: AVAudioPlayer?
        var playWhenReady = false
        var task: Task<Void, Never>?

        init(item: ClientMediaItem) { self.item = item }
    }

    private var assets: [String: Asset] = [:]
    var onError: ((String) -> Void)?
    var isMuted = false {
        didSet { if isMuted { stop(name: nil) } }
    }

    func apply(_ event: ClientMediaEvent) {
        switch event {
        case let .load(item): load(item)
        case let .play(item): play(item)
        case let .stop(name): stop(name: name)
        }
    }

    func load(_ item: ClientMediaItem) {
        guard assets[item.name] == nil else { return }
        let asset = Asset(item: item)
        assets[item.name] = asset
        asset.task = Task { [weak self, weak asset] in
            guard let self, let asset else { return }
            do {
                let (data, response) = try await URLSession.shared.data(from: item.source)
                guard data.count <= 64 * 1_024 * 1_024 else { throw ClientMediaPlaybackError.tooLarge }
                if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
                    throw ClientMediaPlaybackError.http(response.statusCode)
                }
                guard self.assets[item.name] === asset else { return }
                asset.data = data
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                player.prepareToPlay()
                asset.player = player
                asset.task = nil
                if asset.playWhenReady { self.start(asset) }
            } catch is CancellationError {
                return
            } catch {
                guard self.assets[item.name] === asset else { return }
                asset.task = nil
                asset.playWhenReady = false
                self.onError?("Client.Media \(item.name): \(error.localizedDescription)")
            }
        }
    }

    func play(_ item: ClientMediaItem) {
        guard !isMuted else { return }
        if assets[item.name] == nil { load(item) }
        guard let asset = assets[item.name] else { return }
        asset.item = item
        if asset.player == nil { asset.playWhenReady = true; return }
        start(asset)
    }

    func stop(name: String?) {
        let values = name.flatMap { assets[$0].map { [$0] } } ?? Array(assets.values)
        for asset in values {
            asset.playWhenReady = false
            asset.player?.stop()
            asset.player?.currentTime = 0
        }
    }

    func flush() {
        for asset in assets.values {
            asset.task?.cancel()
            asset.player?.stop()
        }
        assets.removeAll()
    }

    var information: String {
        if assets.isEmpty { return "No Client.Media assets are loaded." }
        return assets.values.sorted { $0.item.name.localizedCaseInsensitiveCompare($1.item.name) == .orderedAscending }.map { asset in
            let state = if asset.task != nil { "downloading" } else if asset.player?.isPlaying == true { "playing" } else if asset.data != nil { "ready" } else { "unavailable" }
            let size = asset.data.map { ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .file) } ?? "—"
            let duration = asset.player.map { String(format: "%.2fs", $0.duration) } ?? "—"
            return "\(asset.item.name): \(state), \(size), \(duration), volume \(Int((asset.item.volume * 100).rounded()))%, loops \(asset.item.loops)"
        }.joined(separator: "\n")
    }

    private func start(_ asset: Asset) {
        guard !isMuted, let player = asset.player else { return }
        asset.playWhenReady = false
        player.volume = Float(asset.item.volume)
        player.numberOfLoops = asset.item.loops < 0 ? -1 : max(0, asset.item.loops - 1)
        if asset.item.continues, player.isPlaying { return }
        player.currentTime = 0
        player.play()
    }
}

private enum ClientMediaPlaybackError: LocalizedError {
    case tooLarge
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge: "download exceeds the 64 MB safety limit"
        case let .http(status): "download failed with HTTP status \(status)"
        }
    }
}
