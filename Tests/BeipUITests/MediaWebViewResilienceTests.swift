import BeipCore
import Foundation
@testable import BeipUI
import XCTest

final class MediaWebViewResilienceTests: XCTestCase {
    @MainActor
    func testClientMediaFailureMatrixIsBoundedRetryableAndRemainsUsable() async throws {
        let validMedia = try Data(contentsOf: Self.fixtureURL("notify.wav"))
        let cases: [(name: String, step: M9MediaLoader.Step)] = [
            ("dns", .urlError(.cannotFindHost)),
            ("refusal", .urlError(.cannotConnectToHost)),
            ("timeout", .urlError(.timedOut)),
            ("http", .response(data: Data(), statusCode: 503, expectedLength: 0)),
            ("redirect", .urlError(.httpTooManyRedirects)),
            ("truncated", .urlError(.networkConnectionLost)),
            (
                "oversized",
                .response(data: Data(repeating: 0, count: 1_025), statusCode: 200, expectedLength: 1_025)
            ),
            ("invalid", .response(data: Data(), statusCode: 200, expectedLength: 0)),
        ]

        for testCase in cases {
            let loader = M9MediaLoader(steps: [
                testCase.step,
                .response(
                    data: validMedia,
                    statusCode: 200,
                    expectedLength: Int64(validMedia.count)
                ),
            ])
            let controller = ClientMediaController(
                maximumDownloadBytes: 1_024,
                requestTimeout: 0.05,
                download: { request, _ in try await loader.load(request) }
            )
            let failed = expectation(description: "\(testCase.name) media failure")
            var errorMessage = ""
            controller.onError = { message in
                errorMessage = message
                failed.fulfill()
            }
            let item = ClientMediaItem(
                name: "\(testCase.name).wav",
                source: URL(string: "https://media.invalid/\(testCase.name).wav")!
            )
            controller.apply(.play(item))
            await fulfillment(of: [failed], timeout: 1)

            XCTAssertTrue(errorMessage.contains("Client.Media \(testCase.name).wav"), testCase.name)
            XCTAssertEqual(controller.information, "No Client.Media assets are loaded.", testCase.name)
            let firstRequestTimeout = await loader.firstRequestTimeout()
            XCTAssertEqual(firstRequestTimeout, 0.05, accuracy: 0.001, testCase.name)

            controller.apply(.play(item))
            try await waitUntil("\(testCase.name) retry") {
                !controller.information.contains("downloading")
                    && controller.information.contains("\(testCase.name).wav")
            }
            XCTAssertTrue(
                controller.information.contains("ready") || controller.information.contains("playing"),
                "\(testCase.name): \(controller.information)"
            )
            controller.flush()
            XCTAssertEqual(controller.information, "No Client.Media assets are loaded.")
        }
    }

    @MainActor
    func testWebViewNavigationFailureMalformedUpdateAndCloseRacesRecoverCleanly() async throws {
        var state = WebViewProtocolState()
        guard case let .open(first) = try state.consume(.init(
            package: "webview.open",
            payload: #"{"id":"status","source":"<p>first</p>"}"#
        )) else {
            return XCTFail("missing initial WebView open")
        }
        XCTAssertEqual(first.source, "<p>first</p>")
        XCTAssertThrowsError(try state.consume(.init(
            package: "webview.open",
            payload: #"{"id":"status","url":"#
        )))
        guard case let .open(update) = try state.consume(.init(
            package: "webview.open",
            payload: #"{"id":"status","source":"<p>recovered</p>"}"#
        )) else {
            return XCTFail("missing recovered WebView update")
        }
        XCTAssertEqual(update.source, "<p>recovered</p>")
        XCTAssertEqual(
            try state.consume(.init(package: "webview.close", payload: #"{"id":"status"}"#)),
            .close(id: "status")
        )
        XCTAssertEqual(
            try state.consume(.init(package: "webview.close", payload: #"{"id":"status"}"#)),
            .close(id: "status")
        )

        let controller = WebViewWindowController(id: "M9 WebView", navigationTimeout: 1)
        controller.showWindow(nil)
        let unreachable = expectation(description: "unreachable WebView navigation")
        controller.onNavigationError = { _ in unreachable.fulfill() }
        controller.apply(.init(
            id: "M9 WebView",
            url: URL(string: "http://127.0.0.1:1/unreachable")!
        ))
        controller.webView(
            controller.webView,
            didFailProvisionalNavigation: nil,
            withError: URLError(.cannotConnectToHost)
        )
        await fulfillment(of: [unreachable], timeout: 3)
        XCTAssertNotNil(controller.lastNavigationError)

        let recovered = expectation(description: "WebView recovery navigation")
        controller.onNavigationFinished = { recovered.fulfill() }
        controller.apply(.init(id: "M9 WebView", source: "<title>Recovered</title><p>usable</p>"))
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertNil(controller.lastNavigationError)
        XCTAssertEqual(controller.currentRequest.source, "<title>Recovered</title><p>usable</p>")

        let updated = expectation(description: "latest WebView update wins")
        controller.onNavigationFinished = { updated.fulfill() }
        var staleFailureCount = 0
        controller.onNavigationError = { _ in staleFailureCount += 1 }
        controller.apply(.init(
            id: "M9 WebView",
            url: URL(string: "http://127.0.0.1:1/stale")!
        ))
        controller.apply(.init(id: "M9 WebView", source: "<p>latest update</p>"))
        await fulfillment(of: [updated], timeout: 3)
        XCTAssertEqual(staleFailureCount, 0)
        XCTAssertNil(controller.lastNavigationError)

        controller.apply(.init(
            id: "M9 WebView",
            url: URL(string: "http://127.0.0.1:1/close-race")!
        ))
        controller.closeSurface()
        try await Task.sleep(for: .milliseconds(100))
        let closedRequest = controller.currentRequest
        controller.apply(.init(id: "M9 WebView", source: "<p>must not reopen</p>"))
        XCTAssertTrue(controller.isClosed)
        XCTAssertEqual(controller.currentRequest, closedRequest)
        XCTAssertEqual(staleFailureCount, 0)
    }

    private static func fixtureURL(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(path)
    }
}

private actor M9MediaLoader {
    enum Step: Sendable {
        case urlError(URLError.Code)
        case response(data: Data, statusCode: Int?, expectedLength: Int64)
    }

    private var steps: [Step]
    private var requestTimeouts: [TimeInterval] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func load(_ request: URLRequest) throws -> ClientMediaDownloadResult {
        requestTimeouts.append(request.timeoutInterval)
        guard !steps.isEmpty else { throw URLError(.unknown) }
        switch steps.removeFirst() {
        case let .urlError(code): throw URLError(code)
        case let .response(data, statusCode, expectedLength):
            return .init(
                data: data,
                statusCode: statusCode,
                expectedContentLength: expectedLength
            )
        }
    }

    func firstRequestTimeout() -> TimeInterval {
        requestTimeouts.first ?? 0
    }
}

@MainActor
private func waitUntil(
    _ operation: String,
    timeout: Duration = .seconds(2),
    condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw M9MediaWebViewTestError.timeout(operation)
}

private enum M9MediaWebViewTestError: LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case let .timeout(operation): "Timed out waiting for \(operation)"
        }
    }
}
