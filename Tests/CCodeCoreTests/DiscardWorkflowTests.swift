import XCTest
import AppKit
import SwiftUI
import Darwin
import CCodeCore
@testable import CCode

final class DiscardWorkflowTests: XCTestCase, @unchecked Sendable {
    @MainActor private func setup() async throws -> (AppStore, ChatSession, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-discard-workflow-\(UUID())")
        let project = root.appendingPathComponent("project"), data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await Repository.run(["init", "-b", "main"], at: project.path)
        for name in ["selected.txt", "other.txt"] { try "original\n".write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        _ = try await Repository.run(["add", "."], at: project.path)
        _ = try await Repository.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "Initial"], at: project.path)
        for name in ["selected.txt", "other.txt"] { try "working\n".write(to: project.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let store = AppStore(directory: data, claudeDirectory: root.appendingPathComponent("empty-claude"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "delivery", withExtension: "py", subdirectory: "Fixtures")!.path, "--no-steering"]
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: project.path, worktree: false)
        return (store, try XCTUnwrap(store.selected), project, data)
    }

    // Catches consuming the composer/editor draft or losing the durable recovery receipt.
    @MainActor func testExplicitPreviewApplyAndReloadPreserveDraftsHistoryAndUnselectedFiles() async throws {
        let (store, chat, project, _) = try await setup()
        chat.draft = "Keep this unsent follow-up"
        chat.fileDrafts["selected.txt"] = FileDraft(original: "working\n", text: "unsaved editor work\n")
        chat.transcript.items = [TranscriptItem(kind: "assistant", text: "Retain conversation")]
        let items = chat.transcript.items
        let preview = try await store.previewDiscardChanges(chat, paths: ["selected.txt"], scope: .working)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("selected.txt"), encoding: .utf8), "working\n")
        XCTAssertNil(chat.transcript.discards); XCTAssertNil(chat.connection)
        let result = try await store.discardChanges(chat, preview: preview)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("selected.txt"), encoding: .utf8), "original\n")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("other.txt"), encoding: .utf8), "working\n")
        XCTAssertEqual(chat.draft, "Keep this unsent follow-up")
        XCTAssertEqual(chat.fileDrafts["selected.txt"]?.text, "unsaved editor work\n")
        XCTAssertEqual(chat.transcript.items, items); XCTAssertNil(chat.connection)
        XCTAssertFalse(chat.restoringFiles); XCTAssertNil(chat.discardTask)
        let saved = try await store.storage.load(chat.id)
        XCTAssertEqual(saved.discards?.last?.id, result.id); XCTAssertEqual(saved.discards?.last?.status, .completed)
        let reopened = try ChatSession(id: chat.id, path: project.path, transcript: saved)
        XCTAssertEqual(reopened.draft, "Keep this unsent follow-up")
        XCTAssertEqual(reopened.fileDrafts["selected.txt"]?.text, "unsaved editor work\n")
        XCTAssertEqual(reopened.transcript.discards?.last?.status, .completed)
        let freshStore = AppStore(directory: project.deletingLastPathComponent().appendingPathComponent("data"), claudeDirectory: project.deletingLastPathComponent().appendingPathComponent("empty-claude"))
        addTeardownBlock { await freshStore.shutdown() }
        await freshStore.restore()
        let restored = try XCTUnwrap(freshStore.selected)
        XCTAssertEqual(restored.id, chat.id); XCTAssertEqual(restored.transcript.discards?.last?.id, preview.id)
        XCTAssertEqual(restored.draft, "Keep this unsent follow-up"); XCTAssertNil(restored.connection)
        await freshStore.shutdown()
        let recovery = try await Repository.discardRecoveryDirectory(result, at: project.path)
        XCTAssertEqual(try String(contentsOf: recovery.appendingPathComponent("working/selected.txt"), encoding: .utf8), "working\n")
    }

    // Catches wrong chat ownership, a busy sibling, or queued work bypassing the write reservation.
    @MainActor func testSharedRootAndForeignChatCannotDiscardDuringWork() async throws {
        let (store, chat, project, _) = try await setup()
        let preview = try await store.previewDiscardChanges(chat, paths: ["selected.txt"], scope: .all)
        await store.create(path: project.path, worktree: false)
        let other = try XCTUnwrap(store.selected)
        other.state = .running
        XCTAssertFalse(store.canDiscardChanges(chat))
        do { _ = try await store.discardChanges(chat, preview: preview); XCTFail("Busy sibling must refuse") } catch {}
        other.state = .idle
        other.pendingPrompts = [try PendingPrompt(text: "Queued mutation", attachments: [], policy: .nextTurn, executable: "/usr/bin/false", arguments: [], remoteID: nil)]
        other.deliveryPaused = true
        XCTAssertFalse(store.canDiscardChanges(chat))
        do { _ = try await store.previewDiscardChanges(chat, paths: ["selected.txt"], scope: .working); XCTFail("Queued sibling must refuse") } catch {}
        other.pendingPrompts = []
        let foreign = try ChatSession(id: chat.id, path: project.path, transcript: SessionTranscript())
        XCTAssertFalse(store.canDiscardChanges(foreign))
        do { _ = try await store.discardChanges(foreign, preview: preview); XCTFail("Unmanaged chat must refuse") } catch {}
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("selected.txt"), encoding: .utf8), "working\n")
        XCTAssertNil(chat.transcript.discards)
    }

    // Catches starting a destructive operation when its pre-mutation receipt cannot be saved.
    @MainActor func testPersistenceFailureRefusesBeforeAnyFileMutationAndReleasesReservation() async throws {
        let (store, chat, project, data) = try await setup()
        chat.draft = "Keep after save failure"
        let preview = try await store.previewDiscardChanges(chat, paths: ["selected.txt"], scope: .all)
        let file = data.appendingPathComponent("\(chat.id).json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { _ = try await store.discardChanges(chat, preview: preview); XCTFail("Disk-save failure must refuse") } catch {}
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("selected.txt"), encoding: .utf8), "working\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.recoveryDirectory))
        XCTAssertTrue(chat.transcript.discards?.isEmpty != false)
        XCTAssertEqual(chat.draft, "Keep after save failure")
        XCTAssertFalse(chat.restoringFiles); XCTAssertNil(chat.discardTask)
        try FileManager.default.removeItem(at: file)
        let retried = try await store.discardChanges(chat, preview: preview)
        XCTAssertEqual(retried.status, .completed, "A corrected storage failure may use the still-valid preview")
    }

    // Catches overwriting external edits and silently retrying a rejected operation.
    @MainActor func testStalePreviewRecordsRefusalAndInterruptedReceiptNeverReplays() async throws {
        let (store, chat, project, _) = try await setup()
        let preview = try await store.previewDiscardChanges(chat, paths: ["selected.txt"], scope: .working)
        try "external edit\n".write(to: project.appendingPathComponent("selected.txt"), atomically: true, encoding: .utf8)
        do { _ = try await store.discardChanges(chat, preview: preview); XCTFail("Stale preview must refuse") } catch {}
        XCTAssertEqual(chat.transcript.discards?.last?.status, .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.recoveryDirectory))
        let saved = try await store.storage.load(chat.id)
        XCTAssertEqual(saved.discards?.last?.status, .rejected)
        var interrupted = saved; interrupted.discards = [DiscardResult(preparing: preview)]
        let reopened = try ChatSession(id: UUID(), path: project.path, transcript: interrupted)
        XCTAssertEqual(reopened.transcript.discards?.last?.status, .uncertain)
        XCTAssertNil(reopened.discardTask); XCTAssertFalse(reopened.restoringFiles)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("selected.txt"), encoding: .utf8), "external edit\n")
    }

    // Catches shutdown/disconnect abandoning the operation, permitting a duplicate or leaving an index lock.
    @MainActor func testShutdownWaitsForOwnedDiscardAndDuplicateIsRefused() async throws {
        let (store, chat, project, _) = try await setup()
        let preview = try await store.previewDiscardChanges(chat, paths: ["selected.txt"], scope: .all)
        let operation = Task { try await store.discardChanges(chat, preview: preview) }
        let deadline = ContinuousClock.now + .seconds(3)
        while chat.discardTask == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(chat.discardTask); XCTAssertTrue(chat.restoringFiles)
        do { _ = try await store.discardChanges(chat, preview: preview); XCTFail("Duplicate must refuse") } catch {}
        await store.shutdown()
        let result = try await operation.value
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("selected.txt"), encoding: .utf8), "original\n")
        XCTAssertFalse(chat.restoringFiles); XCTAssertNil(chat.discardTask)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".git/index.lock").path))
        let saved = try await store.storage.load(chat.id)
        XCTAssertEqual(saved.discards?.count, 1); XCTAssertEqual(saved.discards?.first?.status, .completed)
    }

    // Catches trusting a persisted arbitrary path, another repository or a substituted recovery manifest.
    @MainActor func testRecoveryRequiresExactRepositoryDirectoryAndManifestIdentity() async throws {
        let (store, chat, project, data) = try await setup()
        let preview = try await store.previewDiscardChanges(chat, paths: ["selected.txt"], scope: .working)
        let result = try await store.discardChanges(chat, preview: preview)
        var forged = result; forged.recoveryDirectory = data.path
        do { _ = try await Repository.discardRecoveryDirectory(forged, at: project.path); XCTFail("Arbitrary directory") } catch {}
        do { _ = try await Repository.discardRecoveryDirectory(result, at: data.path); XCTFail("Foreign root") } catch {}
        var manifest = result; manifest.paths = ["other.txt"]
        let file = URL(fileURLWithPath: result.recoveryDirectory).appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: file, options: .atomic)
        do { _ = try await Repository.discardRecoveryDirectory(result, at: project.path); XCTFail("Substituted manifest") } catch {}
    }

    // Catches Command–Return or composer submission turning preview text into an agent prompt.
    @MainActor func testPreviewAndHistoryBlockPromptSubmissionWithoutConsumingDraft() async throws {
        let (store, chat, _, _) = try await setup()
        chat.draft = "Do not submit this while inspecting changes"
        let preview = try await store.previewDiscardChanges(chat, paths: ["selected.txt"], scope: .working)
        XCTAssertTrue(store.canSendPromptCommand)
        store.discardPreviewRequest = DiscardPreviewRequest(chat: chat, preview: preview)
        XCTAssertFalse(store.canSendPromptCommand)
        store.send(chat)
        XCTAssertNil(chat.connection); XCTAssertTrue(chat.pendingPrompts.isEmpty)
        XCTAssertEqual(chat.draft, "Do not submit this while inspecting changes")
        chat.restoringFiles = true
        store.closeDiscardPreview()
        XCTAssertNotNil(store.discardPreviewRequest, "Escape cannot dismiss an in-flight file operation")
        chat.restoringFiles = false
        store.closeDiscardPreview()
        XCTAssertNil(store.discardPreviewRequest); XCTAssertTrue(store.canSendPromptCommand)
        store.discardHistoryRequest = DiscardHistoryRequest(chat: chat)
        XCTAssertFalse(store.canSendPromptCommand); store.send(chat)
        XCTAssertTrue(chat.pendingPrompts.isEmpty); XCTAssertNil(chat.connection)
        XCTAssertEqual(chat.draft, "Do not submit this while inspecting changes")
        store.discardHistoryRequest = nil
    }

    // Catches new sessions bypassing an existing write reservation and premature queue delivery.
    @MainActor func testNewChatQueuesUntilActualGitDiscardSettles() async throws {
        let (store, chat, project, _) = try await setup()
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "delivery", withExtension: "py", subdirectory: "Fixtures")!.path, "--no-steering"]
        let marker = project.appendingPathComponent("filter-entered"), release = project.appendingPathComponent("filter-release")
        let filter = project.appendingPathComponent("hold-filter.py")
        try """
        import pathlib, sys, time
        pathlib.Path(sys.argv[1]).write_text('entered')
        deadline = time.monotonic() + 15
        while not pathlib.Path(sys.argv[2]).exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        sys.stdout.buffer.write(sys.stdin.buffer.read())
        """.write(to: filter, atomically: true, encoding: .utf8)
        try "selected.txt filter=qa-hold\n".write(to: project.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = (["/usr/bin/python3", filter.path, marker.path, release.path]).map(quote).joined(separator: " ")
        _ = try await Repository.run(["config", "filter.qa-hold.smudge", command], at: project.path)
        defer { try? Data().write(to: release) }
        let preview = try await store.previewDiscardChanges(chat, paths: ["selected.txt"], scope: .working)
        let operation = Task { try await store.discardChanges(chat, preview: preview) }
        let deadline = ContinuousClock.now + .seconds(4)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Actual checkout-index must enter the repository filter")
        await store.create(path: project.path, worktree: false)
        let newcomer = try XCTUnwrap(store.selected)
        XCTAssertTrue(store.checkpointRestorationBlocks(newcomer))
        store.send(newcomer, text: "After the actual discard finishes")
        XCTAssertEqual(newcomer.pendingPrompts.count, 1); XCTAssertNil(newcomer.connection)
        try Data().write(to: release)
        let result = try await operation.value
        XCTAssertEqual(result.status, .completed)
        let finished = ContinuousClock.now + .seconds(4)
        while newcomer.busy || !newcomer.pendingPrompts.isEmpty, ContinuousClock.now < finished { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(newcomer.state, .ready, newcomer.lastError ?? "Queued work did not resume")
        XCTAssertTrue(newcomer.pendingPrompts.isEmpty)
        let peer = try XCTUnwrap(newcomer.connection)
        let state = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(state["prompts"].array.count, 1)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("selected.txt"), encoding: .utf8), "original\n")
    }

    // Catches oversized native sheets and compressed/wrapping action bars at supported compact widths.
    @MainActor func testNativeDiscardSheetsFitInLightAndDarkWithoutUnboundedContent() async throws {
        let (store, chat, _, _) = try await setup()
        let preview = try await store.previewDiscardChanges(chat, paths: ["selected.txt"], scope: .all)
        chat.transcript.discards = [DiscardResult(preparing: preview)]
        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(rootView: DiscardPreviewView(store: store, request: DiscardPreviewRequest(chat: chat, preview: preview)).environment(\.colorScheme, scheme))
            XCTAssertGreaterThan(view.fittingSize.height, 300)
            XCTAssertLessThanOrEqual(view.fittingSize.width, 660); XCTAssertLessThanOrEqual(view.fittingSize.height, 600)
            let history = NSHostingView(rootView: DiscardHistoryView(store: store, request: DiscardHistoryRequest(chat: chat)).environment(\.colorScheme, scheme))
            XCTAssertLessThanOrEqual(history.fittingSize.width, 660); XCTAssertLessThanOrEqual(history.fittingSize.height, 500)
        }
    }
    // Catches treating a rename's implicit original path as a separately selected dirty file during Refresh.
    @MainActor func testRenameRefreshRetainsSelectionAndUsesFreshContents() async throws {
        let (store, chat, project, _) = try await setup()
        _ = try await Repository.run(["mv", "selected.txt", "renamed.txt"], at: project.path)
        let preview = try await store.previewDiscardChanges(chat, paths: ["renamed.txt"], scope: .all)
        XCTAssertEqual(Set(preview.paths), Set(["renamed.txt", "selected.txt"]))
        try "fresh working\n".write(to: project.appendingPathComponent("renamed.txt"), atomically: true, encoding: .utf8)
        let refreshed = try await store.refreshDiscardPreview(chat, preview: preview)
        XCTAssertEqual(Set(refreshed.paths), Set(["renamed.txt", "selected.txt"]))
        XCTAssertNotEqual(refreshed.id, preview.id); XCTAssertTrue(refreshed.diff.contains("fresh working"))
        let result = try await store.discardChanges(chat, preview: refreshed)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("selected.txt"), encoding: .utf8), "original\n")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: result.recoveryDirectory).appendingPathComponent("working/renamed.txt"), encoding: .utf8), "fresh working\n")
    }
    // Catches a repository filter stranding a non-dismissible discard after the user presses Stop.
    @MainActor func testStopCancelsOwnedGitFilterWithoutDiscardingFilesOrLeavingRecoveryLock() async throws {
        let (store, chat, project, _) = try await setup()
        let marker = project.appendingPathComponent("stopped-filter-pid"), release = project.appendingPathComponent("stopped-filter-release")
        let filter = project.appendingPathComponent("stopped-filter.py")
        try """
        import pathlib, sys, time, os
        pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
        deadline = time.monotonic() + 15
        while not pathlib.Path(sys.argv[2]).exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        sys.stdout.buffer.write(sys.stdin.buffer.read())
        """.write(to: filter, atomically: true, encoding: .utf8)
        try "selected.txt filter=qa-stop\n".write(to: project.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        _ = try await Repository.run(["config", "filter.qa-stop.smudge", ["/usr/bin/python3", filter.path, marker.path, release.path].map(quote).joined(separator: " ")], at: project.path)
        defer { try? Data().write(to: release) }
        let preview = try await store.previewDiscardChanges(chat, paths: ["selected.txt"], scope: .all)
        chat.draft = "Keep after stopping discard"
        let operation = Task { try await store.discardChanges(chat, preview: preview) }
        let deadline = ContinuousClock.now + .seconds(4)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: marker, encoding: .utf8)))
        store.stop(chat)
        do { _ = try await operation.value; XCTFail("Stop must cancel a pre-mutation filter") } catch {}
        XCTAssertEqual(kill(pid, 0), -1, "Owned Git filter must be gone when the operation settles")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("selected.txt"), encoding: .utf8), "working\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(".git/index.lock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.recoveryDirectory))
        XCTAssertEqual(chat.transcript.discards?.last?.status, .rejected)
        XCTAssertEqual(chat.draft, "Keep after stopping discard")
        XCTAssertFalse(chat.restoringFiles); XCTAssertNil(chat.discardTask)
    }
}
