import Foundation

public actor DelayScheduler {
    public struct Entry: Sendable, Equatable {
        public var id: String
        public var command: String
        public var seconds: Double
        public var repeating: Bool
    }

    private struct Scheduled {
        var entry: Entry
        var token: UUID
        var task: Task<Void, Never>
    }

    private var scheduled: [String: Scheduled] = [:]
    private var nextID = 1
    private let sleep: @Sendable (Duration) async throws -> Void

    public init() {
        sleep = { try await Task.sleep(for: $0) }
    }

    init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.sleep = sleep
    }

    deinit { for value in scheduled.values { value.task.cancel() } }

    @discardableResult
    public func schedule(
        id requestedID: String? = nil,
        repeating: Bool,
        seconds: Double,
        command: String,
        action: @escaping @Sendable (String) async -> Void
    ) -> String {
        let id = requestedID ?? String(nextID)
        nextID += 1
        scheduled[id]?.task.cancel()
        let entry = Entry(id: id, command: command, seconds: seconds, repeating: repeating)
        let token = UUID()
        let duration = Duration.milliseconds(Int64(max(0, seconds) * 1_000))
        let sleep = self.sleep
        let task = Task { [weak self] in
            repeat {
                do { try await sleep(duration) } catch { return }
                guard !Task.isCancelled else { return }
                await action(command)
                if !repeating { await self?.removeCompleted(id, token: token) }
            } while repeating && !Task.isCancelled
        }
        scheduled[id] = .init(entry: entry, token: token, task: task)
        return id
    }

    public func entries() -> [Entry] { scheduled.values.map(\.entry).sorted { $0.id < $1.id } }

    @discardableResult
    public func kill(_ id: String) -> Bool {
        guard let value = scheduled.removeValue(forKey: id) else { return false }
        value.task.cancel()
        return true
    }

    public func killAll() {
        for value in scheduled.values { value.task.cancel() }
        scheduled.removeAll()
    }

    private func removeCompleted(_ id: String, token: UUID) {
        guard scheduled[id]?.token == token else { return }
        scheduled.removeValue(forKey: id)
    }
}
