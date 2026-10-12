import XCTest
import AppKit
import SwiftUI
import Darwin
import CCodeCore
@testable import CCode

final class ContextCompletionTests: XCTestCase, @unchecked Sendable {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-context-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let resolved = try XCTUnwrap(realpath(url.path, nil))
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
    func testInlineQueryUsesUTF16CaretAndDoesNotTreatEmailAsContext() throws {
        let query = try XCTUnwrap(PromptCompletion.query(in: "👋 Review @src/界 then", selection: NSRange(location: 16, length: 0)))
        XCTAssertEqual(query.kind, .context)
        XCTAssertEqual(query.filter, "src/界")
        XCTAssertEqual(query.range, NSRange(location: 10, length: 6))
        XCTAssertEqual(query.removing(from: "👋 Review @src/界 then"), "👋 Review  then")
        for text in ["Email a@b.com", "Already done\nnormal", "```@file"] {
            XCTAssertNil(PromptCompletion.query(in: text, selection: NSRange(location: (text as NSString).length, length: 0)))
        }
        XCTAssertNil(PromptCompletion.query(in: "@src", selection: NSRange(location: 1, length: 2)))
    }
    func testSlashCompletionKeepsArgumentsAndUsesOnlyAdvertisedCommands() throws {
        let query = try XCTUnwrap(PromptCompletion.query(in: "/comp keep these args", selection: NSRange(location: 5, length: 0)))
        XCTAssertEqual(query.kind, .command)
        let catalog: [JSONValue] = [["name": "compact", "description": "Summarize context"], ["name": "clear", "description": "Clear context"]]
        let matches = PromptCompletion.commands(matching: query.filter, catalog: catalog)
        XCTAssertEqual(matches.map { $0["name"].string }, ["compact"])
        XCTAssertEqual(query.applyingCommand("compact", to: "/comp keep these args"), "/compact keep these args")
        XCTAssertNil(PromptCompletion.query(in: "/compact focus auth", selection: NSRange(location: 19, length: 0)))
        XCTAssertTrue(PromptCompletion.commands(matching: "resume", catalog: catalog).isEmpty)
    }
    func testContextSearchFindsBeyondOldMenuAndKeepsAdditionalRootsDistinct() async throws {
        let root = try temporary(), extra = try temporary()
        for number in 0..<240 { try "filler".write(to: root.appendingPathComponent("a-\(number).txt"), atomically: true, encoding: .utf8) }
        for directory in [root, extra] { try "selected".write(to: directory.appendingPathComponent("z report 界.txt"), atomically: true, encoding: .utf8) }
        let workspace = try Workspace(root: root.path, additionalDirectories: [extra.path])
        let matches = try await workspace.contextCandidates(matching: "report 界", limit: 10)
        XCTAssertEqual(matches.filter { $0.kind == .file }.count, 2)
        XCTAssertEqual(Set(matches.map(\.path)), Set([root.appendingPathComponent("z report 界.txt").path, extra.appendingPathComponent("z report 界.txt").path]))
        XCTAssertEqual(Set(matches.map(\.root)).count, 2)
        let attachment = try await SessionStorage(directory: root.appendingPathComponent("data")).importWorkspaceContext(try XCTUnwrap(matches.first { $0.path.hasPrefix(extra.path) }), workspace: workspace)
        XCTAssertEqual(attachment.context?.path, extra.appendingPathComponent("z report 界.txt").path)
        XCTAssertEqual(attachment.context?.root, extra.path)
    }
    func testContextSearchRespectsGitIgnoreAndExcludesEscapingSymlinks() async throws {
        let root = try temporary(), outside = try temporary()
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        try "secret.txt\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        for name in ["secret.txt", "visible.txt"] { try name.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try "outside".write(to: outside.appendingPathComponent("escape.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.txt"), withDestinationURL: outside.appendingPathComponent("escape.txt"))
        let workspace = try Workspace(root: root.path)
        let matches = try await workspace.contextCandidates(matching: ".txt", limit: 20)
        XCTAssertEqual(matches.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["visible.txt"])
    }
    func testFolderManifestIsBoundedAndSnapshotSurvivesRename() async throws {
        let root = try temporary(), folder = root.appendingPathComponent("Source folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for number in 0..<260 { try "body is not copied".write(to: folder.appendingPathComponent("file-\(number).txt"), atomically: true, encoding: .utf8) }
        let workspace = try Workspace(root: root.path), storage = SessionStorage(directory: root.appendingPathComponent("data"))
        let candidates = try await workspace.contextCandidates(matching: "Source folder", limit: 10)
        let candidate = try XCTUnwrap(candidates.first { $0.kind == .folder && $0.path == folder.path })
        let attachment = try await storage.importWorkspaceContext(candidate, workspace: workspace)
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Renamed"))
        let blocks = try await storage.attachmentPrompt(attachment, capabilities: [:])
        let text = blocks.map { $0["text"].string }.joined(separator: "\n")
        XCTAssertTrue(text.contains(folder.path))
        XCTAssertTrue(text.contains("truncated"))
        XCTAssertFalse(text.contains("body is not copied"))
        XCTAssertLessThan(attachment.byteCount, 65536)
    }
    func testSearchInsideGitSubfolderDoesNotOfferParentRepositoryFiles() async throws {
        let root = try temporary(), folder = root.appendingPathComponent("Selected root")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        try "outside selected root".write(to: root.appendingPathComponent("parent.txt"), atomically: true, encoding: .utf8)
        try "inside".write(to: folder.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)
        let matches = try await Workspace(root: folder.path).contextCandidates(matching: ".txt")
        XCTAssertEqual(matches.map(\.path), [folder.appendingPathComponent("child.txt").path])
    }
    @MainActor func testFailedContextImportKeepsDraftAndSuccessfulSelectionPersistsSnapshot() async throws {
        let root = try temporary(), file = root.appendingPathComponent("context.txt")
        try "immutable context".write(to: file, atomically: true, encoding: .utf8)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        addTeardownBlock { await store.shutdown() }
        let candidates = try await chat.workspace.contextCandidates(matching: "context.txt", limit: 10)
        let candidate = try XCTUnwrap(candidates.first)
        chat.draft = "Read @context.txt then explain"
        let query = try XCTUnwrap(PromptCompletion.query(in: chat.draft, selection: NSRange(location: 17, length: 0)))
        try FileManager.default.removeItem(at: file)
        let failed = await store.attachContext(candidate, to: chat, replacing: query)
        XCTAssertFalse(failed)
        XCTAssertEqual(chat.draft, "Read @context.txt then explain")
        XCTAssertTrue(chat.attachments.isEmpty)
        try "immutable context".write(to: file, atomically: true, encoding: .utf8)
        let success = await store.attachContext(candidate, to: chat, replacing: query)
        XCTAssertTrue(success)
        XCTAssertEqual(chat.draft, "Read  then explain")
        let saved = try await store.storage.load(chat.id)
        XCTAssertEqual(saved.draftText, "Read  then explain")
        XCTAssertEqual(saved.draftAttachments?.first?.context?.path, file.path)
        try FileManager.default.removeItem(at: file)
        let blocks = try await store.storage.attachmentPrompt(try XCTUnwrap(saved.draftAttachments?.first), capabilities: [:])
        XCTAssertTrue(blocks.first?["text"].string.contains("immutable context") == true)
    }
    @MainActor func testEditorCompletionConsumesReturnWithoutSendingAndReportsCaret() throws {
        var text = "@co", sent = 0, picked = 0, caret: NSRange?
        let host = NSHostingView(rootView: PromptEditor(text: Binding(get: { text }, set: { text = $0 }), placeholder: "Prompt", send: { sent += 1 }, cancel: {}, selectionChanged: { _, range in caret = range }, completionKey: { key in if key == 36 { picked += 1; return true }; return false }))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 80); host.layoutSubtreeIfNeeded()
        func editor(_ view: NSView) -> NSTextView? {
            if let value = view as? NSTextView { return value }
            return view.subviews.lazy.compactMap { editor($0) }.first
        }
        let input = try XCTUnwrap(editor(host)); input.setSelectedRange(NSRange(location: 3, length: 0))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        input.keyDown(with: event)
        XCTAssertEqual(picked, 1); XCTAssertEqual(sent, 0)
        XCTAssertEqual(caret, NSRange(location: 3, length: 0))
    }
    @MainActor func testContextImportRetainsNewerDraftAndFilesDroppedWhileItLoads() async throws {
        let root = try temporary(), folder = root.appendingPathComponent("Source"), dropped = root.appendingPathComponent("dropped.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "source".write(to: folder.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        try "dropped".write(to: dropped, atomically: true, encoding: .utf8)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        addTeardownBlock { await store.shutdown() }
        let candidates = try await chat.workspace.contextCandidates(matching: "Source")
        let candidate = try XCTUnwrap(candidates.first { $0.path == folder.path })
        chat.draft = "Read @Source"
        let query = try XCTUnwrap(PromptCompletion.query(in: chat.draft, selection: NSRange(location: 12, length: 0)))
        let operation = Task { await store.attachContext(candidate, to: chat, replacing: query) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !chat.attachingFiles, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(chat.attachingFiles)
        chat.draft = "Keep my newer draft"
        store.attach(dropped, to: chat)
        let accepted = await operation.value
        XCTAssertTrue(accepted)
        await chat.attachmentTask?.value
        XCTAssertEqual(chat.draft, "Keep my newer draft")
        XCTAssertEqual(Set(chat.attachments.map { $0.url.lastPathComponent }), Set(["Source", "dropped.txt"]))
    }
    @MainActor func testContextCanBeAttachedToFollowupDuringAnActiveTurn() async throws {
        let root = try temporary(), file = root.appendingPathComponent("context.txt")
        try "context".write(to: file, atomically: true, encoding: .utf8)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "delivery", withExtension: "py", subdirectory: "Fixtures")!.path, "--no-steering"]
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        addTeardownBlock { await store.shutdown() }
        let candidates = try await chat.workspace.contextCandidates(matching: "context.txt")
        let candidate = try XCTUnwrap(candidates.first)
        store.send(chat, text: "hold original")
        let deadline = ContinuousClock.now + .seconds(4)
        while chat.state != .running, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(chat.state, .running)
        chat.draft = "Next turn @context.txt"
        let query = try XCTUnwrap(PromptCompletion.query(in: chat.draft, selection: NSRange(location: 22, length: 0)))
        let accepted = await store.attachContext(candidate, to: chat, replacing: query)
        XCTAssertTrue(accepted)
        XCTAssertEqual(chat.draft, "Next turn ")
        XCTAssertEqual(chat.attachments.count, 1)
        XCTAssertEqual(chat.state, .running)
    }
    @MainActor func testAdvertisedCommandAndImmutableContextReachTheActualPromptWire() async throws {
        let root = try temporary(), file = root.appendingPathComponent("source 界.txt")
        try "snapshot-token amber17".write(to: file, atomically: true, encoding: .utf8)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "delivery", withExtension: "py", subdirectory: "Fixtures")!.path, "--commands", "--no-steering"]
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        addTeardownBlock { await store.shutdown() }
        try await store.connect(chat)
        let deadline = ContinuousClock.now + .seconds(4)
        while chat.transcript.commands.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(Set(chat.transcript.commands.map { $0["name"].string }), Set(["compact", "clear", "local-skill"]))
        let candidates = try await chat.workspace.contextCandidates(matching: "source 界")
        let candidate = try XCTUnwrap(candidates.first)
        let accepted = await store.attachContext(candidate, to: chat)
        XCTAssertTrue(accepted)
        try FileManager.default.removeItem(at: file)
        let query = try XCTUnwrap(PromptCompletion.query(in: "/comp focus auth", selection: NSRange(location: 5, length: 0)))
        chat.draft = query.applyingCommand("compact", to: "/comp focus auth")
        store.send(chat)
        while chat.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(chat.state, .ready, chat.lastError ?? "Prompt did not finish")
        let state = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        let blocks = try XCTUnwrap(state["prompts"].array.first)["prompt"].array
        XCTAssertEqual(blocks.first?["text"].string, "/compact focus auth")
        XCTAssertTrue(blocks.contains { $0["text"].string.contains("snapshot-token amber17") && $0["text"].string.contains(file.path) })
        XCTAssertTrue(chat.attachments.isEmpty)
    }
    func testSelectedCodeCarriesPathLineRangeAndExactBufferRevision() async throws {
        let root = try temporary(), workspace = try Workspace(root: root.path)
        let snapshot = try await workspace.selectedFileContext(path: root.appendingPathComponent("sample 界.swift").path, text: "first\nlet 界 = 42\nthird", range: NSRange(location: 6, length: 10))
        XCTAssertEqual(snapshot.text, "let 界 = 42")
        XCTAssertEqual(snapshot.context.startLine, 2); XCTAssertEqual(snapshot.context.endLine, 2)
        XCTAssertEqual(snapshot.context.kind, .selection)
        XCTAssertEqual(snapshot.context.path, root.appendingPathComponent("sample 界.swift").path)
        XCTAssertEqual(snapshot.context.source, "editor buffer")
        XCTAssertEqual(snapshot.context.revision, "sha256:0e701ec08b9699a8b0047eb08c990116086a3454ad741003d8d596311136d80b")
        let storage = SessionStorage(directory: root.appendingPathComponent("data"))
        let attachment = try await storage.importSelectedContext(snapshot)
        let blocks = try await storage.attachmentPrompt(attachment, capabilities: [:])
        XCTAssertTrue(blocks[0]["text"].string.contains("let 界 = 42"))
        XCTAssertTrue(blocks[0]["text"].string.contains("Lines: 2–2"))
        XCTAssertEqual(attachment.context, snapshot.context)
        for range in [NSRange(location: 0, length: 0), NSRange(location: 99, length: 1), NSRange(location: 0, length: 99)] {
            do { _ = try await workspace.selectedFileContext(path: root.appendingPathComponent("sample.swift").path, text: "text", range: range); XCTFail("Invalid selection must not become context") } catch { }
        }
        do { _ = try await workspace.selectedFileContext(path: "/outside/selection.swift", text: "text", range: NSRange(location: 0, length: 4)); XCTFail("Out-of-workspace selection must reject") } catch { }
    }
    func testSelectedDiffDistinguishesOriginalAndStagedLinesAndRejectsStaleSelections() async throws {
        let root = try temporary(), workspace = try Workspace(root: root.path)
        let diff = "diff --git a/source.swift b/source.swift\n@@ -3 +3 @@\n-old\n+new\n"
        let lines = Repository.diffLines(diff)
        let removed = try await workspace.selectedDiffContext(path: root.appendingPathComponent("source.swift").path, diff: diff, line: lines[2], stagedOnly: true, baseRevision: "abc123")
        let added = try await workspace.selectedDiffContext(path: root.appendingPathComponent("source.swift").path, diff: diff, line: lines[3], stagedOnly: true, baseRevision: "abc123")
        XCTAssertEqual(removed.context.source, "original HEAD")
        XCTAssertEqual(added.context.source, "staged index")
        XCTAssertEqual(removed.context.startLine, 3); XCTAssertEqual(added.context.startLine, 3)
        XCTAssertEqual(added.text, "+new")
        XCTAssertTrue(added.context.revision?.hasPrefix("HEAD:abc123; diff-sha256:") == true)
        let changed = "diff --git a/source.swift b/source.swift\n@@ -3 +3 @@\n-old\n+changed\n"
        do { _ = try await workspace.selectedDiffContext(path: root.appendingPathComponent("source.swift").path, diff: changed, line: lines[3], stagedOnly: true, baseRevision: "abc123"); XCTFail("A stale selected line must reject") } catch { }
    }
    @MainActor func testSelectedContextKeepsDraftAndPersistsRangeWithoutWritingTheSourceFile() async throws {
        let root = try temporary(), outside = try temporary(), file = root.appendingPathComponent("sample.swift")
        try "original on disk".write(to: file, atomically: true, encoding: .utf8)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        addTeardownBlock { await store.shutdown() }
        chat.draft = "Explain this selected code"
        let selected = try await chat.workspace.selectedFileContext(path: file.path, text: "unsaved editor contents", range: NSRange(location: 8, length: 6))
        let accepted = await store.attachSelectedContext(selected, to: chat)
        XCTAssertTrue(accepted)
        XCTAssertEqual(chat.draft, "Explain this selected code")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original on disk")
        let saved = try await store.storage.load(chat.id)
        XCTAssertEqual(saved.draftAttachments?.first?.context?.startLine, 1)
        let blocks = try await store.storage.attachmentPrompt(try XCTUnwrap(saved.draftAttachments?.first), capabilities: [:])
        XCTAssertTrue(blocks[0]["text"].string.contains("editor"))
        let wrongRoot = try Workspace(root: outside.path)
        let wrong = try await wrongRoot.selectedFileContext(path: outside.appendingPathComponent("source.swift").path, text: "outside", range: NSRange(location: 0, length: 7))
        let rejected = await store.attachSelectedContext(wrong, to: chat)
        XCTAssertFalse(rejected)
        XCTAssertEqual(chat.attachments.count, 1)
        XCTAssertEqual(chat.draft, "Explain this selected code")
    }
    @MainActor func testCodeEditorReportsSelectionInTheSameBufferWithoutSubmittingAChat() throws {
        var text = "first\nlet 界 = 42\nthird", selection = NSRange(location: 0, length: 0)
        let host = NSHostingView(rootView: SelectionTextEditor(text: Binding(get: { text }, set: { text = $0 }), selection: Binding(get: { selection }, set: { selection = $0 })))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 300); host.layoutSubtreeIfNeeded()
        func editor(_ view: NSView) -> NSTextView? {
            if let value = view as? NSTextView { return value }
            return view.subviews.lazy.compactMap { editor($0) }.first
        }
        let input = try XCTUnwrap(editor(host)); input.setSelectedRange(NSRange(location: 6, length: 10))
        XCTAssertEqual(selection, NSRange(location: 6, length: 10))
        XCTAssertEqual(text, "first\nlet 界 = 42\nthird")
    }
    @MainActor func testSymlinkDiffContextNamesTheSelectedLinkAndRejectsAChangedTarget() async throws {
        let root = try temporary(), link = root.appendingPathComponent("selected-link"), target = root.appendingPathComponent("target.txt")
        try "target contents".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        addTeardownBlock { await store.shutdown() }
        let diff = "diff --git a/selected-link b/selected-link\n@@ -1 +1 @@\n-old-target\n+target.txt\n"
        let line = Repository.diffLines(diff)[3]
        let snapshot = try await chat.workspace.selectedDiffContext(path: link.path, diff: diff, line: line, stagedOnly: false, baseRevision: "abc123")
        XCTAssertEqual(snapshot.context.path, link.path, "A diff of the symlink is not a diff of its target")
        let accepted = await store.attachSelectedContext(snapshot, to: chat)
        XCTAssertTrue(accepted)
        try FileManager.default.removeItem(at: link)
        let changed = root.appendingPathComponent("changed.txt")
        try "different".write(to: changed, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: changed)
        let rejected = await store.attachSelectedContext(snapshot, to: chat)
        XCTAssertFalse(rejected)
        XCTAssertEqual(chat.attachments.count, 1)
    }
}
