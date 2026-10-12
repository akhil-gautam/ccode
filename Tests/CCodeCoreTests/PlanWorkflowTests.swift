import XCTest
import Foundation
import CCodeCore
import SwiftUI
import AppKit
@testable import CCode

final class PlanWorkflowTests: XCTestCase, @unchecked Sendable {
    @MainActor private func setup() async throws -> (AppStore, ChatSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-plan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "plan", withExtension: "py", subdirectory: "Fixtures")!.path]
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        return (store, chat, root)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Expected plan state did not arrive")
    }
    @MainActor func testPlanRevisionPreservesDraftContextAndRequiresFreshApprovalBeforeWrite() async throws {
        let (store, chat, root) = try await setup()
        store.send(chat, text: "Plan the implementation first")
        try await wait { chat.approvals.first?.request["toolCall"]["name"] == "EnterPlanMode" }
        store.resolveApproval(chat, id: try XCTUnwrap(chat.approvals.first).id, option: "opaque-accept:enter")
        try await wait { chat.approvals.first?.toolCall["rawInput"]["plan"].string.contains("JSON") == true }
        let attachment = root.appendingPathComponent("draft-context.txt")
        try "Unrelated draft context".write(to: attachment, atomically: true, encoding: .utf8)
        store.attach(attachment, to: chat)
        try await wait { !chat.attachingFiles }
        let snapshots = chat.attachments
        chat.draft = "My unrelated draft"
        let approval = try XCTUnwrap(chat.approvals.first)
        await store.revisePlan(chat, id: approval.id, feedback: "Use SQLite instead of JSON")
        try await wait { chat.approvals.first?.toolCall["rawInput"]["plan"].string.contains("SQLite") == true }
        XCTAssertEqual(chat.draft, "My unrelated draft")
        XCTAssertEqual(chat.attachments, snapshots)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("plan-result.txt").path))
        let wire = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertEqual(wire["prompts"].array.count, 2)
        XCTAssertEqual(wire["prompts"].array.last?["prompt"].array, [["type": "text", "text": "Use SQLite instead of JSON"]])
        XCTAssertEqual(wire["choices"].array.last?["outcome"]["optionId"], "opaque-reject:exit-original")
        store.resolveApproval(chat, id: try XCTUnwrap(chat.approvals.first).id, option: "opaque-accept:exit-revised")
        try await wait { !chat.busy }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("plan-result.txt"), encoding: .utf8), "sqlite")
    }
    @MainActor func testInvalidFeedbackAndFullQueueLeavePlanDecisionAvailable() async throws {
        let (store, chat, _) = try await setup()
        store.send(chat, text: "Plan first")
        try await wait { !chat.approvals.isEmpty }
        store.resolveApproval(chat, id: try XCTUnwrap(chat.approvals.first).id, option: "opaque-accept:enter")
        try await wait { chat.approvals.first?.toolCall["rawInput"]["plan"].string.isEmpty == false }
        let id = try XCTUnwrap(chat.approvals.first).id
        await store.revisePlan(chat, id: id, feedback: "   ")
        XCTAssertEqual(chat.approvals.first?.id, id)
        XCTAssertNotNil(chat.approvals.first?.error)
        for index in 0..<15 { store.enqueuePrompt(chat, text: "queued \(index)", policy: .nextTurn) }
        await store.revisePlan(chat, id: id, feedback: "Use SQLite")
        XCTAssertEqual(chat.approvals.first?.id, id)
        XCTAssertEqual(chat.pendingPrompts.count, 16)
        XCTAssertFalse(chat.pendingPrompts.contains { $0.text == "Use SQLite" })
        store.stop(chat)
        try await wait { !chat.busy }
        await store.revisePlan(chat, id: id, feedback: "Stale feedback")
        XCTAssertFalse(chat.pendingPrompts.contains { $0.text == "Stale feedback" })
    }
    @MainActor func testStoppedPlanToolPersistsInterruptionWithoutInventingProviderFailure() async throws {
        let (store, chat, root) = try await setup()
        store.send(chat, text: "Plan first")
        try await wait { !chat.approvals.isEmpty }
        store.resolveApproval(chat, id: try XCTUnwrap(chat.approvals.first).id, option: "opaque-accept:enter")
        try await wait { chat.approvals.first?.toolCall["name"] == "ExitPlanMode" }
        let pendingID = try XCTUnwrap(chat.approvals.first).toolCall["toolCallId"]
        chat.draft = "Preserve my unrelated draft"
        store.stop(chat)
        try await wait { !chat.busy }
        let item = try XCTUnwrap(chat.transcript.items.first { $0.kind == "tool" && $0.tool["toolCallId"] == pendingID })
        let encoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(encoded["toolInterruption"], "stopped", "A cancelled turn must not leave its uncompleted tool spinning forever")
        XCTAssertEqual(item.tool["status"], "pending", "Preserve the last provider status; cancellation is a separate client observation")
        XCTAssertEqual(chat.draft, "Preserve my unrelated draft")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("plan-result.txt").path))
        await store.save(chat)
        let restored = try await store.storage.load(chat.id)
        let saved = try XCTUnwrap(restored.items.first { $0.id == item.id })
        let persisted = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(persisted["toolInterruption"], "stopped")
    }
    @MainActor func testDisconnectAndRestartMarkUnfinishedToolsWithoutChangingCompletedOnes() async throws {
        let (store, chat, root) = try await setup()
        chat.transcript.items = [
            TranscriptItem(kind: "tool", tool: ["toolCallId": "waiting", "title": "Bash", "status": "in_progress"]),
            TranscriptItem(kind: "tool", tool: ["toolCallId": "done", "title": "Read", "status": "completed"])
        ]
        chat.draft = "Keep this draft"
        await store.disconnect(chat)
        let disconnected = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(chat.transcript.items[0]))
        XCTAssertEqual(disconnected["toolInterruption"], "disconnected")
        let completed = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(chat.transcript.items[1]))
        XCTAssertTrue(completed["toolInterruption"].isNull)
        XCTAssertEqual(chat.transcript.items[1].tool["status"], "completed")
        var old = SessionTranscript(remoteID: "old")
        old.items = [TranscriptItem(kind: "tool", tool: ["toolCallId": "old", "status": "pending"])]
        old.draftText = "Legacy draft"
        let reopened = try ChatSession(id: UUID(), path: root.path, transcript: old)
        let interrupted = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(reopened.transcript.items[0]))
        XCTAssertEqual(interrupted["toolInterruption"], "interrupted")
        XCTAssertEqual(reopened.draft, "Legacy draft")
    }
    @MainActor func testSimultaneousPermissionsResolveIndependentlyAndExactlyOnce() async throws {
        let (store, chat, _) = try await setup()
        store.send(chat, text: "simultaneous approvals")
        try await wait { chat.approvals.count == 2 }
        let first = chat.approvals[0], second = chat.approvals[1]
        store.resolveApproval(chat, id: second.id, option: "opaque-accept:parallel-two")
        store.resolveApproval(chat, id: second.id, option: nil)
        XCTAssertEqual(chat.approvals.map(\.id), [first.id])
        store.resolveApproval(chat, id: first.id, option: nil)
        try await wait { !chat.busy }
        let wire = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertEqual(wire["choices"].array.count, 2)
        XCTAssertEqual(wire["choices"].array.last?["outcome"]["outcome"], "cancelled")
    }
    func testPermissionPreviewKeepsFullCommandsAndActualEditDiffs() {
        let command = "printf 'hello\\n'\ncat <<'EOF'\n$(literal) `literal`\nEOF\n" + String(repeating: "# context\n", count: 3000)
        let preview = PermissionPresentation(tool: ["rawInput": ["command": .string(command)]])
        XCTAssertEqual(preview.command, command)
        let edit = PermissionPresentation(tool: ["rawInput": ["file_path": "/tmp/file.swift", "old_string": "let x = 1", "new_string": "let x = 2"]])
        XCTAssertEqual(edit.diffs, [.init(path: "/tmp/file.swift", before: "let x = 1", after: "let x = 2")])
        let generic = PermissionPresentation(tool: ["kind": "switch_mode", "rawInput": ["plan": "# Plan"]])
        XCTAssertEqual(generic.plan, "# Plan")
        XCTAssertFalse(generic.canRevise, "A generic switch_mode tool does not establish Claude's reject/next-turn semantics")
    }
    func testPlanFilePreviewUsesCompletedRootWritesAndExactEdits() {
        let path = "/home/test/.claude/plans/session.md"
        let enter = TranscriptItem(kind: "tool", tool: ["name": "EnterPlanMode", "status": "completed"])
        let write = TranscriptItem(kind: "tool", tool: ["name": "Write", "status": "completed", "rawInput": ["file_path": .string(path), "content": "# Plan\nReturn json.\nTest json."]])
        let edit = TranscriptItem(kind: "tool", tool: ["name": "Edit", "status": "completed", "rawInput": ["file_path": .string(path), "old_string": "json", "new_string": "sqlite", "replace_all": true]])
        let snapshot = PermissionPresentation.planSnapshot(items: [enter, write, edit])
        XCTAssertEqual(snapshot?.path, path)
        XCTAssertEqual(snapshot?.text, "# Plan\nReturn sqlite.\nTest sqlite.")
        var ambiguous = edit
        ambiguous.tool["rawInput"]["replace_all"] = false
        XCTAssertNil(PermissionPresentation.planSnapshot(items: [enter, write, ambiguous]), "Do not present a guessed edit when its replacement is ambiguous")
        var child = write
        child.tool["_meta"] = ["claudeCode": ["parentToolUseId": "parent"]]
        XCTAssertNil(PermissionPresentation.planSnapshot(items: [enter, child]))
        var pending = write
        pending.tool["status"] = "pending"
        XCTAssertNil(PermissionPresentation.planSnapshot(items: [enter, pending]))
        let unrelated = TranscriptItem(kind: "tool", tool: ["name": "Write", "status": "completed", "rawInput": ["file_path": "/tmp/report.md", "content": "Unrelated report"]])
        XCTAssertNil(PermissionPresentation.planSnapshot(items: [enter, unrelated]))
        XCTAssertNil(PermissionPresentation.planSnapshot(items: [enter, write, enter]), "A new planning cycle must not inherit an older proposal")
    }
    @MainActor func testFeedbackSaveFailureDoesNotRejectPlanOrLoseComposer() async throws {
        let (store, chat, root) = try await setup()
        store.send(chat, text: "Plan first")
        try await wait { !chat.approvals.isEmpty }
        store.resolveApproval(chat, id: try XCTUnwrap(chat.approvals.first).id, option: "opaque-accept:enter")
        try await wait { chat.approvals.first?.toolCall["rawInput"]["plan"].string.isEmpty == false }
        let id = try XCTUnwrap(chat.approvals.first).id
        chat.draft = "Keep this draft"
        // Replace the disposable store directory with a file: real atomic persistence fails.
        let data = root.appendingPathComponent("data")
        try FileManager.default.moveItem(at: data, to: root.appendingPathComponent("data-backup"))
        // The old directory URL can retain a trailing slash after moveItem.
        let blocker = root.appendingPathComponent("data", isDirectory: false)
        try "Blocked store".write(to: blocker, atomically: true, encoding: .utf8)
        await store.revisePlan(chat, id: id, feedback: "Use SQLite")
        XCTAssertEqual(chat.approvals.first?.id, id)
        XCTAssertNotNil(chat.approvals.first?.error)
        XCTAssertFalse(chat.approvals.first?.submittingRevision ?? true)
        XCTAssertFalse(chat.revisingPlan)
        XCTAssertFalse(chat.pendingPrompts.contains { $0.text == "Use SQLite" })
        XCTAssertEqual(chat.draft, "Keep this draft")
        let wire = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertEqual(wire["choices"].array.count, 1, "Only EnterPlanMode has been approved; the unsaved revision must not reject ExitPlanMode")
    }
    @MainActor func testPausedDeliveryPreservesRevisionUntilExplicitResume() async throws {
        let (store, chat, _) = try await setup()
        store.send(chat, text: "Plan first")
        try await wait { !chat.approvals.isEmpty }
        store.resolveApproval(chat, id: try XCTUnwrap(chat.approvals.first).id, option: "opaque-accept:enter")
        try await wait { chat.approvals.first?.toolCall["rawInput"]["plan"].string.isEmpty == false }
        chat.deliveryPaused = true
        await store.revisePlan(chat, id: try XCTUnwrap(chat.approvals.first).id, feedback: "Use SQLite")
        try await wait { !chat.busy }
        XCTAssertTrue(chat.approvals.isEmpty)
        XCTAssertEqual(chat.pendingPrompts.map(\.text), ["Use SQLite"])
        let wire = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertEqual(wire["prompts"].array.count, 1)
        store.resumeQueuedPrompts(chat)
        try await wait { !chat.approvals.isEmpty }
        XCTAssertTrue(chat.approvals[0].toolCall["rawInput"]["plan"].string.contains("SQLite"))
    }
    @MainActor func testStopWhileSavingFeedbackPreservesUnsentRevisionPaused() async throws {
        let (store, chat, _) = try await setup()
        store.send(chat, text: "Plan first")
        try await wait { !chat.approvals.isEmpty }
        store.resolveApproval(chat, id: try XCTUnwrap(chat.approvals.first).id, option: "opaque-accept:enter")
        try await wait { chat.approvals.first?.toolCall["rawInput"]["plan"].string.isEmpty == false }
        let id = try XCTUnwrap(chat.approvals.first).id
        let revision = Task { await store.revisePlan(chat, id: id, feedback: "Save this revision even if I stop") }
        // Main actor work resumes while the real storage actor persists the queue.
        let deadline = ContinuousClock.now + .seconds(3)
        while !chat.revisingPlan, ContinuousClock.now < deadline { await Task.yield() }
        guard chat.revisingPlan else { await revision.value; XCTFail("Did not observe the revision save boundary"); return }
        store.stop(chat)
        await revision.value
        try await wait { !chat.busy }
        XCTAssertTrue(chat.deliveryPaused)
        XCTAssertEqual(chat.pendingPrompts.map(\.text), ["Save this revision even if I stop"])
        XCTAssertEqual(chat.pendingPrompts.first?.state, .queued)
        let wire = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertEqual(wire["prompts"].array.count, 1)
    }
    @MainActor func testPlanOptionsFitCompactAndWideCardsWithoutHorizontalButtonStack() async throws {
        let (store, chat, _) = try await setup()
        store.send(chat, text: "Plan first")
        try await wait { !chat.approvals.isEmpty }
        let actual = try XCTUnwrap(chat.approvals.first)
        var request = actual.request
        request["toolCall"]["rawInput"] = ["plan": .string("# Plan\n\n" + String(repeating: "A detailed implementation step.\n", count: 900))]
        request["options"] = .array((0..<7).map { ["optionId": .string("opaque-\($0)"), "name": .string("Yes, clear the context and allow edits with the advertised permission mode \($0)"), "kind": "allow_once"] })
        let approval = Approval(id: actual.id, request: request, continuation: actual.continuation)
        for scheme in [ColorScheme.light, .dark] {
            for width: CGFloat in [320, 820] {
                let host = NSHostingView(rootView: PermissionCard(chat: chat, store: store, approval: approval).frame(width: width).environment(\.colorScheme, scheme))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 500)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
                XCTAssertGreaterThan(host.fittingSize.height, 100)
                XCTAssertLessThan(host.fittingSize.height, 420)
            }
        }
    }
    @MainActor func testUnofferedPermissionChoiceDoesNotConsumeTheActualRequest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-plan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path]
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        store.send(chat, text: "Inspect project")
        let deadline = ContinuousClock.now + .seconds(4)
        while chat.approvals.isEmpty && chat.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let approval = try XCTUnwrap(chat.approvals.first)
        store.resolveApproval(chat, id: approval.id, option: "stale-unoffered-option")
        XCTAssertEqual(chat.approvals.count, 1, "An invalid selection must leave the real choice available")
        XCTAssertNotNil(chat.approvals.first?.error, "Validation feedback belongs to the pending permission card")
        XCTAssertTrue(chat.busy)
        store.resolveApproval(chat, id: approval.id, option: "allow")
        store.resolveApproval(chat, id: approval.id, option: "deny")
        while chat.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(chat.state, .ready)
        XCTAssertNil(chat.lastError, "A corrected permission choice must not leave an unrelated chat failure")
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "assistant" && $0.text.contains("approved") })
    }
}
