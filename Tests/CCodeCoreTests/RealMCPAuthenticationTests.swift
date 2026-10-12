import XCTest
import Foundation
import CCodeCore
@testable import CCode

final class RealMCPAuthenticationTests: XCTestCase {
    func testPinnedAdapterCompletesRealLocalOAuthWithPKCEWithoutModelTurn() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_CONFIGURATION_AGENT"], FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("Opt-in real OAuth adapter proof") }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ccode-real-oauth-\(UUID())")
        let project = root.appendingPathComponent("project"), config = root.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let terminals = TerminalService()
        let server = try await terminals.create(command: "/usr/bin/python3", arguments: [Bundle.module.url(forResource: "oauth_mcp", withExtension: "py", subdirectory: "Fixtures")!.path, root.path], directory: root.path)
        let peer = ACPConnection(onUpdates: { _ in }, onRequest: { _, _ in throw ACPError.workspace("No client interaction is expected in this fixture") })
        addTeardownBlock { await peer.close(); try? await terminals.release(server) }
        let ready = root.appendingPathComponent("server.json")
        let until = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(20)) }
        let info = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: ready)), base = info["url"].string
        let configuration: JSONValue = ["mcpServers": ["owned-oauth-fixture": ["type": "http", "url": .string(base + "/mcp")]]]
        try JSONEncoder().encode(configuration).write(to: project.appendingPathComponent(".mcp.json"))
        let launch = AgentSettings.nativeSubagentLaunch(executable: executable, arguments: [])
        var environment = AgentSettings.environment
        environment["CLAUDE_CONFIG_DIR"] = config.path
        environment["ANTHROPIC_API_KEY"] = "disposable-no-model-turn-fixture"
        try await peer.start(executable: launch.executable, arguments: launch.arguments, directory: project.path, environment: environment)
        let handshake = try await peer.request("initialize", params: ["protocolVersion": 1, "clientInfo": ["name": "ccode", "version": "0.1"], "clientCapabilities": ["_meta": ["ccode": ["configurationManagement": true]]]])
        let cap = try XCTUnwrap(LiveConfigurationCapability(handshake["_meta"]["ccode"]["configurationManagement"]))
        let session = try await peer.request("session/new", params: ["cwd": .string(project.path), "mcpServers": []])
        let id = session["sessionId"].string
        func perform(_ operation: LiveConfigurationOperation) async throws -> LiveConfigurationResult {
            let raw = try await peer.request("_ccode/configuration", params: cap.parameters(sessionID: id, operation: operation))
            return try LiveConfigurationResult(raw, capability: cap, sessionID: id, operation: operation)
        }
        let initial = try await perform(.status)
        XCTAssertEqual(initial.servers.first { $0.name == "owned-oauth-fixture" }?.status, .needsAuthentication)
        let begin = try await perform(.beginAuthentication(name: "owned-oauth-fixture"))
        let flow = try XCTUnwrap(begin.authentication), url = try XCTUnwrap(flow.url)
        XCTAssertEqual(url.host, "127.0.0.1"); XCTAssertEqual(flow.state, .pending)
        // Simulated authorization by this disposable issuer only. Real user
        // login remains an explicit native Open in browser action.
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var status = begin
        let deadline = ContinuousClock.now + .seconds(30)
        repeat {
            try await Task.sleep(for: .milliseconds(200))
            status = try await perform(.authenticationStatus(name: flow.name, flowID: flow.id))
        } while status.authentication?.state == .pending && ContinuousClock.now < deadline
        XCTAssertEqual(status.authentication?.state, .connected)
        XCTAssertNil(status.authentication?.url)
        XCTAssertEqual(status.servers.first { $0.name == flow.name }?.status, .connected)
        let events = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("events.json"))).array
        XCTAssertTrue(events.contains { $0["event"] == "token" && $0["pkce_verified"] == true })
        XCTAssertTrue(events.contains { $0["method"] == "tools/list" })
        XCTAssertFalse(events.contains { $0["method"] == "tools/call" })
        _ = try await perform(.cancelAuthentication(name: flow.name, flowID: flow.id))
        await peer.close(); try await terminals.release(server)
        print("Real MCP OAuth + PKCE proof: \(root.path)")
    }
}
