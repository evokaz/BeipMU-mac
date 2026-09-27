import Foundation

enum UpdateCheckOutcome: Equatable, Sendable {
    case updateAvailable(AvailableGitHubRelease)
    case upToDate
    case failed
}

@MainActor
final class UpdateCheckCoordinator {
    typealias Fetch = @Sendable (String) async throws -> AvailableGitHubRelease?
    typealias Completion = @MainActor (UpdateCheckOutcome) -> Void

    private let fetch: Fetch
    private var checkTask: Task<UpdateCheckOutcome, Never>?
    private var completion: Completion?

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    func check(
        currentVersion: String,
        manually: Bool,
        completion: @escaping Completion
    ) {
        if checkTask != nil {
            if manually { self.completion = completion }
            return
        }

        self.completion = completion
        let fetch = self.fetch
        let task = Task { () -> UpdateCheckOutcome in
            do {
                guard let release = try await fetch(currentVersion) else { return .upToDate }
                return .updateAvailable(release)
            } catch {
                return .failed
            }
        }
        checkTask = task

        Task { [weak self] in
            let outcome = await task.value
            guard let self else { return }
            checkTask = nil
            let completion = self.completion
            self.completion = nil
            completion?(outcome)
        }
    }
}
