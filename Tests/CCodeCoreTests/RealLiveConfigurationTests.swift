import XCTest
import Foundation
import Darwin
import CCodeCore
@testable import CCode
final class RealLiveConfigurationTests: XCTestCase {
    @MainActor func testActualMCPProcessToggleAndSkillReloadWithoutModelTurn() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_CONFIGURATION_AGENT"], FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("Opt-in real live configuration proof") }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ccode-real-live-configuration-\(UUID())")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let script = project.appendingPathComponent("fixture_mcp.py"), marker = project.appendingPathComponent("started-pids.json")
        try """
        import json,sys,pathlib,os,time,signal
        marker=pathlib.Path(__file__).with_name('started-pids.json')
        pids=json.loads(marker.read_text()) if marker.exists() else []
        pids.append(os.getpid());marker.write_text(json.dumps(pids))
        events=pathlib.Path(__file__).with_name('process-events.jsonl')
        def event(value):
            with events.open('a') as file: file.write(json.dumps(dict(pid=os.getpid(),parent=os.getppid(),time=time.time(),event=value))+'\\n')
        event('start')
        def stop(sig,frame): event('signal-'+str(sig));sys.exit(0)
        signal.signal(signal.SIGTERM,stop)
        signal.signal(signal.SIGINT,stop)
        for line in sys.stdin:
            try: request=json.loads(line)
            except Exception: continue
            if 'id' not in request: continue
            method=request.get('method');event(method)
            if method=='initialize': result={'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'owned-live-fixture','version':'1'}}
            elif method=='tools/list': result={'tools':[{'name':'read_owned_fixture','description':'Read-only disposable fixture','inputSchema':{'type':'object','properties':{},'additionalProperties':False}}]}
            elif method=='ping': result={}
            else:
                if method=='tools/call': pathlib.Path(__file__).with_name('unexpected-call.json').write_text(json.dumps({'method':method}))
                print(json.dumps({'jsonrpc':'2.0','id':request['id'],'error':{'code':-32601,'message':'Unexpected method'}}),flush=True);continue
            print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
        event('eof')
        """.write(to: script, atomically: true, encoding: .utf8)
        let config = try AgentConfiguration(project: project.path, configurationDirectory: root.appendingPathComponent("isolated-cli-config").path)
        _ = try await config.invoke(executable: executable, arguments: [], operation: .addMCP(name: "owned-live-fixture", configuration: ["type": "stdio", "command": "/usr/bin/python3", "args": [.string(script.path)]], scope: .project))
        let store = AppStore(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("empty-history"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown() }
        await store.create(path: project.path, worktree: false)
        let chat = try XCTUnwrap(store.selected); try await store.connect(chat)
        let remote = try XCTUnwrap(chat.transcript.remoteID), peer = try XCTUnwrap(chat.connection)
        let originalCommands = chat.transcript.commands
        let initial = try await store.performLiveConfiguration(chat, operation: .status)
        XCTAssertEqual(initial.servers.first { $0.name == "owned-live-fixture" }?.status, .connected)
        let pids = try JSONDecoder().decode([Int32].self, from: Data(contentsOf: marker))
        let firstPID = try XCTUnwrap(pids.last)
        XCTAssertEqual(Darwin.kill(firstPID, 0), 0)
        let disabled = try await store.performLiveConfiguration(chat, operation: .toggle(name: "owned-live-fixture", enabled: false))
        XCTAssertEqual(disabled.servers.first { $0.name == "owned-live-fixture" }?.status, .disabled)
        // The exact SDK disables tool availability and retains a cached stdio
        // process until enable/reconnect. Do not claim Disable is process Stop.
        let enabled = try await store.performLiveConfiguration(chat, operation: .toggle(name: "owned-live-fixture", enabled: true))
        XCTAssertEqual(enabled.servers.first { $0.name == "owned-live-fixture" }?.status, .connected)
        let restarted = try JSONDecoder().decode([Int32].self, from: Data(contentsOf: marker))
        XCTAssertGreaterThan(restarted.count, pids.count)
        XCTAssertNotEqual(restarted.last, firstPID)
        let skillName = "owned-live-skill-" + UUID().uuidString.lowercased().prefix(8)
        let skill = project.appendingPathComponent(".claude/skills/\(skillName)/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "---\nname: \(skillName)\ndescription: Read a disposable fixture\n---\nReturn the fixture name without running tools.\n".write(to: skill, atomically: true, encoding: .utf8)
        XCTAssertFalse(originalCommands.contains { $0["name"].string == skillName })
        _ = try await store.performLiveConfiguration(chat, operation: .reloadSkills)
        let commandsUntil = ContinuousClock.now + .seconds(10)
        while !chat.transcript.commands.contains(where: { $0["name"].string == skillName }), ContinuousClock.now < commandsUntil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(chat.transcript.commands.contains { $0["name"].string == skillName })
        _ = try await store.performLiveConfiguration(chat, operation: .reloadPlugins)
        XCTAssertTrue(chat.connection === peer); XCTAssertEqual(chat.transcript.remoteID, remote)
        XCTAssertFalse(chat.transcript.items.contains { $0.kind == "user" || $0.kind == "assistant" || $0.kind == "tool" }, "Configuration controls must not create model turns")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("unexpected-call.json").path))
        let proof: JSONValue = ["remoteSessionId": .string(remote), "firstPID": .number(Double(firstPID)), "restartedPIDs": .array(restarted.map { .number(Double($0)) }), "skill": .string(String(skillName)), "modelTurns": 0]
        try JSONEncoder().encode(proof).write(to: root.appendingPathComponent("verified-live-configuration.json"))
        await store.shutdown()
        let stoppedUntil = ContinuousClock.now + .seconds(10)
        while restarted.contains(where: { Darwin.kill($0, 0) == 0 }), ContinuousClock.now < stoppedUntil { try await Task.sleep(for: .milliseconds(20)) }
        for pid in restarted { XCTAssertEqual(Darwin.kill(pid, 0), -1, "All owned MCP fixture processes must exit on shutdown") }
        print("Actual live configuration proof: \(root.path)")
    }
}
