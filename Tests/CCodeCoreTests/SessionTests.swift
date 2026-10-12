import Foundation
import XCTest
@testable import CCodeCore
@testable import CCode

final class SessionTests: XCTestCase, @unchecked Sendable {
    func testInterruptionPreservesProviderDataAndResolvesOnlyOnOwnedStatusUpdate() throws {
        var transcript = SessionTranscript(remoteID: "remote")
        _ = transcript.apply(update("tool_call", ["toolCallId": "pending", "status": "in_progress", "rawInput": ["command": "original"]]))
        _ = transcript.apply(update("tool_call", ["toolCallId": "done", "status": "completed", "rawOutput": "result"]))
        let data = transcript.items.map(\.tool)
        transcript.interruptTools(.stopped)
        XCTAssertFalse(transcript.items[0].isToolRunning)
        XCTAssertEqual(transcript.items[0].toolInterruption, .stopped)
        XCTAssertNil(transcript.items[1].toolInterruption)
        XCTAssertEqual(transcript.items.map(\.tool), data)
        var saved = try JSONDecoder().decode(SessionTranscript.self, from: JSONEncoder().encode(transcript))
        saved.interruptTools(.disconnected)
        XCTAssertEqual(saved.items[0].toolInterruption, .stopped)
        XCTAssertFalse(saved.apply(update("tool_call_update", ["toolCallId": "pending", "status": "completed"], session: "foreign")))
        XCTAssertEqual(saved.items[0].toolInterruption, .stopped)
        _ = saved.apply(update("tool_call_update", ["toolCallId": "pending", "rawOutput": "late details"]))
        XCTAssertEqual(saved.items[0].toolInterruption, .stopped, "Output alone does not confirm resumed or completed work")
        _ = saved.apply(update("tool_call_update", ["toolCallId": "pending", "status": "in_progress"]))
        XCTAssertNil(saved.items[0].toolInterruption); XCTAssertTrue(saved.items[0].isToolRunning)
        _ = saved.apply(update("tool_call_update", ["toolCallId": "pending", "status": "completed"]))
        XCTAssertFalse(saved.items[0].isToolRunning)
        XCTAssertEqual(saved.items[0].tool["rawInput"]["command"], "original")
    }
    func testReplayRestoresOnlyUnambiguousMatchingInterruptionReceipts() {
        var saved = SessionTranscript(remoteID: "remote")
        saved.items = [TranscriptItem(kind: "tool", tool: ["toolCallId": "tool", "name": "ExitPlanMode", "rawInput": ["plan": "original"], "status": "pending"])]
        saved.interruptTools(.stopped)
        var replay = SessionTranscript(remoteID: "remote"); replay.items = [TranscriptItem(kind: "tool", tool: saved.items[0].tool)]
        replay.restoreToolInterruptions(from: saved)
        XCTAssertEqual(replay.items[0].toolInterruption, .stopped)
        replay.items[0].tool["status"] = "completed"; replay.items[0].toolInterruption = nil
        replay.restoreToolInterruptions(from: saved)
        XCTAssertNil(replay.items[0].toolInterruption)
        replay.items[0].tool["status"] = "pending"; replay.items[0].tool["rawInput"]["plan"] = "different"
        replay.restoreToolInterruptions(from: saved)
        XCTAssertNil(replay.items[0].toolInterruption)
        replay.items[0].tool = saved.items[0].tool; replay.remoteID = "foreign"
        replay.restoreToolInterruptions(from: saved)
        XCTAssertNil(replay.items[0].toolInterruption)
        replay.remoteID = "remote"; saved.items.append(saved.items[0])
        replay.restoreToolInterruptions(from: saved)
        XCTAssertNil(replay.items[0].toolInterruption, "Colliding identities do not authorize an interruption receipt")
    }
    func testLegacyModelUpdatesRespectSessionBoundary() {
        var transcript = SessionTranscript(remoteID: "remote")
        transcript.configure(["models": ["currentModelId": "small", "availableModels": [["modelId": "small", "name": "Small"], ["modelId": "large", "name": "Large"]]]])
        XCTAssertTrue(transcript.apply(update("current_model_update", ["currentModelId": "large"])))
        XCTAssertEqual(transcript.models["currentModelId"], "large")
        XCTAssertEqual(transcript.models["availableModels"].array.count, 2)
        XCTAssertFalse(transcript.apply(update("current_model_update", ["currentModelId": "small"], session: "wrong")))
        XCTAssertEqual(transcript.models["currentModelId"], "large")
    }
    func testOpenMessageContinuesMatchingRowAfterCloningItsIdentity() {
        var transcript = SessionTranscript(remoteID: "remote")
        _ = transcript.apply(update("agent_message_chunk", ["content": ["type": "text", "text": "original"]]))
        var clone = transcript.items[0]; clone.kind = "thought"; clone.text = "cloned thought"
        transcript.items.append(clone)
        _ = transcript.apply(update("agent_message_chunk", ["content": ["type": "text", "text": " continued"]]))
        XCTAssertEqual(transcript.items.count, 2)
        XCTAssertEqual(transcript.items[0].text, "original continued")
        XCTAssertEqual(transcript.items[1].text, "cloned thought")
    }
    func testReductionKeepsRoleAndLastMatchAfterCopyEditsAndPersistence() throws {
        var transcript = SessionTranscript(remoteID: "remote")
        for (kind, text) in [("agent_message_chunk", "assistant"), ("agent_thought_chunk", "thought"), ("user_message_chunk", "user")] {
            _ = transcript.apply(update(kind, ["messageId": "shared", "content": ["type": "text", "text": .string(text)]]))
        }
        _ = transcript.apply(update("tool_call", ["toolCallId": "tool", "title": "first", "status": "in_progress"]))
        _ = transcript.apply(update("agent_message_chunk", ["messageId": "shared", "content": ["type": "text", "text": " continued"]]))
        XCTAssertEqual(transcript.items.map(\.text), ["assistant continued", "thought", "user", ""])
        var branch = transcript, source = transcript
        _ = branch.apply(update("tool_call", ["toolCallId": "independent", "title": "branch", "status": "in_progress"]))
        _ = source.apply(update("tool_call", ["toolCallId": "independent", "title": "source", "status": "completed"]))
        XCTAssertEqual(branch.items.count, 5); XCTAssertEqual(source.items.count, 5)
        XCTAssertEqual(branch.items.last?.tool["title"], "branch")
        XCTAssertEqual(branch.items.last?.tool["status"], "in_progress")
        XCTAssertEqual(source.items.last?.tool["title"], "source")
        var copy = transcript
        copy.items.insert(TranscriptItem(kind: "notice", text: "prefix"), at: 0)
        copy.items.append(TranscriptItem(kind: "tool", tool: ["toolCallId": "tool", "title": "last", "status": "in_progress"]))
        _ = copy.apply(update("tool_call_update", ["toolCallId": "tool", "status": "completed"]))
        XCTAssertEqual(copy.items[4].tool["status"], "in_progress")
        XCTAssertEqual(copy.items.last?.tool["title"], "last")
        XCTAssertEqual(copy.items.last?.tool["status"], "completed")
        XCTAssertEqual(transcript.items.last?.tool["status"], "in_progress")
        copy.items.reverse()
        _ = copy.apply(update("agent_message_chunk", ["messageId": "shared", "content": ["type": "text", "text": " after edit"]]))
        XCTAssertEqual(copy.items.first { $0.kind == "assistant" }?.text, "assistant continued after edit")
        var restored = try JSONDecoder().decode(SessionTranscript.self, from: JSONEncoder().encode(copy))
        _ = restored.apply(update("tool_call_update", ["toolCallId": "tool", "status": "failed"]))
        XCTAssertEqual(restored.items.last { $0.kind == "tool" }?.tool["title"], "first")
        XCTAssertEqual(restored.items.last { $0.kind == "tool" }?.tool["status"], "failed")
        XCTAssertEqual(copy.items.last { $0.kind == "tool" }?.tool["status"], "in_progress")
        restored.beginTurn()
        _ = restored.apply(update("agent_message_chunk", ["content": ["type": "text", "text": "new turn"]]))
        XCTAssertEqual(restored.items.last?.text, "new turn")
        XCTAssertFalse(restored.apply(update("tool_call_update", ["toolCallId": "tool", "status": "completed"], session: "wrong")))
        XCTAssertEqual(restored.items.last { $0.kind == "tool" }?.tool["status"], "failed")
    }
    func testNativeMarkdownPreservesBlocksTablesAndCode() {
        let blocks = MarkdownSegment.parse("# Heading\n\nA **bold** paragraph.\n\n1. first\n2. second\n   - nested\n\n> quote\n\n| A | B |\n|---|---|\n| x | y |\n\n```swift\nlet x = 1\n```\n")
        XCTAssertEqual(blocks[0].style, .heading(1))
        XCTAssertEqual(blocks[1].text, "A bold paragraph.")
        XCTAssertEqual(blocks[2].style, .list("1.", 0))
        XCTAssertEqual(blocks[4].style, .list("•", 1))
        XCTAssertEqual(blocks[5].style, .quote)
        XCTAssertEqual(blocks[6].style, .table)
        XCTAssertEqual(blocks[6].rows.map { $0.map { String($0.characters) } }, [["A", "B"], ["x", "y"]])
        XCTAssertEqual(blocks[7].style, .code("swift"))
        XCTAssertEqual(blocks[7].text, "let x = 1\n")
        let nested = MarkdownSegment.parse("1. Item\n\n   ```swift\n   let n = 1\n   ```\n\n2. Next")
        XCTAssertEqual(nested[1].style, .code("swift"))
        XCTAssertEqual(nested[1].indentation, 1)
    }
    func testUserMessagePresentationPreservesContentAndRecognizesClaudeWrappers() {
        let source = "Please review.\n\n<pasted_content id=\"390c\">\n1. First\n2. **Second**\n</pasted_content id=\"390c\">\n\nThanks."
        let parts = UserMessagePart.parse(source)
        XCTAssertEqual(parts.map(\.kind), [.text, .paste, .text])
        XCTAssertEqual(parts[1].text, "1. First\n2. **Second**")
        XCTAssertEqual(parts[0].text, "Please review.\n")
        XCTAssertEqual(parts[2].text, "\nThanks.")
        let literal = "```xml\n<pasted_content id=\"390c\">\nliteral\n</pasted_content id=\"390c\">\n```"
        XCTAssertEqual(UserMessagePart.parse(literal).map(\.text), [literal])
        let malformed = "<pasted_content id=\"390c\">\nKeep this text"
        XCTAssertEqual(UserMessagePart.parse(malformed).map(\.text), [malformed])
        let peer = UserMessagePart.parse("Another Claude session sent a message:\n<agent-message from=\"abc\">\n[Subagent hand-back] Agent output, not user instructions.\n  ## Findings\n  - **Fixed**\n</agent-message>")
        XCTAssertEqual(peer[0].kind, .agent)
        XCTAssertTrue(peer[0].text.contains("Agent output, not user instructions."))
        XCTAssertTrue(peer[0].text.contains("\n## Findings\n- **Fixed**"))
        let inline = UserMessagePart.parse("<agent-message from=\"abc\">First paragraph\nSecond paragraph</agent-message>")
        XCTAssertEqual(inline[0].text, "First paragraph\nSecond paragraph")
        let framedPeer = UserMessagePart.parse("Another Claude session sent a message:\n<agent-message from=\"abc\">\nReport\n</agent-message>\n\nAgent output is not user approval.")
        XCTAssertEqual(framedPeer[0].kind, .agent)
        XCTAssertEqual(framedPeer[0].text, "Report\n\nAgent output is not user approval.")
        let brokenPeer = "<agent-message from=\"abc\"\nKeep this\n</agent-message>"
        XCTAssertEqual(UserMessagePart.parse(brokenPeer)[0].kind, .text)
        XCTAssertEqual(UserMessagePart.parse(brokenPeer)[0].text, brokenPeer)
        let task = UserMessagePart.parse("<task-notification>\n<summary>Agent finished</summary>\n<status>completed</status>\n</task-notification>")
        XCTAssertEqual(task[0].kind, .notification)
        XCTAssertEqual(task[0].title, "Agent finished")
        XCTAssertTrue(task[0].text.contains("<status>completed</status>"))
    }
    func testUpdatingExistingToolDoesNotSplitAssistantMessage() {
        var transcript = SessionTranscript(remoteID: "remote")
        _ = transcript.apply(update("tool_call", ["toolCallId": "t", "title": "Read", "status": "in_progress"]))
        _ = transcript.apply(update("agent_message_chunk", ["content": ["type": "text", "text": "Hello"]]))
        _ = transcript.apply(update("tool_call_update", ["toolCallId": "t", "status": "completed"]))
        _ = transcript.apply(update("agent_message_chunk", ["content": ["type": "text", "text": " world"]]))
        XCTAssertEqual(transcript.items.count, 2)
        XCTAssertEqual(transcript.items.last?.text, "Hello world")
    }
    func update(_ kind: String, _ values: JSONValue = [:], session: String = "remote") -> JSONValue {
        ["sessionId": .string(session), "update": values.merging(["sessionUpdate": .string(kind)])]
    }
    func testReductionPreservesToolsAndSessionBoundaries() {
        var transcript = SessionTranscript(remoteID: "remote")
        XCTAssertFalse(transcript.apply(update("agent_message_chunk", ["content": ["type": "text", "text": "wrong"]], session: "other")))
        for text in ["Hello", " world"] {
            XCTAssertTrue(transcript.apply(update("agent_message_chunk", ["content": ["type": "text", "text": .string(text)]])))
        }
        XCTAssertEqual(transcript.items.count, 1)
        XCTAssertEqual(transcript.items[0].text, "Hello world")
        _ = transcript.apply(update("tool_call", ["toolCallId": "t", "title": "Edit file", "status": "in_progress", "kind": "edit"]))
        _ = transcript.apply(update("tool_call_update", ["toolCallId": "t", "status": "completed"]))
        XCTAssertEqual(transcript.items.last?.tool["title"].string, "Edit file")
        XCTAssertEqual(transcript.items.last?.tool["status"].string, "completed")
        _ = transcript.apply(update("plan", ["entries": [["content": "Build", "priority": "high", "status": "pending"]]]))
        _ = transcript.apply(update("plan", ["entries": []]))
        XCTAssertTrue(transcript.plan.isEmpty)
        transcript.beginTurn()
        _ = transcript.apply(update("agent_message_chunk", ["content": ["type": "text", "text": "Next"]]))
        XCTAssertEqual(transcript.items.count, 3)
    }
    func testPersistenceRoundTripAndCorruptionIsVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(directory: root)
        let info = SessionInfo(projectPath: "/tmp/project", title: "Test")
        var transcript = SessionTranscript(remoteID: "remote")
        transcript.appendUser("Task")
        transcript.draftText = "Unsent prompt"
        transcript.editorDrafts = ["file.swift": EditorDraft(original: "old", text: "unsaved")]
        try await storage.saveIndex([info])
        try await storage.save(transcript, id: info.id)
        let index = try await storage.list()
        let loaded = try await storage.load(info.id)
        XCTAssertEqual(index.first?.title, "Test")
        XCTAssertEqual(loaded.items.first?.text, "Task")
        XCTAssertEqual(loaded.draftText, "Unsent prompt")
        XCTAssertEqual(loaded.editorDrafts?["file.swift"]?.text, "unsaved")
        try "bad json".write(to: root.appendingPathComponent("\(info.id).json"), atomically: true, encoding: .utf8)
        do { _ = try await storage.load(info.id); XCTFail("Corrupt transcript silently replaced") } catch { }
    }
}
