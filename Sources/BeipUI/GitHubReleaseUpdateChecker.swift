import Foundation

struct AvailableGitHubRelease: Equatable, Sendable {
    let version: String
    let url: URL
}

struct GitHubReleaseUpdateChecker: Sendable {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct ReleaseResponse: Decodable {
        let tagName: String
        let htmlURL: URL
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
        }
    }

    private let endpoint: URL
    private let dataLoader: DataLoader

    init(
        endpoint: URL = URL(string: "https://api.github.com/repos/evokaz/BeipMU-mac/releases/latest")!,
        dataLoader: @escaping DataLoader = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.endpoint = endpoint
        self.dataLoader = dataLoader
    }

    func newerRelease(currentVersion: String) async throws -> AvailableGitHubRelease? {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("BeipMU-mac", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await dataLoader(request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw UpdateCheckError.invalidResponse
        }

        let release = try JSONDecoder().decode(ReleaseResponse.self, from: data)
        guard !release.draft,
              !release.prerelease,
              Self.numericVersion(from: release.tagName) != nil,
              Self.numericVersion(from: currentVersion) != nil,
              Self.isProjectReleaseURL(release.htmlURL) else {
            throw UpdateCheckError.invalidResponse
        }
        guard Self.isNewer(release.tagName, than: currentVersion) else {
            return nil
        }

        return AvailableGitHubRelease(
            version: Self.displayVersion(from: release.tagName),
            url: release.htmlURL
        )
    }

    static func installedMacVersion(marketingVersion: String, buildVersion: String?) -> String {
        // Before independent Mac versioning, bundles reported Windows
        // compatibility version 331 as the short version and stored the Mac
        // release number (0.1–0.3) in CFBundleVersion.
        if marketingVersion == "331",
           let buildVersion,
           numericVersion(from: buildVersion) != nil {
            return buildVersion
        }
        return marketingVersion
    }

    static func isNewer(_ releaseTag: String, than currentVersion: String) -> Bool {
        guard let release = numericVersion(from: releaseTag),
              let current = numericVersion(from: currentVersion) else {
            return false
        }

        for index in 0..<max(release.count, current.count) {
            let releasePart = index < release.count ? release[index] : 0
            let currentPart = index < current.count ? current[index] : 0
            if releasePart != currentPart { return releasePart > currentPart }
        }
        return false
    }

    private static func displayVersion(from tag: String) -> String {
        guard let version = numericVersion(from: tag) else { return tag }
        return version.map(String.init).joined(separator: ".")
    }

    private static func numericVersion(from rawValue: String) -> [Int]? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" { value.removeFirst() }

        // Releases predating independent Mac versioning used tags such as
        // v331-0.3, where the suffix was the actual Mac app version.
        if let separator = value.firstIndex(of: "-") {
            let compatibilityVersion = value[..<separator]
            guard !compatibilityVersion.isEmpty,
                  compatibilityVersion.allSatisfy(\.isNumber) else { return nil }
            value = String(value[value.index(after: separator)...])
        }

        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        let parsed = components.compactMap { Int($0) }
        guard parsed.count == components.count, parsed.allSatisfy({ $0 >= 0 }) else { return nil }
        return parsed
    }

    private static func isProjectReleaseURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com" else { return false }
        return components.path.lowercased().hasPrefix("/evokaz/beipmu-mac/releases/")
    }

    private enum UpdateCheckError: Error {
        case invalidResponse
    }
}
