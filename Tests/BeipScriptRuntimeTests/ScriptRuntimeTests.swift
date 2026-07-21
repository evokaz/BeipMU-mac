import BeipScriptRuntime
import XCTest

final class ScriptRuntimeTests: XCTestCase {
    func testPersistentJavaScriptContext() async {
        let runtime = ScriptRuntime()
        _ = await runtime.evaluate("var counter = 40")
        let result = await runtime.evaluate("counter += 2; counter")
        XCTAssertEqual(result, ScriptEvaluation(value: "42", error: nil))
    }

    func testActiveXIsExplicitPlatformException() async {
        let runtime = ScriptRuntime()
        let result = await runtime.evaluate("app.ActiveXObject('Example.Object')")
        XCTAssertNil(result.value)
        XCTAssertTrue(result.error?.contains("not supported on macOS") == true)
    }
}

