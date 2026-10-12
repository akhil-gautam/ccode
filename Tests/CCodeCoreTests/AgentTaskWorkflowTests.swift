import XCTest
import SwiftUI
import AppKit
import CCodeCore
@testable import CCode

final class AgentTaskWorkflowTests: XCTestCase, @unchecked Sendable {
    @MainActor func testWorkingChildProtectsItsCheckoutFromBranchSwitch() async throws {
        let (store, chat) = try await setup()
        let path = chat.workspace.root
        _ = try await Repository.run(["init", "-b", "main"], at: path)
        _ = try await Repository.run(["-c", "user.name=ccode fixture", "-c", "user.email=fixture@example.com", "commit", "--allow-empty", "-m", "Seed"], at: path)
        _ = try await Repository.run(["branch", "alternate"], at: path)
        store.send(chat, text: "Start children"); try await finish(store, chat)
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/start-background", params: [:])
        let result = await store.create(path: path, worktree: false, branch: "alternate")
        XCTAssertNil(result, "A child may still be editing this checkout")
        let branch = try await Repository.run(["symbolic-ref", "--short", "HEAD"], at: path)
        XCTAssertEqual(branch.trimmingCharacters(in: .newlines), "main")
        XCTAssertTrue(chat.connection === peer)
    }
    @MainActor func testWorkingChildCannotForkUntilItsActualCompletion() async throws {
        let (store, chat) = try await setup()
        store.send(chat, text: "Start children"); try await finish(store, chat)
        chat.handshake["agentCapabilities"]["sessionCapabilities"] = ["fork": [:], "resume": [:]]
        XCTAssertTrue(store.canFork(chat))
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/start-background", params: [:])
        XCTAssertFalse(store.canFork(chat))
        do { _ = try await store.fork(chat); XCTFail("Cannot fork an unfinished independent child timeline") }
        catch { XCTAssertTrue(error.localizedDescription.contains("finish")) }
        _ = try await peer.request("fixture/background-finished", params: [:])
        XCTAssertTrue(store.canFork(chat))
    }
    @MainActor func testImportedHistoryRefreshDoesNotDisconnectAWorkingChild() async throws {
        let (store, chat) = try await setup()
        store.send(chat, text: "Start children"); try await finish(store, chat)
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/start-background", params: [:])
        let index = try XCTUnwrap(store.sessions.firstIndex { $0.id == chat.id })
        store.sessions[index].importedFromAgent = true
        chat.transcript.historyUpdatedAt = nil
        await store.select(chat.id)
        XCTAssertTrue(chat.connection === peer, "Opening live history must not replace its working connection")
        XCTAssertEqual(chat.transcript.subagent("background")?.state, "running")
        _ = try await peer.request("fixture/background-finished", params: [:])
        XCTAssertEqual(chat.transcript.subagent("background")?.state, "completed")
    }
    @MainActor func testIdleChildQuestionGetsAttentionAndSurvivesNavigation() async throws {
        let (store, chat) = try await setup()
        store.send(chat, text: "Start children"); try await finish(store, chat)
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/idle-question", params: [:])
        try await wait { chat.interactions.count == 1 }
        XCTAssertTrue(store.attentionSessions.contains { $0.id == chat.id })
        await store.openHome()
        XCTAssertTrue(chat.connection === peer)
        let question = try XCTUnwrap(chat.interactions.first)
        try store.resolveInteraction(chat, id: question.id, action: .accept, content: ["answer": "Keep the child alive"])
        let deadline = ContinuousClock.now + .seconds(5)
        var answers: [JSONValue] = []
        repeat {
            let result = try await peer.request("fixture/state", params: [:])
            answers = result["replies"].array.filter { $0["id"] == "question-idle" }
            if answers.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        } while answers.isEmpty && ContinuousClock.now < deadline
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?["result"]["content"]["answer"], "Keep the child alive")
    }
    @MainActor func testSwitchingAwayRetainsLiveChildThenEvictsAfterActualCompletion() async throws {
        let (store, chat) = try await setup()
        store.send(chat, text: "Start children"); try await finish(store, chat)
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/start-background", params: [:])
        XCTAssertFalse(chat.busy, "Main chat may accept another prompt while the child works")
        await store.openHome()
        XCTAssertTrue(chat.connection === peer, "Switching away must not kill background work")
        _ = try await peer.request("fixture/background-finished", params: [:])
        XCTAssertEqual(chat.transcript.subagent("background")?.state, "completed")
        await store.openHome()
        XCTAssertNil(chat.connection, "An actually idle peer can be released after saving")
    }
    @MainActor func testNavigationSelectsOnlyChildrenOfTheVisibleChatAndPaneFits() async throws {
        let (store, chat) = try await setup()
        store.send(chat, text: "Start children"); try await finish(store, chat)
        store.openSubagent(chat, id: "left")
        XCTAssertEqual(chat.selectedSubagentID, "left"); XCTAssertEqual(store.pane, "tasks")
        store.openSubagent(chat, id: "foreign")
        XCTAssertEqual(chat.selectedSubagentID, "left")
        for width in [CGFloat(320), 640] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let host = NSHostingView(rootView: TasksPane(chat: chat, store: store))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 640)
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 2)
            }
        }
        store.selectedID = nil; store.pane = nil
        store.openSubagent(chat, id: "right")
        XCTAssertNil(store.pane); XCTAssertEqual(chat.selectedSubagentID, "left")
    }
    @MainActor private func setup() async throws -> (AppStore, ChatSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-child-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "subagents", withExtension: "py", subdirectory: "Fixtures")!.path]
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        return (store, chat)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Child workflow state did not arrive")
    }
    @MainActor private func finish(_ store: AppStore, _ chat: ChatSession) async throws {
        try await wait { chat.approvals.count == 2 && chat.interactions.count == 1 || chat.state == .failed }
        XCTAssertEqual(chat.approvals.count, 2)
        for approval in chat.approvals {
            let owner = approval.request["sessionId"].string
            XCTAssertEqual(approval.toolCall["rawInput"]["command"], .string("printf " + owner))
            store.resolveApproval(chat, id: approval.id, option: "allow-" + owner)
        }
        let question = try XCTUnwrap(chat.interactions.first)
        XCTAssertEqual(question.request.sessionID, "nested")
        try store.resolveInteraction(chat, id: question.id, action: .accept, content: ["answer": "Use child context"])
        try await wait { !chat.busy }
    }
    @MainActor func testChildPermissionsQuestionsAndIdenticalToolIDsHaveActualOwners() async throws {
        let (store, chat) = try await setup()
        store.send(chat, text: "Start children")
        try await finish(store, chat)
        let result = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertEqual(result["capabilities"]["subagents"], [:])
        XCTAssertEqual(result["replies"].array.count, 3)
        XCTAssertTrue(result["replies"].array.allSatisfy { $0["error"].isNull })
        XCTAssertEqual(chat.transcript.subagent("left")?.state, "completed")
        XCTAssertEqual(chat.transcript.subagent("right")?.state, "failed")
        XCTAssertEqual(chat.transcript.subagent("nested")?.parentID, "left")
        XCTAssertTrue(chat.transcript.subagent("nested")?.transcript.items.contains { $0.kind == "interaction" && $0.tool["content"]["answer"] == "Use child context" } == true)
        XCTAssertFalse(chat.transcript.items.contains { $0.kind == "interaction" })
        XCTAssertEqual(chat.transcript.items.first(where: { $0.kind == "tool" })?.tool["title"], "work-root")
    }
    @MainActor func testChildOutputAfterMainIdleAndUnknownCallbacksRemainScoped() async throws {
        let (store, chat) = try await setup()
        store.send(chat, text: "Start children"); try await finish(store, chat)
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/late-child", params: [:])
        try await wait { chat.transcript.subagent("left")?.transcript.items.last?.text.contains("main idle") == true }
        XCTAssertFalse(chat.busy)
        _ = try await peer.request("fixture/unknown", params: [:])
        XCTAssertTrue(chat.approvals.isEmpty)
        // Callback replies run independently from fixture/state requests. An
        // empty approval list does not prove the asynchronous rejection arrived.
        var result = try await peer.request("fixture/state", params: [:])
        let deadline = ContinuousClock.now + .seconds(5)
        while !result["replies"].array.contains(where: { $0["id"] == "unknown-permission" }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            result = try await peer.request("fixture/state", params: [:])
        }
        XCTAssertEqual(result["replies"].array.first { $0["id"] == "unknown-permission" }?["error"]["code"], -32603)
        XCTAssertFalse(chat.transcript.items.contains { $0.text.contains("Never render") })
        XCTAssertNil(chat.transcript.subagent("foreign"))
    }
    @MainActor func testStopCancelsIndependentChildDecisionsAndNeverAnswersTwice() async throws {
        let (store, chat) = try await setup()
        store.send(chat, text: "Start children")
        try await wait { chat.approvals.count == 2 && chat.interactions.count == 1 || chat.state == .failed }
        XCTAssertEqual(chat.approvals.count, 2)
        store.stop(chat); try await wait { !chat.busy }
        XCTAssertTrue(chat.approvals.isEmpty); XCTAssertTrue(chat.interactions.isEmpty)
        let result = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertEqual(result["replies"].array.count, 3)
        XCTAssertTrue(result["replies"].array.allSatisfy { $0["error"].isNull })
    }
    @MainActor func testLoadReplayReplacesChildChunksAndRetainsRootDraft() async throws {
        let (store, chat) = try await setup()
        store.send(chat, text: "Start children"); try await finish(store, chat)
        chat.draft = "Keep my draft"
        await store.disconnect(chat)
        try await store.connect(chat, reloadHistory: true)
        XCTAssertEqual(chat.draft, "Keep my draft")
        XCTAssertEqual(chat.transcript.subagents?.count, 3)
        XCTAssertEqual(chat.transcript.subagent("left")?.transcript.items.last?.text, "History of left")
        XCTAssertEqual(chat.transcript.subagent("left")?.state, "completed")
    }
    @MainActor func testChildPlanCannotQueueFeedbackIntoRootConversation() async throws {
        let (store, chat) = try await setup()
        store.send(chat, text: "Start children")
        try await wait { chat.approvals.count == 2 && chat.interactions.count == 1 }
        _ = try await XCTUnwrap(chat.connection).request("fixture/child-plan", params: [:])
        try await wait { chat.approvals.count == 3 }
        let plan = try XCTUnwrap(chat.approvals.first { $0.toolCall["name"] == "ExitPlanMode" })
        chat.handshake["agentInfo"] = ["name": "@agentclientprotocol/claude-agent-acp", "version": "0.84.0"]
        XCTAssertTrue(store.supportsMessageFork(chat))
        let before = chat.pendingPrompts
        await store.revisePlan(chat, id: plan.id, feedback: "Do not steer the parent")
        XCTAssertEqual(chat.pendingPrompts.map(\.text), before.map(\.text), chat.pendingPrompts.map(\.text).description)
        XCTAssertTrue(chat.approvals.contains { $0.id == plan.id })
    }
    @MainActor func testSelectedHistoryCannotExposeLaterChildOutputWithoutACapturedBoundary() async throws {
        let (store, chat) = try await setup()
        store.send(chat, text: "Start children"); try await finish(store, chat)
        chat.handshake["agentInfo"] = ["name": "@agentclientprotocol/claude-agent-acp", "version": "0.84.0"]
        chat.handshake["agentCapabilities"]["sessionCapabilities"] = ["fork": [:], "resume": [:]]
        chat.transcript.appendUser("Follow-up", startedSession: false)
        chat.transcript.items.append(TranscriptItem(kind: "assistant", text: "Later response", messageID: "selected-root-boundary"))
        let index = try XCTUnwrap(chat.transcript.items.lastIndex { $0.kind == "assistant" })
        chat.transcript.items[index].messageID = "selected-root-boundary"
        XCTAssertTrue(store.canFork(chat))
        XCTAssertFalse(store.canFork(chat, at: chat.transcript.items[index].id), "A root message ID does not capture the timeline of an independent child")
        XCTAssertFalse(store.canRevise(chat, at: chat.transcript.items[index].id))
    }
    @MainActor func testWholeForkRebasesArchivedChildrenAndNeverBorrowsLiveOwnership() async throws {
        let (store, chat) = try await setup()
        store.send(chat, text: "Start children"); try await finish(store, chat)
        chat.handshake["agentCapabilities"]["sessionCapabilities"] = ["fork": [:], "resume": [:]]
        let id = try await store.fork(chat)
        let fork = try XCTUnwrap(store.selected)
        XCTAssertEqual(fork.id, id)
        XCTAssertEqual(fork.transcript.subagent("left")?.parentID, fork.transcript.remoteID)
        XCTAssertEqual(fork.transcript.subagent("nested")?.parentID, "left")
        XCTAssertTrue(fork.childOwners.isEmpty)
        XCTAssertEqual(chat.transcript.subagent("left")?.parentID, "work-root")
    }
}
