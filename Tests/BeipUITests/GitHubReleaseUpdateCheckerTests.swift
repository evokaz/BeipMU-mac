import Foundation
import XCTest
@testable import BeipUI

@MainActor
final class GitHubReleaseUpdateCheckerTests: XCTestCase {
    func testVersionComparisonSupportsNewAndHistoricalTagFormats() {
        XCTAssertTrue(GitHubReleaseUpdateChecker.isNewer("v0.5", than: "0.4"))
        XCTAssertTrue(GitHubReleaseUpdateChecker.isNewer("v0.4.1", than: "0.4"))
        XCTAssertTrue(GitHubReleaseUpdateChecker.isNewer("v331-0.4", than: "0.3"))
        XCTAssertFalse(GitHubReleaseUpdateChecker.isNewer("v331-0.3", than: "0.4"))
        XCTAssertFalse(GitHubReleaseUpdateChecker.isNewer("v0.4.0", than: "0.4"))
        XCTAssertFalse(GitHubReleaseUpdateChecker.isNewer("v0.5-beta", than: "0.4"))
        let legacyInstalledVersion = GitHubReleaseUpdateChecker.installedMacVersion(
            marketingVersion: "331",
            buildVersion: "0.3"
        )
        XCTAssertEqual(legacyInstalledVersion, "0.3")
        XCTAssertTrue(GitHubReleaseUpdateChecker.isNewer("v0.4", than: legacyInstalledVersion))
        XCTAssertEqual(
            GitHubReleaseUpdateChecker.installedMacVersion(marketingVersion: "0.4", buildVersion: "4"),
            "0.4"
        )
    }

    func testCheckMakesOneRequestAndReturnsNewRelease() async throws {
        let endpoint = URL(string: "https://api.github.test/repos/evokaz/BeipMU-mac/releases/latest")!
        let recorder = RequestRecorder()
        let responseData = Data("""
        {"tag_name":"v0.5.1","html_url":"https://github.com/evokaz/BeipMU-mac/releases/tag/v0.5.1","draft":false,"prerelease":false}
        """.utf8)
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint) { request in
            await recorder.append(request.url)
            let response = HTTPURLResponse(
                url: endpoint,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (responseData, response)
        }

        let release = try await checker.newerRelease(currentVersion: "0.4")

        XCTAssertEqual(release?.version, "0.5.1")
        XCTAssertEqual(release?.url.absoluteString, "https://github.com/evokaz/BeipMU-mac/releases/tag/v0.5.1")
        let requests = await recorder.snapshot()
        XCTAssertEqual(requests, [endpoint])
    }

    func testCheckIgnoresEqualAndOlderResponses() async throws {
        for (tag, currentVersion, prerelease) in [
            ("v0.4", "0.4", false),
            ("v331-0.3", "0.4", false),
        ] {
            let endpoint = URL(string: "https://api.github.test/releases/latest")!
            let responseData = Data("""
            {"tag_name":"\(tag)","html_url":"https://github.com/evokaz/BeipMU-mac/releases/tag/\(tag)","draft":false,"prerelease":\(prerelease)}
            """.utf8)
            let checker = GitHubReleaseUpdateChecker(endpoint: endpoint) { _ in
                let response = HTTPURLResponse(
                    url: endpoint,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (responseData, response)
            }

            let release = try await checker.newerRelease(currentVersion: currentVersion)
            XCTAssertNil(release)
        }
    }

    func testCheckRejectsPrereleaseResponse() async {
        let endpoint = URL(string: "https://api.github.test/releases/latest")!
        let responseData = Data("""
        {"tag_name":"v0.5-beta","html_url":"https://github.com/evokaz/BeipMU-mac/releases/tag/v0.5-beta","draft":false,"prerelease":true}
        """.utf8)
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint) { _ in
            let response = HTTPURLResponse(
                url: endpoint,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (responseData, response)
        }

        do {
            _ = try await checker.newerRelease(currentVersion: "0.4")
            XCTFail("Expected a prerelease response to be rejected")
        } catch {
            // Manual checks report this as a failure; startup checks stay quiet.
        }
    }

    func testCheckRejectsUnsuccessfulHTTPResponse() async {
        let endpoint = URL(string: "https://api.github.test/releases/latest")!
        let checker = GitHubReleaseUpdateChecker(endpoint: endpoint) { _ in
            let response = HTTPURLResponse(
                url: endpoint,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }

        do {
            _ = try await checker.newerRelease(currentVersion: "0.4")
            XCTFail("Expected a non-200 response to fail")
        } catch {
            // Launch code intentionally suppresses this error and continues normally.
        }
    }

    func testManualCheckJoinsStartupCheckAndReportsOneResult() async {
        let fetcher = ControlledReleaseFetcher()
        let coordinator = UpdateCheckCoordinator { version in
            try await fetcher.fetch(version)
        }
        var startupResults: [UpdateCheckOutcome] = []
        var manualResults: [UpdateCheckOutcome] = []
        let manualResult = expectation(description: "manual check gets the shared result")

        coordinator.check(currentVersion: "0.4", manually: false) {
            startupResults.append($0)
        }
        await fetcher.waitUntilStarted()
        coordinator.check(currentVersion: "0.4", manually: true) {
            manualResults.append($0)
            manualResult.fulfill()
        }
        await fetcher.complete(nil)
        await fulfillment(of: [manualResult], timeout: 1)

        let calls = await fetcher.numberOfCalls()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(startupResults.isEmpty)
        XCTAssertEqual(manualResults, [.upToDate])
    }

    func testManualCheckReceivesFailureOutcome() async {
        let coordinator = UpdateCheckCoordinator { _ in
            throw URLError(.notConnectedToInternet)
        }
        let failed = expectation(description: "manual check reports a network failure")
        var result: UpdateCheckOutcome?

        coordinator.check(currentVersion: "0.4", manually: true) {
            result = $0
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 1)

        XCTAssertEqual(result, .failed)
    }
}

private actor RequestRecorder {
    private var urls: [URL?] = []

    func append(_ url: URL?) {
        urls.append(url)
    }

    func snapshot() -> [URL?] { urls }
}

private actor ControlledReleaseFetcher {
    private var calls = 0
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var resultContinuation: CheckedContinuation<AvailableGitHubRelease?, Error>?

    func fetch(_ version: String) async throws -> AvailableGitHubRelease? {
        calls += 1
        startContinuation?.resume()
        startContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func complete(_ release: AvailableGitHubRelease?) {
        resultContinuation?.resume(returning: release)
        resultContinuation = nil
    }

    func numberOfCalls() -> Int { calls }
}
