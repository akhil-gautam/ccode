import XCTest
import Darwin
import CCodeCore
@testable import CCode

final class MultiRepositoryWorkflowTests: XCTestCase, @unchecked Sendable {
    // Catches returning cached clean text after an agent, Git checkout or external editor changes the same file.
    @MainActor func testReopeningFileRefreshesCleanTextAndPreservesDirtyConflict() async throws {
        let (store, chat, primary, _, _) = try await setup()
        try await store.openWorkspaceReference(chat, reference: "same.txt")
        try "new first\nnew second\n".write(to: primary.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try await store.openWorkspaceReference(chat, reference: "same.txt#L2")
        XCTAssertEqual(chat.fileDrafts["same.txt"]?.text, "new first\nnew second\n")
        XCTAssertEqual(chat.editorSelection, NSRange(location: 10, length: 10))
        chat.fileDrafts["same.txt"]?.text = "unsaved mine\n"
        try "external again\n".write(to: primary.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try await store.openWorkspaceReference(chat, reference: "same.txt")
        XCTAssertEqual(chat.fileDrafts["same.txt"]?.text, "unsaved mine\n")
        do { try await store.saveWorkspaceFile(chat, key: "same.txt"); XCTFail("External changes overwritten") } catch {}
        XCTAssertEqual(try String(contentsOf: primary.appendingPathComponent("same.txt"), encoding: .utf8), "external again\n")
    }
    // Catches saved editor metadata following a file symlink outside the workspace on restart.
    @MainActor func testRestoredEditorRejectsReboundLeafAndForeignFolder() async throws {
        let (_, chat, primary, extra, foreign) = try await setup()
        try FileManager.default.createSymbolicLink(atPath: primary.appendingPathComponent("link.txt").path, withDestinationPath: foreign.appendingPathComponent("same.txt").path)
        var saved = chat.transcript; saved.selectedEditorFile = "link.txt"; saved.editorFolder = foreign.path
        let reopened = try ChatSession(id: UUID(), path: primary.path, transcript: saved, additionalDirectories: [extra.path])
        XCTAssertNil(reopened.selectedEditorFile); XCTAssertNil(reopened.editorFolder)
    }
    // Catches file links redirecting to a browsed root, replacing dirty drafts or losing the selected editor on restart.
    @MainActor func testConversationFileNavigationPreservesDraftsAndRestoresEditor() async throws {
        let (store, chat, primary, extra, _) = try await setup()
        chat.draft = "Unsent composer"
        chat.fileDrafts["same.txt"] = FileDraft(original: "working primary\n", text: "edited primary\nsecond line\n")
        try await store.openWorkspaceReference(chat, reference: extra.appendingPathComponent("same.txt").absoluteString + "#L2")
        XCTAssertEqual(chat.workspaceDirectory, extra.path)
        XCTAssertEqual(chat.selectedEditorFile, extra.appendingPathComponent("same.txt").path)
        XCTAssertEqual(chat.editorSelection, NSRange(location: 10, length: 9))
        XCTAssertEqual(store.pane, "files")
        try await store.openWorkspaceReference(chat, reference: "same.txt:2")
        XCTAssertEqual(chat.workspaceDirectory, primary.path); XCTAssertEqual(chat.workspace.root, primary.path)
        XCTAssertEqual(chat.selectedEditorFile, "same.txt")
        XCTAssertEqual(chat.editorSelection, NSRange(location: 15, length: 11))
        XCTAssertEqual(chat.fileDrafts["same.txt"]?.text, "edited primary\nsecond line\n")
        XCTAssertEqual(chat.draft, "Unsent composer")
        let saved = try await store.storage.load(chat.id)
        let reopened = try ChatSession(id: chat.id, path: primary.path, transcript: saved, additionalDirectories: [extra.path])
        XCTAssertEqual(reopened.selectedEditorFile, "same.txt"); XCTAssertEqual(reopened.fileDrafts["same.txt"]?.text, "edited primary\nsecond line\n")
    }

    // Catches rejected locations or disk-save failure publishing an empty editor and discarding the prior selection.
    @MainActor func testFailedFileNavigationPreservesEditorFolderSelectionAndComposer() async throws {
        let (store, chat, _, extra, foreign) = try await setup()
        try await store.openWorkspaceReference(chat, reference: "same.txt")
        chat.draft = "Keep failed navigation"; store.pane = "diff"
        for raw in ["missing.txt", foreign.appendingPathComponent("same.txt").path, extra.appendingPathComponent("same.txt").path + ":99"] {
            do { try await store.openWorkspaceReference(chat, reference: raw); XCTFail("Invalid reference opened") } catch {}
            XCTAssertEqual(chat.selectedEditorFile, "same.txt"); XCTAssertEqual(store.pane, "diff")
        }
        let data = await store.storage.directory, saved = data.appendingPathComponent("\(chat.id).json")
        try FileManager.default.removeItem(at: saved); try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: false)
        do { try await store.openWorkspaceReference(chat, reference: extra.appendingPathComponent("same.txt").path); XCTFail("Failed save published selection") } catch {}
        XCTAssertEqual(chat.workspaceDirectory, chat.workspace.root); XCTAssertEqual(chat.selectedEditorFile, "same.txt")
        XCTAssertNil(chat.fileDrafts[extra.appendingPathComponent("same.txt").path]); XCTAssertFalse(chat.selectingWorkspaceFolder)
        XCTAssertEqual(chat.draft, "Keep failed navigation"); XCTAssertEqual(store.pane, "diff")
        try FileManager.default.removeItem(at: saved)
    }

    // Catches folder links pretending to be text files or file context being attached from the wrong same-name root.
    @MainActor func testFolderBrowseAndFileAttachmentUseResolvedWorkspaceIdentity() async throws {
        let (store, chat, _, extra, _) = try await setup()
        try await store.openWorkspaceReference(chat, reference: extra.path)
        XCTAssertEqual(chat.workspaceDirectory, extra.path); XCTAssertNil(chat.selectedEditorFile)
        XCTAssertEqual(chat.editorFolder, extra.path); XCTAssertEqual(store.pane, "files")
        let reference = try await chat.workspace.fileReference(extra.appendingPathComponent("same.txt").path)
        let attached = await store.attachContext(reference.candidate, to: chat)
        XCTAssertTrue(attached)
        let attachment = try XCTUnwrap(chat.attachments.first)
        XCTAssertEqual(attachment.context?.root, extra.path); XCTAssertEqual(attachment.context?.path, extra.appendingPathComponent("same.txt").path)
        let snapshot = store.storage.attachmentURL(attachment)
        XCTAssertEqual(try String(contentsOf: snapshot, encoding: .utf8), "extra one\nextra two\n")
    }

    // Catches terminal-here launching at the repository root instead of the chosen file's parent.
    @MainActor func testTerminalHereUsesNestedDirectoryAndRejectsForeignDirectory() async throws {
        let (store, chat, _, extra, foreign) = try await setup()
        let nested = extra.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let marker = nested.appendingPathComponent("cwd.txt")
        let tab = try await store.openWorkspaceTerminal(chat, directory: nested.path)
        for _ in 0..<200 { if tab.ready || tab.ended { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(tab.ready, tab.failure ?? "No shell")
        let command = Array(("/bin/pwd > '" + marker.path + "'\r").utf8); tab.send(source: tab.view, data: command[...])
        for _ in 0..<200 { if FileManager.default.fileExists(atPath: marker.path) { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), nested.path + "\n")
        do { _ = try await store.openWorkspaceTerminal(chat, directory: foreign.path); XCTFail("Foreign terminal") } catch {}
        XCTAssertEqual(chat.terminalTabs.count, 1)
        await tab.close(); chat.terminalTabs.removeAll(); chat.activeTerminalID = nil
    }

    @MainActor private func setup() async throws -> (AppStore, ChatSession, URL, URL, URL) {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw ACPError.workspace("Cannot resolve test directory") }; defer { free(resolved) }
        let base = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("ccode-multi-repository-\(UUID())")
        let primary = base.appendingPathComponent("primary"), extra = base.appendingPathComponent("extra"), foreign = base.appendingPathComponent("foreign")
        for (folder, branch, original) in [(primary, "main", "original primary\n"), (extra, "library", "original extra\n"), (foreign, "other", "foreign\n")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try await Repository.run(["init", "-b", branch], at: folder.path)
            _ = try await Repository.run(["config", "user.name", "QA"], at: folder.path)
            _ = try await Repository.run(["config", "user.email", "qa@example.invalid"], at: folder.path)
            try original.write(to: folder.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
            _ = try await Repository.run(["add", "."], at: folder.path)
            _ = try await Repository.run(["commit", "-m", "Initial"], at: folder.path)
        }
        try "working primary\n".write(to: primary.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try "extra one\nextra two\n".write(to: extra.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        // Directory-routing tests own an empty shell configuration; user themes can consume early input.
        var terminalEnvironment = AgentSettings.environment; terminalEnvironment["ZDOTDIR"] = base.path
        let store = AppStore(directory: base.appendingPathComponent("data"), claudeDirectory: base.appendingPathComponent("empty-claude"), terminalEnvironment: terminalEnvironment)
        store.settings.executable = "/usr/bin/false"; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: base) }
        await store.create(path: primary.path, worktree: false, additionalDirectories: [extra.path])
        return (store, try XCTUnwrap(store.selected), primary, extra, foreign)
    }

    // Catches the selected additional folder still publishing primary repository status/counts, or resetting on restart.
    @MainActor func testFolderSelectionPublishesItsRepositoryAndPersistsWithoutChangingAgentCwd() async throws {
        let (store, chat, primary, extra, _) = try await setup()
        chat.draft = "Keep composer text"
        chat.fileDrafts["same.txt"] = FileDraft(original: "working primary\n", text: "unsaved primary\n")
        try await store.selectWorkspaceFolder(chat, path: extra.path)
        XCTAssertEqual(chat.workspaceDirectory, extra.path)
        XCTAssertEqual(chat.repository.branch, "library")
        await chat.workspaceStatisticsTask?.value
        XCTAssertEqual(chat.changeStatistics?["same.txt"]?.additions, 2)
        XCTAssertEqual(chat.changeStatistics?["same.txt"]?.deletions, 1)
        XCTAssertEqual(chat.workspace.root, primary.path, "Folder browsing must not rebind the agent's working directory")
        XCTAssertEqual(chat.draft, "Keep composer text"); XCTAssertEqual(chat.fileDrafts["same.txt"]?.text, "unsaved primary\n")
        XCTAssertNil(chat.connection)
        let saved = try await store.storage.load(chat.id)
        let reopened = try ChatSession(id: chat.id, path: primary.path, transcript: saved, additionalDirectories: [extra.path])
        XCTAssertEqual(reopened.workspaceDirectory, extra.path)
        XCTAssertEqual(reopened.draft, "Keep composer text")
    }

    // Catches a same-named file being staged/committed in the primary repository instead of the selected additional one.
    @MainActor func testStageCommitAndDiscardTargetSelectedRepositoryOnly() async throws {
        let (store, chat, primary, extra, _) = try await setup()
        let primaryHead = try await Repository.run(["rev-parse", "HEAD"], at: primary.path)
        try await store.selectWorkspaceFolder(chat, path: extra.path)
        try await store.stageWorkspaceFile(chat, path: "same.txt")
        let primaryStatus = try await Repository.status(at: primary.path), extraStatus = try await Repository.status(at: extra.path)
        XCTAssertFalse(primaryStatus.files[0].staged); XCTAssertTrue(extraStatus.files[0].staged)
        try await store.commitWorkspaceChanges(chat, message: "Only selected additional repository")
        let primaryAfter = try await Repository.run(["rev-parse", "HEAD"], at: primary.path)
        let extraMessage = try await Repository.run(["log", "-1", "--format=%s"], at: extra.path)
        XCTAssertEqual(primaryAfter, primaryHead); XCTAssertEqual(extraMessage, "Only selected additional repository\n")
        try "later extra\n".write(to: extra.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        let preview = try await store.previewDiscardChanges(chat, paths: ["same.txt"], scope: .working)
        XCTAssertEqual(preview.root, extra.path)
        let result = try await store.discardChanges(chat, preview: preview)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try String(contentsOf: extra.appendingPathComponent("same.txt"), encoding: .utf8), "extra one\nextra two\n")
        XCTAssertEqual(try String(contentsOf: primary.appendingPathComponent("same.txt"), encoding: .utf8), "working primary\n")
    }

    // Catches arbitrary/foreign roots, escaped paths, or a busy workspace being allowed to mutate.
    @MainActor func testForeignFolderAndEscapedFileRefuseWithoutLosingSelectionOrDraft() async throws {
        let (store, chat, primary, extra, foreign) = try await setup()
        try await store.selectWorkspaceFolder(chat, path: extra.path)
        chat.draft = "Keep after refusal"
        do { try await store.selectWorkspaceFolder(chat, path: foreign.path); XCTFail("Undeclared folder") } catch {}
        do { try await store.stageWorkspaceFile(chat, path: "../primary/same.txt"); XCTFail("Escaped file") } catch {}
        chat.state = .running
        do { try await store.stageWorkspaceFile(chat, path: "same.txt"); XCTFail("Busy workspace") } catch {}
        chat.state = .idle
        XCTAssertEqual(chat.workspaceDirectory, extra.path)
        XCTAssertEqual(chat.draft, "Keep after refusal")
        let status = try await Repository.status(at: primary.path)
        XCTAssertFalse(status.files[0].staged)
        XCTAssertEqual(try String(contentsOf: foreign.appendingPathComponent("same.txt"), encoding: .utf8), "foreign\n")
    }
    // Catches displayed folder changes rewriting a captured comment's repository or preventing delivery validation.
    @MainActor func testReviewContextRetainsItsRepositoryAfterFolderSwitch() async throws {
        let (store, chat, primary, extra, _) = try await setup()
        try await store.selectWorkspaceFolder(chat, path: extra.path)
        let diff = try await Repository.diff(at: extra.path, path: "same.txt")
        let head = try await Repository.run(["rev-parse", "HEAD"], at: extra.path).trimmingCharacters(in: .whitespacesAndNewlines)
        try await store.addReviewComment(chat, path: "same.txt", diff: diff, baseRevision: head, stagedOnly: false, line: nil, text: "Feedback for extra only")
        let comment = try XCTUnwrap(chat.reviewComments.first)
        XCTAssertEqual(comment.root, extra.path)
        try await store.selectWorkspaceFolder(chat, path: primary.path)
        let primaryDiff = try await Repository.diff(at: primary.path, path: "same.txt")
        let primaryHead = try await Repository.run(["rev-parse", "HEAD"], at: primary.path).trimmingCharacters(in: .whitespacesAndNewlines)
        do { try await store.rebindReviewComment(chat, id: comment.id, path: "same.txt", diff: primaryDiff, baseRevision: primaryHead, stagedOnly: false, line: nil); XCTFail("Wrong-root rebind") } catch {}
        XCTAssertEqual(chat.reviewComments, [comment])
        var queued = try PendingPrompt(text: ReviewComment.prompt([comment]), attachments: [], policy: .nextTurn, executable: "/usr/bin/false", arguments: [], remoteID: nil)
        queued.reviewContexts = [comment]; chat.pendingPrompts = [queued]; chat.deliveryPaused = true
        try await store.validateReviewFeedbackPrompt(chat, id: queued.id, text: queued.text)
        XCTAssertEqual(chat.workspaceDirectory, primary.path)
        try "externally changed extra\n".write(to: extra.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        do { try await store.validateReviewFeedbackPrompt(chat, id: queued.id, text: queued.text); XCTFail("Stale extra context") } catch {}
    }

    // Catches code review validation being redirected by the currently displayed folder.
    @MainActor func testCodeReviewRequestIsBoundToSelectedRootAcrossBrowsing() async throws {
        let (store, chat, primary, extra, _) = try await setup()
        try await store.selectWorkspaceFolder(chat, path: extra.path)
        let review = try await CodeReview.capture(at: extra.path)
        chat.transcript.codeReview = review
        try await store.selectWorkspaceFolder(chat, path: primary.path)
        try await store.validateCodeReviewPrompt(chat, id: review.id, text: review.prompt())
        XCTAssertEqual(chat.transcript.codeReview?.root, extra.path)
        XCTAssertEqual(chat.transcript.codeReview?.status, .queued)
    }

    // Catches persisted foreign or symlink-rebound folder metadata granting a workspace outside the declared roots.
    @MainActor func testRestoredForeignSelectionDefaultsToPrimary() async throws {
        let (store, chat, primary, extra, foreign) = try await setup()
        var saved = chat.transcript; saved.workspaceDirectory = foreign.path
        let reopened = try ChatSession(id: UUID(), path: primary.path, transcript: saved, additionalDirectories: [extra.path])
        XCTAssertEqual(reopened.workspaceDirectory, primary.path)
        try FileManager.default.moveItem(at: extra, to: extra.appendingPathExtension("old"))
        try FileManager.default.createSymbolicLink(atPath: extra.path, withDestinationPath: foreign.path)
        do { try await store.selectWorkspaceFolder(chat, path: extra.path); XCTFail("Rebound selection") } catch {}
    }

    // Catches additional-directory editor drafts sharing a primary-relative key and saving the wrong file.
    @MainActor func testEditorDraftsAndConflictAwareSaveStayBoundToTheirFile() async throws {
        let (store, chat, primary, extra, _) = try await setup()
        let primaryKey = try await store.loadWorkspaceFile(chat, path: "same.txt")
        chat.fileDrafts[primaryKey]?.text = "unsaved primary\n"
        try await store.selectWorkspaceFolder(chat, path: extra.path)
        let extraKey = try await store.loadWorkspaceFile(chat, path: "same.txt")
        XCTAssertNotEqual(primaryKey, extraKey)
        XCTAssertEqual(chat.fileDrafts[extraKey]?.text, "extra one\nextra two\n")
        chat.fileDrafts[extraKey]?.text = "saved extra\n"
        try await store.saveWorkspaceFile(chat, key: extraKey)
        XCTAssertEqual(try String(contentsOf: extra.appendingPathComponent("same.txt"), encoding: .utf8), "saved extra\n")
        XCTAssertEqual(try String(contentsOf: primary.appendingPathComponent("same.txt"), encoding: .utf8), "working primary\n")
        XCTAssertEqual(chat.fileDrafts[primaryKey]?.text, "unsaved primary\n")
        chat.fileDrafts[extraKey]?.text = "my later draft\n"
        try "external extra\n".write(to: extra.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        do { try await store.saveWorkspaceFile(chat, key: extraKey); XCTFail("External edit overwritten") } catch {}
        XCTAssertEqual(chat.fileDrafts[extraKey]?.text, "my later draft\n")
        XCTAssertEqual(try String(contentsOf: extra.appendingPathComponent("same.txt"), encoding: .utf8), "external extra\n")
    }

    // Catches unstage/branch controls applying to the primary checkout rather than the chosen additional repository.
    @MainActor func testUnstageAndBranchActionsOnlyChangeSelectedCheckout() async throws {
        let (store, chat, primary, extra, _) = try await setup()
        try await store.selectWorkspaceFolder(chat, path: extra.path)
        try await store.stageWorkspaceFile(chat, path: "same.txt")
        try await store.unstageWorkspaceFile(chat, path: "same.txt")
        let extraStatus = try await Repository.status(at: extra.path)
        XCTAssertFalse(extraStatus.files[0].staged); XCTAssertTrue(extraStatus.files[0].unstaged)
        try await store.createWorkspaceBranch(chat, name: "qa-additional")
        let before = try await Repository.status(at: extra.path)
        XCTAssertEqual(before.branch, "library", "Creating a branch must not secretly switch it")
        try await store.switchWorkspaceBranch(chat, branch: "qa-additional")
        XCTAssertEqual(chat.repository.branch, "qa-additional")
        let primaryStatus = try await Repository.status(at: primary.path)
        XCTAssertEqual(primaryStatus.branch, "main")
        XCTAssertEqual(try String(contentsOf: extra.appendingPathComponent("same.txt"), encoding: .utf8), "extra one\nextra two\n")
        chat.fileDrafts["same.txt"] = FileDraft(original: "working primary\n", text: "keep unsaved\n")
        do { try await store.switchWorkspaceBranch(chat, branch: "library"); XCTFail("Unsaved editors must be reviewed before checkout") } catch {}
        XCTAssertEqual(chat.repository.branch, "qa-additional")
        XCTAssertEqual(chat.fileDrafts["same.txt"]?.text, "keep unsaved\n")
    }

    // Catches terminal launch using primary cwd, or an existing tab following later folder selection.
    @MainActor func testNewTerminalStartsInSelectedFolderAndExistingTabKeepsItsCwd() async throws {
        let (store, chat, primary, extra, _) = try await setup()
        try await store.selectWorkspaceFolder(chat, path: extra.path)
        let tab = try store.openWorkspaceTerminal(chat)
        let marker = extra.appendingPathComponent("ccode-cwd-proof.txt")
        defer { try? FileManager.default.removeItem(at: marker) }
        for _ in 0..<200 {
            if tab.ready || tab.ended { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(tab.ready, tab.failure ?? "Terminal did not start")
        let command = Array("pwd -P > '\(marker.path)'\r".utf8)
        tab.send(source: tab.view, data: command[...])
        for _ in 0..<200 {
            if (try? String(contentsOf: marker, encoding: .utf8))?.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "Terminal output: \(tab.view.accessibilityValue() ?? "Unavailable")")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), extra.path + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: primary.appendingPathComponent("ccode-cwd-proof.txt").path))
        try await store.selectWorkspaceFolder(chat, path: primary.path)
        XCTAssertEqual(tab.directory, extra.path)
        XCTAssertTrue(chat.terminalTabs.first === tab)
        let exitCommand = Array("exit\r".utf8)
        tab.send(source: tab.view, data: exitCommand[...])
        for _ in 0..<200 { if tab.ended { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(tab.ended, "Interactive shell should exit normally")
        await tab.close(); chat.terminalTabs.removeAll(); chat.activeTerminalID = nil
        XCTAssertTrue(tab.ended)
    }

    // Catches a stale pane dispatch applying its captured file path to the newly selected repository.
    @MainActor func testStalePaneActionRefusesAndFailedSelectionSaveRollsBack() async throws {
        let (store, chat, primary, extra, _) = try await setup()
        try await store.selectWorkspaceFolder(chat, path: extra.path)
        do { try await store.stageWorkspaceFile(chat, path: "same.txt", directory: primary.path); XCTFail("Stale pane action redirected") } catch {}
        let extraStatus = try await Repository.status(at: extra.path)
        XCTAssertFalse(extraStatus.files[0].staged)
        let data = await store.storage.directory, saved = data.appendingPathComponent("\(chat.id).json")
        try FileManager.default.removeItem(at: saved)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: false)
        chat.draft = "Keep despite failed selection save"
        do { try await store.selectWorkspaceFolder(chat, path: primary.path); XCTFail("Failed save should keep selection") } catch {}
        XCTAssertEqual(chat.workspaceDirectory, extra.path)
        XCTAssertEqual(chat.repository.branch, "library")
        XCTAssertEqual(chat.draft, "Keep despite failed selection save")
        XCTAssertFalse(chat.selectingWorkspaceFolder)
        try FileManager.default.removeItem(at: saved)
        try await store.selectWorkspaceFolder(chat, path: primary.path)
        XCTAssertEqual(chat.workspaceDirectory, primary.path)
    }

    // Catches native shell cleanup leaving a live tab/process task behind after closing.
    @MainActor func testNativeTerminalCloseSettlesWithoutSendingExit() async throws {
        let (store, chat, _, extra, _) = try await setup()
        try await store.selectWorkspaceFolder(chat, path: extra.path)
        let tab = try store.openWorkspaceTerminal(chat)
        for _ in 0..<200 { if tab.ready || tab.ended { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(tab.ready, tab.failure ?? "No shell")
        await tab.close()
        XCTAssertTrue(tab.ended)
        XCTAssertEqual(tab.directory, extra.path)
        chat.terminalTabs.removeAll(); chat.activeTerminalID = nil
    }

    // Catches Command-Return/composer dispatch sending a draft while the branch form is open.
    @MainActor func testBranchFormOwnsSubmissionWithoutSendingComposerDraft() async throws {
        let (store, chat, _, _, _) = try await setup()
        chat.draft = "Keep while naming branch"
        store.workspaceBranchEditing = true
        XCTAssertFalse(store.canSendPromptCommand)
        store.send(chat)
        XCTAssertNil(chat.promptTask)
        XCTAssertTrue(chat.pendingPrompts.isEmpty)
        XCTAssertEqual(chat.draft, "Keep while naming branch")
        store.workspaceBranchEditing = false
        XCTAssertTrue(store.canSendPromptCommand)
    }

}
