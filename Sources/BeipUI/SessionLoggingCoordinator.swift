import BeipAutomation
import BeipCore
import Foundation

/// Owns the lifetime of the writers associated with one client session.
///
/// The coordinator deliberately knows nothing about the logging panel or the
/// window.  Its context supplies the values which can change while a window
/// is alive, and its typed callbacks let the controller retain presentation
/// of notices and failures.
@MainActor
final class SessionLoggingCoordinator {
    struct AutomaticConfiguration {
        var filename: String?
        var appendsDate: Bool
        var enabled: Bool

        init(filename: String? = nil, appendsDate: Bool = false, enabled: Bool = false) {
            self.filename = filename
            self.appendsDate = appendsDate
            self.enabled = enabled
        }
    }

    struct Context {
        let options: @MainActor () -> SessionLogOptions
        let baseWindowTitle: @MainActor () -> String
        let serverName: @MainActor () -> String
        let characterName: @MainActor () -> String
        let loggingPath: @MainActor () -> String
        let workspaceSourceURL: @MainActor () -> URL?
        let themePalette: @MainActor () -> (foreground: String, background: String)
        let automaticConfiguration: @MainActor () -> AutomaticConfiguration
    }

    struct Callbacks {
        let informationalNotice: @MainActor (String) -> Void
        let clientNotice: @MainActor (String) -> Void
        let error: @MainActor (String) -> Void
        let stateChanged: @MainActor () -> Void
    }

    struct ActiveEntry: Equatable {
        let url: URL
        let isAutomatic: Bool
    }

    private struct ActiveLog {
        var template: String
        var rollsOverDaily: Bool
        var isAutomatic: Bool
        var appendsDate: Bool
        var writer: SessionLogWriter
    }

    private let context: Context
    private let callbacks: Callbacks
    private let fileHandleFactory: SessionLogFileHandleFactory?
    private let bufferSizeOverride: Int?
    private var writers: [URL: ActiveLog] = [:]
    private var dailyRolloverTimer: Timer?

    init(
        context: Context,
        callbacks: Callbacks,
        fileHandleFactory: SessionLogFileHandleFactory? = nil,
        bufferSizeOverride: Int? = nil
    ) {
        self.context = context
        self.callbacks = callbacks
        self.fileHandleFactory = fileHandleFactory
        self.bufferSizeOverride = bufferSizeOverride
    }

    var activeLogCount: Int { writers.count }
    var activeURLs: [URL] { Array(writers.keys) }
    var hasDailyRolloverTimer: Bool { dailyRolloverTimer?.isValid == true }
    var isEmpty: Bool { writers.isEmpty }

    var activeEntries: [ActiveEntry] {
        writers.map { url, log in
            ActiveEntry(url: url, isAutomatic: log.isAutomatic)
        }
        .sorted {
            if $0.isAutomatic != $1.isAutomatic { return $0.isAutomatic && !$1.isAutomatic }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    func append(_ line: RenderedLine) {
        rollOverIfNeeded()
        for (_, log) in Array(writers) { log.writer.append(line) }
    }

    func appendTyped(_ text: String) {
        rollOverIfNeeded()
        for (_, log) in Array(writers) { log.writer.appendTyped(text) }
    }

    func appendSent(_ text: String) {
        rollOverIfNeeded()
        for (_, log) in Array(writers) { log.writer.appendSent(text) }
    }

    func appendScript(_ text: String, asLine: Bool) {
        rollOverIfNeeded()
        for (_, log) in Array(writers) {
            if asLine { log.writer.appendScriptLine(text) }
            else { log.writer.appendScript(text) }
        }
    }

    func start(
        template: String,
        history: CommandOutcome.LogHistory,
        outputHistory: [RenderedLine],
        visibleHistory: [RenderedLine],
        appendingDate: Bool = false,
        automatic: Bool = false
    ) {
        let resolution = resolvedURL(template, appendingDate: appendingDate)
        var url = resolution.url
        if url.pathExtension.isEmpty { url.appendPathExtension("txt") }
        guard writers[url] == nil else {
            if !automatic { callbacks.error("Already logging to " + url.path + ".") }
            return
        }

        let initialLines: [RenderedLine] = switch history {
        case .none: []
        case .all: outputHistory
        case .window: visibleHistory
        }
        let palette = context.themePalette()
        do {
            let writer = try makeWriter(
                url: url,
                options: context.options(),
                title: context.baseWindowTitle(),
                foregroundHex: palette.foreground,
                backgroundHex: palette.background,
                history: initialLines
            )
            writers[url] = .init(
                template: template,
                rollsOverDaily: resolution.rollsOverDaily,
                isAutomatic: automatic,
                appendsDate: appendingDate,
                writer: writer
            )
            scheduleDailyRollover()
            callbacks.informationalNotice(
                (automatic ? "Automatic logging" : "Logging") + " to " + url.path + " started."
            )
            callbacks.stateChanged()
        } catch {
            callbacks.error("Cannot create log " + url.path + ": " + error.localizedDescription)
        }
    }

    func stop(at url: URL, announcing: Bool = true) {
        guard let log = writers.removeValue(forKey: url) else {
            callbacks.stateChanged()
            return
        }
        if announcing { callbacks.informationalNotice("Logging to " + url.path + " stopped.") }
        do { try log.writer.stop() }
        catch { callbacks.error("Could not finish log " + url.lastPathComponent + ": " + error.localizedDescription) }
        scheduleDailyRollover()
        callbacks.stateChanged()
    }

    func stopAll(announcing: Bool = true) {
        guard !writers.isEmpty else {
            dailyRolloverTimer?.invalidate()
            dailyRolloverTimer = nil
            callbacks.stateChanged()
            return
        }
        let active = writers
        if announcing {
            for url in active.keys.sorted(by: { $0.path < $1.path }) {
                callbacks.informationalNotice("Logging to " + url.path + " stopped.")
            }
        }
        writers.removeAll()
        scheduleDailyRollover()
        var errors: [String] = []
        for (url, log) in active {
            do { try log.writer.stop() }
            catch { errors.append(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        errors.forEach { callbacks.error("Could not finish log " + $0) }
        callbacks.stateChanged()
    }

    func stopAllIfActive(announcing: Bool) {
        guard !writers.isEmpty else { return }
        stopAll(announcing: announcing)
    }

    func startAutomatic(
        outputHistory: [RenderedLine] = [],
        visibleHistory: [RenderedLine] = [],
        announcingMissingSetup: Bool = false
    ) {
        guard !writers.values.contains(where: \.isAutomatic) else {
            if announcingMissingSetup { callbacks.clientNotice("Automatic log already running.") }
            return
        }
        let settings = context.options()
        let configuration = context.automaticConfiguration()
        let template = configuration.filename ?? settings.defaultLogFilename
        guard configuration.filename != nil || configuration.enabled,
              !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if announcingMissingSetup { callbacks.clientNotice("No automatic log setup.") }
            return
        }
        start(
            template: template,
            history: .none,
            outputHistory: outputHistory,
            visibleHistory: visibleHistory,
            appendingDate: configuration.filename != nil
                ? configuration.appendsDate : settings.appendsDateToFilename,
            automatic: true
        )
    }

    func rollOverIfNeeded(at date: Date = Date()) {
        let pending = writers.map { (url: $0.key, log: $0.value) }
        for entry in pending where entry.log.rollsOverDaily {
            var replacement = resolvedURL(
                entry.log.template,
                at: date,
                appendingDate: entry.log.appendsDate
            )
            if replacement.url.pathExtension.isEmpty { replacement.url.appendPathExtension("txt") }
            guard replacement.url.standardizedFileURL != entry.url else { continue }
            guard writers[replacement.url] == nil else {
                if let old = writers.removeValue(forKey: entry.url) { try? old.writer.stop() }
                continue
            }
            let palette = context.themePalette()
            do {
                let writer = try makeWriter(
                    url: replacement.url,
                    options: context.options(),
                    title: context.baseWindowTitle(),
                    foregroundHex: palette.foreground,
                    backgroundHex: palette.background
                )
                try entry.log.writer.stop()
                writers.removeValue(forKey: entry.url)
                writers[replacement.url] = .init(
                    template: entry.log.template,
                    rollsOverDaily: replacement.rollsOverDaily,
                    isAutomatic: entry.log.isAutomatic,
                    appendsDate: entry.log.appendsDate,
                    writer: writer
                )
            } catch {
                removeFailed([(entry.url, error)])
            }
        }
        callbacks.stateChanged()
    }

    func scheduleDailyRollover() {
        dailyRolloverTimer?.invalidate()
        dailyRolloverTimer = nil
        guard writers.values.contains(where: \.rollsOverDaily) else { return }

        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        guard let midnight = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) else { return }

        let timer = Timer(timeInterval: max(0.001, midnight.timeIntervalSince(now)), repeats: false) {
            [weak self] timer in
            guard self != nil else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dailyRolloverTimer = nil
                self.rollOverIfNeeded()
                self.scheduleDailyRollover()
            }
        }
        dailyRolloverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func removeFailed(_ failures: [(URL, Error)]) {
        guard !failures.isEmpty else { return }
        for (url, error) in failures {
            if let log = writers.removeValue(forKey: url) { try? log.writer.stop() }
            callbacks.error("Logging stopped for " + url.lastPathComponent + ": " + error.localizedDescription)
        }
        scheduleDailyRollover()
        callbacks.stateChanged()
    }

    private func makeWriter(
        url: URL,
        options: SessionLogOptions,
        title: String,
        foregroundHex: String,
        backgroundHex: String,
        history: [RenderedLine] = []
    ) throws -> SessionLogWriter {
        let writer = try SessionLogWriter(
            url: url,
            options: options,
            title: title,
            foregroundHex: foregroundHex,
            backgroundHex: backgroundHex,
            history: history,
            bufferSizeOverride: bufferSizeOverride,
            fileHandleFactory: fileHandleFactory ?? SessionLogWriter.defaultFileHandle,
            failureHandler: { [weak self] failure in
                self?.handleBackgroundFailure(for: url, failure: failure)
            }
        )
        return writer
    }

    private func handleBackgroundFailure(for url: URL, failure: SessionLogWriterFailure) {
        guard let log = writers[url], log.writer.token == failure.token else { return }
        writers.removeValue(forKey: url)
        log.writer.cancel()
        callbacks.error("Logging stopped for " + url.lastPathComponent + ": " + failure.message)
        scheduleDailyRollover()
        callbacks.stateChanged()
    }

    private func resolvedURL(
        _ filename: String,
        at date: Date = Date(),
        appendingDate: Bool = false
    ) -> (url: URL, rollsOverDaily: Bool) {
        let options = context.options()
        let resolution = SessionLogFilename.resolve(
            filename,
            date: date,
            dateFormat: options.fileDateFormat,
            appendingDate: appendingDate,
            serverName: context.serverName(),
            characterName: context.characterName()
        )
        var value = resolution.filename.replacingOccurrences(
            of: "%userprofile%",
            with: FileManager.default.homeDirectoryForCurrentUser.path,
            options: .caseInsensitive
        )
        value = (value as NSString).expandingTildeInPath
        if value.hasPrefix("/") { return (URL(fileURLWithPath: value), resolution.rollsOverDaily) }
        let configuredBase = context.loggingPath()
            .replacingOccurrences(
                of: "%userprofile%",
                with: FileManager.default.homeDirectoryForCurrentUser.path,
                options: .caseInsensitive
            )
            .replacingOccurrences(of: "\\", with: "/")
        let base = !configuredBase.isEmpty
            ? URL(fileURLWithPath: (configuredBase as NSString).expandingTildeInPath, isDirectory: true)
            : context.workspaceSourceURL()?.deletingLastPathComponent().appendingPathComponent("Logs", isDirectory: true)
                ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("BeipMU Logs", isDirectory: true)
        return (base.appendingPathComponent(value), resolution.rollsOverDaily)
    }
}
