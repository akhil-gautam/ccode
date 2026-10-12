import XCTest
import Foundation
import CCodeCore
@testable import CCode

final class NativeDelegatedWorkflowTests: XCTestCase {
    @MainActor func testNativeRefreshReplacesStaleChildrenPreservesDraftAndRestartsWithoutAgent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-native-family-\(UUID())")
        let claude = root.appendingPathComponent("claude"), project = root.appendingPathComponent("project")
        let history = claude.appendingPathComponent("projects/encoded")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("claude-agent-acp"), audit = root.appendingPathComponent("unexpected-launch")
        try Data("#!/usr/bin/python3\nfrom pathlib import Path\nPath('\(audit.path)').write_text('started')\nraise SystemExit(2)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let remote = UUID().uuidString, childID = remote + ":replay-subagent:launch"
        let childFolder = history.appendingPathComponent(remote + "/subagents")
        try FileManager.default.createDirectory(at: childFolder, withIntermediateDirectories: true)
        func write(_ records: [JSONValue], to file: URL, child: Bool = false) throws {
            var data = Data()
            for var record in records {
                record["sessionId"] = .string(remote)
                if child { record["isSidechain"] = true; record["agentId"] = "child" }
                data.append(try JSONEncoder().encode(record)); data.append(10)
            }
            try data.write(to: file)
        }
        try write([
            ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Inspect"]],
            ["type": "assistant", "uuid": "a", "parentUuid": "u", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "launch", "name": "Agent", "input": ["prompt": "Inspect file"]]]]],
            ["type": "user", "uuid": "r", "parentUuid": "a", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "launch", "content": "Done"]]]],
            ["type": "assistant", "uuid": "done", "parentUuid": "r", "message": ["role": "assistant", "content": "Current root report"]]
        ], to: history.appendingPathComponent(remote + ".jsonl"))
        try JSONEncoder().encode(JSONValue.object(["toolUseId": "launch"])).write(to: childFolder.appendingPathComponent("agent-child.meta.json"))
        var childRecords: [JSONValue] = [
            ["type": "user", "uuid": "cu", "parentUuid": nil, "message": ["role": "user", "content": "Inspect file"]],
            ["type": "assistant", "uuid": "ca", "parentUuid": "cu", "message": ["role": "assistant", "content": "Current child report"]]
        ]
        let childFile = childFolder.appendingPathComponent("agent-child.jsonl")
        try write(childRecords, to: childFile, child: true)
        var info = SessionInfo(projectPath: project.path, title: "Imported family")
        info.remoteSessionID = remote; info.importedFromAgent = true; info.agentExecutable = executable.path; info.agentArguments = []
        var stored = SessionTranscript(remoteID: remote)
        var stale = SubagentSession(id: "saved-old-child", parentID: remote)
        stale.state = "completed"; stale.transcript.items = [TranscriptItem(kind: "assistant", text: "Stale saved report")]
        stored.subagents = [stale]; stored.draftText = "Keep my unsent draft"
        let directory = root.appendingPathComponent("data")
        let storage = SessionStorage(directory: directory, claudeDirectory: claude)
        try await storage.saveIndex([info]); try await storage.save(stored, id: info.id)
        let store = AppStore(directory: directory, claudeDirectory: claude)
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.restore()
        let chat = try XCTUnwrap(store.selected)
        XCTAssertEqual(chat.transcript.subagents?.count, 1)
        XCTAssertNil(chat.transcript.subagent("saved-old-child"))
        XCTAssertEqual(chat.transcript.subagent(childID)?.transcript.items.last?.text, "Current child report")
        XCTAssertEqual(chat.draft, "Keep my unsent draft")
        XCTAssertNil(chat.connection); XCTAssertFalse(FileManager.default.fileExists(atPath: audit.path))
        XCTAssertFalse(store.canStopSubagent(chat, id: childID))
        childRecords.append(["type": "user", "uuid": "cu2", "parentUuid": "ca", "message": ["role": "user", "content": "External follow-up"]])
        childRecords.append(["type": "assistant", "uuid": "ca2", "parentUuid": "cu2", "message": ["role": "assistant", "content": "Externally appended child report"]])
        try write(childRecords, to: childFile, child: true)
        chat.transcript.historyUpdatedAt = .distantPast
        await store.select(info.id)
        XCTAssertEqual(chat.transcript.subagent(childID)?.transcript.items.last?.text, "Externally appended child report")
        XCTAssertEqual(chat.draft, "Keep my unsent draft")
        await store.shutdown()
        let restored = AppStore(directory: directory, claudeDirectory: claude)
        await restored.restore()
        XCTAssertEqual(restored.selected?.transcript.subagent(childID)?.transcript.items.last?.text, "Externally appended child report")
        XCTAssertEqual(restored.selected?.draft, "Keep my unsent draft")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audit.path))
        await restored.shutdown()
    }
}
