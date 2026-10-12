import XCTest
import Foundation
import Network
import Darwin
@testable import CCodeCore

final class PreviewTests: XCTestCase, @unchecked Sendable {
    func testOwnedServerReadinessActualHTTPLogsAndStopReapProcess() async throws {
        let f = try await fixture()
        let config = PreviewLaunchConfiguration(executable: "/usr/bin/python3", arguments: [f.script.path, String(f.port)], directory: f.root.path, url: f.url.absoluteString)
        try await f.server.start(config)
        let snapshot = try await f.server.snapshot()
        XCTAssertEqual(snapshot.phase, .ready); XCTAssertEqual(snapshot.url, f.url.absoluteString)
        let (bytes, response) = try await URLSession.shared.data(from: f.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "owned-preview-response")
        XCTAssertTrue(snapshot.logs.contains("SERVER_CWD=")); XCTAssertTrue(snapshot.logs.contains("READY"))
        let pid = try XCTUnwrap(Int32(String(contentsOf: f.root.appendingPathComponent("pid"), encoding: .utf8)))
        await f.server.stop()
        XCTAssertEqual(kill(pid, 0), -1)
        let stopped = try await f.server.snapshot(); XCTAssertEqual(stopped.phase, .stopped)
    }
    func testOccupiedPortRefusesBeforeLaunchingAndDoesNotStopForeignListener() async throws {
        let f = try await fixture(), occupied = try await listener(port: f.port)
        defer { occupied.cancel() }
        let config = PreviewLaunchConfiguration(executable: "/usr/bin/python3", arguments: [f.script.path, String(f.port)], directory: f.root.path, url: f.url.absoluteString)
        do { try await f.server.start(config); XCTFail("Occupied port accepted") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("pid").path))
        XCTAssertNotEqual(occupied.state, .cancelled)
    }
    func testFailedLaunchAndForeignRootOrNonLocalURLRefuse() async throws {
        let f = try await fixture()
        for config in [
            PreviewLaunchConfiguration(executable: "/usr/bin/false", arguments: [], directory: f.root.path, url: f.url.absoluteString),
            PreviewLaunchConfiguration(executable: "/usr/bin/python3", arguments: [], directory: "/tmp", url: f.url.absoluteString),
            PreviewLaunchConfiguration(executable: "/usr/bin/python3", arguments: [], directory: f.root.path, url: "https://example.com")
        ] {
            do { try await f.server.start(config, deadline: .milliseconds(300)); XCTFail("Invalid launch accepted") } catch {}
            await f.server.stop()
        }
    }
    func testStopDuringReadinessCancelsOwnedStartAndReapsProcess() async throws {
        let f = try await fixture()
        let config = PreviewLaunchConfiguration(executable: "/usr/bin/python3", arguments: [f.script.path, "hang"], directory: f.root.path, url: f.url.absoluteString)
        let task = Task { try await f.server.start(config, deadline: .seconds(30)) }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: f.root.appendingPathComponent("pid").path) { break }; try await Task.sleep(for: .milliseconds(20)) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: f.root.appendingPathComponent("pid"), encoding: .utf8)))
        await f.server.stop()
        do { try await task.value; XCTFail("Stopped start completed") } catch {}
        XCTAssertEqual(kill(pid, 0), -1)
        let stopped = try await f.server.snapshot(); XCTAssertEqual(stopped.phase, .stopped)
    }
    func testMCPInitializesListsAndInvokesRealHTTPHandlerWithLiteralArguments() async throws {
        let calls = Calls()
        let server = BrowserToolServer(tools: [tool]) { name, arguments in
            await calls.record(name: name, arguments: arguments)
            return ["content": [["type": "text", "text": .string(arguments["value"].string)]]]
        }
        let endpoint = try await server.start()
        addTeardownBlock { await server.stop() }
        let initialize = try await post(endpoint, body: ["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":"2025-06-18","capabilities":[:],"clientInfo":["name":"Fixture","version":"1"]]])
        XCTAssertEqual(initialize.1, 200); XCTAssertEqual(initialize.0["result"]["serverInfo"]["name"].string, "ccode-browser")
        let listed = try await post(endpoint, body: ["jsonrpc":"2.0","id":2,"method":"tools/list","params":[:]])
        XCTAssertEqual(listed.0["result"]["tools"].array.count, 1)
        let literal = "$(touch should-not-exist) 'quotes'\nsecond line"
        let invoked = try await post(endpoint, body: ["jsonrpc":"2.0","id":3,"method":"tools/call","params":["name":"echo","arguments":["value":.string(literal)]]])
        XCTAssertEqual(invoked.0["result"]["content"].array.first?["text"].string, literal)
        let recorded = await calls.values
        XCTAssertEqual(recorded.count, 1); XCTAssertEqual(recorded.first?.0, "echo"); XCTAssertEqual(recorded.first?.1["value"].string, literal)
    }
    func testMCPRejectsMissingAuthForeignOriginAndUnsupportedToolBeforeExecution() async throws {
        let calls = Calls()
        let server = BrowserToolServer(tools: [tool]) { name, arguments in await calls.record(name: name, arguments: arguments); return [:] }
        let endpoint = try await server.start(); addTeardownBlock { await server.stop() }
        let request: JSONValue = ["jsonrpc":"2.0","id":1,"method":"tools/call","params":["name":"echo","arguments":["value":"secret"]]]
        let unauthorized = try await post(endpoint, body: request, authenticated: false)
        XCTAssertEqual(unauthorized.1, 401)
        let foreign = try await post(endpoint, body: request, origin: "https://example.com")
        XCTAssertEqual(foreign.1, 403)
        let unknown = try await post(endpoint, body: ["jsonrpc":"2.0","id":2,"method":"tools/call","params":["name":"foreign","arguments":[:]]])
        XCTAssertEqual(unknown.0["error"]["code"].int, -32602)
        let values = await calls.values; XCTAssertTrue(values.isEmpty)
        var get = URLRequest(url: endpoint.url); get.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: get)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 405)
    }
    func testMCPNotificationHasNoBodyAndStopCancelsOwnedRequest() async throws {
        let calls = Calls()
        let server = BrowserToolServer(tools: [tool]) { name, arguments in
            await calls.record(name: name, arguments: arguments)
            do { try await Task.sleep(for: .seconds(30)); return [:] } catch { await calls.cancelled(); throw error }
        }
        let endpoint = try await server.start()
        let notification = try await post(endpoint, body: ["jsonrpc":"2.0","method":"notifications/initialized","params":[:]])
        XCTAssertEqual(notification.1, 202); XCTAssertTrue(notification.0.isNull)
        let task = Task { try await self.post(endpoint, body: ["jsonrpc":"2.0","id":4,"method":"tools/call","params":["name":"echo","arguments":["value":"wait"]]]) }
        for _ in 0..<100 { if await calls.values.count > 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        await server.stop(); _ = try? await task.value
        let count = await calls.cancellations; XCTAssertEqual(count, 1)
        do { _ = try await post(endpoint, body: ["jsonrpc":"2.0","id":5,"method":"tools/list"]); XCTFail("Stopped listener accepted request") } catch {}
    }

    func testPinnedOfficialMCPClientCanDiscoverAndCallServer() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sdk = package.appendingPathComponent(".build/agent/node_modules/@modelcontextprotocol/sdk/dist/esm/client")
        guard FileManager.default.fileExists(atPath: sdk.appendingPathComponent("index.js").path) else { throw XCTSkip("Install the pinned ACP adapter to verify its actual MCP SDK client.") }
        let calls = Calls(), server = BrowserToolServer(tools: [tool]) { name, arguments in
            await calls.record(name: name, arguments: arguments)
            return ["content": [["type": "text", "text": arguments["value"]]]]
        }
        let endpoint = try await server.start(), terminal = TerminalService()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-mcp-sdk-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { await terminal.close(); await server.stop(); try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("client.mjs")
        try #"""
const {Client} = await import(process.env.CCODE_MCP_CLIENT);
const {StreamableHTTPClientTransport} = await import(process.env.CCODE_MCP_TRANSPORT);
const client = new Client({name:'ccode-interop-proof',version:'1'}, {capabilities:{}});
try {
 await client.connect(new StreamableHTTPClientTransport(new URL(process.env.CCODE_MCP_URL), {requestInit:{headers:{Authorization:'Bearer '+process.env.CCODE_MCP_TOKEN}}}));
 const tools = await client.listTools();
 const result = await client.callTool({name:'echo',arguments:{value:'SDK literal response'}});
 console.log(JSON.stringify({names:tools.tools.map(t=>t.name),text:result.content[0].text}));
} finally { await client.close(); }
"""#.write(to: script, atomically: true, encoding: .utf8)
        let id = try await terminal.create(command: "node", arguments: [script.path], directory: root.path, environment: [
            "CCODE_MCP_CLIENT": sdk.appendingPathComponent("index.js").absoluteString,
            "CCODE_MCP_TRANSPORT": sdk.appendingPathComponent("streamableHttp.js").absoluteString,
            "CCODE_MCP_URL": endpoint.url.absoluteString, "CCODE_MCP_TOKEN": endpoint.token
        ], byteLimit: 8192)
        let exit = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await terminal.wait(id) }
            group.addTask { try await Task.sleep(for: .seconds(10)); throw ACPError.timeout("MCP SDK integration") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        let output = try await terminal.output(id)
        XCTAssertEqual(exit["exitCode"].exactInteger, 0, output["output"].string)
        let line = try XCTUnwrap(output["output"].string.split(separator: "\n").last)
        let proof = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        XCTAssertEqual(proof["names"].array, ["echo"]); XCTAssertEqual(proof["text"].string, "SDK literal response")
        let recorded = await calls.values; XCTAssertEqual(recorded.count, 1)
    }

    private var tool: JSONValue { ["name":"echo","description":"Echo a value.","inputSchema":["type":"object","properties":["value":["type":"string"]],"required":["value"],"additionalProperties":false]] }
    private actor Calls {
        var values: [(String, JSONValue)] = []
        var cancellations = 0
        func record(name: String, arguments: JSONValue) { values.append((name, arguments)) }
        func cancelled() { cancellations += 1 }
    }
    private func post(_ endpoint: BrowserToolEndpoint, body: JSONValue, authenticated: Bool = true, origin: String? = nil) async throws -> (JSONValue, Int) {
        var request = URLRequest(url: endpoint.url); request.httpMethod = "POST"; request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if authenticated { request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        request.httpBody = try JSONEncoder().encode(body)
        let (bytes, response) = try await URLSession.shared.data(for: request)
        let decoded = bytes.isEmpty ? JSONValue.null : try JSONDecoder().decode(JSONValue.self, from: bytes)
        return (decoded, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    private struct Fixture: Sendable { let root: URL, script: URL, port: UInt16, server: PreviewServer; var url: URL { URL(string: "http://127.0.0.1:\(port)/")! } }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-preview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reservation = try await listener(), port = try XCTUnwrap(reservation.port?.rawValue); reservation.cancel()
        let script = root.appendingPathComponent("serve.py")
        try #"""
import http.server, os, pathlib, sys, time
pathlib.Path('pid').write_text(str(os.getpid()))
print('SERVER_CWD='+os.getcwd(), flush=True)
if sys.argv[1]=='hang': time.sleep(60); sys.exit(0)
class Handler(http.server.BaseHTTPRequestHandler):
 def do_HEAD(self): self.send_response(200); self.end_headers()
 def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'owned-preview-response')
server=http.server.HTTPServer(('127.0.0.1',int(sys.argv[1])), Handler)
print('READY',flush=True)
server.serve_forever()
"""#.write(to: script, atomically: true, encoding: .utf8)
        let server = PreviewServer(workspace: try Workspace(root: root.path))
        addTeardownBlock { await server.stop(); try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, script: script, port: port, server: server)
    }
    private func listener(port: UInt16? = nil) async throws -> NWListener {
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.map { NWEndpoint.Port(rawValue: $0)! } ?? .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { $0.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.resume() }
                if case .failed(let error) = state { continuation.resume(throwing: error) }
            }
            listener.start(queue: DispatchQueue(label: "ccode.preview.fixture"))
        }
        listener.stateUpdateHandler = nil
        return listener
    }
}
