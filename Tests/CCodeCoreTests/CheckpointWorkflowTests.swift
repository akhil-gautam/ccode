import XCTest
import AppKit
import SwiftUI
import CCodeCore
@testable import CCode

final class CheckpointWorkflowTests: XCTestCase {
    @MainActor func testRealAppStorePreviewUsesActualPromptCheckpointAndPreservesApprovedWrite() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else {
            throw XCTSkip("Set CCODE_REAL_AGENT to the authenticated pinned ACP executable.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-preview-\(UUID())")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("checkpoint.txt"), sentinel = project.appendingPathComponent("unrelated.txt")
        try Data("original\n".utf8).write(to: file); try Data("keep unrelated\n".utf8).write(to: sentinel)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: project.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        XCTAssertTrue(FileCheckpointReference.validCapability(store.fileCheckpointCapability(chat)))
        for category in ["model", "mode"] {
            let config = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"].string == category })
            let options = config["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }
            let option = try XCTUnwrap(options.first { category == "model" ? $0["name"].string.localizedCaseInsensitiveContains("sonnet") : $0["value"] == "default" })
            await store.setConfig(chat, id: config["id"].string, value: option["value"])
        }
        store.send(chat, text: "Use Read on checkpoint.txt, then Write exactly once to replace its entire content with after-checkpoint followed by a newline. No commands, agents, skills, network or other files. Reply done and finish.")
        let deadline = ContinuousClock.now + .seconds(120)
        var approvedWrite = false
        while chat.busy, ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let tool = approval.toolCall, name = PermissionPresentation(tool: tool).toolName
                let target = tool["rawInput"]["file_path"].string
                let canonicalTarget = target.hasPrefix("/") ? URL(fileURLWithPath: target).resolvingSymlinksInPath().path : target
                let allowed = ["Read", "Write"].contains(name) && (target == "checkpoint.txt" || canonicalTarget == file.resolvingSymlinksInPath().path)
                    && (name != "Write" || tool["rawInput"]["content"] == "after-checkpoint\n")
                guard allowed else {
                    store.resolveApproval(chat, id: approval.id, option: nil)
                    throw ACPError.workspace("Unexpected real checkpoint tool: \(name)")
                }
                if name == "Write" { approvedWrite = true }
                let option = try XCTUnwrap(approval.request["options"].array.first { $0["kind"] == "allow_once" })
                store.resolveApproval(chat, id: approval.id, option: option["optionId"].optionalString)
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertFalse(chat.busy, chat.lastError ?? "Agent did not finish")
        XCTAssertEqual(chat.state, .ready); XCTAssertTrue(approvedWrite)
        let user = try XCTUnwrap(chat.transcript.items.first { $0.kind == "user" })
        let reference = try XCTUnwrap(user.fileCheckpoint)
        XCTAssertEqual(reference.promptID, user.id)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after-checkpoint\n")
        chat.draft = "Preserve unsent follow-up"
        let history = chat.transcript.items, peer = chat.connection
        let preview = try await store.previewFileCheckpoint(chat, at: user.id)
        XCTAssertTrue(preview.canRewind)
        XCTAssertTrue(preview.paths.contains {
            let url = $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : project.appendingPathComponent($0)
            return url.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path
        })
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after-checkpoint\n")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep unrelated\n")
        XCTAssertEqual(chat.transcript.items, history); XCTAssertEqual(chat.draft, "Preserve unsent follow-up")
        XCTAssertTrue(chat.connection === peer)
        XCTAssertTrue(store.canRestoreFileCheckpoint(chat, preview: preview))
        try Data("external work after preview\n".utf8).write(to: file)
        let rejectedValue = await store.restoreFileCheckpoint(chat, preview: preview)
        let rejected = try XCTUnwrap(rejectedValue)
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "external work after preview\n")
        let refreshed = try await store.previewFileCheckpoint(chat, at: user.id)
        let restoreValue = await store.restoreFileCheckpoint(chat, preview: refreshed)
        let restored = try XCTUnwrap(restoreValue)
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original\n")
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep unrelated\n")
        XCTAssertEqual(chat.transcript.items, history); XCTAssertEqual(chat.draft, "Preserve unsent follow-up")
        XCTAssertTrue(chat.connection === peer)
        let recovery = URL(fileURLWithPath: try XCTUnwrap(restored.recoveryDirectory))
        XCTAssertEqual(try String(contentsOf: recovery.appendingPathComponent("0.before"), encoding: .utf8), "external work after preview\n")
        let saved = try await store.storage.load(chat.id)
        XCTAssertEqual(saved.fileRestorations?.last?.status, .completed)
        print("Actual AppStore checkpoint: approved Write, exact identity/read-only preview, external conflict refusal, refreshed file restoration and disk recovery verified. Conversation/draft/parent connection preserved. Native UI acceptance is separate.")
    }
    @MainActor private func setup(_ arguments: [String] = []) async throws -> (AppStore, ChatSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-checkpoint-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("answer.py")
        try Data("preserve working file\n".utf8).write(to: file)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "checkpoints", withExtension: "py", subdirectory: "Fixtures")!.path] + arguments
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: project.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        store.send(chat, text: "Fixture work")
        let deadline = ContinuousClock.now + .seconds(4)
        while chat.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(chat.state, .ready, chat.lastError ?? "Agent did not finish")
        return (store, chat, file)
    }
    @MainActor func testSubmittedReceiptPreviewAndRestartPreserveFilesDraftAndProviderOwnership() async throws {
        let (store, chat, file) = try await setup()
        let user = try XCTUnwrap(chat.transcript.items.first { $0.kind == "user" })
        let reference = try XCTUnwrap(user.fileCheckpoint)
        XCTAssertEqual(reference.promptID, user.id)
        XCTAssertTrue(store.canPreviewFileCheckpoint(chat, at: user.id))
        let state = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertEqual(state["submissions"].array, [.string(user.id.uuidString)])
        chat.draft = "Preserve unsent draft"
        let before = try Data(contentsOf: file), items = chat.transcript.items
        let preview = try await store.previewFileCheckpoint(chat, at: user.id)
        XCTAssertEqual(preview.paths, ["answer.py"]); XCTAssertEqual(preview.insertions, 2)
        XCTAssertEqual(try Data(contentsOf: file), before); XCTAssertEqual(chat.transcript.items, items)
        XCTAssertEqual(chat.draft, "Preserve unsent draft"); XCTAssertEqual(chat.state, .ready)
        let saved = try await store.storage.load(chat.id)
        XCTAssertEqual(saved.items.first { $0.id == user.id }?.fileCheckpoint, reference)
        await store.disconnect(chat)
        XCTAssertFalse(store.canPreviewFileCheckpoint(chat, at: user.id))
        try await store.connect(chat)
        XCTAssertFalse(store.canPreviewFileCheckpoint(chat, at: user.id), "New query requires new evidence; saved connection ID is not authority")
        XCTAssertEqual(chat.transcript.items.first { $0.id == user.id }?.fileCheckpoint, reference)
        XCTAssertEqual(chat.draft, "Preserve unsent draft")
    }
    @MainActor func testRestoreOwnsWorkUntilSettledAndPersistsWithoutChangingConversationOrDrafts() async throws {
        let (store, chat, file) = try await setup(["--restoration", "--slow-restore"])
        let user = try XCTUnwrap(chat.transcript.items.first { $0.kind == "user" })
        let preview = try await store.previewFileCheckpoint(chat, at: user.id)
        XCTAssertTrue(store.canRestoreFileCheckpoint(chat, preview: preview))
        chat.draft = "Keep unsent draft"
        chat.fileDrafts["answer.py"] = FileDraft(original: "preserve working file\n", text: "unsaved editor work")
        let before = try Data(contentsOf: file), history = chat.transcript.items
        let task = Task { await store.restoreFileCheckpoint(chat, preview: preview) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !chat.restoringFiles, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(chat.busy); XCTAssertFalse(store.canRestoreFileCheckpoint(chat, preview: preview))
        let duplicate = await store.restoreFileCheckpoint(chat, preview: preview)
        XCTAssertNil(duplicate)
        let disconnect = Task { await store.disconnect(chat) }
        let restoreValue = await task.value
        let restored = try XCTUnwrap(restoreValue)
        await disconnect.value
        XCTAssertEqual(restored.status, .completed); XCTAssertFalse(chat.restoringFiles)
        XCTAssertEqual(chat.transcript.items, history); XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(chat.draft, "Keep unsent draft"); XCTAssertEqual(chat.fileDrafts["answer.py"]?.text, "unsaved editor work")
        let saved = try await store.storage.load(chat.id)
        XCTAssertEqual(saved.fileRestorations?.last?.id, restored.id); XCTAssertEqual(saved.fileRestorations?.last?.status, .completed)
    }
    @MainActor func testMalformedRestoreBecomesUncertainAndInterruptedRecordsNeverReplay() async throws {
        let (store, chat, _) = try await setup(["--restoration", "--bad-restore"])
        let user = try XCTUnwrap(chat.transcript.items.first { $0.kind == "user" })
        let preview = try await store.previewFileCheckpoint(chat, at: user.id)
        let restoreValue = await store.restoreFileCheckpoint(chat, preview: preview)
        let result = try XCTUnwrap(restoreValue)
        XCTAssertEqual(result.status, .uncertain)
        var transcript = chat.transcript
        transcript.fileRestorations = [FileCheckpointRestoration(reference: try XCTUnwrap(user.fileCheckpoint))]
        let reopened = try ChatSession(id: UUID(), path: chat.workspace.root, transcript: transcript)
        XCTAssertEqual(reopened.transcript.fileRestorations?.first?.status, .uncertain)
        XCTAssertFalse(reopened.restoringFiles); XCTAssertNil(reopened.fileRestoreTask)
    }
    @MainActor func testSessionCreatedDuringRestoreQueuesItsWorkUntilTheActualRestoreResponse() async throws {
        let (store, chat, _) = try await setup(["--restoration", "--held-restore"])
        let user = try XCTUnwrap(chat.transcript.items.first { $0.kind == "user" })
        let preview = try await store.previewFileCheckpoint(chat, at: user.id)
        let peer = try XCTUnwrap(chat.connection)
        addTeardownBlock { _ = try? await peer.request("fixture/release-restore", params: [:], timeout: .seconds(1)) }
        let restore = Task { await store.restoreFileCheckpoint(chat, preview: preview) }
        var entered = false
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered, ContinuousClock.now < deadline {
            entered = try await peer.request("fixture/state", params: [:])["restores"] == 1
            if !entered { await Task.yield() }
        }
        XCTAssertTrue(entered)
        await store.create(path: chat.workspace.root, worktree: false)
        let newcomer = try XCTUnwrap(store.selected)
        XCTAssertNotEqual(newcomer.id, chat.id)
        XCTAssertTrue(store.checkpointRestorationBlocks(newcomer))
        store.send(newcomer, text: "Wait until restoration settles")
        XCTAssertEqual(newcomer.pendingPrompts.count, 1); XCTAssertNil(newcomer.connection)
        _ = try await peer.request("fixture/release-restore", params: [:])
        let value = await restore.value
        XCTAssertEqual(value?.status, .completed)
        let finished = ContinuousClock.now + .seconds(3)
        while newcomer.busy || !newcomer.pendingPrompts.isEmpty, ContinuousClock.now < finished { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(newcomer.state, .ready); XCTAssertTrue(newcomer.pendingPrompts.isEmpty)
        XCTAssertTrue(newcomer.transcript.items.contains { $0.kind == "user" && $0.text == "Wait until restoration settles" })
    }
    @MainActor func testUnavailableBusyAndUnknownContractsNeverSubmitPreview() async throws {
        let (store, chat, _) = try await setup()
        let item = try XCTUnwrap(chat.transcript.items.first { $0.kind == "user" })
        XCTAssertFalse(store.canPreviewFileCheckpoint(chat, at: UUID()))
        chat.state = .running
        XCTAssertFalse(store.canPreviewFileCheckpoint(chat, at: item.id)); chat.state = .ready
        chat.handshake["_meta"]["ccode"]["fileCheckpoints"]["version"] = 2
        XCTAssertFalse(store.canPreviewFileCheckpoint(chat, at: item.id))
        do { _ = try await store.previewFileCheckpoint(chat, at: item.id); XCTFail("Unknown contract") } catch {}
        let state = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertEqual(state["previews"], 0)
        let (_, unsupported, _) = try await setup(["--no-checkpoints"])
        XCTAssertNil(unsupported.transcript.items.first { $0.kind == "user" }?.fileCheckpoint)
        let unsupportedState = try await XCTUnwrap(unsupported.connection).request("fixture/state", params: [:])
        XCTAssertEqual(unsupportedState["submissions"].array, [.null], "Ordinary ACP agents receive no private prompt metadata")
    }
    @MainActor func testForeignPreviewResponseIsRejectedWithoutChangingHistoryOrFiles() async throws {
        let (store, chat, file) = try await setup(["--bad-preview"])
        let item = try XCTUnwrap(chat.transcript.items.first { $0.kind == "user" })
        let before = try Data(contentsOf: file), history = chat.transcript.items
        do { _ = try await store.previewFileCheckpoint(chat, at: item.id); XCTFail("Foreign response") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), before); XCTAssertEqual(chat.transcript.items, history)
    }
    @MainActor func testPreviewSheetFitsLightDarkWithoutWrappingActionLabels() async throws {
        let (store, chat, _) = try await setup()
        let item = try XCTUnwrap(chat.transcript.items.first { $0.kind == "user" })
        let request = FileCheckpointPreviewRequest(chat: chat, itemID: item.id)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: FileCheckpointPreviewView(store: store, request: request))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 430)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.height, 500)
            XCTAssertLessThanOrEqual(host.fittingSize.width, 600)
            let history = NSHostingView(rootView: FileRestorationHistoryView(store: store, request: FileRestorationHistoryRequest(chat: chat)))
            history.appearance = NSAppearance(named: appearance); history.frame = NSRect(x: 0, y: 0, width: 560, height: 400)
            history.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(history.fittingSize.width, 600); XCTAssertLessThanOrEqual(history.fittingSize.height, 450)
        }
    }
}
