import XCTest
import CCodeCore

final class AgentTaskTests: XCTestCase {
    func testAnnouncementSeparatesTheParentMessagesBeforeAndAfterDelegation() {
        var transcript = SessionTranscript(remoteID: "root"), owners = Set<String>()
        XCTAssertTrue(transcript.apply(text("root", "Before")))
        XCTAssertTrue(transcript.applyAgentWork(spawn("child"), owners: &owners))
        XCTAssertTrue(transcript.apply(text("root", "After")))
        XCTAssertEqual(transcript.items.map(\.kind), ["assistant", "subagent", "assistant"])
        XCTAssertEqual(transcript.items.map(\.text), ["Before", "", "After"])
    }
    func testDisconnectStopsRenderingChildToolsAsRunningWithoutChangingProviderResults() throws {
        var transcript = SessionTranscript(remoteID: "root"), owners = Set<String>()
        for id in ["left", "right"] {
            XCTAssertTrue(transcript.applyAgentWork(spawn(id), owners: &owners))
            XCTAssertTrue(transcript.applyAgentWork(tool(id, status: "in_progress"), owners: &owners))
        }
        XCTAssertTrue(transcript.applyAgentWork(tool("right", status: "completed"), owners: &owners))
        let original = try XCTUnwrap(transcript.subagent("left")?.transcript.items.last?.tool)
        transcript.disconnectSubagents()
        let saved = try JSONDecoder().decode(SessionTranscript.self, from: JSONEncoder().encode(transcript))
        let left = try XCTUnwrap(saved.subagent("left")?.transcript.items.last)
        XCTAssertFalse(left.isToolRunning)
        XCTAssertEqual(left.toolInterruption, .disconnected)
        XCTAssertEqual(left.tool, original)
        XCTAssertNil(saved.subagent("right")?.transcript.items.last?.toolInterruption)
    }
    func testChildTerminalStateInterruptsOnlyItsOwnUnfinishedTools() throws {
        for (state, reason) in [("cancelled", ToolInterruption.stopped), ("stopped", .stopped), ("failed", .interrupted), ("completed", .interrupted)] {
            var transcript = SessionTranscript(remoteID: "root"), owners = Set<String>()
            for id in ["left", "right"] {
                XCTAssertTrue(transcript.applyAgentWork(spawn(id), owners: &owners))
                XCTAssertTrue(transcript.applyAgentWork(tool(id, status: "in_progress"), owners: &owners))
            }
            XCTAssertTrue(transcript.applyAgentWork(["sessionId": "root", "update": ["sessionUpdate": "subagent_state_update", "subagentSessionId": "left", "state": .string(state)]], owners: &owners))
            let left = try XCTUnwrap(transcript.subagent("left")?.transcript.items.last)
            XCTAssertFalse(left.isToolRunning, state)
            XCTAssertEqual(left.toolInterruption, reason, state)
            XCTAssertEqual(left.tool["status"], "in_progress")
            XCTAssertEqual(transcript.subagent("right")?.transcript.items.last?.isToolRunning, true)
            XCTAssertTrue(transcript.applyAgentWork(tool("left", status: "completed"), owners: &owners))
            XCTAssertNil(transcript.subagent("left")?.transcript.items.last?.toolInterruption)
        }
    }
    func testChildReplayPreservesReceiptsOnlyForTheSameParentAndUniqueChildIdentity() throws {
        var saved = SessionTranscript(remoteID: "root"), owners = Set<String>()
        for id in ["left", "right"] {
            XCTAssertTrue(saved.applyAgentWork(spawn(id), owners: &owners))
            XCTAssertTrue(saved.applyAgentWork(tool(id, status: "in_progress"), owners: &owners))
        }
        let left = try XCTUnwrap(saved.subagents?.firstIndex { $0.id == "left" })
        saved.subagents?[left].transcript.interruptTools(.stopped)
        var replay = saved
        replay.subagents?[left].transcript.items[0].toolInterruption = nil
        replay.restoreToolInterruptions(from: saved)
        XCTAssertEqual(replay.subagent("left")?.transcript.items.last?.toolInterruption, .stopped)
        XCTAssertNil(replay.subagent("right")?.transcript.items.last?.toolInterruption)
        replay.subagents?[left].transcript.items[0].toolInterruption = nil
        replay.subagents?[left].parentID = "right"
        replay.restoreToolInterruptions(from: saved)
        XCTAssertNil(replay.subagent("left")?.transcript.items.last?.toolInterruption)
        replay.subagents?[left].parentID = "root"
        let duplicate = try XCTUnwrap(saved.subagent("left"))
        saved.subagents?.append(duplicate)
        replay.restoreToolInterruptions(from: saved)
        XCTAssertNil(replay.subagent("left")?.transcript.items.last?.toolInterruption)
    }
    private func tool(_ owner: String, status: String) -> JSONValue {
        ["sessionId": .string(owner), "update": ["sessionUpdate": "tool_call", "toolCallId": "same", "title": "Read owned file", "name": "Read", "rawInput": ["file_path": .string(owner + "/file")], "status": .string(status)]]
    }
    private func spawn(_ id: String, parent: String = "root", name: String? = nil) -> JSONValue {
        var update: JSONValue = ["sessionUpdate": "subagent_spawned", "subagentSessionId": .string(id)]
        if let name { update["name"] = .string(name) }
        return ["sessionId": .string(parent), "update": update]
    }
    private func text(_ owner: String, _ value: String) -> JSONValue {
        ["sessionId": .string(owner), "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": .string(value)]]]
    }
    func testNestedAndSiblingTranscriptsStaySeparateAndDefaultMetadataIsHonest() throws {
        var transcript = SessionTranscript(remoteID: "root"), owners = Set<String>()
        XCTAssertTrue(transcript.applyAgentWork(spawn("left", name: "Explorer"), owners: &owners))
        XCTAssertTrue(transcript.applyAgentWork(spawn("right"), owners: &owners))
        XCTAssertTrue(transcript.applyAgentWork(spawn("nested", parent: "left"), owners: &owners))
        XCTAssertTrue(transcript.applyAgentWork(text("left", "Left only"), owners: &owners))
        XCTAssertTrue(transcript.applyAgentWork(text("right", "Right only"), owners: &owners))
        XCTAssertTrue(transcript.applyAgentWork(text("nested", "Nested only"), owners: &owners))
        XCTAssertEqual(transcript.subagents?.count, 3)
        XCTAssertEqual(transcript.subagent("left")?.transcript.items.last?.text, "Left only")
        XCTAssertEqual(transcript.subagent("right")?.transcript.items.last?.text, "Right only")
        XCTAssertEqual(transcript.subagent("nested")?.parentID, "left")
        XCTAssertEqual(transcript.subagent("right")?.state, "running")
        XCTAssertEqual(transcript.subagent("right")?.capabilities, [:])
        XCTAssertFalse(transcript.items.contains { $0.text.contains("only") })
        XCTAssertEqual(transcript.items.filter { $0.kind == "subagent" }.count, 2)
        XCTAssertEqual(transcript.subagent("left")?.transcript.items.filter { $0.kind == "subagent" }.count, 1)
    }
    func testUnknownScopeReparentingCyclesAndUnannouncedStatesCannotAcquireOwnership() {
        var transcript = SessionTranscript(remoteID: "root"), owners = Set<String>()
        XCTAssertFalse(transcript.applyAgentWork(text("unknown", "No announcement"), owners: &owners))
        XCTAssertFalse(transcript.applyAgentWork(spawn("child", parent: "unknown"), owners: &owners))
        XCTAssertFalse(transcript.applyAgentWork(spawn("root"), owners: &owners))
        XCTAssertTrue(transcript.applyAgentWork(spawn("a"), owners: &owners))
        XCTAssertTrue(transcript.applyAgentWork(spawn("b", parent: "a"), owners: &owners))
        XCTAssertFalse(transcript.applyAgentWork(spawn("a", parent: "b"), owners: &owners))
        XCTAssertFalse(transcript.applyAgentWork(spawn("b"), owners: &owners))
        XCTAssertFalse(transcript.applyAgentWork(["sessionId": "root", "update": ["sessionUpdate": "subagent_state_update", "subagentSessionId": "unknown", "state": "completed"]], owners: &owners))
        XCTAssertEqual(owners, ["a", "b"])
    }
    func testDuplicateAnnouncementPatchesMetadataWithoutDuplicatingRowsOrResurrectingWork() {
        var transcript = SessionTranscript(remoteID: "root"), owners = Set<String>()
        XCTAssertTrue(transcript.applyAgentWork(spawn("a", name: "Before"), owners: &owners))
        XCTAssertTrue(transcript.applyAgentWork(text("a", "Result"), owners: &owners))
        XCTAssertTrue(transcript.applyAgentWork(["sessionId": "root", "update": ["sessionUpdate": "subagent_state_update", "subagentSessionId": "a", "state": "completed"]], owners: &owners))
        XCTAssertTrue(transcript.applyAgentWork(spawn("a", name: "After"), owners: &owners))
        XCTAssertEqual(transcript.items.count, 1)
        XCTAssertEqual(transcript.subagent("a")?.name, "After")
        XCTAssertEqual(transcript.subagent("a")?.state, "completed")
        XCTAssertEqual(transcript.subagent("a")?.transcript.items.last?.text, "Result")
        XCTAssertTrue(transcript.applyAgentWork(text("a", " trailing output"), owners: &owners))
        XCTAssertEqual(transcript.subagent("a")?.transcript.items.last?.text, "Result trailing output")
    }
    func testStoredChildHistoryDoesNotAuthorizeANewConnectionUntilAnnounced() throws {
        var transcript = SessionTranscript(remoteID: "root"), owners = Set<String>()
        XCTAssertTrue(transcript.applyAgentWork(spawn("a"), owners: &owners))
        XCTAssertTrue(transcript.applyAgentWork(text("a", "Saved"), owners: &owners))
        let saved = try JSONEncoder().encode(transcript)
        var restored = try JSONDecoder().decode(SessionTranscript.self, from: saved)
        restored.disconnectSubagents(); owners.removeAll()
        XCTAssertEqual(restored.subagent("a")?.state, "disconnected")
        XCTAssertFalse(restored.applyAgentWork(text("a", "Unauthorized"), owners: &owners))
        XCTAssertTrue(restored.applyAgentWork(spawn("a"), owners: &owners))
        XCTAssertTrue(restored.applyAgentWork(text("a", " resumed"), owners: &owners))
        XCTAssertEqual(restored.subagent("a")?.transcript.items.last?.text, "Saved resumed")
        XCTAssertEqual(restored.subagent("a")?.state, "running")
        XCTAssertEqual(restored.items.count, 1)
    }
    func testIdenticalToolIDsBelongToTheirOwnChildAndCompletedChildrenSurviveDisconnect() {
        var transcript = SessionTranscript(remoteID: "root"), owners = Set<String>()
        for id in ["a", "b"] {
            XCTAssertTrue(transcript.applyAgentWork(spawn(id), owners: &owners))
            XCTAssertTrue(transcript.applyAgentWork(["sessionId": .string(id), "update": ["sessionUpdate": "tool_call", "toolCallId": "same", "title": .string(id), "status": "completed"]], owners: &owners))
        }
        XCTAssertEqual(transcript.subagent("a")?.transcript.items.last?.tool["title"], "a")
        XCTAssertEqual(transcript.subagent("b")?.transcript.items.last?.tool["title"], "b")
        XCTAssertTrue(transcript.applyAgentWork(["sessionId": "root", "update": ["sessionUpdate": "subagent_state_update", "subagentSessionId": "a", "state": "failed"]], owners: &owners))
        transcript.disconnectSubagents()
        XCTAssertEqual(transcript.subagent("a")?.state, "failed")
        XCTAssertEqual(transcript.subagent("b")?.state, "disconnected")
    }
}
