import XCTest
import AppKit
import SwiftUI
import WebKit
import Network
import Darwin
import CCodeCore
@testable import CCode

final class BrowserSessionTests: XCTestCase {
    @MainActor func testSessionDevServerSurvivesPaneAndAgentClosureButShutdownReapsIt() async throws {
        let f = try await fixture(http: true), port = try await freePort(), root = URL(fileURLWithPath: f.chat.workspace.root)
        let script = root.appendingPathComponent("serve.py")
        try "import os,pathlib,http.server\npathlib.Path('pid').write_text(str(os.getpid()))\nhttp.server.HTTPServer(('127.0.0.1',\(port)),http.server.SimpleHTTPRequestHandler).serve_forever()\n".write(to: script, atomically: true, encoding: .utf8)
        try "Preview fixture".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let config = PreviewLaunchConfiguration(executable: "/usr/bin/python3", arguments: [script.path], directory: root.path, url: url.absoluteString)
        try await f.store.startPreview(f.chat, configuration: config)
        XCTAssertTrue(f.chat.previewActive); XCTAssertFalse(f.chat.previewStarting)
        XCTAssertEqual(f.chat.transcript.previewLaunch, config)
        let tab = try XCTUnwrap(f.chat.browserWorkspace.selected)
        XCTAssertEqual(tab.url, url); XCTAssertTrue(f.chat.browserWorkspace.isAllowed(url))
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("pid"), encoding: .utf8)))
        f.store.pane = nil; await f.store.disconnect(f.chat)
        let (bytes, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "Preview fixture")
        await f.store.shutdown(); XCTAssertEqual(kill(pid, 0), -1); XCTAssertFalse(f.chat.previewActive)
    }
    @MainActor func testNegotiatedSessionReceivesActualOwnedHTTPServerWithoutPersistingToken() async throws {
        let f = try await fixture(http: true)
        try await f.store.setBrowserTools(f.chat, enabled: true)
        try await f.store.connect(f.chat)
        let calls = try audit(f.audit), params = try XCTUnwrap(calls.last { $0["method"].string == "session/new" })["params"]
        let server = try XCTUnwrap(params["mcpServers"].array.first)
        XCTAssertEqual(server["type"].string, "http"); XCTAssertEqual(server["name"].string, "ccode-browser")
        let endpoint = try XCTUnwrap(URL(string: server["url"].string))
        let authorization = server["headers"].array.first?["value"].string ?? ""
        XCTAssertTrue(authorization.hasPrefix("Bearer "))
        var request = URLRequest(url: endpoint); request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 405)
        let saved = String(decoding: try JSONEncoder().encode(f.chat.transcript), as: UTF8.self)
        XCTAssertFalse(saved.contains(authorization)); XCTAssertFalse(saved.contains(endpoint.absoluteString))
        let browser = f.chat.browserWorkspace, tab = try browser.open(URL(string: "http://127.0.0.1:38931/")!)
        await f.store.disconnect(f.chat)
        XCTAssertTrue(browser.tabs.first === tab, "An ACP reconnect must preserve browser tabs")
        do { _ = try await URLSession.shared.data(for: request); XCTFail("Disconnected MCP listener still accepts requests") } catch {}
        try await f.store.connect(f.chat)
        let next = try XCTUnwrap(try XCTUnwrap(try audit(f.audit).last { ["session/new", "session/load", "session/resume"].contains($0["method"].string) })["params"]["mcpServers"].array.first)
        XCTAssertNotEqual(next["headers"].array.first?["value"].string, authorization)
        await f.store.shutdown(); XCTAssertTrue(browser.tabs.isEmpty); XCTAssertNil(tab.webView.navigationDelegate)
    }

    @MainActor func testUnsupportedAgentRefusesBrowserCapabilityAndCanReconnectWithoutIt() async throws {
        let f = try await fixture(http: false)
        try await f.store.setBrowserTools(f.chat, enabled: true)
        do { try await f.store.connect(f.chat); XCTFail("HTTP MCP capability invented") } catch {}
        XCTAssertFalse(try audit(f.audit).contains { $0["method"].string == "session/new" })
        XCTAssertNil(f.chat.browserWorkspace.endpoint)
        try await f.store.setBrowserTools(f.chat, enabled: false)
        try await f.store.connect(f.chat)
        let params = try XCTUnwrap(try audit(f.audit).last { $0["method"].string == "session/new" })["params"]
        XCTAssertTrue(params["mcpServers"].array.isEmpty)
    }

    @MainActor func testBrowserPaneDetachesWithoutLosingOwnedWebViewAndConfigRestoresWithoutAutorun() async throws {
        let f = try await fixture(http: true), browser = f.chat.browserWorkspace
        let tab = try browser.open(URL(string: "http://127.0.0.1:38931/")!)
        tab.webView.loadHTMLString("<h1>Retained tab</h1>", baseURL: tab.url)
        let host = NSHostingView(rootView: AnyView(WorkspacePane(chat: f.chat, store: f.store, kind: "browser")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }
        try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(findWebView(host) === tab.webView)
        host.rootView = AnyView(EmptyView()); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(browser.tabs.first === tab); XCTAssertNotNil(tab.webView.navigationDelegate)
        host.rootView = AnyView(WorkspacePane(chat: f.chat, store: f.store, kind: "browser")); try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        XCTAssertTrue(findWebView(host) === tab.webView)
        let config = PreviewLaunchConfiguration(executable: "/usr/bin/python3", arguments: ["-m", "http.server", "3000"], directory: f.chat.workspace.root, url: "http://127.0.0.1:3000/")
        f.chat.transcript.previewLaunch = config
        let decoded = try JSONDecoder().decode(SessionTranscript.self, from: JSONEncoder().encode(f.chat.transcript))
        XCTAssertEqual(decoded.previewLaunch, config)
        let restored = try ChatSession(id: UUID(), path: f.chat.workspace.root, transcript: decoded)
        XCTAssertFalse(restored.previewActive); XCTAssertFalse(restored.browserWorkspace.hasTabs)
    }
    @MainActor private func fixture(http: Bool) async throws -> (store: AppStore, chat: ChatSession, audit: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-browser-session-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("no-history")), audit = root.appendingPathComponent("audit.jsonl")
        store.settings.executable = "/usr/bin/python3"; store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--audit-path=" + audit.path] + (http ? ["--http-mcp"] : [])
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        return (store, chat, audit)
    }
    private func audit(_ url: URL) throws -> [JSONValue] { try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } }
    @MainActor private func freePort() async throws -> UInt16 {
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters); listener.newConnectionHandler = { $0.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in if case .ready = state { continuation.resume() }; if case .failed(let error) = state { continuation.resume(throwing: error) } }
            listener.start(queue: DispatchQueue(label: "ccode.browser.test-port"))
        }
        listener.stateUpdateHandler = nil
        let port = try XCTUnwrap(listener.port?.rawValue); listener.cancel(); return port
    }
    @MainActor private func findWebView(_ view: NSView) -> WKWebView? { if let web = view as? WKWebView { return web }; return view.subviews.lazy.compactMap { self.findWebView($0) }.first }
}
