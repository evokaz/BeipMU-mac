import BeipCore
import Foundation

@MainActor
final class SessionLogWriter {
    let url: URL
    let format: SessionLogFormat
    private let renderer: SessionLogRenderer
    private var handle: FileHandle?

    init(
        url: URL,
        options: SessionLogOptions,
        title: String,
        foregroundHex: String,
        backgroundHex: String,
        history: [RenderedLine] = []
    ) throws {
        self.url = url
        format = .infer(from: url)
        renderer = .init(
            format: format,
            options: options,
            title: title,
            foregroundHex: foregroundHex,
            backgroundHex: backgroundHex
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        self.handle = handle
        let size = try handle.seekToEnd()
        if size == 0 { try write(renderer.documentHeader()) }
        try write(renderer.startMarker())
        for line in history { try write(renderer.line(line)) }
    }

    func append(_ line: RenderedLine) throws { try write(renderer.line(line)) }
    func appendTyped(_ text: String, at date: Date = Date()) throws { try write(renderer.typed(text, at: date)) }
    func appendSent(_ text: String, at date: Date = Date()) throws { try write(renderer.sent(text, at: date)) }

    func stop() throws {
        guard handle != nil else { return }
        try write(renderer.stopMarker())
        try handle?.synchronize()
        try handle?.close()
        handle = nil
    }

    private func write(_ text: String) throws {
        guard !text.isEmpty, let handle else { return }
        try handle.write(contentsOf: Data(text.utf8))
    }
}
