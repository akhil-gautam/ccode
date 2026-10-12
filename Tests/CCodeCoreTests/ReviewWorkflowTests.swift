import XCTest
import AppKit
import SwiftUI
import CCodeCore
@testable import CCode

final class ReviewWorkflowTests: XCTestCase, @unchecked Sendable {
    private func repository(retain: Bool = false) async throws -> (URL, URL) {
        let parent = retain ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build") : FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent("ccode-review-\(UUID())")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        if !retain { addTeardownBlock { try? FileManager.default.removeItem(at: root) } }
        _ = try await Repository.run(["init", "-b", "main"], at: project.path)
        for path in ["first file 界.txt", "second.txt"] { try "before\nunchanged\n".write(to: project.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        _ = try await Repository.run(["add", "."], at: project.path)
        _ = try await Repository.run(["-c", "user.name=ccode QA", "-c", "user.email=ccode-qa@example.invalid", "commit", "-m", "Initial"], at: project.path)
        for path in ["first file 界.txt", "second.txt"] { try "after\nunchanged\n".write(to: project.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        return (root, project)
    }
    private func comment(_ project: URL, path: String, staged: Bool = false, removed: Bool? = nil, text: String) async throws -> ReviewComment {
        let diff = try await Repository.diff(at: project.path, path: path, stagedOnly: staged)
        let head = try await Repository.run(["rev-parse", "HEAD"], at: project.path).trimmingCharacters(in: .newlines)
        let line = removed.flatMap { removed in Repository.diffLines(diff).first { removed ? $0.removed : $0.added } }
        return try await ReviewComment.capture(at: project.path, path: path, diff: diff, baseRevision: head, stagedOnly: staged, line: line, text: text)
    }
    func testBatchRetainsFileAndBothLineSourcesWithExactRevisionAndLiteralFeedback() async throws {
        let (_, project) = try await repository()
        let old = try await comment(project, path: "first file 界.txt", removed: true, text: "Keep the original value")
        let file = try await comment(project, path: "second.txt", text: "Handle \"quotes\", ``` fences and\nmultiple lines")
        XCTAssertEqual(old.source, "original HEAD"); XCTAssertEqual(old.oldLine, 1); XCTAssertNil(old.newLine)
        XCTAssertEqual(old.selectedText, "-before")
        try await Repository.stage(at: project.path, path: "second.txt")
        let staged = try await comment(project, path: "second.txt", staged: true, removed: false, text: "Change the new value")
        XCTAssertEqual(staged.source, "staged index"); XCTAssertEqual(staged.newLine, 1)
        try await old.validate(at: project.path); try await file.validate(at: project.path); try await staged.validate(at: project.path)
        let prompt = try ReviewComment.prompt([old, file, staged])
        XCTAssertTrue(prompt.contains("first file 界.txt")); XCTAssertTrue(prompt.contains("original HEAD")); XCTAssertTrue(prompt.contains("staged index"))
        XCTAssertTrue(prompt.contains(old.diffSHA256)); XCTAssertTrue(prompt.contains(old.baseRevision!))
        XCTAssertTrue(prompt.contains("Keep the original value")); XCTAssertTrue(prompt.contains("Change the new value"))
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("second.txt"), encoding: .utf8), "after\nunchanged\n")
    }
    func testChangedDiffOrHeadRejectsWithoutOverwritingFilesOrLosingComment() async throws {
        let (_, project) = try await repository()
        let captured = try await comment(project, path: "second.txt", removed: false, text: "Review this change")
        try "external edit\n".write(to: project.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        do { try await captured.validate(at: project.path); XCTFail("Stale diff must be refused") } catch { }
        XCTAssertEqual(captured.text, "Review this change")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("second.txt"), encoding: .utf8), "external edit\n")
        try "after\nunchanged\n".write(to: project.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        _ = try await Repository.run(["-c", "user.name=ccode QA", "-c", "user.email=ccode-qa@example.invalid", "commit", "--allow-empty", "-m", "Changed HEAD"], at: project.path)
        do { try await captured.validate(at: project.path); XCTFail("Changed base must be refused even if diff content matches") } catch { }
    }
    func testWrongRepositoryAndInvalidLineCannotAuthorizeFeedback() async throws {
        let (_, project) = try await repository(), (_, other) = try await repository()
        let captured = try await comment(project, path: "second.txt", text: "Only this repository")
        do { try await captured.validate(at: other.path); XCTFail("Same diff in another repository is not the selected source") } catch { }
        let diff = try await Repository.diff(at: project.path, path: "second.txt")
        let head = try await Repository.run(["rev-parse", "HEAD"], at: project.path).trimmingCharacters(in: .newlines)
        let foreignLine = try XCTUnwrap(Repository.diffLines("@@ -99 +99 @@\n+foreign").last { $0.newLine != nil })
        do { _ = try await ReviewComment.capture(at: project.path, path: "second.txt", diff: diff, baseRevision: head, stagedOnly: false, line: foreignLine, text: "Invalid"); XCTFail("A line from another snapshot must be refused") } catch { }
        do { _ = try await ReviewComment.capture(at: project.path, path: "../outside", diff: diff, baseRevision: head, stagedOnly: false, line: nil, text: "Invalid"); XCTFail("Outside path") } catch { }
    }
    func testUnbornCombinedDiffUsesWorkingFileOnceAfterStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-unborn-review-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        let path = "new file 界.txt", file = root.appendingPathComponent(path)
        try "staged value\n".write(to: file, atomically: true, encoding: .utf8)
        try await Repository.stage(at: root.path, path: path)
        try "working value\n".write(to: file, atomically: true, encoding: .utf8)
        let diff = try await Repository.diff(at: root.path, path: path)
        let lines = Repository.diffLines(diff)
        XCTAssertEqual(lines.filter(\.added).map(\.text), ["+working value"])
        XCTAssertTrue(lines.filter(\.removed).isEmpty, "No committed original exists in an unborn repository")
        let line = try XCTUnwrap(lines.first { $0.text == "+working value" })
        XCTAssertEqual(line.newLine, 1)
        let captured = try await ReviewComment.capture(at: root.path, path: path, diff: diff, baseRevision: nil, stagedOnly: false, line: line, text: "Review the working value")
        XCTAssertEqual(captured.source, "working file"); try await captured.validate(at: root.path)
        let staged = try await Repository.diff(at: root.path, path: path, stagedOnly: true)
        XCTAssertEqual(Repository.diffLines(staged).filter(\.added).map(\.text), ["+staged value"])
        try FileManager.default.removeItem(at: file)
        let deleted = try await Repository.diff(at: root.path, path: path)
        XCTAssertEqual(deleted, "", "Added then deleted before the first commit has no net working change")
    }
    @MainActor private func setup() async throws -> (AppStore, ChatSession, URL, URL) {
        let (root, project) = try await repository()
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "delivery", withExtension: "py", subdirectory: "Fixtures")!.path, "--no-steering"]
        addTeardownBlock { await store.shutdown() }
        await store.create(path: project.path, worktree: false)
        let chat = try XCTUnwrap(store.selected); try await store.connect(chat)
        return (store, chat, root, project)
    }
    @MainActor func testSubmitSendsOneBatchAndPreservesComposerAttachmentsAndEditorDrafts() async throws {
        let (store, chat, root, project) = try await setup()
        let first = try await comment(project, path: "first file 界.txt", removed: false, text: "Fix the first value")
        let second = try await comment(project, path: "second.txt", text: "Fix the second value")
        chat.reviewComments = [first, second]
        chat.draft = "UNSENT_COMPOSER"
        let context = root.appendingPathComponent("draft-context.txt")
        try "UNSENT_ATTACHMENT".write(to: context, atomically: true, encoding: .utf8)
        let attachment = try await store.storage.importAttachment(context)
        chat.attachments = [attachment]
        chat.fileDrafts["second.txt"] = EditorDraft(original: "after\nunchanged\n", text: "UNSAVED_EDITOR")
        try await store.editReviewComment(chat, id: first.id, text: "REVISED_FIRST_COMMENT")
        let submitted = try await store.submitReviewComments(chat)
        XCTAssertTrue(submitted)
        let deadline = ContinuousClock.now + .seconds(5)
        while chat.busy || !chat.pendingPrompts.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(chat.busy); XCTAssertTrue(chat.pendingPrompts.isEmpty); XCTAssertTrue(chat.reviewComments.isEmpty)
        let peer = try XCTUnwrap(chat.connection), state = try await peer.request("fixture/state", params: [:])
        let prompts = state["prompts"].array
        XCTAssertEqual(prompts.count, 1); XCTAssertEqual(prompts.first?["prompt"].array.count, 1)
        let sent = prompts.first?["prompt"].array.first?["text"].string ?? ""
        XCTAssertTrue(sent.contains("REVISED_FIRST_COMMENT")); XCTAssertFalse(sent.contains("Fix the first value")); XCTAssertTrue(sent.contains("Fix the second value"))
        XCTAssertFalse(sent.contains("UNSENT_COMPOSER")); XCTAssertFalse(sent.contains("UNSENT_ATTACHMENT"))
        XCTAssertEqual(chat.draft, "UNSENT_COMPOSER"); XCTAssertEqual(chat.attachments, [attachment]); XCTAssertEqual(chat.fileDrafts["second.txt"]?.text, "UNSAVED_EDITOR")
        let again = try await store.submitReviewComments(chat)
        XCTAssertFalse(again, "An empty batch is not sent again")
        let persisted = try await store.storage.load(chat.id)
        XCTAssertTrue((persisted.reviewComments ?? []).isEmpty)
        XCTAssertEqual(persisted.draftText, "UNSENT_COMPOSER")
    }
    @MainActor func testExplicitBatchStartsAfterAnEmptyPausedQueue() async throws {
        let (store, chat, _, project) = try await setup()
        chat.reviewComments = [try await comment(project, path: "second.txt", text: "Apply this explicit feedback")]
        chat.deliveryPaused = true; chat.draft = "Keep paused draft"
        let submitted = try await store.submitReviewComments(chat); XCTAssertTrue(submitted)
        let deadline = ContinuousClock.now + .seconds(4)
        while chat.busy || !chat.pendingPrompts.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(chat.deliveryPaused); XCTAssertTrue(chat.pendingPrompts.isEmpty)
        let calls = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:]); XCTAssertEqual(calls["prompts"].array.count, 1)
        XCTAssertEqual(chat.draft, "Keep paused draft")
    }
    @MainActor func testStaleBatchRetainsAllFeedbackAndDoesNotSendAnyPrompt() async throws {
        let (store, chat, _, project) = try await setup()
        let first = try await comment(project, path: "first file 界.txt", text: "Retain first")
        let second = try await comment(project, path: "second.txt", text: "Retain second")
        chat.reviewComments = [first, second]
        try "external\n".write(to: project.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        do { _ = try await store.submitReviewComments(chat); XCTFail("Reject the whole stale batch") } catch { }
        XCTAssertEqual(chat.reviewComments, [first, second])
        let peer = try XCTUnwrap(chat.connection), state = try await peer.request("fixture/state", params: [:])
        XCTAssertTrue(state["prompts"].array.isEmpty); XCTAssertTrue(chat.pendingPrompts.isEmpty)
        XCTAssertFalse(chat.submittingReview)
    }
    @MainActor func testPendingFeedbackSurvivesSaveAndRestartWithoutSending() async throws {
        let (store, chat, root, project) = try await setup()
        let captured = try await comment(project, path: "second.txt", text: "Pending after restart")
        chat.reviewComments = [captured]; chat.draft = "Keep draft"
        await store.save(chat); await store.shutdown()
        let restored = AppStore(directory: root.appendingPathComponent("data"))
        addTeardownBlock { await restored.shutdown() }
        await restored.restore(); await restored.select(chat.id)
        let reopened = try XCTUnwrap(restored.selected)
        XCTAssertEqual(reopened.reviewComments, [captured]); XCTAssertEqual(reopened.draft, "Keep draft")
        XCTAssertNil(reopened.connection); XCTAssertTrue(reopened.pendingPrompts.isEmpty)
    }
    @MainActor func testEditingPendingFeedbackPreservesCapturedSourceAndSurvivesRestartWithoutSending() async throws {
        let (store, chat, root, project) = try await setup()
        let captured = try await comment(project, path: "second.txt", removed: true, text: "Original feedback")
        chat.reviewComments = [captured]; chat.draft = "Keep composer draft"
        // Editing the note must not silently refresh or relocate stale context.
        try "external change\n".write(to: project.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        try await store.editReviewComment(chat, id: captured.id, text: "  Revised feedback\nKeep this line  ")
        var expected = captured; expected.text = "Revised feedback\nKeep this line"
        XCTAssertEqual(chat.reviewComments, [expected]); XCTAssertEqual(chat.draft, "Keep composer draft")
        do { _ = try await store.submitReviewComments(chat); XCTFail("An edited note must still reject its stale source") } catch { }
        let peer = try XCTUnwrap(chat.connection), state = try await peer.request("fixture/state", params: [:])
        XCTAssertTrue(state["prompts"].array.isEmpty); XCTAssertTrue(chat.pendingPrompts.isEmpty)
        await store.shutdown()
        let restored = AppStore(directory: root.appendingPathComponent("data"))
        addTeardownBlock { await restored.shutdown() }
        await restored.restore(); await restored.select(chat.id)
        let reopened = try XCTUnwrap(restored.selected)
        XCTAssertEqual(reopened.reviewComments, [expected]); XCTAssertEqual(reopened.draft, "Keep composer draft")
        XCTAssertNil(reopened.connection); XCTAssertTrue(reopened.pendingPrompts.isEmpty)
    }
    @MainActor func testEditingFeedbackRejectsInvalidOrSubmittingChangesAndRollsBackFailedSave() async throws {
        let (store, chat, root, project) = try await setup()
        let captured = try await comment(project, path: "second.txt", text: "Retain original feedback")
        chat.reviewComments = [captured]
        for text in [" \n ", String(repeating: "x", count: 8193)] {
            do { try await store.editReviewComment(chat, id: captured.id, text: text); XCTFail("Invalid feedback must be refused") } catch { }
            XCTAssertEqual(chat.reviewComments, [captured])
        }
        chat.submittingReview = true
        do { try await store.editReviewComment(chat, id: captured.id, text: "Cannot race submission"); XCTFail("Submission owns its batch") } catch { }
        XCTAssertEqual(chat.reviewComments, [captured]); chat.submittingReview = false
        do { try await store.editReviewComment(chat, id: UUID(), text: "Missing comment"); XCTFail("Unknown comment must not be recreated") } catch { }
        let data = root.appendingPathComponent("data"), backup = root.appendingPathComponent("data-before-edit-failure")
        try FileManager.default.moveItem(at: data, to: backup)
        try Data("not a directory".utf8).write(to: data)
        defer { try? FileManager.default.removeItem(at: data); try? FileManager.default.moveItem(at: backup, to: data) }
        do { try await store.editReviewComment(chat, id: captured.id, text: "Unsaved new feedback"); XCTFail("Failed save must remain retryable") } catch { }
        let displayed = try await Repository.diff(at: project.path, path: "second.txt")
        do { try await store.rebindReviewComment(chat, id: captured.id, path: "second.txt", diff: displayed, baseRevision: captured.baseRevision, stagedOnly: false, line: nil); XCTFail("Failed context save must retain its original receipt") } catch { }
        XCTAssertEqual(chat.reviewComments, [captured]); XCTAssertFalse(chat.submittingReview)
        let peer = try XCTUnwrap(chat.connection), state = try await peer.request("fixture/state", params: [:])
        XCTAssertTrue(state["prompts"].array.isEmpty)
    }
    @MainActor func testRebindingStaleCommentUsesExplicitFreshSelectionAndPersistsBeforeSubmission() async throws {
        let (store, chat, _, project) = try await setup()
        let original = try await comment(project, path: "second.txt", removed: false, text: "Keep the review request")
        chat.reviewComments = [original]; chat.draft = "Keep the composer"
        try "inserted\nnew value\nunchanged\n".write(to: project.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        let fresh = try await Repository.diff(at: project.path, path: "second.txt")
        let selected = try XCTUnwrap(Repository.diffLines(fresh).first { $0.text == "+new value" })
        try await store.rebindReviewComment(chat, id: original.id, path: "second.txt", diff: fresh, baseRevision: original.baseRevision, stagedOnly: false, line: selected)
        let rebound = try XCTUnwrap(chat.reviewComments.first)
        XCTAssertNotEqual(rebound.id, original.id); XCTAssertNotEqual(rebound.diffSHA256, original.diffSHA256)
        XCTAssertEqual(rebound.path, "second.txt"); XCTAssertEqual(rebound.root, original.root)
        XCTAssertEqual(rebound.text, "Keep the review request"); XCTAssertEqual(rebound.newLine, 2)
        XCTAssertEqual(rebound.selectedText, "+new value"); XCTAssertEqual(rebound.source, "working file")
        let saved = try await store.storage.load(chat.id)
        XCTAssertEqual(saved.reviewComments, [rebound]); XCTAssertEqual(saved.draftText, "Keep the composer")
        XCTAssertTrue(chat.pendingPrompts.isEmpty)
        let didSubmit = try await store.submitReviewComments(chat); XCTAssertTrue(didSubmit)
        let deadline = ContinuousClock.now + .seconds(5)
        while chat.busy || !chat.pendingPrompts.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(chat.busy); XCTAssertTrue(chat.pendingPrompts.isEmpty)
        let peer = try XCTUnwrap(chat.connection), state = try await peer.request("fixture/state", params: [:])
        let sent = try XCTUnwrap(state["prompts"].array.first?["prompt"].array.first?["text"].optionalString)
        XCTAssertEqual(state["prompts"].array.count, 1)
        XCTAssertTrue(sent.contains("+new value")); XCTAssertTrue(sent.contains(rebound.diffSHA256)); XCTAssertFalse(sent.contains(original.diffSHA256))
        XCTAssertEqual(chat.draft, "Keep the composer")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("second.txt"), encoding: .utf8), "inserted\nnew value\nunchanged\n")
    }
    @MainActor func testRebindingRejectsForeignOrAlreadyChangedSelectionsWithoutLosingFeedback() async throws {
        let (store, chat, _, project) = try await setup()
        let original = try await comment(project, path: "second.txt", text: "Keep original")
        chat.reviewComments = [original]
        let displayed = try await Repository.diff(at: project.path, path: "second.txt")
        do { try await store.rebindReviewComment(chat, id: original.id, path: "first file 界.txt", diff: displayed, baseRevision: original.baseRevision, stagedOnly: false, line: nil); XCTFail("Another file cannot silently relocate feedback") } catch { }
        try "new external data\n".write(to: project.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        do { try await store.rebindReviewComment(chat, id: original.id, path: "second.txt", diff: displayed, baseRevision: original.baseRevision, stagedOnly: false, line: nil); XCTFail("The displayed diff must still match") } catch { }
        XCTAssertEqual(chat.reviewComments, [original]); XCTAssertFalse(chat.submittingReview)
        let peer = try XCTUnwrap(chat.connection), state = try await peer.request("fixture/state", params: [:])
        XCTAssertTrue(state["prompts"].array.isEmpty); XCTAssertTrue(chat.pendingPrompts.isEmpty)
    }
    @MainActor func testStopDuringRebindingPreservesOriginalAndDoesNotSend() async throws {
        let (store, chat, _, project) = try await setup()
        let original = try await comment(project, path: "second.txt", text: "Retain if stopped")
        chat.reviewComments = [original]
        let displayed = try await Repository.diff(at: project.path, path: "second.txt")
        let operation = Task { try await store.rebindReviewComment(chat, id: original.id, path: "second.txt", diff: displayed, baseRevision: original.baseRevision, stagedOnly: false, line: nil) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !chat.submittingReview, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(chat.submittingReview); store.stop(chat)
        do { try await operation.value; XCTFail("Stop invalidates pending context replacement") } catch { }
        XCTAssertEqual(chat.reviewComments, [original]); XCTAssertFalse(chat.submittingReview)
        let peer = try XCTUnwrap(chat.connection), state = try await peer.request("fixture/state", params: [:])
        XCTAssertTrue(state["prompts"].array.isEmpty)
    }
    @MainActor func testBusySubmissionRefusesAndRetainsCommentsUntilWorkFinishes() async throws {
        let (store, chat, _, project) = try await setup()
        let captured = try await comment(project, path: "second.txt", text: "Pending review")
        chat.reviewComments = [captured]
        store.send(chat, text: "hold existing task")
        let deadline = ContinuousClock.now + .seconds(3)
        while chat.state != .running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(chat.state, .running)
        do { _ = try await store.submitReviewComments(chat); XCTFail("Do not silently steer a revision-bound batch into live work") } catch { }
        XCTAssertEqual(chat.reviewComments, [captured]); XCTAssertFalse(chat.submittingReview)
        let peer = try XCTUnwrap(chat.connection), state = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(state["prompts"].array.count, 1)
        XCTAssertTrue(state["steers"].array.isEmpty)
        _ = try await peer.request("fixture/finish", params: [:])
    }
    @MainActor func testBatchViewFitsBothFileAndLineCommentsInLightAndDark() async throws {
        let (store, chat, _, project) = try await setup()
        chat.reviewComments = [try await comment(project, path: "first file 界.txt", text: "File-level feedback"), try await comment(project, path: "second.txt", removed: true, text: "Removed line feedback")]
        for scheme in [ColorScheme.light, .dark] {
            let host = NSHostingView(rootView: ReviewCommentsView(chat: chat, store: store).environment(\.colorScheme, scheme).frame(width: 360))
            host.frame = NSRect(x: 0, y: 0, width: 360, height: 260); host.layoutSubtreeIfNeeded()
            XCTAssertTrue(host.fittingSize.width.isFinite); XCTAssertLessThanOrEqual(host.fittingSize.width, 360)
            XCTAssertLessThanOrEqual(host.fittingSize.height, 350)
        }
    }
    @MainActor func testPersistenceFailureKeepsBatchAndNeverDelivers() async throws {
        let (store, chat, root, project) = try await setup()
        let captured = try await comment(project, path: "second.txt", text: "Keep after disk failure")
        chat.reviewComments = [captured]
        let data = root.appendingPathComponent("data"), backup = root.appendingPathComponent("data-before-failure")
        try FileManager.default.moveItem(at: data, to: backup)
        try Data("not a directory".utf8).write(to: data)
        defer { try? FileManager.default.removeItem(at: data); try? FileManager.default.moveItem(at: backup, to: data) }
        do { _ = try await store.submitReviewComments(chat); XCTFail("Failed durable save must not deliver a review") } catch { }
        XCTAssertEqual(chat.reviewComments, [captured]); XCTAssertTrue(chat.pendingPrompts.isEmpty); XCTAssertFalse(chat.submittingReview)
        let peer = try XCTUnwrap(chat.connection), state = try await peer.request("fixture/state", params: [:])
        XCTAssertTrue(state["prompts"].array.isEmpty)
    }
    @MainActor func testStopDuringReviewValidationKeepsCommentsAndSendsNothing() async throws {
        let (store, chat, _, project) = try await setup()
        let captured = try await comment(project, path: "second.txt", text: "Stopped before submission")
        chat.reviewComments = [captured]
        let operation = Task { try await store.submitReviewComments(chat) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !chat.submittingReview, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(chat.submittingReview)
        store.stop(chat)
        do { _ = try await operation.value; XCTFail("Stop must cancel review validation before any prompt is published") } catch { }
        XCTAssertEqual(chat.reviewComments, [captured]); XCTAssertTrue(chat.pendingPrompts.isEmpty)
        XCTAssertFalse(chat.submittingReview)
        let peer = try XCTUnwrap(chat.connection), state = try await peer.request("fixture/state", params: [:])
        XCTAssertTrue(state["prompts"].array.isEmpty)
    }
    @MainActor func testRealReviewBatchMakesBothChangesAndRunsRequestedTest() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT for actual review feedback execution.") }
        // Retain the owned repository: production agent history can advertise it
        // globally, and a removed temporary project must not become a launch trap.
        let (root, project) = try await repository(retain: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown() }
        await store.create(path: project.path, worktree: false)
        let chat = try XCTUnwrap(store.selected); try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(chat, id: mode["id"].string, value: "default")
        XCTAssertNil(chat.lastError)
        let command = "/usr/bin/python3 -c 'from pathlib import Path; assert Path(\"first file 界.txt\").read_text() == \"cobalt42\\n\"; assert Path(\"second.txt\").read_text() == \"amber17\\n\"; Path(\"test-result.txt\").write_text(\"both passed\")'"
        let first = try await comment(project, path: "first file 界.txt", removed: false, text: "Replace the entire file with exactly cobalt42 followed by one newline. Use Write or Edit. Do not use agents, skills, planning, network or other tasks.")
        let second = try await comment(project, path: "second.txt", text: "Replace the entire file with exactly amber17 followed by one newline. Use Write or Edit. After both edits, use Bash with exactly this command: \(command). No other commands or edits. Finish when it passes.")
        chat.reviewComments = [first, second]; chat.draft = "UNSENT_REAL_REVIEW_DRAFT"
        try "refreshed working state\nunchanged\n".write(to: project.appendingPathComponent("first file 界.txt"), atomically: true, encoding: .utf8)
        do { _ = try await store.submitReviewComments(chat); XCTFail("Actual batch must not submit stale feedback") } catch { }
        XCTAssertEqual(chat.reviewComments, [first, second]); XCTAssertTrue(chat.pendingPrompts.isEmpty)
        XCTAssertTrue(chat.transcript.items.filter { $0.kind == "user" }.isEmpty)
        let refreshed = try await Repository.diff(at: project.path, path: "first file 界.txt")
        let selectedLine = try XCTUnwrap(Repository.diffLines(refreshed).first { $0.text == "+refreshed working state" })
        try await store.rebindReviewComment(chat, id: first.id, path: "first file 界.txt", diff: refreshed, baseRevision: first.baseRevision, stagedOnly: false, line: selectedLine)
        let updatedFirst = try XCTUnwrap(chat.reviewComments.first)
        XCTAssertEqual(updatedFirst.text, first.text); XCTAssertNotEqual(updatedFirst.diffSHA256, first.diffSHA256)
        let submitted = try await store.submitReviewComments(chat); XCTAssertTrue(submitted)
        let deadline = ContinuousClock.now + .seconds(160)
        while chat.busy || !chat.pendingPrompts.isEmpty, ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let tool = approval.toolCall, name = PermissionPresentation(tool: tool).toolName
                let input = tool["rawInput"]
                if ["Write", "Edit", "Read"].contains(name) {
                    let path = URL(fileURLWithPath: input["file_path"].string).resolvingSymlinksInPath().path
                    let allowed = ["first file 界.txt", "second.txt"].map { project.appendingPathComponent($0).resolvingSymlinksInPath().path }
                    guard allowed.contains(path) else { throw ACPError.workspace("Unexpected file operation in owned review proof: \(name)") }
                } else if name == "Bash" {
                    guard input["command"].string == command else { throw ACPError.workspace("Unexpected command in owned review proof") }
                } else { throw ACPError.workspace("Unexpected tool in owned review proof: \(name)") }
                let options = approval.request["options"].array
                let option = try XCTUnwrap(options.first { $0["kind"].string == "allow_once" } ?? options.first { $0["kind"].string.hasPrefix("allow") })
                store.resolveApproval(chat, id: approval.id, option: option["optionId"].string)
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard !chat.busy, chat.pendingPrompts.isEmpty, chat.lastError == nil else { throw ACPError.workspace(chat.lastError ?? "Actual review batch did not finish") }
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("first file 界.txt"), encoding: .utf8), "cobalt42\n")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("second.txt"), encoding: .utf8), "amber17\n")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("test-result.txt"), encoding: .utf8), "both passed")
        XCTAssertEqual(chat.transcript.items.filter { $0.kind == "user" }.count, 1)
        XCTAssertTrue(chat.reviewComments.isEmpty); XCTAssertEqual(chat.draft, "UNSENT_REAL_REVIEW_DRAFT")
        print("Actual review batch: stale source refused, first comment explicitly rebound, two comments delivered in one prompt, both approved edits and requested assertion passed, unrelated draft preserved. Owned evidence: \(project.path)")
    }
}
