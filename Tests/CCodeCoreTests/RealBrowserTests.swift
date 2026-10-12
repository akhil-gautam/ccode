import XCTest
import Foundation
import AppKit
import Network
import CCodeCore
@testable import CCode

final class RealBrowserTests: XCTestCase {
    @MainActor func testActualAgentInspectsRepairsReloadsAndVerifiesOwnedPreview() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_BROWSER_AGENT"] else { throw XCTSkip("Set CCODE_REAL_BROWSER_AGENT for the authenticated actual-browser repair proof.") }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ccode-real-browser-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let port = try await freePort(), target = root.appendingPathComponent("index.html"), server = root.appendingPathComponent("serve.py")
        try "<!doctype html><html><head><title>Owned browser proof</title></head><body><h1>Broken heading</h1><p>Keep this paragraph unchanged.</p></body></html>\n".write(to: target, atomically: true, encoding: .utf8)
        try "import http.server\nhttp.server.HTTPServer(('127.0.0.1',\(port)),http.server.SimpleHTTPRequestHandler).serve_forever()\n".write(to: server, atomically: true, encoding: .utf8)
        let store = AppStore(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("empty-history"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown() }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.setBrowserTools(chat, enabled: true)
        try await store.startPreview(chat, configuration: PreviewLaunchConfiguration(executable: "/usr/bin/python3", arguments: [server.path], directory: root.path, url: "http://127.0.0.1:\(port)/"))
        let tab = try XCTUnwrap(chat.browserWorkspace.selected)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tab.webView; defer { window.contentView = nil }
        try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(chat, id: mode["id"].string, value: "default")
        XCTAssertNil(chat.lastError)
        print("Actual browser proof directory: \(root.path)")
        store.send(chat, text: "Use the ccode-browser MCP tools on the existing preview tab \(tab.id.uuidString). First browser_inspect the rendered page to identify its heading. Edit only \(target.path) to change the h1 text to Preview ready, preserving the paragraph. Then browser_reload that same tab and browser_inspect it again to verify the actual rendered heading. Do not use Bash, agents, skills, external network, or modify other files. Do not just read the HTML instead of inspecting the browser. Finish after browser verification.")
        let until = ContinuousClock.now + .seconds(150)
        while chat.busy, ContinuousClock.now < until {
            for approval in chat.approvals {
                let tool = approval.toolCall, presentation = PermissionPresentation(tool: tool)
                let identity = [presentation.toolName, tool["name"].string, tool["title"].string].joined(separator: " ")
                let args = tool["rawInput"]
                let file = ["Read", "Edit", "Write"].contains(presentation.toolName) && args["file_path"].string == target.path
                let browser = identity.contains("browser_tabs") || ["browser_inspect", "browser_reload"].contains(where: identity.contains) && args["tabId"].string == tab.id.uuidString
                guard file || browser else { store.resolveApproval(chat, id: approval.id, option: nil); throw ACPError.workspace("Unexpected browser-proof permission: \(presentation.toolName)") }
                let option = approval.request["options"].array.first { $0["kind"] == "allow_once" }
                store.resolveApproval(chat, id: approval.id, option: option?["optionId"].optionalString)
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard !chat.busy, chat.state == .ready else { store.stop(chat); throw ACPError.workspace(chat.lastError ?? "Actual browser repair did not finish") }
        let tools = chat.transcript.items.filter { $0.kind == "tool" }
        let inspections = tools.filter { ($0.tool["title"].string + " " + $0.tool["name"].string).contains("browser_inspect") && $0.tool["status"].string == "completed" }
        XCTAssertGreaterThanOrEqual(inspections.count, 2, "Agent must inspect the actual browser before and after editing")
        let text = try String(contentsOf: target, encoding: .utf8)
        XCTAssertTrue(text.contains("<h1>Preview ready</h1>")); XCTAssertTrue(text.contains("<p>Keep this paragraph unchanged.</p>"))
        let heading = try await tab.webView.evaluateJavaScript("document.querySelector('h1').textContent") as? String
        XCTAssertEqual(heading, "Preview ready", "Independent WebKit check must see the agent's reloaded result")
        let proof: JSONValue = ["heading": .string(heading ?? ""), "inspections": .number(Double(inspections.count)), "tools": .array(tools.map { ["title": $0.tool["title"], "name": $0.tool["name"], "status": $0.tool["status"]] })]
        try JSONEncoder().encode(proof).write(to: root.appendingPathComponent("verified-browser.json"))
        await store.shutdown()
        print("Actual browser inspection, file repair, reload and independent rendered heading check passed. Native installed UI acceptance remains separate.")
    }
    @MainActor private func freePort() async throws -> UInt16 {
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters); listener.newConnectionHandler = { $0.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in if case .ready = state { continuation.resume() }; if case .failed(let error) = state { continuation.resume(throwing: error) } }
            listener.start(queue: DispatchQueue(label: "ccode.real-browser.port"))
        }
        listener.stateUpdateHandler = nil
        let port = try XCTUnwrap(listener.port?.rawValue); listener.cancel(); return port
    }
}
