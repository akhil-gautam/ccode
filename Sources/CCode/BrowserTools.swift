import AppKit
@preconcurrency import WebKit
import Observation
import CCodeCore

@MainActor @Observable final class BrowserTab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored weak var workspace: BrowserWorkspace?
    @ObservationIgnored var navigationID = UUID()
    @ObservationIgnored var agentNavigation = false
    @ObservationIgnored var closed = false
    @ObservationIgnored var pickerToken: UUID?
    @ObservationIgnored var pickerEpoch: UUID?
    @ObservationIgnored var pickerOrigin: String?
    @ObservationIgnored private var urlObservation: NSKeyValueObservation?
    var currentURL: URL { webView.url ?? url }
    let manualLogin: Bool
    var url: URL
    var title = "New tab"
    var loading = false
    var error: String?
    var selectedContext: String?
    var selectingElement = false
    var console: [JSONValue] = []
    var network: [JSONValue] = []
    init(url: URL, login: Bool, profile: WKWebsiteDataStore, workspace: BrowserWorkspace) {
        self.url = url; manualLogin = login; self.workspace = workspace
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = profile
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self; webView.isInspectable = true
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, change in
            if let value = change.newValue ?? nil { Task { @MainActor [weak self] in if self?.closed == false { self?.url = value } } }
        }
        if !login {
            configuration.userContentController.add(BrowserLogHandler(tab: self), name: "ccodeDiagnostics")
            configuration.userContentController.addUserScript(WKUserScript(source: BrowserWorkspace.diagnosticsScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            configuration.userContentController.add(BrowserPickerHandler(tab: self), contentWorld: BrowserWorkspace.pickerWorld, name: "ccodePicker")
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationID = UUID(); loading = true; selectedContext = nil; selectingElement = false
        pickerToken = nil; pickerEpoch = nil; pickerOrigin = nil; console = []; network = []; error = nil
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { if let value = webView.url { url = value } }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; title = manualLogin ? "Login" : webView.title ?? url.host ?? "Preview" }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: any Error) { loading = false; error = failure.localizedDescription }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: any Error) { loading = false; error = failure.localizedDescription }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard !closed, let destination = action.request.url,
              ["http", "https"].contains(destination.scheme ?? "") || destination.absoluteString == "about:blank" else { decisionHandler(.cancel); return }
        if agentNavigation, destination.absoluteString != "about:blank",
           workspace?.isAllowed(destination) != true || BrowserWorkspace.isAuthentication(destination) {
            error = "Navigation needs a site grant, or must be opened in a manual login tab."
            loading = false; decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let destination = action.request.url, let workspace else { return nil }
        if agentNavigation && (!workspace.isAllowed(destination) || BrowserWorkspace.isAuthentication(destination)) { error = "Popup needs a site grant or a manual login tab."; return nil }
        do { let tab = try workspace.open(destination, login: manualLogin); tab.agentNavigation = agentNavigation; tab.webView.load(action.request) }
        catch { self.error = error.localizedDescription }
        return nil
    }
    func receiveLog(_ message: WKScriptMessage) {
        guard !closed, !manualLogin, !BrowserWorkspace.isAuthentication(currentURL), workspace?.isAllowed(currentURL) == true,
              message.frameInfo.isMainFrame,
              let bytes = try? JSONSerialization.data(withJSONObject: message.body), bytes.count <= 4096,
              let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { return }
        if value["kind"].string == "console" { console.append(value); console = Array(console.suffix(100)) }
        if value["kind"].string == "network" { network.append(value); network = Array(network.suffix(100)) }
    }
    func dispose() {
        closed = true; navigationID = UUID(); webView.stopLoading()
        urlObservation?.invalidate(); urlObservation = nil
        webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        workspace = nil; console = []; network = []; selectedContext = nil; selectingElement = false
        pickerToken = nil; pickerEpoch = nil; pickerOrigin = nil
    }
}

@MainActor private final class BrowserPickerHandler: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    init(tab: BrowserTab) { self.tab = tab }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let tab else { return }
        tab.workspace?.receivePick(message, tab: tab)
    }
}

@MainActor private final class BrowserLogHandler: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?
    init(tab: BrowserTab) { self.tab = tab }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { tab?.receiveLog(message) }
}

@MainActor @Observable final class BrowserWorkspace {
    private(set) var tabs: [BrowserTab] = []
    var selectedID: UUID? {
        didSet {
            if oldValue != selectedID, let old = tabs.first(where: { $0.id == oldValue }) { stopPicker(old) }
        }
    }
    private(set) var allowedOrigins: Set<String> = []
    @ObservationIgnored private var profile: WKWebsiteDataStore?
    @ObservationIgnored private var server: BrowserToolServer?
    @ObservationIgnored private(set) var endpoint: BrowserToolEndpoint?
    var selected: BrowserTab? { tabs.first { $0.id == selectedID } }
    var hasTabs: Bool { !tabs.isEmpty }

    fileprivate static let pickerWorld = WKContentWorld.world(name: "ccode-element-picker")
    func beginElementPicking(_ id: UUID) async throws {
        guard let tab = tabs.first(where: { $0.id == id }), selectedID == id, !tab.closed, !tab.manualLogin,
              !Self.isAuthentication(tab.currentURL), !tab.loading, !tab.webView.isLoading else {
            throw ACPError.workspace("Pick an element on the selected preview after it finishes loading. Login pages stay manual.")
        }
        let epoch = tab.navigationID, origin = Self.origin(tab.currentURL)
        // Native picking is a user action. It neither requires nor creates an agent site grant.
        _ = try await evaluate(tab, operation: "guard", arguments: [:])
        try Task.checkCancellation()
        guard !tab.closed, selectedID == id, tab.navigationID == epoch, origin == Self.origin(tab.currentURL), !Self.isAuthentication(tab.currentURL) else { throw ACPError.workspace("The page changed. Pick again.") }
        await cancelElementPicking(id)
        let token = UUID()
        tab.pickerToken = token; tab.pickerEpoch = epoch; tab.pickerOrigin = origin
        tab.selectingElement = true; tab.selectedContext = nil
        do {
            _ = try await tab.webView.callAsyncJavaScript(Self.pickerScript, arguments: ["token": token.uuidString], in: nil, contentWorld: Self.pickerWorld)
            try Task.checkCancellation()
            guard !tab.closed, selectedID == id, tab.navigationID == epoch, origin == Self.origin(tab.currentURL), !Self.isAuthentication(tab.currentURL) else { throw ACPError.workspace("The page changed. Pick again.") }
        } catch { if tab.pickerToken == token { await cancelElementPicking(id) }; throw error }
    }
    func cancelElementPicking(_ id: UUID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let token = invalidatePicker(tab)
        await cleanPicker(tab, token: token)
    }
    private func invalidatePicker(_ tab: BrowserTab) -> UUID? {
        let token = tab.pickerToken
        tab.selectingElement = false; tab.pickerToken = nil; tab.pickerEpoch = nil; tab.pickerOrigin = nil
        return token
    }
    private func stopPicker(_ tab: BrowserTab) {
        let token = invalidatePicker(tab)
        Task { @MainActor [weak tab] in if let tab { await self.cleanPicker(tab, token: token) } }
    }
    private func cleanPicker(_ tab: BrowserTab, token: UUID?) async {
        guard let token, !tab.closed else { return }
        _ = try? await tab.webView.callAsyncJavaScript("if(window.__ccodePicker?.token===token) window.__ccodePicker.stop();", arguments: ["token": token.uuidString], in: nil, contentWorld: Self.pickerWorld)
    }
    fileprivate func receivePick(_ message: WKScriptMessage, tab: BrowserTab) {
        guard !tab.closed, tab.selectingElement, selectedID == tab.id, !tab.manualLogin,
              tab.pickerEpoch == tab.navigationID, message.frameInfo.isMainFrame,
              let token = tab.pickerToken, let bytes = try? JSONSerialization.data(withJSONObject: message.body), bytes.count <= 24 * 1024,
              let value = try? JSONDecoder().decode(JSONValue.self, from: bytes), value["token"].string == token.uuidString else { return }
        let safe = !Self.isAuthentication(tab.currentURL) && tab.pickerOrigin == Self.origin(tab.currentURL)
        _ = invalidatePicker(tab)
        guard safe, value["kind"].string == "selected", value["context"]["tag"].optionalString != nil else { return }
        tab.selectedContext = "Browser: \(Self.displayURL(tab.currentURL))\n\(value["context"].pretty)"
    }

    func open(_ url: URL, login: Bool = false, persistentLogin: Bool = false) throws -> BrowserTab {
        guard tabs.count < 5, Self.origin(url) != nil, url.user == nil, url.password == nil else { throw ACPError.workspace("Open an HTTP(S) URL without embedded credentials. Close a tab before opening more than five.") }
        let manual = login || Self.isAuthentication(url)
        if profile == nil { profile = .nonPersistent() }
        let store: WKWebsiteDataStore = manual ? (persistentLogin ? .default() : .nonPersistent()) : profile!
        let tab = BrowserTab(url: url, login: manual, profile: store, workspace: self)
        tabs.append(tab); selectedID = tab.id
        return tab
    }
    func navigate(_ tab: BrowserTab, to url: URL, agent: Bool = false) throws {
        guard tabs.contains(where: { $0 === tab }), !tab.closed, Self.origin(url) != nil, url.user == nil, url.password == nil else { throw ACPError.workspace("Invalid browser tab or URL.") }
        guard !agent || isAllowed(url) && !Self.isAuthentication(url) && !tab.manualLogin else { throw ACPError.workspace("Allow this site in the browser pane before agent navigation. Login stays manual.") }
        guard tab.manualLogin || !Self.isAuthentication(url) else { throw ACPError.workspace("Open authentication pages using Login to isolate their profile.") }
        tab.agentNavigation = agent; tab.url = url; tab.error = nil; tab.webView.load(URLRequest(url: url))
    }
    func allowAgent(on id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), !tab.manualLogin, !Self.isAuthentication(tab.url), let origin = Self.origin(tab.url) else { return }
        allowedOrigins.insert(origin)
    }
    func revokeAgent(on id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), let origin = Self.origin(tab.url) else { return }
        allowedOrigins.remove(origin)
        for tab in tabs where Self.origin(tab.url) == origin { stopPicker(tab); tab.console = []; tab.network = []; tab.selectedContext = nil }
    }
    func isAllowed(_ url: URL) -> Bool { Self.origin(url).map { allowedOrigins.contains($0) } ?? false }
    func closeTab(_ id: UUID) {
        tabs.first { $0.id == id }?.dispose(); tabs.removeAll { $0.id == id }
        if selectedID == id { selectedID = tabs.last?.id }
        if tabs.isEmpty { profile = nil }
    }
    func close() async { await disconnectTools(); for tab in tabs { tab.dispose() }; tabs = []; selectedID = nil; allowedOrigins = []; profile = nil }
    func previewFromLogin(_ id: UUID) async throws -> BrowserTab {
        guard tabs.count < 5, let login = tabs.first(where: { $0.id == id && $0.manualLogin }), !login.closed,
              !Self.isAuthentication(login.currentURL), Self.origin(login.currentURL) != nil else { throw ACPError.workspace("Finish login and open an application page before creating its preview.") }
        let epoch = login.navigationID
        _ = try await evaluate(login, operation: "guard", arguments: [:])
        try Task.checkCancellation()
        guard tabs.contains(where: { $0 === login }), !login.closed, login.navigationID == epoch, !Self.isAuthentication(login.currentURL) else { throw ACPError.workspace("Login page changed. Try the handoff again.") }
        let tab = BrowserTab(url: login.currentURL, login: false, profile: login.webView.configuration.websiteDataStore, workspace: self)
        tabs.append(tab); selectedID = tab.id; allowAgent(on: tab.id)
        return tab
    }
    func prepareTools() async throws -> BrowserToolEndpoint {
        if let endpoint { return endpoint }
        guard server == nil else { throw ACPError.workspace("Browser tools are already starting.") }
        let value = BrowserToolServer(tools: Self.tools) { [weak self] name, arguments in
            guard let self else { throw CancellationError() }
            return try await self.callTool(name, arguments: arguments)
        }
        server = value
        do {
            let endpoint = try await value.start()
            guard server === value, !Task.isCancelled else { await value.stop(); throw CancellationError() }
            self.endpoint = endpoint; return endpoint
        } catch { await value.stop(); if server === value { server = nil }; throw error }
    }
    func disconnectTools() async { let owned = server; server = nil; endpoint = nil; await owned?.stop() }

    func callTool(_ name: String, arguments: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        if name == "browser_tabs" {
            return Self.text(["tabs": .array(tabs.map {
                let manual = $0.manualLogin || Self.isAuthentication($0.currentURL)
                return ["id": .string($0.id.uuidString), "title": .string(manual ? "Manual login" : $0.title), "url": .string(Self.displayURL($0.currentURL)), "manualOnly": .bool(manual), "agentAllowed": .bool(isAllowed($0.currentURL) && !manual)]
            })])
        }
        if name == "browser_open" {
            guard let url = URL(string: arguments["url"].string), isAllowed(url), !Self.isAuthentication(url) else { throw ACPError.workspace("Open the site manually and allow the agent first.") }
            let tab = try open(url); try navigate(tab, to: url, agent: true); try await waitForPage(tab)
            return Self.text(["tabId": .string(tab.id.uuidString), "url": .string(Self.displayURL(tab.url))])
        }
        guard let id = UUID(uuidString: arguments["tabId"].string), let tab = tabs.first(where: { $0.id == id }) else { throw ACPError.workspace("Unknown browser tab.") }
        try authorize(tab)
        if name == "browser_close" { closeTab(id); return Self.text(["closed": true]) }
        if name == "browser_navigate" {
            guard let url = URL(string: arguments["url"].string) else { throw ACPError.workspace("Invalid URL.") }
            try navigate(tab, to: url, agent: true); try await waitForPage(tab)
            return Self.text(["url": .string(Self.displayURL(tab.url))])
        }
        if name == "browser_back" || name == "browser_reload" {
            tab.agentNavigation = true
            if name == "browser_back" { _ = tab.webView.goBack() } else { _ = tab.webView.reload() }
            try await waitForPage(tab); return Self.text(["url": .string(Self.displayURL(tab.url))])
        }
        try await waitForPage(tab); try authorize(tab)
        let epoch = tab.navigationID
        _ = try await evaluate(tab, operation: "guard", arguments: [:])
        try verify(tab, epoch: epoch)
        if name == "browser_screenshot" {
            let config = WKSnapshotConfiguration(); config.rect = tab.webView.bounds; config.snapshotWidth = 1024
            let image = try await tab.webView.takeSnapshot(configuration: config)
            _ = try await evaluate(tab, operation: "guard", arguments: [:]); try verify(tab, epoch: epoch)
            guard let bitmap = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }), let bytes = bitmap.representation(using: .png, properties: [:]), bytes.count <= 2 * 1024 * 1024 else { throw ACPError.workspace("Browser screenshot exceeds the 2 MB limit.") }
            return ["content": [["type": "image", "mimeType": "image/png", "data": .string(bytes.base64EncodedString())]]]
        }
        if name == "browser_diagnostics" { return Self.text(["console": .array(tab.console), "network": .array(tab.network)]) }
        let operations = ["browser_inspect": "inspect", "browser_click": "click", "browser_fill": "fill", "browser_select": "select"]
        guard let operation = operations[name] else { throw ACPError.workspace("Unknown browser tool.") }
        if operation != "inspect" {
            guard let element = arguments["elementId"].optionalString, !element.isEmpty, element.utf8.count <= 100 else { throw ACPError.workspace("Inspect the page first to obtain an element ID.") }
        }
        if operation == "fill" { guard arguments["value"].optionalString != nil, arguments["value"].string.utf8.count <= 8192 else { throw ACPError.workspace("Fill requires text up to 8 KB.") } }
        tab.agentNavigation = true
        let result = try await evaluate(tab, operation: operation, arguments: arguments)
        try verify(tab, epoch: epoch, allowNavigation: operation == "click")
        if operation == "select" { tab.selectedContext = "Browser: \(Self.displayURL(tab.url))\n\(result.pretty)" }
        return Self.text(result)
    }
    private func authorize(_ tab: BrowserTab) throws {
        try Task.checkCancellation()
        guard !tab.closed, !tab.manualLogin, !Self.isAuthentication(tab.currentURL), isAllowed(tab.currentURL) else { throw ACPError.workspace("This page has no agent grant, or is a manual authentication page.") }
    }
    private func verify(_ tab: BrowserTab, epoch: UUID, allowNavigation: Bool = false) throws {
        try authorize(tab)
        guard tabs.contains(where: { $0 === tab }), allowNavigation || tab.navigationID == epoch else { throw ACPError.workspace("Page changed during the browser operation. Inspect it again.") }
    }
    private func waitForPage(_ tab: BrowserTab) async throws {
        let until = ContinuousClock.now + .seconds(10)
        // Allow WebKit to announce a just-submitted navigation before inspecting.
        try await Task.sleep(for: .milliseconds(20))
        while tab.webView.isLoading || tab.loading {
            try Task.checkCancellation(); guard !tab.closed, ContinuousClock.now < until else { throw ACPError.workspace("Browser navigation timed out or tab closed.") }
            try await Task.sleep(for: .milliseconds(25))
        }
        if let error = tab.error { throw ACPError.workspace(error) }
    }
    private func evaluate(_ tab: BrowserTab, operation: String, arguments: JSONValue) async throws -> JSONValue {
        let input: JSONValue = ["operation": .string(operation), "arguments": arguments]
        let raw = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        guard let value = try await tab.webView.callAsyncJavaScript(Self.domScript, arguments: ["payload": raw], in: nil, contentWorld: .page) else { throw ACPError.workspace("Browser returned no document data.") }
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard bytes.count <= 128 * 1024 else { throw ACPError.workspace("Browser response is too large.") }
        return try JSONDecoder().decode(JSONValue.self, from: bytes)
    }
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
    static func isAuthentication(_ url: URL) -> Bool {
        let pieces = url.path.lowercased().split(separator: "/")
        return pieces.contains { ["login", "signin", "sign-in", "sign_in", "oauth", "oauth2", "authorize", "auth", "authentication", "sso"].contains(String($0)) }
    }
    static func displayURL(_ url: URL) -> String { var value = URLComponents(url: url, resolvingAgainstBaseURL: false); value?.query = nil; value?.fragment = nil; value?.user = nil; value?.password = nil; return value?.string ?? "" }
    private static func text(_ value: JSONValue) -> JSONValue { ["content": [["type": "text", "text": .string(value.pretty)]]] }
    static let tools: [JSONValue] = {
        func tool(_ name: String, _ description: String, _ properties: [String: JSONValue], _ required: [String]) -> JSONValue {
            ["name": .string(name), "description": .string(description), "inputSchema": ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]]
        }
        let string: JSONValue = ["type": "string"], tab: [String: JSONValue] = ["tabId": ["type": "string"]]
        return [tool("browser_tabs", "List this session's browser tabs and site grants.", [:], []), tool("browser_open", "Open a new tab on a site explicitly granted in the browser pane.", ["url": string], ["url"])] +
        ["browser_inspect", "browser_screenshot", "browser_diagnostics", "browser_back", "browser_reload", "browser_close"].map { tool($0, "\($0): use the real browser tab. Login pages are manual only.", tab, ["tabId"]) } +
        [tool("browser_navigate", "Navigate within granted sites.", tab.merging(["url": string]) { _, new in new }, ["tabId", "url"]), tool("browser_click", "Click an element ID returned by browser_inspect.", tab.merging(["elementId": string]) { _, new in new }, ["tabId", "elementId"]), tool("browser_fill", "Fill a non-secret text control and dispatch input/change events.", tab.merging(["elementId": string, "value": string]) { _, new in new }, ["tabId", "elementId", "value"]), tool("browser_select", "Highlight an inspected element and return bounded context.", tab.merging(["elementId": string]) { _, new in new }, ["tabId", "elementId"])]
    }()
    private static let domScript = #"""
    const p=JSON.parse(payload), a=p.arguments;
    if(document.querySelector('input[type="password"],input[autocomplete="current-password"],input[autocomplete="new-password"]')) throw new Error('Authentication fields: manual inspection only.');
    if(p.operation==='guard') return {};
    const state=window.__ccodeDOM ||= {nonce:crypto.randomUUID(),next:0,elements:new Map(),ids:new WeakMap()};
    const visible=e=>!!(e.getBoundingClientRect().width&&e.getBoundingClientRect().height)&&getComputedStyle(e).visibility!=='hidden';
    const describe=e=>({id:state.ids.get(e),tag:e.tagName.toLowerCase(),role:e.getAttribute('role')||'',label:(e.getAttribute('aria-label')||e.innerText||e.getAttribute('placeholder')||'').slice(0,1000),type:e.getAttribute('type')||''});
    if(p.operation==='inspect') {
      const elements=Array.from(document.querySelectorAll('a,button,input,textarea,select,[role="button"],[contenteditable="true"]')).filter(visible).slice(0,120);
      for(const e of elements) if(!state.ids.has(e)){const id=state.nonce+'-'+(++state.next);state.ids.set(e,id);state.elements.set(id,e);}
      return {title:document.title,text:(document.body?.innerText||'').slice(0,30000),viewport:{width:innerWidth,height:innerHeight},elements:elements.map(describe)};
    }
    const e=state.elements.get(a.elementId);
    if(!e||!e.isConnected||!visible(e)) throw new Error('Element expired. Inspect the page again.');
    if(p.operation==='click'){e.click();return {clicked:true};}
    if(p.operation==='fill') {
      if(!['INPUT','TEXTAREA'].includes(e.tagName)||['password','hidden','file'].includes(e.type)||e.disabled||e.readOnly) throw new Error('Control cannot be filled.');
      const proto=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto,'value').set.call(e,a.value);
      e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return {filled:true};
    }
    if(p.operation==='select'){e.style.outline='2px solid #cc785c';return {...describe(e),text:(e.innerText||'').slice(0,5000),rect:{x:e.getBoundingClientRect().x,y:e.getBoundingClientRect().y,width:e.getBoundingClientRect().width,height:e.getBoundingClientRect().height}};}
    throw new Error('Unknown browser operation.');
    """#
    private static let pickerScript = #"""
    const unsafe=()=>!!document.querySelector('input[type="password"],input[autocomplete="current-password"],input[autocomplete="new-password"]')||/(^|\/)(login|signin|sign-in|sign_in|oauth2?|auth|authentication|authorize|sso)(\/|$)/i.test(location.pathname);
    if(unsafe()) throw new Error('Authentication pages stay manual.');
    window.__ccodePicker?.stop();
    const outline=document.createElement('div');
    outline.setAttribute('aria-hidden','true');
    outline.style.cssText='position:fixed;pointer-events:none;border:2px solid #cc785c;border-radius:3px;box-sizing:border-box;background:rgba(204,120,92,.08);z-index:2147483647;display:none;';
    document.documentElement.append(outline);
    const visible=e=>e instanceof Element&&e!==outline&&!!(e.getBoundingClientRect().width&&e.getBoundingClientRect().height);
    const send=v=>window.webkit.messageHandlers.ccodePicker.postMessage({token,...v});
    let stopped=false;
    const stop=()=>{if(stopped)return;stopped=true;outline.remove();document.removeEventListener('mousemove',move,true);document.removeEventListener('click',pick,true);document.removeEventListener('keydown',key,true);window.removeEventListener('pagehide',leave);if(window.__ccodePicker?.token===token)delete window.__ccodePicker;};
    const cancel=()=>{stop();send({kind:'cancelled'});};
    const move=event=>{if(unsafe()){cancel();return;}const e=event.target;if(!visible(e)){outline.style.display='none';return;}const r=e.getBoundingClientRect();Object.assign(outline.style,{display:'block',left:r.x+'px',top:r.y+'px',width:r.width+'px',height:r.height+'px'});};
    const selector=e=>{const parts=[];for(let n=e;n&&n!==document.documentElement&&parts.length<8;n=n.parentElement){if(n.id){parts.unshift('#'+CSS.escape(n.id));break;}let part=n.tagName.toLowerCase();const siblings=n.parentElement?Array.from(n.parentElement.children).filter(s=>s.tagName===n.tagName):[];if(siblings.length>1)part+=':nth-of-type('+(siblings.indexOf(n)+1)+')';parts.unshift(part);}return parts.join(' > ').slice(0,2000);};
    const pick=event=>{if(event.button!==0)return;event.preventDefault();event.stopImmediatePropagation();if(unsafe()){cancel();return;}const e=event.target;if(!visible(e))return;const r=e.getBoundingClientRect();const context={tag:e.tagName.toLowerCase(),selector:selector(e),role:e.getAttribute('role')||'',label:(e.getAttribute('aria-label')||e.getAttribute('placeholder')||'').slice(0,1000),text:(e.innerText||'').slice(0,5000),rect:{x:r.x,y:r.y,width:r.width,height:r.height}};stop();send({kind:'selected',context});};
    const key=event=>{if(event.key==='Escape'){event.preventDefault();event.stopImmediatePropagation();cancel();}};
    const leave=()=>stop();
    window.__ccodePicker={token,stop};
    document.addEventListener('mousemove',move,true);document.addEventListener('click',pick,true);document.addEventListener('keydown',key,true);window.addEventListener('pagehide',leave,{once:true});
    return {};
    """#
    fileprivate static let diagnosticsScript = #"""
    (()=>{
      const safe=()=>!document.querySelector('input[type="password"],input[autocomplete="current-password"],input[autocomplete="new-password"]')&&!/(^|\/)(login|signin|sign-in|oauth2?|auth|authorize|sso)(\/|$)/i.test(location.pathname);
      const send=v=>{if(safe())try{window.webkit.messageHandlers.ccodeDiagnostics.postMessage(v)}catch{}};
      const clean=u=>{try{const v=new URL(String(u),location.href);return (v.origin+v.pathname).slice(0,1000)}catch{return '[invalid URL]'}};
      for(const level of ['log','warn','error','info']){const old=console[level].bind(console);console[level]=(...a)=>{old(...a);send({kind:'console',level,text:a.map(v=>typeof v==='string'?v:'[value]').join(' ').slice(0,2000)})};}
      const fetchOriginal=window.fetch.bind(window);window.fetch=async(...a)=>{const url=clean(a[0]?.url||a[0]);const start=performance.now();try{const r=await fetchOriginal(...a);send({kind:'network',url,status:r.status,milliseconds:Math.round(performance.now()-start)});return r}catch(e){send({kind:'network',url,status:0,milliseconds:Math.round(performance.now()-start)});throw e}};
      const open=XMLHttpRequest.prototype.open,sendXHR=XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open=function(method,url,...a){this.__ccodeURL=clean(url);return open.call(this,method,url,...a)};
      XMLHttpRequest.prototype.send=function(...a){this.addEventListener('loadend',()=>send({kind:'network',url:this.__ccodeURL,status:this.status}),{once:true});return sendXHR.apply(this,a)};
    })();
    """#
}
