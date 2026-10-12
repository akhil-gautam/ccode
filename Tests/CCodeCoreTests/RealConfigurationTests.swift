import XCTest
import Foundation
import CCodeCore
@testable import CCode

final class RealConfigurationTests: XCTestCase {
    @MainActor func testConfiguredMCPAndSkillAreUsedAfterNativeManagerReconnect() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_CONFIGURATION_AGENT"], FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("Opt-in actual authenticated Claude configuration proof") }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ccode-real-configuration-\(UUID())")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let script = project.appendingPathComponent("fixture_mcp.py"), marker = project.appendingPathComponent("tool-called.json")
        let nonce = "fixture-" + UUID().uuidString
        try JSONEncoder().encode(["value": nonce]).write(to: project.appendingPathComponent("fixture-value.json"))
        try """
        import json, sys, pathlib
        for line in sys.stdin:
            try: request=json.loads(line)
            except Exception: continue
            if 'id' not in request: continue
            method=request.get('method')
            if method=='initialize': result={'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'owned-configuration-fixture','version':'1'}}
            elif method=='tools/list': result={'tools':[{'name':'read_fixture_value','description':'Read the disposable fixture value requested by the ccode-config-fixture skill.','inputSchema':{'type':'object','properties':{},'additionalProperties':False}}]}
            elif method=='tools/call':
                pathlib.Path(__file__).with_name('tool-called.json').write_text(json.dumps(request.get('params',{})))
                result={'content':[{'type':'text','text':json.loads(pathlib.Path(__file__).with_name('fixture-value.json').read_text())['value']}]}
            elif method=='ping': result={}
            else:
                print(json.dumps({'jsonrpc':'2.0','id':request['id'],'error':{'code':-32601,'message':'Unknown method'}}),flush=True); continue
            print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        let configuration = try AgentConfiguration(project: project.path, configurationDirectory: root.appendingPathComponent("isolated-cli-config").path)
        let skill = project.appendingPathComponent(".claude/skills/ccode-config-fixture/SKILL.md")
        let store = AppStore(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("empty-history"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown() }
        await store.create(path: project.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        // Configure after connection, then use the same native manager reconnect
        // path. Inheritance at the original launch is not reload proof.
        _ = try await configuration.invoke(executable: executable, arguments: [], operation: .addMCP(name: "owned-configuration-fixture", configuration: ["type": "stdio", "command": "/usr/bin/python3", "args": [.string(script.path)]], scope: .project))
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: ccode-config-fixture\ndescription: Verify a disposable MCP fixture connection\n---\nUse the owned-configuration-fixture MCP tool read_fixture_value exactly once. Report its returned value verbatim. Do not inspect or edit files, run commands, or use other tools.\n".write(to: skill, atomically: true, encoding: .utf8)
        try await store.reloadAgentConfiguration(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(chat, id: mode["id"].string, value: "default")
        print("Actual configuration proof directory: \(root.path)")
        store.send(chat, text: "/ccode-config-fixture")
        let until = ContinuousClock.now + .seconds(120)
        while chat.busy, ContinuousClock.now < until {
            for approval in chat.approvals {
                let presentation = PermissionPresentation(tool: approval.toolCall)
                let identity = [presentation.toolName, approval.toolCall["title"].string, approval.toolCall["name"].string].joined(separator: " ")
                let input = approval.toolCall["rawInput"]
                let expected = identity.contains("read_fixture_value") || presentation.toolName == "Skill" && input["skill"].string == "ccode-config-fixture" || presentation.toolName == "Read" && input["file_path"].string == skill.path || presentation.toolName == "ToolSearch" && input["query"].string.contains("read_fixture_value")
                guard expected else { store.resolveApproval(chat, id: approval.id, option: nil); throw ACPError.workspace("Unexpected configuration proof permission: \(presentation.toolName)") }
                let choice = approval.request["options"].array.first { $0["kind"] == "allow_once" }
                store.resolveApproval(chat, id: approval.id, option: choice?["optionId"].optionalString)
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard !chat.busy, chat.state == .ready else { store.stop(chat); throw ACPError.workspace(chat.lastError ?? "Actual configured tool/skill proof did not finish") }
        let called = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: marker))
        XCTAssertEqual(called["name"], "read_fixture_value")
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "assistant" && $0.text.contains(nonce) })
        let tools = chat.transcript.items.filter { $0.kind == "tool" }
        XCTAssertTrue(tools.contains { ($0.tool["title"].string + " " + $0.tool["name"].string).contains("read_fixture_value") && $0.tool["status"] == "completed" })
        let proof: JSONValue = ["returnedValue": .string(nonce), "called": called, "tools": .array(tools.map { ["title": $0.tool["title"], "name": $0.tool["name"], "status": $0.tool["status"]] })]
        try JSONEncoder().encode(proof).write(to: root.appendingPathComponent("verified-configuration.json"))
        await store.shutdown()
        print("Actual configured MCP tool and project skill used after manager reconnect. Native UI acceptance remains separate.")
    }
}
