import AppKit
import Foundation

@MainActor
protocol OutputImageLoaderObserver: AnyObject {
    func outputImageLoaderDidUpdate(accessibilityChanged: Bool)
}

/// Shares output image requests across every output surface for one client
/// session. A URL is attempted once and retains either its decoded image or
/// its terminal failure until the next session starts.
@MainActor
final class OutputImageLoader {
    typealias Downloader = @Sendable (URL) async throws -> Data

    private enum Entry {
        case loading
        case loaded(NSImage)
        case failed
    }

    private final class WeakObserver {
        weak var value: (any OutputImageLoaderObserver)?

        init(_ value: any OutputImageLoaderObserver) {
            self.value = value
        }
    }

    private let downloader: Downloader
    private var entries: [URL: Entry] = [:]
    private var tasks: [URL: Task<Void, Never>] = [:]
    private var observers: [WeakObserver] = []
    private var animationTimer: Timer?
    private var isEnabled = false
    private var reduceMotion = AccessibilityDisplayOptions.current.reduceMotion
    private(set) var requestCountForTesting = 0
    private(set) var animationFrameAdvanceCountForTesting = 0

    var isAnimationTimerActive: Bool { animationTimer != nil }

    init(downloader: @escaping Downloader = OutputImageLoader.download) {
        self.downloader = downloader
    }

    func register(_ observer: any OutputImageLoaderObserver) {
        pruneObservers()
        guard !observers.contains(where: { $0.value === observer }) else { return }
        observers.append(WeakObserver(observer))
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            updateAnimationTimer()
        } else {
            cancelPendingRequests()
            resetAnimationsToFirstFrame()
            updateAnimationTimer()
        }
        notifyObservers(accessibilityChanged: true)
    }

    func setReduceMotion(_ reduceMotion: Bool) {
        guard self.reduceMotion != reduceMotion else { return }
        self.reduceMotion = reduceMotion
        if reduceMotion { resetAnimationsToFirstFrame() }
        updateAnimationTimer()
        notifyObservers()
    }

    func image(for url: URL) -> NSImage? {
        guard case let .loaded(image) = entries[url] else { return nil }
        return image
    }

    func hasFailed(_ url: URL) -> Bool {
        guard case .failed = entries[url] else { return false }
        return true
    }

    func requestIfNeeded(_ url: URL) {
        guard isEnabled,
              Self.isHTTPURL(url),
              !entries.keys.contains(url) else { return }
        entries[url] = .loading
        requestCountForTesting += 1
        notifyObservers(accessibilityChanged: true)
        tasks[url] = Task { [weak self, downloader] in
            do {
                let data = try await downloader(url)
                guard !Task.isCancelled, let self else { return }
                guard let image = NSImage(data: data) else {
                    finish(url, with: .failed)
                    return
                }
                finish(url, with: .loaded(image))
            } catch {
                guard !Task.isCancelled, let self else { return }
                finish(url, with: .failed)
            }
        }
    }

    /// Cancels outstanding downloads and clears per-session attempt history.
    /// The current preview preference remains in effect for the next session.
    func resetForNewSession() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll(keepingCapacity: true)
        resetAnimationsToFirstFrame()
        entries.removeAll(keepingCapacity: true)
        requestCountForTesting = 0
        animationFrameAdvanceCountForTesting = 0
        updateAnimationTimer()
        notifyObservers(accessibilityChanged: true)
    }

    private func finish(_ url: URL, with entry: Entry) {
        tasks.removeValue(forKey: url)
        entries[url] = entry
        updateAnimationTimer()
        notifyObservers(accessibilityChanged: true)
    }

    private func cancelPendingRequests() {
        for (url, task) in tasks {
            task.cancel()
            entries[url] = .failed
        }
        tasks.removeAll(keepingCapacity: true)
    }

    private func updateAnimationTimer() {
        let hasAnimation = isEnabled && !reduceMotion && entries.values.contains { entry in
            guard case let .loaded(image) = entry else { return false }
            return image.representations.contains { representation in
                guard let bitmap = representation as? NSBitmapImageRep else { return false }
                return (bitmap.value(forProperty: .frameCount) as? Int ?? 1) > 1
            }
        }
        if hasAnimation, animationTimer == nil {
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.advanceAnimations() }
            }
        } else if !hasAnimation {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func advanceAnimations() {
        var advanced = false
        for entry in entries.values {
            guard case let .loaded(image) = entry else { continue }
            for case let bitmap as NSBitmapImageRep in image.representations {
                let count = bitmap.value(forProperty: .frameCount) as? Int ?? 1
                guard count > 1 else { continue }
                let current = bitmap.value(forProperty: .currentFrame) as? Int ?? 0
                bitmap.setProperty(.currentFrame, withValue: (current + 1) % count)
                advanced = true
            }
        }
        if advanced {
            animationFrameAdvanceCountForTesting += 1
            notifyObservers()
        }
    }

    private func resetAnimationsToFirstFrame() {
        for entry in entries.values {
            guard case let .loaded(image) = entry else { continue }
            for case let bitmap as NSBitmapImageRep in image.representations {
                if (bitmap.value(forProperty: .frameCount) as? Int ?? 1) > 1 {
                    bitmap.setProperty(.currentFrame, withValue: 0)
                }
            }
        }
    }

    private func notifyObservers(accessibilityChanged: Bool = false) {
        pruneObservers()
        observers.forEach { $0.value?.outputImageLoaderDidUpdate(accessibilityChanged: accessibilityChanged) }
    }

    private func pruneObservers() {
        observers.removeAll { $0.value == nil }
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let response = response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
