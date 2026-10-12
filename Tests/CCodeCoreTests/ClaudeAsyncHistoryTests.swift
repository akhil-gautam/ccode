import XCTest
import CCodeCore
import Darwin
@testable import CCode

final class ClaudeAsyncHistoryTests: XCTestCase {
    private let remote = "31da61a1-8fba-4b7a-8e3e-5e3f67df73a3"
    private func fixture(error: Bool = false, metadata: JSONValue = ["backgroundTaskId": "job"], stopped: Bool = false, outputPath: String? = nil) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-async-history-\(UUID())")
        let folder = root.appendingPathComponent("projects/fixture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent(remote + ".jsonl")
        let output = outputPath ?? "/tmp/claude-501/project/\(remote)/tasks/job.output"
        var records: [JSONValue] = [
            ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Run build"]],
            ["type": "assistant", "uuid": "a", "parentUuid": "u", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "launch", "name": "Bash", "input": ["command": "swift test", "run_in_background": true]]]]],
            ["type": "user", "uuid": "r", "parentUuid": "a", "toolUseResult": metadata, "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "launch", "is_error": .bool(error), "content": .string("Command running in background with ID: job. Output is being written to: \(output). You will be notified when it completes.")]]]]
        ]
        if stopped {
            records += [
                ["type": "assistant", "uuid": "s", "parentUuid": "r", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "stop", "name": "TaskStop", "input": ["task_id": "job"]]]]],
                ["type": "user", "uuid": "sr", "parentUuid": "s", "toolUseResult": ["task_id": "job", "task_type": "local_bash", "message": "Task stopped"], "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "stop", "content": "Stopped"]]]]
            ]
        }
        var data = Data()
        for var record in records { record["sessionId"] = .string(remote); data.append(try JSONEncoder().encode(record)); data.append(10) }
        try data.write(to: file)
        return (root, file)
    }
    func testHistoricalBashLaunchRestoresIdentityAndCommandWithoutInventingCompletionOrControl() throws {
        let (root, file) = try fixture()
        let original = try Data(contentsOf: file)
        let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: remote, cwd: "/project", configurationDirectory: root))
        let task = try XCTUnwrap(value.asyncTasks?.first)
        XCTAssertEqual(task.id, AsyncTaskIdentity(owner: remote, task: "job"))
        XCTAssertEqual(task.description, "swift test"); XCTAssertEqual(task.toolCallID, "launch")
        XCTAssertEqual(task.state, .disconnected); XCTAssertFalse(task.canStop); XCTAssertFalse(task.isRunning)
        XCTAssertTrue(task.outputFilePath?.hasSuffix("/tasks/job.output") == true)
        XCTAssertEqual(value.items.filter { $0.kind == "tool" }.count, 1, "Keep actual command/input/output disclosure")
        XCTAssertFalse(value.items.contains { $0.kind == "async_task" }, "Tasks pane must not duplicate the command row")
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testActualStructuredStopRetainsStoppedState() throws {
        let (root, _) = try fixture(stopped: true)
        let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: remote, cwd: "/project", configurationDirectory: root))
        XCTAssertEqual(value.asyncTasks?.first?.state, .stopped)
        XCTAssertFalse(value.asyncTasks?.first?.canStop ?? true)
    }
    func testRootAndChildBackgroundTasksWithSameIDsKeepDistinctHistoryOwners() throws {
        let (root, file) = try fixture()
        var bytes = try Data(contentsOf: file)
        for var record: JSONValue in [
            ["type": "assistant", "uuid": "child-launch", "parentUuid": "r", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "agent", "name": "Agent", "input": ["prompt": "Build", "run_in_background": true]]]]],
            ["type": "user", "uuid": "child-result", "parentUuid": "child-launch", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "agent", "content": "Launched"]]]]
        ] {
            record["sessionId"] = .string(remote)
            bytes.append(try JSONEncoder().encode(record)); bytes.append(10)
        }
        try bytes.write(to: file)
        let children = file.deletingLastPathComponent().appendingPathComponent(remote + "/subagents")
        try FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
        try JSONEncoder().encode(JSONValue.object(["toolUseId": "agent"])).write(to: children.appendingPathComponent("agent-child.meta.json"))
        let (_, source) = try fixture(stopped: true)
        var childBytes = Data()
        for line in try Data(contentsOf: source).split(separator: 10) {
            var record = try JSONDecoder().decode(JSONValue.self, from: Data(line))
            record["agentId"] = "child"; record["isSidechain"] = true
            childBytes.append(try JSONEncoder().encode(record)); childBytes.append(10)
        }
        let childFile = children.appendingPathComponent("agent-child.jsonl")
        try childBytes.write(to: childFile)
        let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: remote, cwd: "/project", configurationDirectory: root))
        let child = remote + ":replay-subagent:agent"
        XCTAssertEqual(value.asyncTasks?.count, 2)
        XCTAssertEqual(value.asyncTask(AsyncTaskIdentity(owner: remote, task: "job"))?.state, .disconnected)
        XCTAssertEqual(value.asyncTask(AsyncTaskIdentity(owner: child, task: "job"))?.state, .stopped)
        XCTAssertNil(value.subagent(child)?.transcript.asyncTasks, "One root registry owns child tasks without copying them twice")
        XCTAssertEqual(value.asyncTasks?.map(\.toolCallID), ["launch", "launch"])
        XCTAssertTrue((value.asyncTasks ?? []).allSatisfy { !$0.canStop })
        XCTAssertEqual(try Data(contentsOf: file), bytes); XCTAssertEqual(try Data(contentsOf: childFile), childBytes)
    }
    func testMergeCannotTransferTerminalStateAcrossDifferentLaunchesOrForeignOwners() throws {
        let (root, _) = try fixture()
        let native = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: remote, cwd: "/project", configurationDirectory: root))
        for difference in ["same", "command", "tool", "path", "type"] {
            var saved = native, fresh = native
            saved.asyncTasks?[0].state = .stopped; saved.asyncTasks?[0].canStop = true
            switch difference {
            case "command": saved.asyncTasks?[0].description = "other command"
            case "tool": saved.asyncTasks?[0].toolCallID = "other"
            case "path": saved.asyncTasks?[0].outputFilePath = "/other"
            case "type": saved.asyncTasks?[0].taskType = "other"
            default: break
            }
            var foreign = AgentAsyncTask(id: AsyncTaskIdentity(owner: "foreign", task: "job")); foreign.state = .completed
            saved.asyncTasks?.append(foreign)
            fresh.mergeClaudeHistoricalTasks(from: saved)
            XCTAssertEqual(fresh.asyncTasks?.count, 1)
            XCTAssertEqual(fresh.asyncTasks?.first?.state, difference == "same" ? .stopped : .disconnected)
            XCTAssertFalse(fresh.asyncTasks?.first?.canStop ?? true)
        }
    }
    func testReplayRetainsProviderTaskControlAndRefusesIncompleteHistoryAtomically() throws {
        let (root, _) = try fixture()
        let native = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: remote, cwd: "/project", configurationDirectory: root))
        var replay = native; replay.asyncTasks = nil
        var owners: Set<AsyncTaskIdentity> = []
        let spawn: JSONValue = ["sessionId": .string(remote), "update": ["sessionUpdate": "async_task_spawned", "asyncTaskId": "job", "canStop": true]]
        XCTAssertTrue(replay.applyAsyncWork(spawn, children: [], owners: &owners))
        XCTAssertTrue(replay.restoreClaudeAsyncReplay(with: native))
        XCTAssertEqual(replay.asyncTasks?.count, 1); XCTAssertTrue(replay.asyncTasks?.first?.canStop ?? false)
        XCTAssertEqual(replay.asyncTasks?.first?.state, .running)
        for difference in ["missing tool", "changed command", "foreign owner", "active source", "control source", "duplicate"] {
            var source = native, target = native; target.asyncTasks = nil
            switch difference {
            case "missing tool": target.items = []
            case "changed command": source.asyncTasks?[0].description = "other command"
            case "foreign owner": source.asyncTasks?[0].id = AsyncTaskIdentity(owner: "foreign", task: "job")
            case "active source": source.asyncTasks?[0].state = .running
            case "control source": source.asyncTasks?[0].canStop = true
            default:
                let duplicate = try XCTUnwrap(source.asyncTasks?.first)
                source.asyncTasks?.append(duplicate)
            }
            let before = try JSONEncoder().encode(target)
            XCTAssertFalse(target.restoreClaudeAsyncReplay(with: source), difference)
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(target)), try JSONDecoder().decode(JSONValue.self, from: before))
        }
    }
    func testTextAloneErrorsAndInvalidStructuredIDsCannotFabricateTasks() throws {
        for (error, metadata) in [(true, JSONValue.object(["backgroundTaskId": "job"])), (false, JSONValue.null), (false, ["backgroundTaskId": "../job"]), (false, ["backgroundTaskId": ""])] {
            let (root, _) = try fixture(error: error, metadata: metadata)
            let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: remote, cwd: "/project", configurationDirectory: root))
            XCTAssertTrue((value.asyncTasks ?? []).isEmpty)
            XCTAssertEqual(value.items.filter { $0.kind == "tool" }.count, 1)
        }
    }
    func testRealDisposableBackgroundHistoryRestoresTaskWithoutAgent() throws {
        guard let path = ProcessInfo.processInfo.environment["CCODE_REAL_ASYNC_HISTORY_DIRECTORY"] else { throw XCTSkip("Set CCODE_REAL_ASYNC_HISTORY_DIRECTORY to the disposable background-command proof.") }
        let folder = URL(fileURLWithPath: path)
        guard folder.lastPathComponent.contains("ccode-real-background-") else { throw XCTSkip("Read only the controlled background proof.") }
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil })
        let original = try Data(contentsOf: file), id = file.deletingPathExtension().lastPathComponent
        let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: id, cwd: "/unavailable/disposable/project", configurationDirectory: folder.deletingLastPathComponent().deletingLastPathComponent()))
        let task = try XCTUnwrap(value.asyncTasks?.first)
        XCTAssertEqual(task.id.owner, id); XCTAssertEqual(task.taskType, "local_bash")
        XCTAssertTrue(task.description.contains("task-proof.txt"))
        XCTAssertTrue(task.outputFilePath?.hasSuffix("/tasks/\(task.id.task).output") == true)
        XCTAssertEqual(task.state, .disconnected); XCTAssertFalse(task.canStop)
        let output = try AsyncTaskOutput.readClaudeHistory(path: XCTUnwrap(task.outputFilePath), taskID: task.id.task, rootID: id)
        XCTAssertLessThanOrEqual(output.byteCount, 64 * 1024)
        XCTAssertTrue(output.text.contains("ccode-background:"), "Actual controlled background command output")
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    @MainActor func testRealForcedBackgroundReplayPreservesActualLaunchWithoutModelPrompt() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CCODE_REAL_ASYNC_HISTORY_DIRECTORY"], let executable = env["CCODE_REAL_AGENT"] else {
            throw XCTSkip("Set CCODE_REAL_AGENT and CCODE_REAL_ASYNC_HISTORY_DIRECTORY to the disposable background-command proof.")
        }
        let source = URL(fileURLWithPath: path)
        guard source.lastPathComponent.contains("ccode-real-background-") else { throw XCTSkip("Replay only the controlled background proof.") }
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).first {
            $0.pathExtension == "jsonl" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
        })
        let original = try Data(contentsOf: file), oldID = file.deletingPathExtension().lastPathComponent
        let rootID = UUID().uuidString.lowercased()
        let copy = source.deletingLastPathComponent().appendingPathComponent("ccode-async-replay-proof-\(UUID())")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        var bytes = Data()
        for line in original.split(separator: 10) {
            var record = try JSONDecoder().decode(JSONValue.self, from: Data(line))
            if record["sessionId"] == .string(oldID) { record["sessionId"] = .string(rootID) }
            bytes.append(try JSONEncoder().encode(record)); bytes.append(10)
        }
        let copiedFile = copy.appendingPathComponent(rootID + ".jsonl")
        try bytes.write(to: copiedFile)
        func conversation(_ data: Data) throws -> [JSONValue] {
            try data.split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }.filter { ["user", "assistant"].contains($0["type"].string) }
        }
        let originalConversation = try conversation(bytes)
        let config = source.deletingLastPathComponent().deletingLastPathComponent()
        let native = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: rootID, cwd: "/unavailable/disposable/project", configurationDirectory: config))
        let task = try XCTUnwrap(native.asyncTasks?.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-async-replay-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(directory: directory.appendingPathComponent("data"), claudeDirectory: config)
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await store.create(path: directory.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        chat.transcript.remoteID = rootID; chat.draft = "Keep actual replay draft"
        try await store.connect(chat, reloadHistory: true)
        let restored = try XCTUnwrap(chat.transcript.asyncTask(task.id))
        XCTAssertEqual(restored.description, task.description)
        XCTAssertEqual(restored.toolCallID, task.toolCallID)
        XCTAssertEqual(restored.outputFilePath, task.outputFilePath)
        XCTAssertEqual(restored.state, .disconnected); XCTAssertFalse(restored.canStop)
        XCTAssertTrue(chat.asyncTaskOwners.isEmpty); XCTAssertFalse(store.canStopAsyncTask(chat, id: task.id))
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "tool" && $0.tool["toolCallId"] == .string(task.toolCallID ?? "") && $0.tool["rawInput"]["command"] == .string(task.description) })
        XCTAssertEqual(chat.draft, "Keep actual replay draft")
        await store.shutdown()
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try conversation(Data(contentsOf: copiedFile)), originalConversation)
        print("Actual forced background session/load preserved the launch with no model prompt; source history unchanged.")
    }
    @MainActor func testNativeTaskRefreshPreservesRecordedTerminalStateAndDraftWithoutLaunchingAgent() async throws {
        for savedState in [AsyncTaskState?.none, .some(.stopped)] {
            let (config, _) = try fixture()
            let root = config.appendingPathComponent("project"), data = config.appendingPathComponent("data")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("claude-agent-acp"), audit = root.appendingPathComponent("unexpected-launch")
            try Data("#!/usr/bin/python3\nfrom pathlib import Path\nPath('\(audit.path)').write_text('started')\nraise SystemExit(2)\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            var info = SessionInfo(projectPath: root.path, title: "Background history")
            info.remoteSessionID = remote; info.importedFromAgent = true; info.agentExecutable = executable.path; info.agentArguments = []
            var saved = SessionTranscript(remoteID: remote); saved.draftText = "Keep unsent draft"
            if let savedState {
                var task = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: remote, cwd: root.path, configurationDirectory: config)?.asyncTasks?.first)
                task.state = savedState; task.canStop = true; task.summary = "Client recorded actual Stop acknowledgement"
                saved.asyncTasks = [task]
            }
            let storage = SessionStorage(directory: data, claudeDirectory: config)
            try await storage.saveIndex([info]); try await storage.save(saved, id: info.id)
            let store = AppStore(directory: data, claudeDirectory: config)
            addTeardownBlock { await store.shutdown() }
            await store.restore()
            let chat = try XCTUnwrap(store.selected), task = try XCTUnwrap(chat.transcript.asyncTasks?.first)
            XCTAssertEqual(task.state, savedState ?? .disconnected)
            XCTAssertFalse(task.canStop, "Saved control flags cannot authorize a fresh native import")
            XCTAssertEqual(task.description, "swift test")
            XCTAssertEqual(chat.draft, "Keep unsent draft"); XCTAssertNil(chat.connection)
            XCTAssertFalse(FileManager.default.fileExists(atPath: audit.path))
            await store.shutdown()
            let restored = AppStore(directory: data, claudeDirectory: config)
            await restored.restore()
            XCTAssertEqual(restored.selected?.transcript.asyncTasks?.first?.state, savedState ?? .disconnected)
            XCTAssertEqual(restored.selected?.draft, "Keep unsent draft")
            await restored.shutdown()
        }
    }
    @MainActor func testHistoricalOutputReadsPagesWithoutPeerAndRejectsUnprovenChangedPaths() async throws {
        let outputRoot = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())/ccode-output-proof-\(UUID())")
        let taskFolder = outputRoot.appendingPathComponent(remote + "/tasks")
        try FileManager.default.createDirectory(at: taskFolder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outputRoot) }
        let outputFile = taskFolder.appendingPathComponent("job.output")
        let text = String(repeating: "0123456789", count: 20_000) + "historical-output-proof\n"
        try Data(text.utf8).write(to: outputFile)
        let (config, _) = try fixture(outputPath: outputFile.path)
        let project = config.appendingPathComponent("project"), data = config.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var info = SessionInfo(projectPath: project.path, title: "Output history")
        info.remoteSessionID = remote; info.importedFromAgent = true; info.agentExecutable = "/unavailable/claude-agent-acp"; info.agentArguments = []
        let storage = SessionStorage(directory: data, claudeDirectory: config)
        try await storage.saveIndex([info])
        let store = AppStore(directory: data, claudeDirectory: config)
        addTeardownBlock { await store.shutdown() }
        await store.restore()
        let chat = try XCTUnwrap(store.selected), id = AsyncTaskIdentity(owner: remote, task: "job")
        XCTAssertNil(chat.connection); XCTAssertTrue(chat.asyncTaskOwners.isEmpty)
        let latestValue = try await store.readAsyncOutput(chat, id: id)
        let latest = try XCTUnwrap(latestValue)
        XCTAssertLessThanOrEqual(latest.byteCount, 64 * 1024)
        XCTAssertTrue(latest.text.hasSuffix("historical-output-proof\n"))
        let olderValue = try await store.readAsyncOutput(chat, id: id, endingAt: latest.offset)
        let older = try XCTUnwrap(olderValue)
        XCTAssertEqual(older.offset + UInt64(older.byteCount), latest.offset)
        XCTAssertFalse(store.canStopAsyncTask(chat, id: id)); XCTAssertNil(chat.connection)
        chat.transcript.asyncTasks?[0].outputFilePath = config.appendingPathComponent("private-file").path
        do { _ = try await store.readAsyncOutput(chat, id: id); XCTFail("Stored paths are not independent read authority") }
        catch { }
        XCTAssertTrue(chat.asyncTaskOwners.isEmpty); XCTAssertNil(chat.connection)
        await store.shutdown()
    }
    @MainActor func testForcedReplayRestoresOnlyVerifiedNativeLaunchesWithoutControlAuthority() async throws {
        for (version, missing, savedStop) in [("0.84.0", false, false), ("0.84.0", false, true), ("0.85.0", false, false), ("0.84.0", true, false)] {
            let (config, file) = try fixture()
            let native = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: remote, cwd: "/project", configurationDirectory: config))
            if missing { try FileManager.default.removeItem(at: file) }
            let project = config.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let scenario = config.appendingPathComponent("events.json"), script = config.appendingPathComponent("agent.py")
            let source = try XCTUnwrap(native.items.first { $0.kind == "tool" })
            let events: [JSONValue] = [
                ["sessionId": .string(remote), "update": ["sessionUpdate": "tool_call", "toolCallId": source.tool["toolCallId"], "title": "Bash", "kind": "execute", "status": "completed", "rawInput": source.tool["rawInput"], "rawOutput": "Keep provider rendering"]],
                ["sessionId": .string(remote), "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Keep provider report"]]]
            ]
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
            let directory = config.appendingPathComponent("data")
            let store = AppStore(directory: directory, claudeDirectory: config)
            store.settings.executable = "/usr/bin/python3"; store.settings.arguments = [script.path, scenario.path, version]
            addTeardownBlock { await store.shutdown() }
            await store.create(path: project.path, worktree: false)
            let chat = try XCTUnwrap(store.selected)
            chat.transcript.remoteID = remote; chat.draft = "Keep replay draft"
            if savedStop { chat.transcript.asyncTasks = native.asyncTasks; chat.transcript.asyncTasks?[0].state = .stopped }
            try await store.connect(chat, reloadHistory: true)
            let expected = version == "0.84.0" && !missing
            XCTAssertEqual(chat.transcript.asyncTasks?.count ?? 0, expected ? 1 : 0)
            if expected {
                XCTAssertEqual(chat.transcript.asyncTasks?.first?.state, savedStop ? .stopped : .disconnected)
                XCTAssertFalse(chat.transcript.asyncTasks?.first?.canStop ?? true)
                XCTAssertEqual(chat.transcript.asyncTasks?.first?.description, "swift test")
            }
            XCTAssertTrue(chat.asyncTaskOwners.isEmpty)
            XCTAssertFalse(store.canStopAsyncTask(chat, id: AsyncTaskIdentity(owner: remote, task: "job")))
            XCTAssertEqual(chat.transcript.items.first { $0.kind == "tool" }?.tool["rawOutput"], "Keep provider rendering")
            XCTAssertEqual(chat.transcript.items.last?.text, "Keep provider report")
            XCTAssertEqual(chat.draft, "Keep replay draft")
            await store.shutdown()
            let restored = AppStore(directory: directory, claudeDirectory: config)
            await restored.restore()
            XCTAssertEqual(restored.selected?.transcript.asyncTasks?.count ?? 0, expected ? 1 : 0)
            XCTAssertEqual(restored.selected?.draft, "Keep replay draft"); XCTAssertNil(restored.selected?.connection)
            await restored.shutdown()
        }
    }
}
