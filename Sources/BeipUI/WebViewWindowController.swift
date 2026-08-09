import AppKit
import BeipCore
import WebKit

enum WebViewBridgeCommand: Equatable {
    case close
    case isConnected
    case send(text: String, processAliases: Bool)
    case receive(String)
    case display(String)
    case sendGMCP(package: String, json: String)
    case processAliases(String)
    case addToInputHistory(String)
    case property(String)
}

@MainActor
final class WebViewWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    private struct DisplayHook {
        var id: Int
        var regex: NSRegularExpression
        var gag: Bool
    }

    private struct CaptureHook {
        var id: Int
        var begin: NSRegularExpression
        var end: NSRegularExpression
    }

    let logicalID: String
    let webView: WKWebView
    var onClose: (() -> Void)?
    var onCommand: ((WebViewBridgeCommand) throws -> Any?)?
    var onNavigationFinished: (() -> Void)?
    var onNavigationError: ((String) -> Void)?
    private(set) var lastNavigationError: String?
    private(set) var isClosed = false
    private var activeNavigation: WKNavigation?
    private var navigationTimeoutTask: Task<Void, Never>?
    private var navigationGeneration: UInt64 = 0
    private let navigationTimeout: TimeInterval
    private(set) var isDocked = false
    private var displayHooks: [Int: DisplayHook] = [:]
    private var captureHooks: [Int: CaptureHook] = [:]
    private var activeCaptureID: Int?
    private var gmcpPrefixes: [String] = []
    private var wantsConnect = false
    private var wantsDisconnect = false
    private var wantsSend = false
    private var wantsReceive = false
    private var headers: [String: String] = [:]
    private var allowsFileNavigation: Bool
    private(set) var currentRequest: WebViewOpenRequest
    var isServerRequested: Bool { !allowsFileNavigation }
    private let dockingAccessory = DockSurfaceAccessoryViewController()
    var onDockRequest: ((WebViewDockSide) -> Void)? {
        didSet { dockingAccessory.onDockRequest = onDockRequest }
    }

    init(
        id: String,
        request: WebViewOpenRequest = .init(),
        allowsFileNavigation: Bool = true,
        navigationTimeout: TimeInterval = 15
    ) {
        logicalID = id
        self.allowsFileNavigation = allowsFileNavigation
        self.navigationTimeout = max(0.05, navigationTimeout)
        currentRequest = request
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        configuration.userContentController.addUserScript(.init(
            source: Self.bridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        webView = WKWebView(frame: .zero, configuration: configuration)
        let width = request.width ?? request.frame?.width ?? 800
        let height = request.height ?? request.frame?.height ?? 600
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "beipClient")
        window.delegate = self
        window.addTitlebarAccessoryViewController(dockingAccessory)
        window.title = id.isEmpty ? "WebView" : id
        window.minSize = NSSize(width: 240, height: 180)
        window.contentView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setAccessibilityIdentifier("webViewContent")
        webView.setAccessibilityLabel(id.isEmpty ? "Web content" : "Web content: \(id)")
        RuntimeStateContext.setFrameAutosaveName(
            "BeipMUWebView-\(Self.safeAutosaveName(id))",
            for: window
        )
        window.center()
        apply(request)
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ request: WebViewOpenRequest, allowsFileNavigation: Bool? = nil) {
        guard !isClosed else { return }
        currentRequest = request
        if let allowsFileNavigation { self.allowsFileNavigation = allowsFileNavigation }
        headers = request.headers
        lastNavigationError = nil
        navigationTimeoutTask?.cancel()
        navigationGeneration &+= 1
        webView.stopLoading()
        activeNavigation = nil
        if let frame = request.frame {
            window?.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: true)
        } else if request.width != nil || request.height != nil, let window {
            var frame = window.frame
            frame.size.width = CGFloat(request.width ?? Int(frame.width))
            frame.size.height = CGFloat(request.height ?? Int(frame.height))
            window.setFrame(frame, display: true)
        }
        if request.maximized { window?.zoom(nil) }
        if let source = request.source {
            activeNavigation = webView.loadHTMLString(source, baseURL: nil)
            scheduleNavigationTimeout()
        } else if let url = request.url {
            var value = URLRequest(url: url)
            for (name, header) in headers { value.setValue(header, forHTTPHeaderField: name) }
            activeNavigation = webView.load(value)
            scheduleNavigationTimeout()
        }
    }

    func recordDockSide(_ side: WebViewDockSide?) { currentRequest.dock = side }

    func applyTheme(_ palette: WorkspaceThemePalette) {
        window?.appearance = palette.appearance
        window?.backgroundColor = palette.chrome
        injectTheme(palette)
    }

    func contentViewForDocking() -> NSView {
        window?.orderOut(nil)
        if window?.contentView === webView { window?.contentView = nil }
        webView.removeFromSuperview()
        isDocked = true
        return webView
    }

    func showFloating(_ sender: Any?) {
        if isDocked {
            webView.removeFromSuperview()
            window?.contentView = webView
            isDocked = false
        }
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func closeSurface() {
        guard !isClosed else { return }
        invalidateNavigation()
        if isDocked {
            webView.removeFromSuperview()
            window?.contentView = webView
            isDocked = false
        }
        close()
    }

    func connectionChanged(connected: Bool) {
        if connected, wantsConnect { dispatch("connect", [:]) }
        if !connected, wantsDisconnect { dispatch("disconnect", [:]) }
    }

    func observeSent(_ text: String) {
        if wantsSend { dispatch("send", ["text": text]) }
    }

    func observeReceived(_ text: String) {
        if wantsReceive { dispatch("receive", ["text": text]) }
    }

    func observeDisplay(_ line: RenderedLine) -> Bool {
        let range = NSRange(line.text.startIndex..., in: line.text)
        let payload: [String: Any] = [
            "line": ["string": line.text, "length": line.text.utf16.count, "htmlString": line.text],
        ]
        if let id = activeCaptureID, let capture = captureHooks[id] {
            if capture.end.firstMatch(in: line.text, range: range) != nil {
                dispatch("captureChanged", payload.merging(["id": id, "starting": false]) { $1 })
                activeCaptureID = nil
            } else {
                dispatch("captureLine", payload.merging(["id": id]) { $1 })
            }
            return true
        }
        for id in captureHooks.keys.sorted() {
            guard let capture = captureHooks[id], capture.begin.firstMatch(in: line.text, range: range) != nil else { continue }
            activeCaptureID = id
            dispatch("captureChanged", payload.merging(["id": id, "starting": true]) { $1 })
            return true
        }
        for id in displayHooks.keys.sorted() {
            guard let hook = displayHooks[id], hook.regex.firstMatch(in: line.text, range: range) != nil else { continue }
            dispatch("display", payload.merging(["id": id]) { $1 })
            return hook.gag
        }
        return false
    }

    func observeGMCP(_ message: GMCPMessage) {
        let package = message.package.lowercased()
        guard let prefix = gmcpPrefixes.first(where: {
            package == $0 || package.hasPrefix($0 + ".")
        }) else { return }
        dispatch("gmcp", ["prefix": prefix, "package": message.package, "json": message.payload])
    }

    @discardableResult
    func handleBridge(method: String, arguments: [String: Any]) throws -> Any? {
        func string(_ name: String, maximumBytes: Int = 1_048_576) throws -> String {
            guard let value = arguments[name] as? String else { throw WebViewBridgeError.missing(name) }
            guard value.utf8.count <= maximumBytes else { throw WebViewBridgeError.valueTooLarge(name) }
            return value
        }
        func id() throws -> Int {
            guard let number = arguments["id"] as? NSNumber else { throw WebViewBridgeError.missing("id") }
            return number.intValue
        }
        switch method.lowercased() {
        case "closewindow": return try onCommand?(.close)
        case "isconnected": return try onCommand?(.isConnected) ?? false
        case "send": return try onCommand?(.send(text: string("text"), processAliases: arguments["processAliases"] as? Bool ?? false))
        case "receive": return try onCommand?(.receive(string("text")))
        case "display": return try onCommand?(.display(string("text")))
        case "sendgmcp": return try onCommand?(.sendGMCP(package: string("package"), json: string("json")))
        case "processaliases": return try onCommand?(.processAliases(string("text"))) ?? string("text")
        case "addtoinputhistory": return try onCommand?(.addToInputHistory(string("text")))
        case "getpropertystring": return try onCommand?(.property(string("property")))
        case "setonconnect": wantsConnect = arguments["enabled"] as? Bool ?? true
        case "setondisconnect": wantsDisconnect = arguments["enabled"] as? Bool ?? true
        case "setonsend": wantsSend = arguments["enabled"] as? Bool ?? true
        case "setonreceive": wantsReceive = arguments["enabled"] as? Bool ?? true
        case "setondisplay":
            let id = try id()
            guard displayHooks[id] != nil || displayHooks.count < 128 else { throw WebViewBridgeError.tooManyHooks }
            displayHooks[id] = .init(id: id, regex: try regex(string("regex", maximumBytes: 4_096)), gag: arguments["gag"] as? Bool ?? false)
        case "clearondisplay": displayHooks.removeValue(forKey: try id())
        case "setondisplaycapture":
            let id = try id()
            guard captureHooks[id] != nil || captureHooks.count < 32 else { throw WebViewBridgeError.tooManyHooks }
            captureHooks[id] = .init(id: id, begin: try regex(string("begin", maximumBytes: 4_096)), end: try regex(string("end", maximumBytes: 4_096)))
        case "clearondisplaycapture":
            let id = try id()
            guard activeCaptureID != id else { return false }
            return captureHooks.removeValue(forKey: id) != nil
        case "setongmcp":
            let prefix = try string("prefix", maximumBytes: 256).lowercased()
            guard gmcpPrefixes.count < 128 else { throw WebViewBridgeError.tooManyHooks }
            guard !prefix.isEmpty, !gmcpPrefixes.contains(prefix) else { throw WebViewBridgeError.duplicate(prefix) }
            gmcpPrefixes.append(prefix)
        case "clearongmcp":
            let prefix = try string("prefix").lowercased()
            guard let index = gmcpPrefixes.firstIndex(of: prefix) else { return false }
            gmcpPrefixes.remove(at: index)
            return true
        default: throw WebViewBridgeError.unknownMethod(method)
        }
        return true
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame else {
            replyHandler(nil, "The BeipMU client bridge is only available to the main frame")
            return
        }
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else {
            replyHandler(nil, "Malformed client bridge message")
            return
        }
        do {
            replyHandler(try handleBridge(method: method, arguments: body["arguments"] as? [String: Any] ?? [:]), nil)
        } catch {
            replyHandler(nil, error.localizedDescription)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isClosed, navigation === activeNavigation else { return }
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        activeNavigation = nil
        if let title = webView.title, !title.isEmpty { window?.title = title }
        onNavigationFinished?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(navigation, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationFailed(navigation, error: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["http", "https", "about"].contains(scheme) || (scheme == "file" && allowsFileNavigation) { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        invalidateNavigation()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "beipClient", contentWorld: .page)
        let close = onClose
        onClose = nil
        close?()
    }

    private func regex(_ pattern: String) throws -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: pattern) }
        catch { throw WebViewBridgeError.invalidRegex(pattern) }
    }

    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        guard !isClosed, navigation == nil || navigation === activeNavigation else { return }
        // WebKit reports a policy-driven replacement navigation as error 102;
        // it is not a user-visible load failure.
        if (error as NSError).domain == WKError.errorDomain,
           (error as NSError).code == 102 {
            return
        }
        activeNavigation = nil
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        lastNavigationError = error.localizedDescription
        onNavigationError?(error.localizedDescription)
    }

    private func invalidateNavigation() {
        guard !isClosed else { return }
        isClosed = true
        navigationGeneration &+= 1
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        activeNavigation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func scheduleNavigationTimeout() {
        let generation = navigationGeneration
        navigationTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(self?.navigationTimeout ?? 0.05)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.navigationTimedOut(generation: generation)
        }
    }

    private func navigationTimedOut(generation: UInt64) {
        guard !isClosed, generation == navigationGeneration else { return }
        webView.stopLoading()
        activeNavigation = nil
        navigationTimeoutTask = nil
        let message = String(format: "Navigation timed out after %.2f seconds", navigationTimeout)
        lastNavigationError = message
        onNavigationError?(message)
    }

    private func dispatch(_ event: String, _ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8),
              let eventData = try? JSONEncoder().encode(event),
              let eventJSON = String(data: eventData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__beipClientDispatch?.(\(eventJSON), \(json))")
    }

    private func injectTheme(_ palette: WorkspaceThemePalette) {
        let script = """
        (() => { let style=document.getElementById('clientInputOutputStyleVars');
        if(!style){style=document.createElement('style');style.id='clientInputOutputStyleVars';document.head.appendChild(style);}
        style.textContent=`:root{--client-output-background:\(palette.background.hexString);--client-output-foreground:\(palette.foreground.hexString);--client-output-font:ui-monospace;--client-output-font-size:13px;--client-input-background:\(palette.background.hexString);--client-input-foreground:\(palette.foreground.hexString);--client-input-font:ui-monospace;--client-input-font-size:13px;}`; })()
        """
        webView.evaluateJavaScript(script)
    }

    private static func safeAutosaveName(_ id: String) -> String {
        let value = id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "_" }
        return String(value.prefix(80))
    }

    private static let bridgeScript = #"""
    (() => {
      const post=(method,arguments={})=>window.webkit.messageHandlers.beipClient.postMessage({method,arguments});
      const callbacks={display:new Map(),capture:new Map(),gmcp:new Map()};
      const client={
        closeWindow:()=>post('closeWindow'), isConnected:()=>post('isConnected'),
        send:(text,processAliases=false)=>post('send',{text,processAliases}),
        receive:text=>post('receive',{text}), display:text=>post('display',{text}),
        sendGMCP:(packageName,json='')=>post('sendGMCP',{package:packageName,json}),
        processAliases:text=>post('processAliases',{text}), addToInputHistory:text=>post('addToInputHistory',{text}),
        getPropertyString:property=>post('getPropertyString',{property}),
        setOnConnect:callback=>{callbacks.connect=callback;return post('setOnConnect',{enabled:!!callback});},
        setOnDisconnect:callback=>{callbacks.disconnect=callback;return post('setOnDisconnect',{enabled:!!callback});},
        setOnSend:callback=>{callbacks.send=callback;return post('setOnSend',{enabled:!!callback});},
        setOnReceive:callback=>{callbacks.receive=callback;return post('setOnReceive',{enabled:!!callback});},
        setOnDisplay:(id,callback,regex,gag=false)=>{callbacks.display.set(id,callback);return post('setOnDisplay',{id,regex,gag});},
        clearOnDisplay:id=>{callbacks.display.delete(id);return post('clearOnDisplay',{id});},
        setOnDisplayCapture:(id,capture,changed,begin,end)=>{callbacks.capture.set(id,{capture,changed});return post('setOnDisplayCapture',{id,begin,end});},
        clearOnDisplayCapture:id=>{callbacks.capture.delete(id);return post('clearOnDisplayCapture',{id});},
        setOnGMCP:(first,second)=>{const prefix=(typeof first==='string'?first:second);const callback=(typeof first==='string'?second:first);callbacks.gmcp.set(prefix.toLowerCase(),callback);return post('setOnGMCP',{prefix});},
        clearOnGMCP:prefix=>{callbacks.gmcp.delete(prefix.toLowerCase());return post('clearOnGMCP',{prefix});}
      };
      Object.assign(client,{CloseWindow:client.closeWindow,IsConnected:client.isConnected,Send:client.send,
        Receive:client.receive,Display:client.display,SendGMCP:client.sendGMCP,ProcessAliases:client.processAliases,
        AddToInputHistory:client.addToInputHistory,GetPropertyString:client.getPropertyString,
        SetOnConnect:client.setOnConnect,SetOnDisconnect:client.setOnDisconnect,SetOnSend:client.setOnSend,
        SetOnReceive:client.setOnReceive,SetOnDisplay:client.setOnDisplay,ClearOnDisplay:client.clearOnDisplay,
        SetOnDisplayCapture:client.setOnDisplayCapture,ClearOnDisplayCapture:client.clearOnDisplayCapture,
        SetOnGMCP:client.setOnGMCP,ClearOnGMCP:client.clearOnGMCP});
      window.__beipClientDispatch=(event,p)=>{try{
        if(event==='connect'||event==='disconnect'||event==='send'||event==='receive') callbacks[event]?.(p.text);
        else if(event==='display') callbacks.display.get(p.id)?.(p.id,p.line);
        else if(event==='captureLine') callbacks.capture.get(p.id)?.capture?.(p.id,p.line);
        else if(event==='captureChanged') callbacks.capture.get(p.id)?.changed?.(p.id,p.line,p.starting);
        else if(event==='gmcp') callbacks.gmcp.get(p.prefix)?.(p.package,p.json);
      }catch(error){console.error('BeipMU client callback',error);}};
      window.beipClient=client; window.chrome=window.chrome||{}; window.chrome.webview=window.chrome.webview||{};
      window.chrome.webview.hostObjects=window.chrome.webview.hostObjects||{}; window.chrome.webview.hostObjects.client=client;
    })();
    """#
}

private enum WebViewBridgeError: LocalizedError {
    case missing(String)
    case duplicate(String)
    case invalidRegex(String)
    case unknownMethod(String)
    case valueTooLarge(String)
    case tooManyHooks

    var errorDescription: String? {
        switch self {
        case let .missing(name): "WebView client call is missing '\(name)'"
        case let .duplicate(name): "WebView client hook already exists: \(name)"
        case let .invalidRegex(value): "Invalid WebView regular expression: \(value)"
        case let .unknownMethod(name): "Unknown WebView client method: \(name)"
        case let .valueTooLarge(name): "WebView client value is too large: \(name)"
        case .tooManyHooks: "WebView client registered too many hooks"
        }
    }
}
