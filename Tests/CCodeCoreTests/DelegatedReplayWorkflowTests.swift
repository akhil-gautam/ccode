import XCTest
import CCodeCore
@testable import CCode

final class DelegatedReplayWorkflowTests: XCTestCase {
    @MainActor func testVerifiedReplayReconcilesHistoryAndOwnersButOtherVersionsAndMissingFilesStayUntouched() async throws {
        for (version, missing) in [("0.84.0", false), ("0.85.0", false), ("0.84.0", true)] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-replay-workflow-\(UUID())")
            let config = root.appendingPathComponent("claude"), folder = config.appendingPathComponent("projects/fixture")
            let remote = UUID().uuidString, good = remote + ":replay-subagent:good", bad = remote + ":replay-subagent:bad"
            let childFolder = folder.appendingPathComponent(remote + "/subagents")
            try FileManager.default.createDirectory(at: childFolder, withIntermediateDirectories: true)
            func records(_ values: [JSONValue], to file: URL, child: Bool = false) throws {
                var data = Data()
                for var record in values {
                    record["sessionId"] = .string(remote)
                    if child { record["agentId"] = "child"; record["isSidechain"] = true }
                    data.append(try JSONEncoder().encode(record)); data.append(10)
                }
                try data.write(to: file)
            }
            try records([
                ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Inspect"]],
                ["type": "assistant", "uuid": "bad", "parentUuid": "u", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "bad", "name": "Agent", "input": ["prompt": "Invalid agent"]]]]],
                ["type": "user", "uuid": "r1", "parentUuid": "bad", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "bad", "is_error": true, "content": "Unknown agent type"]]]],
                ["type": "assistant", "uuid": "good", "parentUuid": "r1", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "good", "name": "Agent", "input": ["prompt": "Actual child", "run_in_background": true]]]]],
                ["type": "user", "uuid": "r2", "parentUuid": "good", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "good", "content": "Launched"]]]]
            ], to: folder.appendingPathComponent(remote + ".jsonl"))
            try JSONEncoder().encode(JSONValue.object(["toolUseId": "good", "stoppedByUser": true])).write(to: childFolder.appendingPathComponent("agent-child.meta.json"))
            if !missing {
                try records([
                    ["type": "user", "uuid": "cu", "parentUuid": nil, "message": ["role": "user", "content": "Actual child"]],
                    ["type": "assistant", "uuid": "ca", "parentUuid": "cu", "message": ["role": "assistant", "content": "Local child history"]]
                ], to: childFolder.appendingPathComponent("agent-child.jsonl"), child: true)
            }
            let events: [JSONValue] = [
                ["sessionId": .string(remote), "update": ["sessionUpdate": "subagent_spawned", "subagentSessionId": .string(bad), "capabilities": [:]]],
                ["sessionId": .string(remote), "update": ["sessionUpdate": "subagent_state_update", "subagentSessionId": .string(bad), "state": "failed"]],
                ["sessionId": .string(remote), "update": ["sessionUpdate": "subagent_spawned", "subagentSessionId": .string(good), "capabilities": [:]]],
                ["sessionId": .string(good), "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Keep provider child rendering"]]],
                ["sessionId": .string(remote), "update": ["sessionUpdate": "subagent_state_update", "subagentSessionId": .string(good), "state": "completed"]],
                ["sessionId": .string(remote), "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Keep provider root rendering"]]]
            ]
            let scenario = root.appendingPathComponent("events.json"), script = root.appendingPathComponent("agent.py")
            try JSONEncoder().encode(events).write(to: scenario)
            try Data("""
            import json,sys
            events=json.load(open(sys.argv[1]))
            def send(**value): print(json.dumps(dict(jsonrpc='2.0',**value)),flush=True)
            for line in sys.stdin:
                m=json.loads(line);method=m.get('method');ident=m.get('id')
                if method=='initialize': send(id=ident,result=dict(protocolVersion=1,agentInfo=dict(name='@agentclientprotocol/claude-agent-acp',version=sys.argv[2]),agentCapabilities=dict(loadSession=True)))
                elif method=='session/load':
                    for e in events: send(method='session/update',params=e)
                    send(id=ident,result=dict(sessionId=m['params']['sessionId']))
            """.utf8).write(to: script)
            let directory = root.appendingPathComponent("data")
            let store = AppStore(directory: directory, claudeDirectory: config)
            store.settings.executable = "/usr/bin/python3"; store.settings.arguments = [script.path, scenario.path, version]
            addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
            await store.create(path: root.path, worktree: false)
            let chat = try XCTUnwrap(store.selected)
            chat.transcript.remoteID = remote; chat.draft = "Keep unsent draft"
            try await store.connect(chat, reloadHistory: true)
            let reconciled = version == "0.84.0" && !missing
            XCTAssertEqual(chat.transcript.subagents?.count, reconciled ? 1 : 2)
            XCTAssertEqual(chat.transcript.subagent(good)?.state, reconciled ? "cancelled" : "completed")
            XCTAssertEqual(chat.childOwners, reconciled ? Set([good]) : Set([good, bad]), "A disproved phantom cannot remain an owned callback target")
            XCTAssertEqual(chat.transcript.items.filter { $0.kind == "tool" }.count, reconciled ? 1 : 0)
            XCTAssertEqual(chat.transcript.subagent(good)?.transcript.items.last?.text, "Keep provider child rendering")
            XCTAssertEqual(chat.transcript.items.last?.text, "Keep provider root rendering")
            XCTAssertFalse(store.canStopSubagent(chat, id: good))
            XCTAssertEqual(chat.draft, "Keep unsent draft")
            await store.shutdown()
            let restored = AppStore(directory: directory, claudeDirectory: config)
            await restored.restore()
            XCTAssertEqual(restored.selected?.transcript.subagents?.count, reconciled ? 1 : 2)
            XCTAssertEqual(restored.selected?.transcript.subagent(good)?.state, reconciled ? "cancelled" : "completed")
            XCTAssertEqual(restored.selected?.draft, "Keep unsent draft")
            XCTAssertNil(restored.selected?.connection)
            await restored.shutdown()
        }
    }
}
