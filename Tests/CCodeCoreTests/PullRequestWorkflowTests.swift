import XCTest
import CCodeCore
@testable import CCode

final class PullRequestWorkflowTests: XCTestCase, @unchecked Sendable {
    @MainActor private func setup() async throws -> (AppStore, ChatSession, PullRequestTests.Fixture) {
        let f = try await PullRequestTests.Fixture.make()
        let store = AppStore(directory: f.dir.appendingPathComponent("data"), claudeDirectory: f.dir.appendingPathComponent("no-claude"))
        store.settings.executable = "/usr/bin/false"; store.settings.arguments = []
        store.pullRequests = f.service
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: f.dir) }
        await store.create(path: f.root.path, worktree: false)
        return (store, try XCTUnwrap(store.selected), f)
    }
    // Catches publishing before an operation receipt is saved, or losing draft/history across PR work.
    @MainActor func testCreatePersistsIdentityAndPreservesComposerAndEditorDrafts() async throws {
        let (store, chat, f) = try await setup()
        chat.draft = "unsent composer"; chat.fileDrafts["file.txt"] = FileDraft(original: "feature\n", text: "unsaved editor\n")
        let preview = try await store.preparePullRequest(chat, remote: "origin", base: "main", title: "Owned", body: "Exact\nbody")
        try await store.createPullRequest(chat, preview: preview, push: false)
        XCTAssertEqual(chat.transcript.pullRequest?.number, 41)
        XCTAssertEqual(chat.transcript.pullRequestOperation?.state, .completed)
        let saved = try await store.storage.load(chat.id)
        XCTAssertEqual(saved.pullRequest?.repository.branch, "feature/owned")
        XCTAssertEqual(saved.draftText, "unsent composer"); XCTAssertEqual(saved.editorDrafts?["file.txt"]?.text, "unsaved editor\n")
        XCTAssertEqual(chat.draft, "unsent composer")
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("file.txt"), encoding: .utf8), "feature\n")
    }
    @MainActor func testPersistenceFailurePreventsCreatingExternalPR() async throws {
        let (store, chat, f) = try await setup()
        let preview = try await store.preparePullRequest(chat, remote: "origin", base: "main", title: "Owned", body: "Body")
        let path = (await store.storage.directory).appendingPathComponent("\(chat.id).json")
        try FileManager.default.removeItem(at: path); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        do { try await store.createPullRequest(chat, preview: preview, push: false); XCTFail("External creation before durability") } catch {}
        XCTAssertFalse(try f.audit().contains { $0.prefix(2) == ["pr", "create"] })
        XCTAssertNil(chat.transcript.pullRequestOperation); XCTAssertEqual(chat.workspaceWrites, 0)
        try FileManager.default.removeItem(at: path)
    }
    // A queued fix must use actual logs and validate the exact PR head at delivery, not whatever is browsed later.
    @MainActor func testCIFixUsesDurableDeliveryAndRejectsChangedHeadWithoutLosingDraft() async throws {
        let (store, chat, f) = try await setup()
        let preview = try await store.preparePullRequest(chat, remote: "origin", base: "main", title: "Owned", body: "Body")
        try await store.createPullRequest(chat, preview: preview, push: false)
        try f.mode("failed")
        chat.draft = "keep draft"
        let id = try await store.fixPullRequestCI(chat)
        let saved = try await store.storage.load(chat.id), prompt = try XCTUnwrap(saved.pendingPrompts?.first { $0.id == id })
        XCTAssertTrue(prompt.text.contains("AssertionError: expected 43")); XCTAssertNotNil(prompt.pullRequestContext)
        XCTAssertTrue(prompt.text.contains(preview.repository.headSHA)); XCTAssertEqual(saved.draftText, "keep draft")
        try f.mode("changed-head")
        do { try await store.validatePullRequestFixPrompt(chat, id: id, text: prompt.text); XCTFail("Stale CI fix delivered") } catch {}
        XCTAssertEqual(chat.draft, "keep draft")
    }
    @MainActor func testMonitoringStopsOnTerminalStateAndDisconnectReapsWatcher() async throws {
        let (store, chat, f) = try await setup()
        let preview = try await store.preparePullRequest(chat, remote: "origin", base: "main", title: "Owned", body: "Body")
        try await store.createPullRequest(chat, preview: preview, push: false)
        try f.mode("merged")
        try store.startPullRequestMonitoring(chat, interval: .milliseconds(10), maximumPolls: 2)
        await chat.pullRequestMonitor?.value
        XCTAssertEqual(chat.transcript.pullRequest?.state, .merged); XCTAssertNil(chat.pullRequestMonitor)
        try f.mode("pending")
        try await store.refreshPullRequest(chat)
        try store.startPullRequestMonitoring(chat, interval: .seconds(30), maximumPolls: 10)
        await store.disconnect(chat)
        XCTAssertNil(chat.pullRequestMonitor)
    }
    @MainActor func testPRPreviewModalOwnsComposerShortcutAndEscapeDuringMutation() async throws {
        let (store, chat, _) = try await setup()
        let request = PullRequestDraftRequest(chat: chat)
        store.pullRequestDraftRequest = request
        chat.draft = "Should remain unsent"
        XCTAssertFalse(store.canSendPromptCommand)
        store.send(chat)
        XCTAssertTrue(chat.pendingPrompts.isEmpty); XCTAssertNil(chat.promptTask); XCTAssertEqual(chat.draft, "Should remain unsent")
        request.applying = true; store.closePullRequestDraft()
        XCTAssertNotNil(store.pullRequestDraftRequest)
        request.applying = false; store.closePullRequestDraft()
        XCTAssertNil(store.pullRequestDraftRequest); XCTAssertTrue(store.canSendPromptCommand)
        store.pullRequestLogsRequest = PullRequestLogsRequest(text: "Log")
        XCTAssertFalse(store.canSendPromptCommand)
        store.pullRequestLogsRequest = nil
        let preview = try await store.preparePullRequest(chat, remote: "origin", base: "main", title: "Owned", body: "Body")
        try await store.createPullRequest(chat, preview: preview, push: false)
        let merge = PullRequestMergeRequest(chat: chat, pullRequest: try XCTUnwrap(chat.transcript.pullRequest))
        store.pullRequestMergeRequest = merge
        XCTAssertFalse(store.canSendPromptCommand)
        merge.applying = true; store.closePullRequestMerge(); XCTAssertNotNil(store.pullRequestMergeRequest)
        merge.applying = false; store.closePullRequestMerge(); XCTAssertNil(store.pullRequestMergeRequest)
    }
    @MainActor func testAutoFixPolicyQueuesThisHeadOnceAndDoesNotPublishOrMerge() async throws {
        let (store, chat, f) = try await setup()
        let preview = try await store.preparePullRequest(chat, remote: "origin", base: "main", title: "Owned", body: "Body")
        try await store.createPullRequest(chat, preview: preview, push: false)
        try await store.setPullRequestAutoFix(chat, enabled: true)
        try f.mode("failed")
        try store.startPullRequestMonitoring(chat, interval: .milliseconds(10), maximumPolls: 2)
        await chat.pullRequestMonitor?.value
        let saved = try await store.storage.load(chat.id)
        XCTAssertNotNil(saved.pullRequestAutoFix?.submittedPromptID)
        XCTAssertEqual(saved.pendingPrompts?.filter { $0.pullRequestContext != nil }.count, 1)
        XCTAssertFalse(try f.audit().contains { $0.prefix(2) == ["pr", "merge"] })
        XCTAssertEqual(try f.audit().filter { $0.prefix(2) == ["pr", "create"] }.count, 1)
    }
    @MainActor func testStopDuringUnsettledCreationRetainsUncertainReceiptAndReapsCLI() async throws {
        let (store, chat, f) = try await setup()
        let preview = try await store.preparePullRequest(chat, remote: "origin", base: "main", title: "Owned", body: "Body")
        try f.mode("create-hang")
        let task = Task { try await store.createPullRequest(chat, preview: preview, push: false) }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: f.dir.appendingPathComponent("pid").path) { break }; try await Task.sleep(for: .milliseconds(20)) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: f.dir.appendingPathComponent("pid"), encoding: .utf8)))
        store.stop(chat)
        do { try await task.value; XCTFail("Stopped creation returned success") } catch {}
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(chat.workspaceWrites, 0)
        XCTAssertEqual(chat.transcript.pullRequestOperation?.state, .uncertain)
        let saved = try await store.storage.load(chat.id)
        XCTAssertEqual(saved.pullRequestOperation?.state, .uncertain)
        XCTAssertEqual(try f.audit().filter { $0.prefix(2) == ["pr", "create"] }.count, 1)
    }
    @MainActor func testRestartMarksUnsettledWriteUncertainWithoutReplayingIt() async throws {
        let (store, chat, f) = try await setup()
        let preview = try await store.preparePullRequest(chat, remote: "origin", base: "main", title: "Owned", body: "Body")
        var transcript = chat.transcript
        transcript.pullRequestOperation = PullRequestOperation(repository: preview.repository, kind: .create)
        let restored = try ChatSession(id: UUID(), path: f.root.path, transcript: transcript)
        XCTAssertEqual(restored.transcript.pullRequestOperation?.state, .uncertain)
        XCTAssertNil(restored.workspaceActionTask)
        XCTAssertFalse(try f.audit().contains { $0.prefix(2) == ["pr", "create"] })
    }
}
