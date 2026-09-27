import AppKit
import Foundation

@MainActor
protocol OutputImageLoaderObserver: AnyObject {
    func outputImageLoaderDidUpdate(accessibilityChanged: Bool)
}

/// Shares output image requests across every output surface for one client
/// session. A URL is attempted once per session. Decoded images are retained
/// only while an output surface references them; attempt outcomes remain
/// recorded until the next session starts.
@MainActor
final class OutputImageLoader {
    typealias Downloader = @Sendable (URL) async throws -> Data

    private enum Entry {
        case loading
        case loaded(NSImage)
        case failed
        case released
    }

    enum State: Equatable {
        case notRequested
        case loading
        case loaded
        case failed
        case released
    }

    private final class ObserverRecord {
        weak var observer: (any OutputImageLoaderObserver)?
        var imageReferenceCounts: [URL: Int]

        init(_ observer: any OutputImageLoaderObserver, imageReferenceCounts: [URL: Int] = [:]) {
            self.observer = observer
            self.imageReferenceCounts = imageReferenceCounts
        }
    }

    private let downloader: Downloader
    private var entries: [URL: Entry] = [:]
    private var tasks: [URL: Task<Void, Never>] = [:]
    private var observers: [ObjectIdentifier: ObserverRecord] = [:]
    private var imageReferenceCounts: [URL: Int] = [:]
    private var animationTimer: Timer?
    private var isEnabled = false
    private var reduceMotion = AccessibilityDisplayOptions.current.reduceMotion
    private(set) var requestCountForTesting = 0
    private(set) var animationFrameAdvanceCountForTesting = 0

    var isAnimationTimerActive: Bool { animationTimer != nil }

    init(downloader: @escaping Downloader = OutputImageLoader.download) {
        self.downloader = downloader
    }

    func register(_ observer: any OutputImageLoaderObserver, imageReferenceCounts: [URL: Int] = [:]) {
        _ = pruneDeadObservers()
        let id = ObjectIdentifier(observer)
        guard observers[id] == nil else { return }
        let normalizedCounts = imageReferenceCounts.filter { $0.value > 0 }
        observers[id] = ObserverRecord(observer, imageReferenceCounts: normalizedCounts)
        _ = applyGlobalReferenceDeltas(normalizedCounts)
    }

    func setReferences(
        for observer: any OutputImageLoaderObserver,
        to imageReferenceCounts: [URL: Int]
    ) {
        _ = pruneDeadObservers()
        let id = ObjectIdentifier(observer)
        let record = observers[id] ?? ObserverRecord(observer)
        observers[id] = record
        let nextCounts = imageReferenceCounts.filter { $0.value > 0 }
        var deltas: [URL: Int] = [:]
        for url in Set(record.imageReferenceCounts.keys).union(nextCounts.keys) {
            let delta = (nextCounts[url] ?? 0) - (record.imageReferenceCounts[url] ?? 0)
            if delta != 0 { deltas[url] = delta }
        }
        record.imageReferenceCounts = nextCounts
        if applyGlobalReferenceDeltas(deltas) { notifyObservers(accessibilityChanged: true) }
    }

    func adjustReferences(
        for observer: any OutputImageLoaderObserver,
        by deltas: [URL: Int]
    ) {
        guard !deltas.isEmpty else { return }
        _ = pruneDeadObservers()
        let id = ObjectIdentifier(observer)
        let record = observers[id] ?? ObserverRecord(observer)
        observers[id] = record
        var normalizedDeltas: [URL: Int] = [:]
        for (url, delta) in deltas where delta != 0 {
            let oldCount = record.imageReferenceCounts[url] ?? 0
            let newCount = max(0, oldCount + delta)
            let normalizedDelta = newCount - oldCount
            guard normalizedDelta != 0 else { continue }
            normalizedDeltas[url] = normalizedDelta
            if newCount == 0 {
                record.imageReferenceCounts.removeValue(forKey: url)
            } else {
                record.imageReferenceCounts[url] = newCount
            }
        }
        if applyGlobalReferenceDeltas(normalizedDeltas) { notifyObservers(accessibilityChanged: true) }
    }

    func unregister(_ observer: any OutputImageLoaderObserver) {
        let id = ObjectIdentifier(observer)
        guard let record = observers.removeValue(forKey: id) else { return }
        let deltas = record.imageReferenceCounts.mapValues { -$0 }
        if applyGlobalReferenceDeltas(deltas) { notifyObservers(accessibilityChanged: true) }
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

    func state(for url: URL) -> State {
        switch entries[url] {
        case .loading: .loading
        case .loaded: .loaded
        case .failed: .failed
        case .released: .released
        case nil: .notRequested
        }
    }

    func requestIfNeeded(_ url: URL) {
        guard isEnabled,
              Self.isHTTPURL(url),
              imageReferenceCounts[url, default: 0] > 0,
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

    /// Applies reference changes for all output views at once, then releases
    /// decoded images or pending requests that no retained line still uses.
    private func applyGlobalReferenceDeltas(_ deltas: [URL: Int]) -> Bool {
        var releasedImage = false
        for (url, delta) in deltas where delta != 0 {
            let nextCount = max(0, imageReferenceCounts[url, default: 0] + delta)
            if nextCount == 0 {
                imageReferenceCounts.removeValue(forKey: url)
                releasedImage = releaseImageIfUnreferenced(url) || releasedImage
            } else {
                imageReferenceCounts[url] = nextCount
            }
        }
        if releasedImage { updateAnimationTimer() }
        return releasedImage
    }

    private func releaseImageIfUnreferenced(_ url: URL) -> Bool {
        guard imageReferenceCounts[url, default: 0] == 0 else { return false }
        switch entries[url] {
        case .loading, .loaded:
            tasks.removeValue(forKey: url)?.cancel()
            entries[url] = .released
            return true
        case .failed, .released, nil:
            return false
        }
    }

    @discardableResult
    private func pruneDeadObservers() -> Bool {
        let deadIDs = observers.compactMap { id, record in record.observer == nil ? id : nil }
        var deltas: [URL: Int] = [:]
        for id in deadIDs {
            guard let record = observers.removeValue(forKey: id) else { continue }
            for (url, count) in record.imageReferenceCounts {
                deltas[url, default: 0] -= count
            }
        }
        return applyGlobalReferenceDeltas(deltas)
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
        _ = pruneDeadObservers()
        observers.values.forEach { $0.observer?.outputImageLoaderDidUpdate(accessibilityChanged: accessibilityChanged) }
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
