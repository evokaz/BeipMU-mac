import XCTest
@testable import BeipCore

final class WebViewProtocolTests: XCTestCase {
    func testOpenParsesEveryFieldAndSourceTakesPrecedence() throws {
        var state = WebViewProtocolState()
        let event = try state.consume(.init(
            package: "WebView.Open",
            payload: #"{"id":"Editor","dock":"right","width":500,"height":400,"caption":false,"url":"https://ignored.example/","source":"<h1>Edit</h1>","http-request-headers":{"Session-Key":"abc"}}"#
        ))
        guard case let .open(request) = event else { return XCTFail("missing open") }
        XCTAssertEqual(request.id, "Editor")
        XCTAssertEqual(request.dock, .right)
        XCTAssertEqual(request.width, 500)
        XCTAssertEqual(request.height, 400)
        XCTAssertEqual(request.caption, false)
        XCTAssertNil(request.url)
        XCTAssertEqual(request.source, "<h1>Edit</h1>")
        XCTAssertEqual(request.headers, ["Session-Key": "abc"])
        XCTAssertEqual(request.permissionSummary, "<h1>Edit</h1>")
    }

    func testURLCloseAndUnrelatedPackages() throws {
        var state = WebViewProtocolState()
        let event = try state.consume(.init(package: "webview.open", payload: #"{"url":"https://example.com/page"}"#))
        guard case let .open(request) = event else { return XCTFail("missing open") }
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/page")
        XCTAssertEqual(try state.consume(.init(package: "WEBVIEW.CLOSE", payload: #"{"id":"Editor"}"#)), .close(id: "Editor"))
        XCTAssertNil(try state.consume(.init(package: "Other.Package", payload: #"{}"#)))
    }

    func testServerRequestsRejectUnsafeURLsHeadersAndDimensions() {
        var state = WebViewProtocolState()
        XCTAssertThrowsError(try state.consume(.init(package: "webview.open", payload: #"{"url":"file:///etc/passwd"}"#))) {
            XCTAssertEqual($0 as? WebViewProtocolError, .invalidServerURL("file:///etc/passwd"))
        }
        XCTAssertThrowsError(try state.consume(.init(package: "webview.open", payload: #"{"width":20}"#))) {
            XCTAssertEqual($0 as? WebViewProtocolError, .invalidDimension("width"))
        }
        XCTAssertThrowsError(try state.consume(.init(package: "webview.open", payload: "{\"http-request-headers\":{\"X-Test\":\"bad\\nvalue\"}}"))) {
            XCTAssertEqual($0 as? WebViewProtocolError, .invalidHeader("X-Test"))
        }
    }

    func testServerWebViewPolicyCodableValuesMatchV331() throws {
        XCTAssertEqual(ServerWebViewPolicy.ignore.rawValue, 0)
        XCTAssertEqual(ServerWebViewPolicy.allow.rawValue, 1)
        XCTAssertEqual(ServerWebViewPolicy.ask.rawValue, 2)
        XCTAssertEqual(try JSONDecoder().decode(ServerWebViewPolicy.self, from: Data("2".utf8)), .ask)
    }
}
