import XCTest
import CCodeCore

final class DelegatedReplayTests: XCTestCase {
    private let root = "31da61a1-8fba-4b7a-8e3e-5e3f67df73a3"
    private func fixture() -> (SessionTranscript, SessionTranscript) {
        func child(_ tool: String, parent: String, state: String) -> SubagentSession {
            var value = SubagentSession(id: root + ":replay-subagent:" + tool, parentID: parent)
            value.state = state; return value
        }
        func row(_ id: String) -> TranscriptItem { TranscriptItem(kind: "subagent", tool: ["subagentSessionId": .string(id)]) }
        var native = SessionTranscript(remoteID: root), replay = SessionTranscript(remoteID: root)
        var parent = child("parent", parent: root, state: "cancelled")
        let nested = child("nested", parent: parent.id, state: "disconnected")
        parent.transcript.items = [row(nested.id), TranscriptItem(kind: "tool", tool: ["toolCallId": "bad", "title": "Agent", "status": "failed", "rawInput": ["prompt": "Invalid agent"], "rawOutput": "Unknown agent type"])]
        native.items = [row(parent.id)]; native.subagents = [parent, nested]
        parent.state = "completed"
        var replayNested = nested; replayNested.state = "completed"
        let phantom = child("bad", parent: parent.id, state: "failed")
        parent.transcript.items = [row(nested.id), row(phantom.id), TranscriptItem(kind: "assistant", text: "Provider-rendered child text")]
        replay.items = [TranscriptItem(kind: "assistant", text: "Provider-rendered root text"), row(parent.id)]
        replay.subagents = [parent, replayNested, phantom]
        var task = AgentAsyncTask(id: AsyncTaskIdentity(owner: parent.id, task: "kept-task")); task.state = .completed
        replay.asyncTasks = [task]
        replay.plan = [["content": "Keep provider plan"]]; replay.draftText = "Keep draft"
        return (native, replay)
    }
    func testExactHistoricalFamilyRestoresLifecycleAndFailedToolWithoutReplacingProviderText() {
        let (native, original) = fixture()
        var replay = original
        XCTAssertTrue(replay.reconcileClaudeDelegatedReplay(with: native))
        XCTAssertEqual(replay.subagents?.count, 2)
        XCTAssertEqual(replay.subagents?[0].state, "cancelled")
        XCTAssertEqual(replay.subagents?[1].state, "disconnected")
        XCTAssertEqual(replay.items.first?.text, "Provider-rendered root text")
        XCTAssertEqual(replay.subagents?[0].transcript.items.last?.text, "Provider-rendered child text")
        let failed = replay.subagents?[0].transcript.items.first { $0.kind == "tool" }
        XCTAssertEqual(failed?.tool["status"], "failed")
        XCTAssertEqual(failed?.tool["rawInput"]["prompt"], "Invalid agent")
        XCTAssertEqual(failed?.tool["rawOutput"], "Unknown agent type")
        XCTAssertEqual(replay.plan, original.plan); XCTAssertEqual(replay.draftText, original.draftText)
        XCTAssertEqual(replay.asyncTasks?.first?.id, original.asyncTasks?.first?.id)
        XCTAssertTrue(replay.subagents?.allSatisfy { $0.capabilities == [:] } == true)
        XCTAssertEqual(native.subagents?.count, 2, "Source family stays untouched")
    }
    func testUnsafeOrIncompleteFamilyIsAnAtomicNoOp() throws {
        for variant in 0..<16 {
            var (native, replay) = fixture()
            switch variant {
            case 0: native.remoteID = UUID().uuidString
            case 1: replay.subagents?[0].capabilities = ["prompt": [:]]
            case 2: replay.subagents?[0].state = "running"
            case 3: replay.subagents?[1].parentID = root
            case 4: replay.subagents?.remove(at: 1)
            case 5: let duplicate = replay.subagents![0]; replay.subagents?.append(duplicate)
            case 6: let duplicate = native.subagents![0]; native.subagents?.append(duplicate)
            case 7: native.subagents?[0].state = "pending"
            case 8: replay.subagents?[2].transcript.items.append(TranscriptItem(kind: "assistant", text: "Actual unknown child"))
            case 9: native.subagents?[0].transcript.items[1].tool["status"] = "completed"
            case 10: replay.items.removeAll { $0.kind == "subagent" }
            case 11: replay.items.append(replay.items[1])
            case 12: replay.subagents?[2].id = root + ":unknown:bad"
            case 13: replay.asyncTasks?[0].id = AsyncTaskIdentity(owner: replay.subagents![2].id, task: "phantom-owned-task")
            case 14: replay.asyncTasks?[0].state = .running
            default: replay.asyncTasks?[0].canStop = true
            }
            let original = try JSONEncoder().encode(replay)
            XCTAssertFalse(replay.reconcileClaudeDelegatedReplay(with: native), "Variant \(variant)")
            let after = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(replay))
            let before = try JSONDecoder().decode(JSONValue.self, from: original)
            XCTAssertTrue(after == before, "Variant \(variant) must not partially change history")
        }
    }
    func testOnlyFailedLaunchesCanRestoreWithoutAnyActualChildren() {
        var native = SessionTranscript(remoteID: root), replay = SessionTranscript(remoteID: root)
        var phantom = SubagentSession(id: root + ":replay-subagent:bad", parentID: root); phantom.state = "failed"
        native.items = [TranscriptItem(kind: "tool", tool: ["toolCallId": "bad", "title": "Task", "status": "failed", "rawOutput": "Launch rejected"])]
        replay.subagents = [phantom]; replay.items = [TranscriptItem(kind: "subagent", tool: ["subagentSessionId": .string(phantom.id)])]
        XCTAssertTrue(replay.reconcileClaudeDelegatedReplay(with: native))
        XCTAssertNil(replay.subagents)
        XCTAssertEqual(replay.items.first?.tool["rawOutput"], "Launch rejected")
    }
}
