import AppKit
import BeipCore
import BeipTestSupport
import CoreGraphics
import ImageIO
@testable import BeipUI
import XCTest

@MainActor
final class OutputImageLoaderTests: XCTestCase {
    func testFailedURLIsAttemptedOnceAcrossOutputViewsUntilSessionReset() async throws {
        let downloads = FailedImageDownloads()
        let loader = OutputImageLoader(downloader: { _ in try await downloads.fail() })
        let url = URL(string: "https://images.example.test/missing.gif")!
        let views = [
            VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 420, height: 240)),
            VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 420, height: 240)),
        ]

        for view in views {
            view.imageLoader = loader
            view.showsInlineImagePreviews = true
            view.setItems([.init(
                id: UUID(),
                attributedText: NSAttributedString(string: "https://images.example.test/missing.gif\n"),
                contentRange: NSRange(location: 0, length: (url.absoluteString + "\n").utf16.count),
                assets: [],
                previews: [.init(source: url)]
            )])
            draw(view)
        }

        XCTAssertEqual(loader.requestCountForTesting, 1)
        try await eventuallyOnMainActor("failed inline image request") { loader.hasFailed(url) }
        let attemptsBeforeReset = await downloads.count()
        XCTAssertEqual(attemptsBeforeReset, 1)
        for view in views { draw(view) }
        XCTAssertEqual(loader.requestCountForTesting, 1)

        loader.resetForNewSession()
        XCTAssertFalse(loader.hasFailed(url))
        loader.requestIfNeeded(url)
        XCTAssertEqual(loader.requestCountForTesting, 1)
        try await eventuallyOnMainActor("failed image request after session reset") { loader.hasFailed(url) }
        let attemptsAfterReset = await downloads.count()
        XCTAssertEqual(attemptsAfterReset, 2)
    }

    func testDisabledPreviewsDoNotFetchAvatarsOrInlineImagesAndKeepURLClickable() throws {
        let loader = OutputImageLoader(downloader: { _ in throw URLError(.cannotFindHost) })
        let output = OutputTextView()
        output.setOutputImageLoader(loader)
        let url = URL(string: "https://images.example.test/avatar.png")!
        let line = RenderedLine(
            text: url.absoluteString,
            assets: [
                .init(kind: .avatar, source: url, altText: "Avatar", characterOffset: 0),
                .init(kind: .image, source: url, altText: "Inline image", characterOffset: 0),
            ]
        )
        output.append(line)
        output.flushPendingOutput()
        let view = output.primaryOutputViewForTesting

        draw(view)
        XCTAssertEqual(loader.requestCountForTesting, 0)
        XCTAssertEqual(view.inlinePreviewSourcesForTesting(at: 0), [])

        let text = try XCTUnwrap(view.drawnAttributedTextForTesting(at: 0))
        let linkRange = (text.string as NSString).range(of: url.absoluteString)
        XCTAssertEqual(text.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL, url)
        var openedURL: URL?
        view.onLink = { openedURL = $0 }
        view.activateLinkForTesting(itemID: line.id, at: linkRange.location, modifierFlags: [.command])
        XCTAssertEqual(openedURL, url)
    }

    func testDisablingPreviewsCancelsPendingAttemptWithoutRetryingOnReenable() async throws {
        let loader = OutputImageLoader(downloader: { _ in
            try await Task.sleep(for: .seconds(10))
            return Data()
        })
        let url = URL(string: "https://images.example.test/slow.png")!
        let view = makePreviewView(loader: loader, url: url)
        loader.requestIfNeeded(url)
        XCTAssertEqual(loader.requestCountForTesting, 1)

        view.showsInlineImagePreviews = false
        XCTAssertTrue(loader.hasFailed(url))
        view.showsInlineImagePreviews = true
        loader.requestIfNeeded(url)
        XCTAssertEqual(loader.requestCountForTesting, 1)
        XCTAssertTrue(loader.hasFailed(url))
    }

    func testAnimatedGIFAdvancesLocallyAndStopsWhenPreviewsAreDisabled() async throws {
        let gif = try Self.animatedGIFData()
        let loader = OutputImageLoader(downloader: { _ in gif })
        let url = URL(string: "https://images.example.test/animated.gif")!
        let view = makePreviewView(loader: loader, url: url)
        loader.requestIfNeeded(url)

        try await eventuallyOnMainActor("animated GIF decode") { loader.image(for: url) != nil }
        let image = try XCTUnwrap(loader.image(for: url))
        let bitmap = try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        XCTAssertGreaterThan(bitmap.value(forProperty: .frameCount) as? Int ?? 1, 1)
        try await eventuallyOnMainActor("animated GIF frame advance", timeout: .seconds(2)) {
            loader.animationFrameAdvanceCountForTesting > 0
        }
        XCTAssertEqual(loader.requestCountForTesting, 1)

        view.showsInlineImagePreviews = false
        XCTAssertFalse(loader.isAnimationTimerActive)
        XCTAssertEqual(loader.requestCountForTesting, 1)
    }

    func testImagesStayCachedUntilTheirLastOutputReferenceIsRemoved() async throws {
        let gif = try Self.animatedGIFData()
        let loader = OutputImageLoader(downloader: { _ in gif })
        let url = URL(string: "https://images.example.test/shared.gif")!
        let firstView = makePreviewView(loader: loader, url: url)
        let secondView = makePreviewView(loader: loader, url: url)
        loader.requestIfNeeded(url)

        try await eventuallyOnMainActor("shared GIF decode") { loader.image(for: url) != nil }
        XCTAssertTrue(loader.isAnimationTimerActive)
        XCTAssertEqual(loader.requestCountForTesting, 1)

        firstView.removeAll()
        XCTAssertNotNil(loader.image(for: url))

        secondView.removeAll()
        XCTAssertNil(loader.image(for: url))
        XCTAssertEqual(loader.state(for: url), .released)
        XCTAssertFalse(loader.isAnimationTimerActive)

        firstView.setItems([.init(
            id: UUID(),
            attributedText: NSAttributedString(string: "shared image\n"),
            contentRange: NSRange(location: 0, length: 12),
            assets: [],
            previews: [.init(source: url)]
        )])
        loader.requestIfNeeded(url)
        XCTAssertEqual(loader.requestCountForTesting, 1)
        XCTAssertEqual(loader.state(for: url), .released)
    }

    func testRemovingLastReferenceCancelsPendingAttemptWithoutRetrying() async throws {
        let download = PendingImageDownload()
        let loader = OutputImageLoader(downloader: { _ in try await download.waitForCancellation() })
        let url = URL(string: "https://images.example.test/removed-while-loading.png")!
        let view = makePreviewView(loader: loader, url: url)

        loader.requestIfNeeded(url)
        await download.waitUntilStarted()
        XCTAssertEqual(loader.state(for: url), .loading)

        view.removeAll()
        XCTAssertEqual(loader.state(for: url), .released)
        await download.waitUntilCancelled()

        view.setItems([.init(
            id: UUID(),
            attributedText: NSAttributedString(string: "image\n"),
            contentRange: NSRange(location: 0, length: 6),
            assets: [],
            previews: [.init(source: url)]
        )])
        loader.requestIfNeeded(url)
        XCTAssertEqual(loader.requestCountForTesting, 1)
        XCTAssertEqual(loader.state(for: url), .released)
    }

    func testHistoryEvictionReleasesDecodedImageButKeepsAttemptRecord() async throws {
        let gif = try Self.animatedGIFData()
        let loader = OutputImageLoader(downloader: { _ in gif })
        let url = URL(string: "https://images.example.test/evicted.gif")!
        let view = makePreviewView(loader: loader, url: url)
        view.applyBatch(removingFirst: 0, appending: [
            .init(
                id: UUID(),
                attributedText: NSAttributedString(string: "retained line\n"),
                contentRange: NSRange(location: 0, length: 14),
                assets: []
            ),
        ])
        loader.requestIfNeeded(url)

        try await eventuallyOnMainActor("GIF decode before history eviction") { loader.image(for: url) != nil }
        view.applyBatch(removingFirst: 1, appending: [])

        XCTAssertNil(loader.image(for: url))
        XCTAssertEqual(loader.state(for: url), .released)
        XCTAssertEqual(loader.requestCountForTesting, 1)
    }

    private func makePreviewView(loader: OutputImageLoader, url: URL) -> VirtualizedOutputView {
        let view = VirtualizedOutputView(frame: NSRect(x: 0, y: 0, width: 420, height: 240))
        view.imageLoader = loader
        view.showsInlineImagePreviews = true
        view.setItems([.init(
            id: UUID(),
            attributedText: NSAttributedString(string: "image\n"),
            contentRange: NSRange(location: 0, length: 5),
            assets: [],
            previews: [.init(source: url)]
        )])
        return view
    }

    private func draw(_ view: VirtualizedOutputView) {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(view.bounds.width)),
            pixelsHigh: max(1, Int(view.bounds.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func animatedGIFData() throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            "com.compuserve.gif" as CFString,
            2,
            nil
        ) else { throw URLError(.cannotCreateFile) }

        for color in [CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 0, blue: 1, alpha: 1)] {
            let context = CGContext(
                data: nil,
                width: 2,
                height: 2,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            let frameProperties: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1],
            ]
            CGImageDestinationAddImage(destination, context.makeImage()!, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotCreateFile) }
        return data as Data
    }
}

private actor FailedImageDownloads {
    private var attempts = 0

    func fail() async throws -> Data {
        attempts += 1
        throw URLError(.cannotFindHost)
    }

    func count() -> Int { attempts }
}

private actor PendingImageDownload {
    private var started = false
    private var cancelled = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var cancelledContinuation: CheckedContinuation<Void, Never>?

    func waitForCancellation() async throws -> Data {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        do {
            try await Task.sleep(for: .seconds(60))
            return Data()
        } catch {
            cancelled = true
            cancelledContinuation?.resume()
            cancelledContinuation = nil
            throw error
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancelledContinuation = $0 }
    }
}
