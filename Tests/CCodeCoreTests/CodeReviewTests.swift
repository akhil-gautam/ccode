import XCTest
import SwiftUI
import AppKit
import CCodeCore
@testable import CCode

final class CodeReviewTests: XCTestCase, @unchecked Sendable {
    private func repository() async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-findings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        try "def add(a, b):\n    return a + b\n".write(to: root.appendingPathComponent("answer.py"), atomically: true, encoding: .utf8)
        try await Repository.stage(at: root.path, path: "answer.py")
        _ = try await Repository.run(["-c", "user.name=ccode QA", "-c", "user.email=ccode-qa@example.invalid", "commit", "-m", "Initial"], at: root.path)
        try "def add(a, b):\n    return a - b\n".write(to: root.appendingPathComponent("answer.py"), atomically: true, encoding: .utf8)
        return root
    }
    private func report(_ id: UUID, path: String = "answer.py", start: Int = 2, end: Int = 2, side: String = "new", priority: Int = 1) -> String {
        "Summary\n```ccode-review\n{\"reviewId\":\"\(id.uuidString)\",\"findings\":[{\"path\":\"\(path)\",\"startLine\":\(start),\"endLine\":\(end),\"side\":\"\(side)\",\"priority\":\(priority),\"title\":\"Addition subtracts\",\"body\":\"Return a + b so add(2, 3) is 5.\"}]}\n```"
    }
    private func fileReport(_ id: UUID, path: String = "answer.py") -> String {
        "```ccode-review\n{\"reviewId\":\"\(id.uuidString)\",\"findings\":[{\"path\":\"\(path)\",\"startLine\":null,\"endLine\":null,\"side\":null,\"priority\":1,\"title\":\"File-level issue\",\"body\":\"Fix this file without guessing a line number.\"}]}\n```"
    }
    func testFileFindingPreservesAbsentLocationThroughPersistenceAndFeedback() async throws {
        let root = try await repository(), review = try await CodeReview.capture(at: root.path)
        let proposals = try XCTUnwrap(CodeReview.parse([fileReport(review.id)], reviewID: review.id))
        let findings = try await review.resolve(proposals, at: root.path)
        let finding = try XCTUnwrap(findings.first)
        XCTAssertNil(finding.startLine); XCTAssertNil(finding.endLine)
        XCTAssertNil(finding.context.side); XCTAssertNil(finding.context.lineNumber); XCTAssertNil(finding.context.selectedText)
        XCTAssertEqual(finding.context.path, "answer.py")
        let restored = try JSONDecoder().decode(ReviewFinding.self, from: JSONEncoder().encode(finding))
        XCTAssertEqual(restored, finding)
        let feedback = try ReviewComment.prompt([restored.context])
        XCTAssertTrue(feedback.contains("File-level issue"))
        XCTAssertFalse(feedback.contains("newLine")); XCTAssertFalse(feedback.contains("oldLine"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("answer.py"), encoding: .utf8), "def add(a, b):\n    return a - b\n")
    }
    func testBinaryFileFindingUsesNoFabricatedRangeAndRefusesExternalChanges() async throws {
        let root = try await repository(), binary = root.appendingPathComponent("asset.bin")
        try Data([0, 1, 2, 3]).write(to: binary)
        try await Repository.stage(at: root.path, path: "asset.bin")
        _ = try await Repository.run(["-c", "user.name=ccode QA", "-c", "user.email=ccode-qa@example.invalid", "commit", "-m", "Binary baseline"], at: root.path)
        try Data([0, 4, 5, 6]).write(to: binary)
        let diff = try await Repository.diff(at: root.path, path: "asset.bin")
        XCTAssertTrue(diff.contains("Binary files"))
        XCTAssertTrue(Repository.diffLines(diff).allSatisfy { $0.oldLine == nil && $0.newLine == nil })
        let review = try await CodeReview.capture(at: root.path)
        let proposals = try XCTUnwrap(CodeReview.parse([fileReport(review.id, path: "asset.bin")], reviewID: review.id))
        let findings = try await review.resolve(proposals, at: root.path), finding = try XCTUnwrap(findings.first)
        XCTAssertNil(finding.startLine); XCTAssertNil(finding.context.selectedText)
        try await finding.context.validate(at: root.path)
        try Data([0, 7, 8, 9]).write(to: binary)
        do { try await finding.context.validate(at: root.path); XCTFail("A stale binary finding cannot be sent for a newer asset") } catch { }
        XCTAssertEqual(try Data(contentsOf: binary), Data([0, 7, 8, 9]))
    }
    func testPermissionOnlyFileFindingDoesNotInventLineOne() async throws {
        let root = try await repository(), file = root.appendingPathComponent("answer.py")
        try "def add(a, b):\n    return a + b\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Repository.run(["config", "core.filemode", "true"], at: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let diff = try await Repository.diff(at: root.path, path: "answer.py")
        XCTAssertTrue(diff.contains("new mode 100755"))
        let review = try await CodeReview.capture(at: root.path)
        let proposals = try XCTUnwrap(CodeReview.parse([fileReport(review.id)], reviewID: review.id))
        let findings = try await review.resolve(proposals, at: root.path), finding = try XCTUnwrap(findings.first)
        XCTAssertNil(finding.startLine); XCTAssertNil(finding.context.lineNumber)
        XCTAssertEqual(finding.context.source, "working file")
    }
    func testFileFindingRejectsPartialRangeAndUnreviewedPath() async throws {
        let root = try await repository(), review = try await CodeReview.capture(at: root.path)
        let full = fileReport(review.id)
        for text in [full.replacingOccurrences(of: "\"startLine\":null", with: "\"startLine\":1"),
                     full.replacingOccurrences(of: "\"endLine\":null", with: "\"endLine\":1"),
                     full.replacingOccurrences(of: "\"side\":null", with: "\"side\":\"new\"")] {
            XCTAssertThrowsError(try CodeReview.parse([text], reviewID: review.id))
        }
        let proposals = try XCTUnwrap(CodeReview.parse([fileReport(review.id, path: "unreviewed.bin")], reviewID: review.id))
        do { _ = try await review.resolve(proposals, at: root.path); XCTFail("File-level reports need an exact captured path") } catch { }
    }
    func testStructuredFindingHasExactDiffSourceAndPersistedRange() async throws {
        let root = try await repository(), review = try await CodeReview.capture(at: root.path)
        let proposals = try XCTUnwrap(CodeReview.parse([report(review.id)], reviewID: review.id))
        let findings = try await review.resolve(proposals, at: root.path)
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(findings.count, 1); XCTAssertEqual(finding.path, "answer.py")
        XCTAssertEqual(finding.startLine, 2); XCTAssertEqual(finding.endLine, 2); XCTAssertEqual(finding.priority, 1)
        XCTAssertEqual(finding.context.selectedText, "+    return a - b"); XCTAssertEqual(finding.context.source, "working file")
        XCTAssertEqual(finding.title, "Addition subtracts"); XCTAssertEqual(finding.body, "Return a + b so add(2, 3) is 5.")
        var complete = review; complete.status = .complete; complete.findings = findings
        let restored = try JSONDecoder().decode(CodeReview.self, from: JSONEncoder().encode(complete))
        XCTAssertEqual(restored.findings, findings); XCTAssertEqual(restored.status, .complete)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("answer.py"), encoding: .utf8), "def add(a, b):\n    return a - b\n")
    }
    func testOldContextLineRetainsOriginalHeadSource() async throws {
        let root = try await repository(), review = try await CodeReview.capture(at: root.path)
        let proposals = try XCTUnwrap(CodeReview.parse([report(review.id, start: 1, end: 1, side: "old")], reviewID: review.id))
        let findings = try await review.resolve(proposals, at: root.path)
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(finding.context.source, "original HEAD"); XCTAssertEqual(finding.context.side, .old)
        XCTAssertEqual(finding.context.lineNumber, 1); XCTAssertEqual(finding.context.selectedText, " def add(a, b):")
    }
    func testUnstructuredForeignMalformedAndAmbiguousReportsNeverProduceAnnotations() async throws {
        let root = try await repository(), review = try await CodeReview.capture(at: root.path)
        XCTAssertNil(try CodeReview.parse(["Please change answer.py:2"], reviewID: review.id))
        for text in [report(UUID()), "```ccode-review\nnot json\n```", report(review.id) + "\n" + report(review.id), report(review.id, priority: 5)] {
            do { _ = try CodeReview.parse([text], reviewID: review.id); XCTFail("Invalid or ambiguous report") } catch { }
        }
        for text in [report(review.id, path: "../outside.py"), report(review.id, path: "unreviewed.py"), report(review.id, start: 99, end: 100), report(review.id, start: 3, end: 2)] {
            do {
                if let proposals = try CodeReview.parse([text], reviewID: review.id) {
                    _ = try await review.resolve(proposals, at: root.path); XCTFail("Invalid file/range cannot be guessed")
                } else { XCTFail("A malformed structured report must not be mistaken for plain prose") }
            } catch { }
        }
    }
    func testLiteralInlineFenceAndOversizedFixTextCannotBecomeFindings() async throws {
        let root = try await repository(), review = try await CodeReview.capture(at: root.path)
        let literal = report(review.id).replacingOccurrences(of: "Summary\n", with: "An inline literal ")
        XCTAssertNil(try CodeReview.parse([literal], reviewID: review.id))
        XCTAssertNil(try CodeReview.parse(["````text\n" + report(review.id) + "\n````"], reviewID: review.id))
        let oversized = report(review.id).replacingOccurrences(of: "Return a + b so add(2, 3) is 5.", with: String(repeating: "x", count: 8180))
        do { _ = try CodeReview.parse([oversized], reviewID: review.id); XCTFail("Accepted findings must fit their eventual fix context") } catch { }
    }
    func testChangedDiffOrRepositoryCannotReceiveOldAnnotations() async throws {
        let root = try await repository(), other = try await repository(), review = try await CodeReview.capture(at: root.path)
        let proposals = try XCTUnwrap(CodeReview.parse([report(review.id)], reviewID: review.id))
        do { _ = try await review.resolve(proposals, at: other.path); XCTFail("Same contents do not establish ownership") } catch { }
        try "external edit\n".write(to: root.appendingPathComponent("answer.py"), atomically: true, encoding: .utf8)
        do { _ = try await review.resolve(proposals, at: root.path); XCTFail("Old review must not attach to newer content") } catch { }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("answer.py"), encoding: .utf8), "external edit\n")
    }
    @MainActor private func setup(hold: Bool = false, flags: [String] = []) async throws -> (AppStore, ChatSession, URL, URL) {
        let root = try await repository()
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-findings-data-\(UUID())")
        let store = AppStore(directory: data)
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "delivery", withExtension: "py", subdirectory: "Fixtures")!.path, "--no-steering", "--review-report", "--audit-log=" + data.appendingPathComponent("actual-prompts.json").path] + (hold ? ["--hold-review"] : []) + flags
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: data) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected); try await store.connect(chat)
        return (store, chat, root, data)
    }
    @MainActor private func waitIdle(_ chat: ChatSession) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while chat.busy || !chat.pendingPrompts.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(chat.busy); XCTAssertTrue(chat.pendingPrompts.isEmpty)
    }
    @MainActor func testFileReviewFixAndResponseRetainFileContextWithoutASelectedLine() async throws {
        let (store, chat, root, _) = try await setup(flags: ["--file-review-report"])
        chat.draft = "Keep file finding draft"
        _ = try await store.requestCodeReview(chat); try await waitIdle(chat)
        XCTAssertEqual(chat.transcript.codeReview?.status, .complete)
        let finding = try XCTUnwrap(chat.transcript.codeReview?.findings.first)
        XCTAssertNil(finding.startLine); XCTAssertNil(finding.context.selectedText)
        let fixed = try await store.fixCodeReview(chat, findingIDs: [finding.id]); XCTAssertTrue(fixed)
        try await waitIdle(chat)
        let peer = try XCTUnwrap(chat.connection), calls = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(calls["prompts"].array.count, 2)
        let feedback = calls["prompts"].array[1]["prompt"].array[0]["text"].string
        XCTAssertTrue(feedback.contains("Addition subtracts")); XCTAssertFalse(feedback.contains("newLine"))
        let diff = try await Repository.diff(at: root.path, path: "answer.py")
        try await store.addReviewComment(chat, path: finding.path, diff: diff, baseRevision: finding.context.baseRevision, stagedOnly: false, line: nil, text: "File-wide response")
        XCTAssertNil(chat.reviewComments.first?.selectedText); XCTAssertNil(chat.reviewComments.first?.lineNumber)
        XCTAssertEqual(chat.draft, "Keep file finding draft")
    }
    @MainActor func testFileFindingCardFitsCompactAndWideLightAndDark() async throws {
        let root = try await repository(), review = try await CodeReview.capture(at: root.path)
        let proposals = try XCTUnwrap(CodeReview.parse([fileReport(review.id)], reviewID: review.id))
        let findings = try await review.resolve(proposals, at: root.path), finding = try XCTUnwrap(findings.first)
        for width in [CGFloat(320), 680] {
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: ReviewFindingCard(finding: finding, canFix: true, fix: {}, respond: {}).frame(width: width).environment(\.colorScheme, scheme))
                XCTAssertGreaterThan(host.fittingSize.height, 30)
                XCTAssertLessThanOrEqual(host.fittingSize.width, width)
            }
        }
    }
    @MainActor func testReviewAndFixRequestsPreserveUnsentContextAndProduceOneOwnedReport() async throws {
        let (store, chat, root, data) = try await setup()
        chat.draft = "UNSENT_REVIEW_DRAFT"
        let file = data.appendingPathComponent("attachment.txt"); try "UNSENT_REVIEW_ATTACHMENT".write(to: file, atomically: true, encoding: .utf8)
        let attachment = try await store.storage.importAttachment(file); chat.attachments = [attachment]
        chat.fileDrafts["answer.py"] = EditorDraft(original: "def add(a, b):\n    return a - b\n", text: "UNSAVED_EDITOR")
        chat.deliveryPaused = true // An explicit new request may start with no old work queued.
        let id = try await store.requestCodeReview(chat)
        try await waitIdle(chat)
        let review = try XCTUnwrap(chat.transcript.codeReview), finding = try XCTUnwrap(review.findings.first)
        XCTAssertEqual(review.id, id); XCTAssertEqual(review.status, .complete); XCTAssertEqual(review.snapshots.count, 1)
        XCTAssertEqual(finding.path, "answer.py"); XCTAssertEqual(finding.startLine, 2)
        let peer = try XCTUnwrap(chat.connection), state = try await peer.request("fixture/state", params: [:])
        let prompts = state["prompts"].array
        XCTAssertEqual(prompts.count, 1); XCTAssertEqual(prompts[0]["prompt"].array.count, 1)
        let sent = prompts[0]["prompt"].array[0]["text"].string
        XCTAssertFalse(sent.contains("UNSENT_REVIEW")); XCTAssertFalse(sent.contains("UNSAVED_EDITOR"))
        let didFix = try await store.fixCodeReview(chat, findingIDs: [finding.id]); XCTAssertTrue(didFix)
        try await waitIdle(chat)
        let after = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(after["prompts"].array.count, 2)
        let fix = after["prompts"].array[1]["prompt"].array
        XCTAssertEqual(fix.count, 1); XCTAssertTrue(fix[0]["text"].string.contains("Addition subtracts"))
        XCTAssertEqual(chat.draft, "UNSENT_REVIEW_DRAFT"); XCTAssertEqual(chat.attachments, [attachment])
        XCTAssertEqual(chat.fileDrafts["answer.py"]?.text, "UNSAVED_EDITOR")
        try "new external edit\n".write(to: root.appendingPathComponent("answer.py"), atomically: true, encoding: .utf8)
        do { _ = try await store.fixCodeReview(chat); XCTFail("A stale finding must not fix new code") } catch { }
        let final = try await peer.request("fixture/state", params: [:]); XCTAssertEqual(final["prompts"].array.count, 2)
    }
    @MainActor func testDelayedReviewOfChangedFilesBecomesStaleWithoutGuessingAnnotations() async throws {
        let (store, chat, root, _) = try await setup(hold: true)
        chat.draft = "Keep late draft"
        _ = try await store.requestCodeReview(chat)
        let peer = try XCTUnwrap(chat.connection), deadline = ContinuousClock.now + .seconds(5)
        var state = try await peer.request("fixture/state", params: [:])
        while state["prompts"].array.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)); state = try await peer.request("fixture/state", params: [:])
        }
        XCTAssertEqual(state["prompts"].array.count, 1); XCTAssertEqual(chat.transcript.codeReview?.status, .running)
        try "external while reviewing\n".write(to: root.appendingPathComponent("answer.py"), atomically: true, encoding: .utf8)
        _ = try await peer.request("fixture/finish", params: [:]); try await waitIdle(chat)
        XCTAssertEqual(chat.transcript.codeReview?.status, .stale); XCTAssertTrue(chat.transcript.codeReview?.findings.isEmpty == true)
        XCTAssertEqual(chat.draft, "Keep late draft")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("answer.py"), encoding: .utf8), "external while reviewing\n")
    }
    @MainActor func testStopPreventsACompletedLookingCancelledReportFromBecomingFindings() async throws {
        let (store, chat, _, _) = try await setup(hold: true)
        _ = try await store.requestCodeReview(chat)
        let peer = try XCTUnwrap(chat.connection), deadline = ContinuousClock.now + .seconds(5)
        var state = try await peer.request("fixture/state", params: [:])
        while state["prompts"].array.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)); state = try await peer.request("fixture/state", params: [:]) }
        XCTAssertEqual(state["prompts"].array.count, 1)
        store.stop(chat); try await waitIdle(chat)
        XCTAssertEqual(chat.transcript.codeReview?.status, .interrupted); XCTAssertTrue(chat.transcript.codeReview?.findings.isEmpty == true)
    }
    @MainActor func testRestartedQueuedReviewRevalidatesBeforeAnyPromptAndDoesNotAutoResume() async throws {
        let (store, chat, root, data) = try await setup()
        let review = try await CodeReview.capture(at: root.path), owner = try store.promptOwner(chat)
        chat.transcript.codeReview = review; chat.draft = "Retain queued draft"
        chat.pendingPrompts = [try PendingPrompt(id: review.id, text: review.prompt(), attachments: [], policy: .nextTurn, executable: owner.0, arguments: owner.1, remoteID: chat.transcript.remoteID)]
        await store.save(chat); await store.shutdown()
        let restored = AppStore(directory: data); addTeardownBlock { await restored.shutdown() }
        await restored.restore(); await restored.select(chat.id)
        let reopened = try XCTUnwrap(restored.selected)
        XCTAssertNil(reopened.connection); XCTAssertTrue(reopened.deliveryPaused); XCTAssertEqual(reopened.pendingPrompts.count, 1)
        try "changed during restart\n".write(to: root.appendingPathComponent("answer.py"), atomically: true, encoding: .utf8)
        restored.resumeQueuedPrompts(reopened)
        let deadline = ContinuousClock.now + .seconds(6)
        while reopened.busy || reopened.pendingPrompts.first?.state == .queued, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(reopened.transcript.codeReview?.status, .stale); XCTAssertEqual(reopened.pendingPrompts.first?.state, .failed)
        XCTAssertEqual(reopened.draft, "Retain queued draft")
        let calls = try JSONDecoder().decode([JSONValue].self, from: Data(contentsOf: data.appendingPathComponent("actual-prompts.json")))
        XCTAssertTrue(calls.isEmpty); XCTAssertTrue(reopened.transcript.items.isEmpty)
    }
    @MainActor func testPlainAndForeignReportsRemainConversationTextAndCannotBeFixed() async throws {
        for flags in [["--plain-review"], ["--foreign-review"]] {
            let (store, chat, _, _) = try await setup(flags: flags)
            _ = try await store.requestCodeReview(chat); try await waitIdle(chat)
            XCTAssertEqual(chat.transcript.codeReview?.status, .unstructured); XCTAssertTrue(chat.transcript.codeReview?.findings.isEmpty == true)
            XCTAssertFalse(chat.transcript.items.filter { $0.kind == "assistant" }.isEmpty)
            do { _ = try await store.fixCodeReview(chat); XCTFail("Plain or foreign reports cannot become actionable findings") } catch { }
            let calls = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:]); XCTAssertEqual(calls["prompts"].array.count, 1)
        }
    }
    @MainActor func testNoFindingsIsACompleteReviewAndFixDoesNotSubmitEmptyWork() async throws {
        let (store, chat, _, _) = try await setup(flags: ["--no-findings"])
        _ = try await store.requestCodeReview(chat); try await waitIdle(chat)
        XCTAssertEqual(chat.transcript.codeReview?.status, .complete); XCTAssertTrue(chat.transcript.codeReview?.findings.isEmpty == true)
        let result = try await store.fixCodeReview(chat); XCTAssertFalse(result)
        let calls = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:]); XCTAssertEqual(calls["prompts"].array.count, 1)
    }
    @MainActor func testFailedSavePreservesPriorReviewDraftsAndDoesNotSubmit() async throws {
        let (store, chat, _, data) = try await setup()
        _ = try await store.requestCodeReview(chat); try await waitIdle(chat)
        let prior = try XCTUnwrap(chat.transcript.codeReview)
        chat.draft = "Keep failed save draft"; chat.deliveryPaused = true
        let saved = data.appendingPathComponent(chat.id.uuidString + ".json")
        try FileManager.default.removeItem(at: saved); try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: false)
        for fix in [false, true] {
            do { if fix { _ = try await store.fixCodeReview(chat) } else { _ = try await store.requestCodeReview(chat) }; XCTFail("Save failure must prevent submission") } catch { }
            XCTAssertEqual(chat.transcript.codeReview?.id, prior.id); XCTAssertTrue(chat.pendingPrompts.isEmpty); XCTAssertTrue(chat.deliveryPaused)
            XCTAssertEqual(chat.draft, "Keep failed save draft"); XCTAssertFalse(chat.busy)
        }
        let calls = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:]); XCTAssertEqual(calls["prompts"].array.count, 1)
        try FileManager.default.removeItem(at: saved)
    }
    @MainActor func testReviewControlsFitCompactLightAndDarkLayoutsAndOnlyMatchCapturedDiff() async throws {
        let root = try await repository(), snapshot = try await CodeReview.capture(at: root.path)
        let proposals = try XCTUnwrap(CodeReview.parse([report(snapshot.id)], reviewID: snapshot.id))
        var review = snapshot; review.status = .complete; review.findings = try await review.resolve(proposals, at: root.path)
        let finding = try XCTUnwrap(review.findings.first), diff = try await Repository.diff(at: root.path, path: finding.path)
        XCTAssertTrue(finding.context.matchesDisplayed(root: review.root, path: finding.path, diff: diff, baseRevision: finding.context.baseRevision, stagedOnly: false))
        XCTAssertFalse(finding.context.matchesDisplayed(root: review.root, path: finding.path, diff: diff + "\n+external", baseRevision: finding.context.baseRevision, stagedOnly: false))
        XCTAssertFalse(finding.context.matchesDisplayed(root: review.root, path: finding.path, diff: diff, baseRevision: finding.context.baseRevision, stagedOnly: true))
        for scheme in [ColorScheme.light, .dark] {
            let header = NSHostingView(rootView: CodeReviewStatusView(review: review, canFix: true, select: { _ in }, fixAll: {}).frame(width: 360).environment(\.colorScheme, scheme))
            let card = NSHostingView(rootView: ReviewFindingCard(finding: finding, canFix: true, fix: {}, respond: {}).frame(width: 320).environment(\.colorScheme, scheme))
            XCTAssertGreaterThan(header.fittingSize.height, 20); XCTAssertLessThan(header.fittingSize.height, 140)
            XCTAssertGreaterThan(card.fittingSize.height, 30); XCTAssertLessThan(card.fittingSize.height, 240)
            XCTAssertLessThanOrEqual(header.fittingSize.width, 360); XCTAssertLessThanOrEqual(card.fittingSize.width, 320)
        }
    }
    @MainActor func testStopDuringCapturePublishesNoReviewOrPrompt() async throws {
        let (store, chat, _, _) = try await setup()
        chat.draft = "Keep capture draft"
        let task = Task { try await store.requestCodeReview(chat) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !chat.submittingReview, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(chat.submittingReview); store.stop(chat)
        do { _ = try await task.value; XCTFail("Stop must invalidate capture before publication") } catch { }
        XCTAssertNil(chat.transcript.codeReview); XCTAssertTrue(chat.pendingPrompts.isEmpty); XCTAssertEqual(chat.draft, "Keep capture draft")
        let calls = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:]); XCTAssertTrue(calls["prompts"].array.isEmpty)
    }
    @MainActor func testUnknownFindingAndActiveWorkCannotCreateExtraFixRequests() async throws {
        let (store, chat, _, _) = try await setup()
        _ = try await store.requestCodeReview(chat); try await waitIdle(chat)
        do { _ = try await store.fixCodeReview(chat, findingIDs: [UUID()]); XCTFail("Unknown findings cannot be silently dropped") } catch { }
        store.send(chat, text: "hold ordinary task")
        let deadline = ContinuousClock.now + .seconds(3)
        while chat.state != .running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(chat.state, .running)
        do { _ = try await store.fixCodeReview(chat); XCTFail("Fix must not interleave with active work") } catch { }
        do { _ = try await store.requestCodeReview(chat); XCTFail("Review must not interleave with active work") } catch { }
        _ = try await XCTUnwrap(chat.connection).request("fixture/finish", params: [:]); try await waitIdle(chat)
        let calls = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:]); XCTAssertEqual(calls["prompts"].array.count, 2)
    }
    @MainActor func testFixRevalidatesAfterReconnectBeforeAnyAgentPrompt() async throws {
        let (store, chat, root, _) = try await setup(flags: ["--question-load"])
        _ = try await store.requestCodeReview(chat); try await waitIdle(chat)
        await store.disconnect(chat); chat.draft = "Keep reconnect draft"
        let submitted = try await store.fixCodeReview(chat); XCTAssertTrue(submitted)
        let deadline = ContinuousClock.now + .seconds(5)
        while chat.interactions.isEmpty, chat.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let question = try XCTUnwrap(chat.interactions.first)
        try "external during reconnect\n".write(to: root.appendingPathComponent("answer.py"), atomically: true, encoding: .utf8)
        try store.resolveInteraction(chat, id: question.id, action: .accept, content: ["ready": true])
        while chat.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(chat.busy); XCTAssertEqual(chat.pendingPrompts.first?.state, .failed)
        let calls = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:]); XCTAssertTrue(calls["prompts"].array.isEmpty)
        XCTAssertEqual(chat.draft, "Keep reconnect draft")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("answer.py"), encoding: .utf8), "external during reconnect\n")
    }
    @MainActor func testRestartedFixRetainsSourceReceiptsAndRejectsStaleFilesWithoutAutoResume() async throws {
        let (store, chat, root, data) = try await setup(flags: ["--question-load"])
        _ = try await store.requestCodeReview(chat); try await waitIdle(chat)
        let finding = try XCTUnwrap(chat.transcript.codeReview?.findings.first)
        await store.disconnect(chat)
        _ = try await store.fixCodeReview(chat)
        let deadline = ContinuousClock.now + .seconds(5)
        while chat.interactions.isEmpty, chat.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(chat.interactions.isEmpty)
        XCTAssertEqual(chat.pendingPrompts.first?.reviewContexts, [finding.context])
        let pendingID = try XCTUnwrap(chat.pendingPrompts.first?.id)
        do { try store.editQueuedPrompt(chat, id: pendingID, text: "Changed context"); XCTFail("Typed receipts cannot silently diverge from their request") } catch { }
        await store.shutdown()
        let restored = AppStore(directory: data); addTeardownBlock { await restored.shutdown() }
        await restored.restore(); await restored.select(chat.id)
        let reopened = try XCTUnwrap(restored.selected)
        XCTAssertTrue(reopened.deliveryPaused); XCTAssertNil(reopened.connection)
        XCTAssertEqual(reopened.pendingPrompts.first?.reviewContexts, [finding.context])
        try "external after restart\n".write(to: root.appendingPathComponent("answer.py"), atomically: true, encoding: .utf8)
        restored.resumeQueuedPrompts(reopened)
        let resumed = ContinuousClock.now + .seconds(6)
        while reopened.interactions.isEmpty, reopened.busy || reopened.pendingPrompts.first?.state == .queued, ContinuousClock.now < resumed { try await Task.sleep(for: .milliseconds(10)) }
        let question = try XCTUnwrap(reopened.interactions.first)
        try restored.resolveInteraction(reopened, id: question.id, action: .accept, content: ["ready": true])
        while reopened.busy, ContinuousClock.now < resumed { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(reopened.pendingPrompts.first?.state, .failed); XCTAssertEqual(reopened.transcript.codeReview?.status, .stale)
        let calls = try await XCTUnwrap(reopened.connection).request("fixture/state", params: [:]); XCTAssertTrue(calls["prompts"].array.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("answer.py"), encoding: .utf8), "external after restart\n")
    }
    @MainActor func testRefreshInvalidatesDisplayedDiffWhenGitStatusMetadataIsUnchanged() async throws {
        let (store, chat, root, _) = try await setup()
        await store.refreshWorkspace(chat)
        let revision = chat.workspaceRevision, files = chat.repository.files
        XCTAssertEqual(files.count, 1)
        try "def add(a, b):\n    return a * b\n".write(to: root.appendingPathComponent("answer.py"), atomically: true, encoding: .utf8)
        await store.refreshWorkspace(chat)
        XCTAssertEqual(chat.repository.files, files, "M remains M; equality alone cannot signal changed diff content")
        XCTAssertNotEqual(chat.workspaceRevision, revision, "Refresh must invalidate the view's displayed diff")
        let refreshed = try await Repository.diff(at: root.path, path: "answer.py"); XCTAssertTrue(refreshed.contains("+    return a * b"))
    }
    // A test-fixture gate, not product authorization. Compound read commands
    // are permitted only over the disposable current file and its HEAD blob.
    private func ownedBinaryInspection(_ command: String, exactRead: String, exactWrite: String? = nil) -> Bool {
        if command == exactRead { return true }
        guard !command.contains("$"), !command.contains("`"), !command.contains("\n"), !command.contains("\r") else { return false }
        var normalized = command.replacingOccurrences(of: "<(git show HEAD:asset.bin)", with: "CCODE_HEAD_BINARY").replacingOccurrences(of: "\\'", with: "'").replacingOccurrences(of: exactRead, with: "CCODE_FIXTURE_READ")
        if let exactWrite { normalized = normalized.replacingOccurrences(of: exactWrite, with: "CCODE_FIXTURE_WRITE") }
        let sources: Set<String> = ["git diff", "git diff HEAD", "git diff -- asset.bin", "git diff HEAD -- asset.bin", "git diff --stat", "git diff HEAD --stat", "git diff HEAD --stat -- asset.bin", "git diff --numstat", "git diff HEAD --numstat", "git diff HEAD --numstat -- asset.bin", "git diff HEAD --binary", "git diff HEAD --binary -- asset.bin", "git show HEAD:asset.bin", "git cat-file -s HEAD:asset.bin", "git status", "git status --short", "git status --porcelain", "git rev-parse HEAD", "ls *.md 2>/dev/null", "cat README.md", "ls", "ls -l", "ls -la", "ls -l asset.bin", "pwd", "xxd asset.bin", "xxd CCODE_HEAD_BINARY", "hexdump -C asset.bin", "od -An -tu1 asset.bin", "file asset.bin", "wc -c asset.bin"]
        return normalized.replacingOccurrences(of: " && ", with: ";").components(separatedBy: ";").allSatisfy { part in
            let stages = part.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = stages.first else { return false }
            let args = first.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let diffArguments: Set<String> = ["HEAD", "--stat", "--numstat", "--binary", "--no-ext-diff", "--no-textconv", "--", "asset.bin"]
            let ownedDiff = Array(args.prefix(2)) == ["git", "diff"] && args.dropFirst(2).allSatisfy { diffArguments.contains($0) }
            guard sources.contains(first) || ownedDiff || first == "CCODE_FIXTURE_READ" || exactWrite != nil && first == "CCODE_FIXTURE_WRITE" else { return false }
            return stages.dropFirst().allSatisfy { stage in
                let args = stage.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if args == ["xxd"] || args == ["head"] { return true }
                guard args.first == "head" else { return false }
                let count: Int?
                if args.count == 2, args[1].hasPrefix("-") { count = Int(args[1].dropFirst()) }
                else if args.count == 3, ["-n", "-c"].contains(args[1]) { count = Int(args[2]) }
                else { return false }
                return count.map { (1...4096).contains($0) } ?? false
            }
        }
    }
    func testBinaryProofGatePermitsOwnedInspectionAndRejectsUnrelatedCommands() {
        let read = "/usr/bin/python3 -B -c \"from pathlib import Path; print(list(Path('asset.bin').read_bytes()))\""
        let write = "/usr/bin/python3 -B -c \"from pathlib import Path; Path('asset.bin').write_bytes(bytes([0, 67, 67, 79, 68, 69, 1]))\""
        XCTAssertTrue(ownedBinaryInspection("git rev-parse HEAD && " + read, exactRead: read))
        XCTAssertTrue(ownedBinaryInspection("git rev-parse HEAD && " + read.replacingOccurrences(of: "'", with: "\\'"), exactRead: read))
        XCTAssertFalse(ownedBinaryInspection(write, exactRead: read))
        XCTAssertTrue(ownedBinaryInspection("git status --short && " + write, exactRead: read, exactWrite: write))
        XCTAssertFalse(ownedBinaryInspection(write + "; rm README.md", exactRead: read, exactWrite: write))
        for command in ["ls *.md 2>/dev/null", "cat README.md", "git diff HEAD --stat && git diff HEAD --binary | head -c 3000 && ls -l asset.bin && git show HEAD:asset.bin | xxd | head -20 && xxd asset.bin | head -20", "git diff HEAD --stat && git diff HEAD | head -50 && ls -l asset.bin && git show HEAD:asset.bin | xxd | head; xxd asset.bin | head", "git diff --stat HEAD -- asset.bin; xxd asset.bin | head", "xxd <(git show HEAD:asset.bin) | head", "git diff HEAD --numstat -- asset.bin; ls -l asset.bin", "git diff HEAD --stat -- asset.bin; git diff HEAD --numstat -- asset.bin; git cat-file -s HEAD:asset.bin; wc -c asset.bin; xxd asset.bin | head -20; git show HEAD:asset.bin | xxd | head -20"] {
            XCTAssertTrue(ownedBinaryInspection(command, exactRead: "READ_ONLY_FIXTURE"))
        }
        for command in ["ls *.md 2>outside", "cat ../README.md", "cat README.md > asset.bin", "git diff HEAD; rm asset.bin", "xxd ../outside", "xxd asset.bin > outside", "git config core.sshCommand evil", "git show OTHER:asset.bin", "git diff HEAD || curl example.invalid", "xxd <(cat ../outside)", "xxd asset.bin | head;", "git diff HEAD\nrm asset.bin", "git diff $(cat ../outside)", "git diff HEAD -- ../outside", "git diff --output=outside HEAD", "git diff --no-index asset.bin ../outside", "git diff --ext-diff HEAD", "xxd asset.bin | head ../outside", "xxd asset.bin | head -c 9999999", "xxd asset.bin | head -n 20 ../outside"] {
            XCTAssertFalse(ownedBinaryInspection(command, exactRead: "READ_ONLY_FIXTURE"))
        }
    }
    @MainActor func testRealBinaryFileFindingAndExplicitFix() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT for actual binary-file review/fix execution.") }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ccode-binary-review-\(UUID())")
        let project = root.appendingPathComponent("project"), data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let binary = project.appendingPathComponent("asset.bin")
        let expected = Data([0, 67, 67, 79, 68, 69, 1]), broken = Data([0, 67, 67, 79, 68, 69, 255])
        let readCommand = "/usr/bin/python3 -B -c \"from pathlib import Path; print(list(Path('asset.bin').read_bytes()))\""
        let fixCommand = "/usr/bin/python3 -B -c \"from pathlib import Path; Path('asset.bin').write_bytes(bytes([0, 67, 67, 79, 68, 69, 1]))\""
        let readme = "This repository stores a seven-byte binary asset. Its required bytes are exactly [0, 67, 67, 79, 68, 69, 1]. The last byte is format version 1; every other version is rejected by the consumer. Preserve all other bytes. Inspect bytes with exactly: \(readCommand)\nIf explicitly asked to fix a wrong version, use exactly: \(fixCommand)\nBinary issues have no source line numbers. Do not modify README.md.\n"
        try expected.write(to: binary); try readme.write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await Repository.run(["init", "-b", "main"], at: project.path)
        _ = try await Repository.run(["add", "asset.bin", "README.md"], at: project.path)
        _ = try await Repository.run(["-c", "user.name=ccode QA", "-c", "user.email=ccode-qa@example.invalid", "commit", "-m", "Binary baseline"], at: project.path)
        try broken.write(to: binary)
        let store = AppStore(directory: data); store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown() }
        await store.create(path: project.path, worktree: false)
        let chat = try XCTUnwrap(store.selected); try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(chat, id: mode["id"].string, value: "default")
        chat.draft = "Unsent binary review draft"
        func finishBinaryReview(mayWrite: Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(180)
            while chat.busy || !chat.pendingPrompts.isEmpty, ContinuousClock.now < deadline {
                for approval in chat.approvals {
                    let tool = approval.toolCall, name = PermissionPresentation(tool: tool).toolName, input = tool["rawInput"]
                    var allowed = false
                    if name == "Read" {
                        let file = URL(fileURLWithPath: input["file_path"].string).resolvingSymlinksInPath().path
                        allowed = file == binary.path || file == project.appendingPathComponent("README.md").path
                    } else if name == "Bash" {
                        allowed = ownedBinaryInspection(input["command"].string, exactRead: readCommand, exactWrite: mayWrite ? fixCommand : nil)
                    }
                    guard allowed, let option = approval.request["options"].array.first(where: { $0["kind"].string == "allow_once" }) else {
                        store.resolveApproval(chat, id: approval.id, option: nil)
                        throw ACPError.workspace("Unexpected binary review proof action: \(name) \(input)")
                    }
                    store.resolveApproval(chat, id: approval.id, option: option["optionId"].string)
                }
                try await Task.sleep(for: .milliseconds(30))
            }
            guard !chat.busy, chat.pendingPrompts.isEmpty, chat.state == .ready, chat.lastError == nil else { throw ACPError.workspace(chat.lastError ?? "Binary review did not finish") }
        }
        _ = try await store.requestCodeReview(chat); try await finishBinaryReview(mayWrite: false)
        let review = try XCTUnwrap(chat.transcript.codeReview)
        XCTAssertEqual(review.status, .complete, review.details ?? "Missing structured binary review")
        let finding = try XCTUnwrap(review.findings.first { $0.path == "asset.bin" })
        XCTAssertNil(finding.startLine); XCTAssertNil(finding.endLine); XCTAssertNil(finding.context.selectedText)
        XCTAssertEqual(try Data(contentsOf: binary), broken, "Review must remain read-only")
        let sent = try await store.fixCodeReview(chat, findingIDs: [finding.id]); XCTAssertTrue(sent)
        try await finishBinaryReview(mayWrite: true)
        XCTAssertEqual(try Data(contentsOf: binary), expected)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("README.md"), encoding: .utf8), readme)
        XCTAssertEqual(chat.draft, "Unsent binary review draft")
        let status = try await Repository.status(at: project.path)
        XCTAssertTrue(status.files.isEmpty, "Exact original binary restored; no other project changes")
        await store.save(chat)
        print("Real binary review: absent line range, explicit fix and independently checked exact bytes. Owned evidence: \(project.path)")
    }
    @MainActor func testRealReviewFindingFixIndependentTestsAndRereview() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT for actual review/fix/re-review execution.") }
        // Retain the project because the real provider's shared history can list it.
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ccode-code-review-\(UUID())")
        let project = root.appendingPathComponent("project"), data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("answer.py")
        try "def add(a, b):\n    return a + b\n".write(to: file, atomically: true, encoding: .utf8)
        let readme = "A small utility. add(a, b) must return the sum of both numbers.\nIf testing, run exactly: /usr/bin/python3 -B -c 'from answer import add; assert add(2, 3) == 5'\n"
        try readme.write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let ignore = "__pycache__/\n*.pyc\n"
        try ignore.write(to: project.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try await Repository.run(["init", "-b", "main"], at: project.path)
        _ = try await Repository.run(["add", "answer.py", "README.md", ".gitignore"], at: project.path)
        _ = try await Repository.run(["-c", "user.name=ccode QA", "-c", "user.email=ccode-qa@example.invalid", "commit", "-m", "Initial"], at: project.path)
        let broken = "def add(a, b):\n    \"\"\"Return the sum of two numbers.\"\"\"\n    return a - b\n"
        try broken.write(to: file, atomically: true, encoding: .utf8)
        let store = AppStore(directory: data); store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown() }
        await store.create(path: project.path, worktree: false)
        let chat = try XCTUnwrap(store.selected); try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(chat, id: mode["id"].string, value: "default"); XCTAssertNil(chat.lastError)
        chat.draft = "UNSENT_REAL_FINDINGS_DRAFT"
        let request = try await store.requestCodeReview(chat)
        try await finishRealReview(chat, store: store, project: project, mayWrite: false)
        let review = try XCTUnwrap(chat.transcript.codeReview)
        print("Actual review returned \(review.findings.count) validated findings, status \(review.status.rawValue). Owned evidence: \(project.path)")
        XCTAssertEqual(review.id, request)
        guard review.status == .complete else { throw ACPError.workspace(review.details ?? "Missing structured report") }
        let finding = try XCTUnwrap(review.findings.first { $0.path == "answer.py" && ($0.startLine ?? Int.max) <= 3 && ($0.endLine ?? 0) >= 3 })
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), broken, "Review must not edit files")
        let requestedFix = try await store.fixCodeReview(chat, findingIDs: [finding.id]); XCTAssertTrue(requestedFix)
        try await finishRealReview(chat, store: store, project: project, mayWrite: true)
        print("Actual review fix turn completed.")
        let fixed = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(fixed.contains("return a + b")); XCTAssertTrue(fixed.contains("Return the sum of two numbers."))
        let terminal = TerminalService()
        let test = try await terminal.create(command: "/usr/bin/python3", arguments: ["-B", "-c", "from answer import add; assert add(2, 3) == 5; assert add(-2, 3) == 1; assert add(2.5, 3.5) == 6"], directory: project.path)
        let result = try await terminal.wait(test); await terminal.close(); XCTAssertEqual(result["exitCode"], 0)
        let second = try await store.requestCodeReview(chat); XCTAssertNotEqual(second, request)
        try await finishRealReview(chat, store: store, project: project, mayWrite: false)
        guard chat.transcript.codeReview?.status == .complete, chat.transcript.codeReview?.findings.isEmpty == true else { throw ACPError.workspace(chat.transcript.codeReview?.details ?? "Re-review still has findings") }
        XCTAssertEqual(chat.draft, "UNSENT_REAL_FINDINGS_DRAFT"); XCTAssertEqual(chat.transcript.items.filter { $0.kind == "user" }.count, 3)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("README.md"), encoding: .utf8), readme)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent(".gitignore"), encoding: .utf8), ignore)
        await store.save(chat)
        print("Actual structured review: exact finding, explicit fix, independent Python assertions and fresh clean re-review; draft and README preserved. Owned evidence: \(project.path)")
    }
    @MainActor private func finishRealReview(_ chat: ChatSession, store: AppStore, project: URL, mayWrite: Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(180)
        let readCommands: Set<String> = ["ls", "ls -l", "ls -la", "pwd", "git diff", "git diff HEAD", "git diff -- answer.py", "git diff HEAD -- answer.py", "git status", "git status --short", "git status --porcelain", "git diff --stat", "git rev-parse HEAD"]
        while chat.busy || !chat.pendingPrompts.isEmpty, ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let tool = approval.toolCall, name = PermissionPresentation(tool: tool).toolName, input = tool["rawInput"]
                var allowed = false
                if name == "Read" || mayWrite && ["Write", "Edit"].contains(name) {
                    let path = URL(fileURLWithPath: input["file_path"].string).resolvingSymlinksInPath().path
                    allowed = path == project.appendingPathComponent("answer.py").path || name == "Read" && path == project.appendingPathComponent("README.md").path
                } else if name == "Bash" {
                    let command = input["command"].string
                    allowed = command.components(separatedBy: " && ").allSatisfy { readCommands.contains($0) || mayWrite && allowedArithmeticCheck($0) }
                }
                guard allowed, let option = approval.request["options"].array.first(where: { $0["kind"].string == "allow_once" }) else {
                    store.resolveApproval(chat, id: approval.id, option: nil)
                    throw ACPError.workspace("Unexpected tool in owned structured-review proof: \(name) \(input)")
                }
                store.resolveApproval(chat, id: approval.id, option: option["optionId"].string)
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard !chat.busy, chat.pendingPrompts.isEmpty, chat.state == .ready, chat.lastError == nil else { throw ACPError.workspace(chat.lastError ?? "Actual structured review did not finish") }
    }
    private func allowedArithmeticCheck(_ command: String) -> Bool {
        // Only known arithmetic checks in the owned project. Quote/spacing
        // variation must not make a harmless provider check fail the fixture.
        let value = command.hasPrefix("ls; ") ? String(command.dropFirst(4)) : command
        let prefixes = ["python3 -c ", "python3 -B -c ", "/usr/bin/python3 -c ", "/usr/bin/python3 -B -c "]
        guard let prefix = prefixes.first(where: { value.hasPrefix($0) }) else { return false }
        let quoted = value.dropFirst(prefix.count)
        guard let quote = quoted.first, quote == "\"" || quote == "'", quoted.count > 2, quoted.last == quote else { return false }
        let code = quoted.dropFirst().dropLast()
        guard !code.contains("$"), !code.contains("`"), !code.contains("\\") else { return false }
        let normalized = String(code.filter { !$0.isWhitespace })
        return ["fromanswerimportadd;assertadd(2,3)==5", "fromanswerimportadd;assertadd(2,3)==5;print('ok')", "fromanswerimportadd;assertadd(2,3)==5;print(\"ok\")", "fromanswerimportadd;print(add(2,3))"].contains(normalized)
    }
    func testOwnedArithmeticFixtureAllowsHarmlessVariantsAndRejectsExtraCommands() {
        XCTAssertTrue(allowedArithmeticCheck("ls; python3 -c \"from answer import add; assert add(2,3)==5; print('ok')\""))
        XCTAssertTrue(allowedArithmeticCheck("python3 -c \"from answer import add; print(add(2,3))\""))
        XCTAssertTrue(allowedArithmeticCheck("/usr/bin/python3 -B -c 'from answer import add; assert add(2, 3) == 5'"))
        for command in ["python3 -c \"$(cat outside)\"", "python3 -c 'from answer import add; assert add(2,3)==5'; curl example.invalid", "python3 -c 'from answer import add; import os; os.remove(\"outside\")'", "curl example.invalid"] {
            XCTAssertFalse(allowedArithmeticCheck(command))
        }
    }
}
