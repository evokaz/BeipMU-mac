import BeipCore
import Darwin
import Foundation

private struct BenchmarkConfiguration {
    var lineCount = 250_000
    var historyLimit = 10_000
    var queryCount = 100_000
    var minimumLinesPerSecond = 250_000.0
    var minimumQueriesPerSecond = 500_000.0
    var enforceBudgets = true

    init(arguments: [String]) throws {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            func value() throws -> String {
                guard let value = iterator.next() else {
                    throw BenchmarkError.invalidArgument("Missing value after \(argument)")
                }
                return value
            }
            switch argument {
            case "--lines": lineCount = try Self.positiveInteger(value(), name: argument)
            case "--history-limit": historyLimit = try Self.positiveInteger(value(), name: argument)
            case "--queries": queryCount = try Self.positiveInteger(value(), name: argument)
            case "--minimum-lines-per-second":
                let raw = try value()
                guard let parsed = Double(raw), parsed > 0 else {
                    throw BenchmarkError.invalidArgument("Invalid value for \(argument): \(raw)")
                }
                minimumLinesPerSecond = parsed
            case "--minimum-queries-per-second":
                let raw = try value()
                guard let parsed = Double(raw), parsed > 0 else {
                    throw BenchmarkError.invalidArgument("Invalid value for \(argument): \(raw)")
                }
                minimumQueriesPerSecond = parsed
            case "--report-only": enforceBudgets = false
            case "--help":
                print(Self.usage)
                Darwin.exit(EXIT_SUCCESS)
            default: throw BenchmarkError.invalidArgument("Unknown argument: \(argument)")
            }
        }
        historyLimit = min(historyLimit, lineCount)
    }

    static let usage = """
    Usage: BeipWorkspaceBenchmark [options]
      --lines N                       Lines to append (default: 250000)
      --history-limit N               Retained line bound (default: 10000)
      --queries N                     Viewport index queries (default: 100000)
      --minimum-lines-per-second N    Required append throughput (default: 250000)
      --minimum-queries-per-second N  Required viewport queries/sec (default: 500000)
      --report-only                    Emit measurements without enforcing speed budgets
    """

    private static func positiveInteger(_ value: String, name: String) throws -> Int {
        guard let parsed = Int(value), parsed > 0 else {
            throw BenchmarkError.invalidArgument("Invalid value for \(name): \(value)")
        }
        return parsed
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case invalidArgument(String)

    var description: String {
        switch self {
        case let .invalidArgument(value): value
        }
    }
}

private struct BenchmarkReport: Codable {
    var schemaVersion = 1
    var lineCount: Int
    var historyLimit: Int
    var retainedLineCount: Int
    var queryCount: Int
    var historySeconds: Double
    var layoutIndexSeconds: Double
    var querySeconds: Double
    var historyLinesPerSecond: Double
    var layoutLinesPerSecond: Double
    var queryOperationsPerSecond: Double
    var minimumLinesPerSecond: Double
    var minimumQueriesPerSecond: Double
    var budgetsEnforced: Bool
    var checksum: Int
    var passed: Bool
}

private func elapsedSeconds(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
    let components = start.duration(to: clock.now).components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

private func run(_ configuration: BenchmarkConfiguration) -> BenchmarkReport {
    let clock = ContinuousClock()

    var history = OutputHistory(limit: configuration.historyLimit)
    var start = clock.now
    for index in 0..<configuration.lineCount {
        history.append(RenderedLine(text: "Benchmark output line \(index) — UTF-8 ✓"))
    }
    let historySeconds = elapsedSeconds(since: start, clock: clock)

    var layout = LineLayoutIndex()
    start = clock.now
    for index in 0..<configuration.lineCount {
        layout.append(height: Double(18 + index % 4))
        if layout.count > configuration.historyLimit {
            layout.removeFirst(layout.count - configuration.historyLimit)
        }
    }
    let layoutSeconds = elapsedSeconds(since: start, clock: clock)

    var checksum = 0
    let totalHeight = max(1, Int(layout.totalHeight))
    start = clock.now
    for query in 0..<configuration.queryCount {
        let offset = Double((query &* 7_919) % totalHeight)
        checksum &+= layout.index(atVerticalOffset: offset) ?? 0
        checksum &+= layout.visibleRange(intersecting: offset..<(offset + 720)).count
    }
    let querySeconds = elapsedSeconds(since: start, clock: clock)

    let historyRate = Double(configuration.lineCount) / max(historySeconds, 0.000_001)
    let layoutRate = Double(configuration.lineCount) / max(layoutSeconds, 0.000_001)
    let queryRate = Double(configuration.queryCount) / max(querySeconds, 0.000_001)
    let correctnessPassed = history.count == configuration.historyLimit
        && layout.count == configuration.historyLimit
    let performancePassed = historyRate >= configuration.minimumLinesPerSecond
        && layoutRate >= configuration.minimumLinesPerSecond
        && queryRate >= configuration.minimumQueriesPerSecond
    let passed = correctnessPassed && (!configuration.enforceBudgets || performancePassed)

    let report = BenchmarkReport(
        lineCount: configuration.lineCount,
        historyLimit: configuration.historyLimit,
        retainedLineCount: history.count,
        queryCount: configuration.queryCount,
        historySeconds: historySeconds,
        layoutIndexSeconds: layoutSeconds,
        querySeconds: querySeconds,
        historyLinesPerSecond: historyRate,
        layoutLinesPerSecond: layoutRate,
        queryOperationsPerSecond: queryRate,
        minimumLinesPerSecond: configuration.minimumLinesPerSecond,
        minimumQueriesPerSecond: configuration.minimumQueriesPerSecond,
        budgetsEnforced: configuration.enforceBudgets,
        checksum: checksum,
        passed: passed
    )
    return report
}

do {
    let configuration = try BenchmarkConfiguration(arguments: CommandLine.arguments)
    let report = run(configuration)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
    if !report.passed {
        fputs("BeipWorkspaceBenchmark: retention or throughput budget failed\n", stderr)
        Darwin.exit(EXIT_FAILURE)
    }
} catch {
    fputs("BeipWorkspaceBenchmark: \(error)\n", stderr)
    Darwin.exit(EXIT_FAILURE)
}
