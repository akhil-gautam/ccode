import XCTest
import Foundation
import Observation
import Darwin
@testable import CCode
import CCodeCore

final class AppStoreTests: XCTestCase, @unchecked Sendable {
    @MainActor func testPublishedContinuationCannotClearNextForkOwnership() async throws {
        let root = try temporary(), audit = root.appendingPathComponent("audit.jsonl")
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--slow-fork", "--audit-path=" + audit.path]
        addTeardownBlock { await store.shutdown() }
        await store.create(path: root.path, worktree: false)
        let source = try XCTUnwrap(store.selected)
        try await store.connect(source)
        let first = Task { try await store.fork(source) }
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? String(contentsOf: audit, encoding: .utf8).contains("session/fork")) != true, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let registered = expectation(description: "Observe publication")
        let second = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking { _ = source.forking } onChange: { continuation.resume() }
                registered.fulfill()
            }
            return try await store.fork(source)
        }
        await fulfillment(of: [registered], timeout: 5)
        _ = try await first.value
        let requested = ContinuousClock.now + .seconds(5)
        while (try? String(contentsOf: audit, encoding: .utf8).components(separatedBy: "session/fork").count) != 3, ContinuousClock.now < requested { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(source.forking, "The older operation's defer must not release the new operation")
        store.stop(source)
        do { _ = try await second.value; XCTFail("Stop must cancel the second pending fork") } catch {}
        XCTAssertEqual(store.sessions.count, 2)
    }
    @MainActor func testEditAndRetryPreserveSourceAndExcludeReplacedTurn() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data"), audit = root.appendingPathComponent("audit.jsonl")
        let store = AppStore(directory: data)
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--fork", "--config", "--attachments", "--audit-path=" + audit.path]
        addTeardownBlock { await store.shutdown() }
        await store.create(path: root.path, worktree: false)
        let source = try XCTUnwrap(store.selected)
        try await store.connect(source)
        await store.setConfig(source, id: "model", value: "large")
        let file = root.appendingPathComponent("context.txt")
        try "Saved context".write(to: file, atomically: true, encoding: .utf8)
        store.attach(file, to: source); await source.attachmentTask?.value
        let attachment = try XCTUnwrap(source.attachments.first)
        store.send(source, text: "Original first prompt"); try await finish(source, store: store)
        let first = try XCTUnwrap(source.transcript.items.first { $0.kind == "user" })
        source.transcript.pendingConfiguration = SessionConfiguration(executable: store.settings.executable, arguments: store.settings.arguments, values: ["effort": "high"])
        source.draft = "Keep source composer"
        source.fileDrafts["draft.txt"] = FileDraft(original: "old", text: "unsaved editor")
        let original = source.transcript.items
        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(store.canRevise(source, at: first.id))
        let editID = try await store.editMessage(source, at: first.id)
        let edit = try XCTUnwrap(store.selected)
        XCTAssertEqual(edit.id, editID); XCTAssertTrue(edit.transcript.items.isEmpty)
        let editOrigin = try XCTUnwrap(store.sessions.first { $0.id == editID }?.origin)
        XCTAssertEqual(editOrigin.kind, .edit)
        XCTAssertEqual(editOrigin.sourceSessionID, source.id)
        XCTAssertEqual(editOrigin.sourceItemID, first.id)
        XCTAssertTrue(editOrigin.startsFresh)
        XCTAssertNil(editOrigin.boundaryMessageID)
        XCTAssertNil(edit.transcript.remoteID, "Replacing the first prompt must start with empty agent context")
        XCTAssertEqual(edit.transcript.pendingConfiguration?.values["model"], "large", "A remaining effort choice must retain the model already accepted by the source")
        XCTAssertEqual(edit.transcript.pendingConfiguration?.values["effort"], "high")
        XCTAssertEqual(edit.draft, first.text); XCTAssertEqual(edit.attachments, [attachment])
        XCTAssertEqual(source.transcript.items, original); XCTAssertEqual(source.draft, "Keep source composer")
        XCTAssertEqual(source.fileDrafts["draft.txt"]?.text, "unsaved editor")
        edit.draft = "Edited first prompt"
        await store.shutdown()
        let restored = AppStore(directory: data); restored.settings = store.settings
        addTeardownBlock { await restored.shutdown() }
        await restored.restore(); await restored.select(editID)
        let resumed = try XCTUnwrap(restored.selected)
        XCTAssertEqual(resumed.draft, "Edited first prompt"); XCTAssertEqual(resumed.attachments, [attachment])
        XCTAssertEqual(restored.sessions.first { $0.id == editID }?.origin, editOrigin)
        restored.send(resumed); try await finish(resumed, store: restored)
        XCTAssertEqual(resumed.state, .ready, resumed.lastError ?? "")
        XCTAssertEqual(resumed.transcript.configOptions.first { $0["id"].string == "model" }?["currentValue"], "large")
        let calls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let sent = try XCTUnwrap(calls.last { $0["method"].string == "session/prompt" })["params"]["prompt"].array
        XCTAssertEqual(sent.map { $0["text"].string }, ["Edited first prompt", "File: context.txt\nSaved context"])
        XCTAssertFalse(calls.contains { $0["method"].string == "session/fork" }, "First-message edit must not fork the unwanted context")

        // Retrying a later response forks before its prompt and drops every later turn.
        resumed.handshake["agentInfo"] = ["name": "@agentclientprotocol/claude-agent-acp", "version": "0.84.0"]
        let early = TranscriptItem(kind: "assistant", text: "Earlier response", messageID: "msg-early")
        var prompt = TranscriptItem(kind: "user", text: "Prompt to retry"); prompt.startedSession = false
        let response = TranscriptItem(kind: "assistant", text: "Response to replace", messageID: "msg-replace")
        let retainedPrompt = try XCTUnwrap(resumed.transcript.items.first { $0.kind == "user" })
        resumed.transcript.items = [retainedPrompt, early, prompt, response, TranscriptItem(kind: "user", text: "Future prompt"), TranscriptItem(kind: "assistant", text: "Future response", messageID: "msg-future")]
        resumed.draft = "Keep later source draft"
        let history = resumed.transcript.items
        XCTAssertTrue(restored.canRevise(resumed, at: response.id))
        let retryID = try await restored.retryResponse(resumed, at: response.id)
        let retry = try XCTUnwrap(restored.selected)
        XCTAssertEqual(retry.id, retryID)
        let retryOrigin = try XCTUnwrap(restored.sessions.first { $0.id == retryID }?.origin)
        XCTAssertEqual(retryOrigin.kind, .retry)
        XCTAssertEqual(retryOrigin.sourceSessionID, resumed.id)
        XCTAssertEqual(retryOrigin.sourceItemID, response.id)
        XCTAssertEqual(retryOrigin.boundaryMessageID, "msg-early")
        XCTAssertFalse(retryOrigin.startsFresh)
        try await finish(retry, store: restored)
        XCTAssertEqual(Array(retry.transcript.items.prefix(2)), Array(history.prefix(2)))
        XCTAssertEqual(retry.transcript.items.filter { $0.kind == "user" }.map(\.text), ["Edited first prompt", "Prompt to retry"])
        XCTAssertEqual(resumed.transcript.items, history); XCTAssertEqual(resumed.draft, "Keep later source draft")
        let laterCalls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(laterCalls.last { $0["method"].string == "session/fork" }?["params"]["_meta"]["jetbrains"]["air"]["fork"]["messageId"], "msg-early")
    }
    @MainActor func testRevisionRejectsUnknownOrIncompleteContextAndStop() async throws {
        let root = try temporary(), audit = root.appendingPathComponent("audit.jsonl")
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--slow-fork", "--audit-path=" + audit.path]
        addTeardownBlock { await store.shutdown() }
        await store.create(path: root.path, worktree: false)
        let source = try XCTUnwrap(store.selected)
        try await store.connect(source)
        let boundary = TranscriptItem(kind: "assistant", text: "Keep", messageID: "msg-keep")
        var prompt = TranscriptItem(kind: "user", text: "Replace"); prompt.startedSession = false
        source.transcript.items = [boundary, prompt]
        XCTAssertFalse(store.canRevise(source, at: prompt.id), "Unknown providers must not receive an unverified boundary extension")
        do { _ = try await store.editMessage(source, at: prompt.id); XCTFail("Unknown provider") } catch {}
        source.handshake["agentInfo"] = ["name": "@agentclientprotocol/claude-agent-acp", "version": "0.84.0"]
        XCTAssertTrue(store.canRevise(source, at: prompt.id))
        source.transcript.items = [boundary, TranscriptItem(kind: "user", text: "Imported mid-turn input")]
        XCTAssertFalse(store.canRevise(source, at: source.transcript.items[1].id), "Imported input can join a running turn and has no verified checkpoint")
        source.transcript.items = [boundary, prompt]
        source.transcript.items.insert(TranscriptItem(kind: "tool", tool: ["toolCallId": "end-turn", "status": "completed"]), at: 1)
        XCTAssertFalse(store.canRevise(source, at: prompt.id), "An end-turn tool carrier must not be cut off at an earlier assistant")
        source.transcript.items = [prompt]
        XCTAssertFalse(store.canRevise(source, at: prompt.id), "An imported first visible prompt may have hidden context")
        source.transcript.items = [boundary, TranscriptItem(kind: "user", text: "Another Claude session sent a message:\n<agent-message>Report</agent-message>")]
        XCTAssertFalse(store.canRevise(source, at: source.transcript.items[1].id))
        source.transcript.items[1].startedSession = false
        XCTAssertTrue(store.canRevise(source, at: source.transcript.items[1].id), "A literal wrapper submitted by the user is still their editable prompt")
        source.transcript.items = [boundary, TranscriptItem(kind: "user", text: "Unowned attachment", blocks: [["type": "resource_link", "uri": "file:///private/secret", "_meta": ["ccode": ["snapshot": true]]]])]
        XCTAssertFalse(store.canRevise(source, at: source.transcript.items[1].id))
        source.transcript.items = [boundary, prompt]; source.draft = "Keep source"
        let operation = Task { try await store.editMessage(source, at: prompt.id) }
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? String(contentsOf: audit, encoding: .utf8).contains("session/fork")) != true, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue((try? String(contentsOf: audit, encoding: .utf8).contains("session/fork")) == true)
        store.stop(source)
        do { _ = try await operation.value; XCTFail("Stopped edit must not publish") } catch {}
        XCTAssertEqual(store.sessions.count, 1); XCTAssertEqual(source.transcript.items, [boundary, prompt]); XCTAssertEqual(source.draft, "Keep source")
    }
    @MainActor func testUnsupportedAttachmentSendPreservesDraftAndSnapshots() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data")
        let store = AppStore(directory: data)
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--config", "--unpersisted-new", "--audit-path=" + root.appendingPathComponent("audit.jsonl").path]
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        await store.setConfig(chat, id: "model", value: "large")
        let audio = root.appendingPathComponent("sample.wav")
        try XCTUnwrap(Data(base64Encoded: "UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA=")).write(to: audio)
        store.attach(Array(repeating: audio, count: 11), to: chat)
        XCTAssertFalse(chat.attachingFiles); XCTAssertTrue(chat.attachments.isEmpty)
        store.error = nil
        store.attach(audio, to: chat)
        await chat.attachmentTask?.value
        let attachment = try XCTUnwrap(chat.attachments.first)
        chat.draft = "Keep my audio draft"
        store.send(chat)
        try await finish(chat, store: store)
        XCTAssertEqual(chat.state, .failed)
        XCTAssertTrue(chat.lastError?.contains("does not support audio") == true)
        XCTAssertEqual(chat.draft, "Keep my audio draft")
        XCTAssertEqual(chat.attachments, [attachment]); XCTAssertTrue(chat.transcript.items.isEmpty)
        await store.shutdown()
        let restored = AppStore(directory: data); restored.settings = store.settings
        await restored.restore(); await restored.select(chat.id)
        XCTAssertEqual(restored.selected?.attachments, [attachment])
        XCTAssertEqual(restored.selected?.draft, "Keep my audio draft")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.attachmentURL(attachment).path))
        let retry = try XCTUnwrap(restored.selected)
        await restored.removeAttachment(attachment, from: retry)
        restored.send(retry); try await finish(retry, store: restored)
        XCTAssertEqual(retry.state, .ready, retry.lastError ?? "")
        XCTAssertEqual(retry.transcript.configOptions.first { $0["id"].string == "model" }?["currentValue"], "large")
        XCTAssertEqual(retry.transcript.items.filter { $0.kind == "user" }.count, 1)
        let remoteID = try XCTUnwrap(retry.transcript.remoteID), history = retry.transcript.items
        restored.attach(audio, to: retry); await retry.attachmentTask?.value
        retry.draft = "Keep existing context"
        restored.send(retry); try await finish(retry, store: restored)
        XCTAssertEqual(retry.state, .failed)
        XCTAssertEqual(retry.transcript.remoteID, remoteID, "Existing context must not be reset by attachment preflight failure")
        XCTAssertEqual(retry.transcript.items, history)
        XCTAssertEqual(retry.draft, "Keep existing context")
        await restored.shutdown()
    }
    @MainActor func testCancelFileLoadingKeepsActiveResponseAndDraft() async throws {
        let root = try temporary(), audit = root.appendingPathComponent("audit.jsonl")
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--audit-path=" + audit.path]
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        store.send(chat, text: "Active response")
        for _ in 0..<300 where chat.approvals.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(chat.approvals.isEmpty)
        let prompt = try XCTUnwrap(chat.promptTask)
        chat.draft = "Next unsent prompt"
        let file = root.appendingPathComponent("pending.txt")
        try "Pending context".write(to: file, atomically: true, encoding: .utf8)
        store.attach(file, to: chat)
        let importing = try XCTUnwrap(chat.attachmentTask)
        store.cancelAttachmentImports(chat)
        await importing.value
        XCTAssertFalse(chat.attachingFiles)
        XCTAssertTrue(chat.attachments.isEmpty)
        XCTAssertEqual(chat.state, .running)
        XCTAssertFalse(prompt.isCancelled)
        XCTAssertEqual(chat.draft, "Next unsent prompt")
        try await finish(chat, store: store)
        XCTAssertEqual(chat.state, .ready)
        let calls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertFalse(calls.contains { $0["method"].string == "session/cancel" })
        await store.shutdown()
    }
    @MainActor func testAttachmentDraftsPersistThroughEvictionRestartAndSend() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data"), audit = root.appendingPathComponent("audit.jsonl")
        let text = root.appendingPathComponent("context.txt"), image = root.appendingPathComponent("pixel.png")
        try "Original snapshot".write(to: text, atomically: true, encoding: .utf8)
        try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aCJkAAAAASUVORK5CYII=")).write(to: image)
        let store = AppStore(directory: data)
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--attachments", "--audit-path=" + audit.path]
        await store.create(path: root.path, worktree: false)
        let original = try XCTUnwrap(store.selected)
        store.attach([text, image], to: original)
        for _ in 0..<500 where original.attachingFiles { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(original.attachingFiles)
        XCTAssertEqual(original.attachments.count, 2, store.error ?? "")
        let sourceID = original.id
        await store.create(path: root.path, worktree: false)
        await store.select(try XCTUnwrap(store.selectedID))
        await store.select(sourceID)
        let evicted = try XCTUnwrap(store.selected)
        XCTAssertFalse(evicted === original, "Saved attachment metadata must allow idle chat eviction")
        XCTAssertEqual(evicted.attachments, original.attachments)
        await store.shutdown()
        try FileManager.default.removeItem(at: text); try FileManager.default.removeItem(at: image)
        let restored = AppStore(directory: data); restored.settings = store.settings
        await restored.restore(); await restored.select(sourceID)
        let chat = try XCTUnwrap(restored.selected)
        XCTAssertEqual(chat.attachments.count, 2)
        restored.send(chat, text: "Use saved context")
        try await finish(chat, store: restored)
        XCTAssertTrue(chat.attachments.isEmpty)
        let calls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let prompt = try XCTUnwrap(calls.last { $0["method"].string == "session/prompt" })["params"]["prompt"].array
        XCTAssertTrue(prompt.contains { $0["text"].string.contains("Original snapshot") })
        XCTAssertEqual(prompt.filter { $0["type"].string == "image" }.count, 1)
        XCTAssertNil(chat.transcript.draftAttachments)
        for block in chat.transcript.items.first(where: { $0.kind == "user" })?.blocks ?? [] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(URL(string: block["uri"].string)).path))
        }
        await restored.shutdown()
    }
    @MainActor func testProjectOrganizationPersistsAndPaletteSearchDoesNotFilterSidebar() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data")
        let store = AppStore(directory: data)
        let a = SessionInfo(projectPath: root.appendingPathComponent("a").path, title: "Alpha")
        let b = SessionInfo(projectPath: root.appendingPathComponent("b").path, title: "Beta")
        let c = SessionInfo(projectPath: root.appendingPathComponent("c").path, title: "Gamma")
        var d = SessionInfo(projectPath: root.appendingPathComponent("d").path, title: "Archived D")
        var e = SessionInfo(projectPath: root.appendingPathComponent("e").path, title: "Archived E")
        d.archived = true; e.archived = true
        for info in [a, b, c, d, e] { try FileManager.default.createDirectory(atPath: info.projectPath, withIntermediateDirectories: true) }
        store.sessions = [a, b, c, d, e]
        try await SessionStorage(directory: data).saveIndex(store.sessions)
        store.moveProject(c.projectPath, before: a.projectPath)
        store.toggleProjectPin(b.projectPath)
        store.moveProject(a.projectPath, before: b.projectPath)
        XCTAssertEqual(store.sidebarPreferences.projectOrder, [c.projectPath, a.projectPath, b.projectPath], "A drop across the pinned boundary must not alter saved ranks")
        store.setAllProjectsCollapsed(true)
        XCTAssertEqual(store.sidebarProjects, [b.projectPath, c.projectPath, a.projectPath])
        XCTAssertEqual(store.sidebarSnapshot.rows.count, 3)
        store.openSessionSearch(project: a.projectPath)
        store.search = "alpha"
        XCTAssertEqual(store.sessionSearchResults.map(\.id), [a.id])
        XCTAssertEqual(store.sidebarSnapshot.rows.count, 3)
        store.closeSessionSearch()
        store.toggleProjectCollapsed(a.projectPath)
        store.showArchived = true
        store.moveProject(e.projectPath, before: d.projectPath)
        store.showArchived = false
        XCTAssertEqual(store.sidebarProjects, [b.projectPath, c.projectPath, a.projectPath], "Archived ordering must preserve hidden active-project ranks")
        await store.shutdown()
        let restored = AppStore(directory: data); await restored.restore()
        XCTAssertEqual(restored.sidebarProjects, [b.projectPath, c.projectPath, a.projectPath])
        XCTAssertEqual(restored.sidebarPreferences.collapsedProjects, [b.projectPath, c.projectPath])
        restored.showArchived = true
        XCTAssertEqual(restored.sidebarProjects, [e.projectPath, d.projectPath])
        restored.showArchived = false
        restored.openSessionSearch(); restored.search = "Beta"
        XCTAssertEqual(restored.sessionSearchResults.map(\.id), [b.id])
        restored.newSessionDraft.text = "Unsent prompt"
        restored.search = " \n "
        await restored.composeFromSessionSearch()
        XCTAssertEqual(restored.newSessionDraft.text, "Unsent prompt")
        XCTAssertTrue(restored.showSessionSearch, "Empty Compose must keep the palette open without changing Home")
        await restored.shutdown()
    }
    @MainActor func testStopDuringFirstConfigurationPreservesRetryChoices() async throws {
        let root = try temporary(), audit = root.appendingPathComponent("audit.jsonl")
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--config", "--stall-mode", "--audit-path=" + audit.path]
        let configuration = SessionConfiguration(executable: store.settings.executable, arguments: store.settings.arguments, values: ["model": "large", "mode": "plan"])
        await store.create(path: root.path, worktree: false, initialPrompt: "Keep this prompt", configuration: configuration)
        let chat = try XCTUnwrap(store.selected)
        chat.launching = false; store.send(chat)
        let prompt = try XCTUnwrap(chat.promptTask)
        var setterReached = false
        for _ in 0..<300 {
            if let log = try? String(contentsOf: audit, encoding: .utf8), log.split(separator: "\n").contains(where: { line in
                guard let call = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return false }
                return call["method"].string == "session/set_config_option" && call["params"]["configId"].string == "mode"
            }) { setterReached = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(setterReached)
        store.stop(chat); await prompt.value
        XCTAssertNil(chat.transcript.remoteID)
        XCTAssertNil(store.sessions.first { $0.id == chat.id }?.remoteSessionID)
        XCTAssertEqual(chat.transcript.pendingConfiguration, configuration)
        XCTAssertEqual(chat.draft, "Keep this prompt")
        XCTAssertTrue(chat.transcript.items.isEmpty)
        try Data().write(to: URL(fileURLWithPath: audit.path + ".continue"))
        store.send(chat); try await finish(chat, store: store)
        XCTAssertEqual(chat.state, .ready, chat.lastError ?? "")
        let applied = try await XCTUnwrap(chat.connection).request("fixture/config", params: [:])
        XCTAssertEqual(applied["lastPrompt"]["model"], "large")
        XCTAssertEqual(applied["lastPrompt"]["mode"], "plan")
        let calls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(calls.filter { $0["method"].string == "session/new" }.count, 2)
        XCTAssertFalse(calls.contains { ["session/resume", "session/load"].contains($0["method"].string) })
        await store.shutdown()
    }
    @MainActor func testModelChangeDropsDisappearedDefaultsButPreservesExplicitChoices() async throws {
        for explicit in [false, true] {
            let root = try temporary(), data = root.appendingPathComponent("data")
            let store = AppStore(directory: data)
            store.settings.executable = "/usr/bin/python3"
            store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--config", "--model-hides-fast"]
            await store.openHome(path: root.path)
            store.chooseHomeConfiguration(id: "model", value: "large")
            store.chooseHomeConfiguration(id: "mode", value: "plan")
            if explicit { store.chooseHomeConfiguration(id: "fast", value: false) }
            store.newSessionDraft.text = "Launch with selected model and mode"
            await store.shutdown()
            let restored = AppStore(directory: data); restored.settings = store.settings
            await restored.restore(); await restored.startFromHome()
            let chat = try XCTUnwrap(restored.selected)
            try await finish(chat, store: restored)
            if explicit {
                XCTAssertEqual(chat.state, .failed)
                XCTAssertTrue(chat.transcript.items.isEmpty)
                XCTAssertEqual(chat.draft, "Launch with selected model and mode")
                XCTAssertEqual(chat.transcript.pendingConfiguration?.values["fast"], false)
                XCTAssertNil(chat.transcript.remoteID, "A failed first setup must not retain an unsaved remote session")
                XCTAssertNil(restored.sessions.first { $0.id == chat.id }?.remoteSessionID)
                XCTAssertEqual(chat.transcript.pendingConfiguration?.values["model"], "large", "Retry must reapply choices consumed before the failure")
                restored.continueWithCurrentConfiguration(chat)
                try await restored.connect(chat)
                XCTAssertEqual(chat.state, .ready)
                XCTAssertEqual(chat.draft, "Launch with selected model and mode")
                restored.send(chat, text: "Establish saved context")
                try await finish(chat, store: restored)
                XCTAssertEqual(chat.draft, "Launch with selected model and mode")
                let establishedID = chat.transcript.remoteID
                chat.transcript.pendingConfiguration = SessionConfiguration(executable: restored.settings.executable, arguments: restored.settings.arguments, values: ["model": "removed-model"])
                await restored.disconnect(chat)
                do { try await restored.connect(chat); XCTFail("A rejected saved choice must still fail") } catch { }
                XCTAssertEqual(chat.transcript.remoteID, establishedID, "Failure while resuming must preserve the existing remote identity")
            } else {
                XCTAssertEqual(chat.state, .ready, chat.lastError ?? "")
                let applied = try await XCTUnwrap(chat.connection).request("fixture/config", params: [:])
                XCTAssertEqual(applied["lastPrompt"]["model"], "large")
                XCTAssertEqual(applied["lastPrompt"]["mode"], "plan")
                XCTAssertTrue(applied["lastPrompt"]["fast"].isNull)
                XCTAssertNil(chat.transcript.pendingConfiguration)
            }
            await restored.shutdown()
        }
    }
    @MainActor func testFirstLocalClaudeVisitDoesNotStartAgentAndSendResumesSameSession() async throws {
        for legacyNodeLauncher in [false, true] {
            let root = try temporary(), claude = root.appendingPathComponent("claude"), project = claude.appendingPathComponent("projects/encoded-project"), audit = root.appendingPathComponent("audit.jsonl")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let fixture = Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!
            let executable = root.appendingPathComponent(legacyNodeLauncher ? "node" : "claude-agent-acp")
            try (Data("#!/usr/bin/python3\n".utf8) + Data(contentsOf: fixture)).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let remote = "fe07e7d0-529e-4e96-a2c2-207a9a03a3f3"
            let file = project.appendingPathComponent(remote + ".jsonl")
            var rows: [JSONValue] = [
                ["type": "user", "uuid": "question", "parentUuid": nil, "sessionId": .string(remote), "message": ["role": "user", "content": "Original question"]],
                ["type": "assistant", "uuid": "answer", "parentUuid": "question", "sessionId": .string(remote), "message": ["id": "original-response", "role": "assistant", "content": "Original answer"]]
            ]
            try Data(rows.map { $0.pretty.replacingOccurrences(of: "\n", with: "") }.joined(separator: "\n").appending("\n").utf8).write(to: file)
            let store = AppStore(directory: root.appendingPathComponent("data"), claudeDirectory: claude)
            store.settings.executable = executable.path; store.settings.arguments = ["--resume", "--audit-path=" + audit.path]
            if legacyNodeLauncher { store.settings.arguments.insert(root.appendingPathComponent("node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js").path, at: 0) }
            var info = SessionInfo(projectPath: root.path, title: "External Claude session")
            info.importedFromAgent = true; info.remoteSessionID = remote; info.agentExecutable = executable.path; info.agentArguments = store.settings.arguments
            store.sessions = [info]
            let start = ContinuousClock.now; await store.select(info.id)
            print("First native selection: \(start.duration(to: .now))")
            XCTAssertNil(store.selected?.connection)
            XCTAssertFalse(FileManager.default.fileExists(atPath: audit.path), "Viewing local history must start no ACP process")
            XCTAssertEqual(store.selected?.transcript.items.map(\.text), ["Original question", "Original answer"])
            rows.append(["type": "user", "uuid": "external-new", "parentUuid": "answer", "sessionId": .string(remote), "message": ["role": "user", "content": "Appended elsewhere"]])
            try Data(rows.map { $0.pretty.replacingOccurrences(of: "\n", with: "") }.joined(separator: "\n").appending("\n").utf8).write(to: file)
            store.selected?.transcript.historyUpdatedAt = Date().addingTimeInterval(-31)
            store.selected?.draft = "Unsent draft"
            let initialChat = try XCTUnwrap(store.selected)
            initialChat.deliveryPaused = true
            store.enqueuePrompt(initialChat, text: "Paused follow-up", policy: .nextTurn)
            let interrupted = AgentFailure(error: ACPError.remoteFailure(-32603, "Provider explanation", ["errorKind": "rate_limit"]), deliveryID: initialChat.pendingPrompts.first?.id)
            initialChat.lastError = interrupted.details; initialChat.failure = interrupted
            await store.select(info.id)
            let chat = try XCTUnwrap(store.selected)
            XCTAssertEqual(chat.transcript.items.last?.text, "Appended elsewhere")
            XCTAssertEqual(chat.draft, "Unsent draft")
            XCTAssertEqual(chat.pendingPrompts.map(\.text), ["Paused follow-up"], "Native transcript refresh must preserve unsent owned messages")
            XCTAssertTrue(chat.deliveryPaused)
            XCTAssertEqual(chat.failure, interrupted, "Native transcript refresh must retain failure category and interrupted-request identity")
            for prompt in chat.pendingPrompts { store.removeQueuedPrompt(chat, id: prompt.id) }
            XCTAssertNil(chat.connection)
            store.send(chat, text: "Continue the existing session")
            try await finish(chat, store: store)
            let requests = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            XCTAssertEqual(requests.filter { $0["method"] == "session/resume" }.first?["params"]["sessionId"].string, remote)
            XCTAssertFalse(requests.contains { ["session/new", "session/load"].contains($0["method"].string) })
            XCTAssertEqual(chat.transcript.items.filter { $0.text == "Original question" }.count, 1)
            await store.shutdown()
        }
    }
    @MainActor func testStoppingHistoryReconnectDoesNotLaunchReplacementPeer() async throws {
        let root = try temporary(), catalog = root.appendingPathComponent("catalog.json"), audit = root.appendingPathComponent("audit.jsonl")
        let rows: JSONValue = ["sessions": [["sessionId": "external", "cwd": .string(root.path)]]]
        try JSONEncoder().encode(rows).write(to: catalog)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--list-path=" + catalog.path, "--resume", "--resist-term", "--resist-eof", "--audit-path=" + audit.path]
        await store.refreshSessionHistory(); let id = try XCTUnwrap(store.sessions.first?.id)
        await store.select(id); let chat = try XCTUnwrap(store.selected)
        chat.transcript.historyUpdatedAt = Date().addingTimeInterval(-31)
        let reload = Task { await store.select(id) }
        let deadline = ContinuousClock.now + .seconds(3)
        while chat.state != .connecting && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(chat.state, .connecting)
        store.stop(chat); await reload.value
        let stopDeadline = ContinuousClock.now + .seconds(3)
        while chat.state == .connecting && ContinuousClock.now < stopDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(chat.connection)
        XCTAssertNil(chat.lastError, "Stopping a history refresh is not a load failure")
        XCTAssertEqual(chat.transcript.items.last?.text, "Existing external answer")
        await store.shutdown()
        let requests = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(requests.filter { $0["method"] == "initialize" }.count, 2, "Stop during peer closure must not start a replacement")
        for pid in Set(requests.map { Int32($0["pid"].int) }) { XCTAssertTrue(kill(pid, 0) == -1 && errno == ESRCH) }
    }
    @MainActor func testUntimestampedHistoryExpiresAndSwitchingDuringReconnectReleasesPeer() async throws {
        let root = try temporary(), catalog = root.appendingPathComponent("catalog.json"), audit = root.appendingPathComponent("audit.jsonl")
        let rows: JSONValue = ["sessions": [["sessionId": "external", "cwd": .string(root.path)]]]
        try JSONEncoder().encode(rows).write(to: catalog)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--list-path=" + catalog.path, "--resume", "--resist-term", "--resist-eof", "--audit-path=" + audit.path]
        await store.refreshSessionHistory()
        let id = try XCTUnwrap(store.sessions.first?.id)
        await store.select(id)
        XCTAssertGreaterThan(try XCTUnwrap(store.selected?.transcript.historyUpdatedAt), Date().addingTimeInterval(-5))
        store.send(try XCTUnwrap(store.selected), text: "Local activity must not replace provider freshness")
        try await finish(XCTUnwrap(store.selected), store: store)
        XCTAssertNil(store.sessions.first { $0.id == id }?.agentUpdatedAt)
        await store.select(id)
        store.selected?.transcript.historyUpdatedAt = Date().addingTimeInterval(-31)
        weak let abandoned = store.selected
        let reload = Task { await store.select(id) }
        let deadline = ContinuousClock.now + .seconds(2)
        while store.selected?.state != .connecting && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.selected?.state, .connecting)
        let other = SessionInfo(projectPath: root.path); store.sessions.append(other)
        await store.select(other.id)
        await reload.value
        let evictionDeadline = ContinuousClock.now + .seconds(2)
        while abandoned != nil && ContinuousClock.now < evictionDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(abandoned, "A superseded refresh must release both its transcript and peer")
        XCTAssertEqual(store.selectedID, other.id)
        await store.shutdown()
        let requests = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(requests.filter { $0["method"] == "session/load" }.count, 2, "Unknown catalog freshness must expire, not cache forever")
        for pid in Set(requests.map { Int32($0["pid"].int) }) { XCTAssertTrue(kill(pid, 0) == -1 && errno == ESRCH, "Leaked agent PID \(pid)") }
    }
    @MainActor func testHistorySelectionUsesDiskCacheAndRefreshesChangedSessions() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data"), catalog = root.appendingPathComponent("catalog.json"), audit = root.appendingPathComponent("audit.jsonl")
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        let hook = root.appendingPathComponent("slow-monitor")
        try "#!/bin/sh\nsleep 1\nprintf 'token\\0'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try await Repository.run(["config", "core.fsmonitor", hook.path], at: root.path)
        let rows: JSONValue = ["sessions": [["sessionId": "external", "cwd": .string(root.path), "updatedAt": "2026-09-30T10:00:00Z"]]]
        try JSONEncoder().encode(rows).write(to: catalog)
        let store = AppStore(directory: data)
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--list-path=" + catalog.path, "--resume", "--slow-load", "--audit-path=" + audit.path]
        await store.refreshSessionHistory()
        let id = try XCTUnwrap(store.sessions.first?.id)
        let initial = Task { await store.select(id) }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(store.selectedID, id)
        XCTAssertEqual(store.selected?.state, .connecting, "Workspace scans must not delay history loading")
        await initial.value
        XCTAssertEqual(store.selected?.transcript.items.last?.text, "Existing external answer")
        weak let evicted = store.selected
        let other = SessionInfo(projectPath: root.path); store.sessions.append(other)
        await store.select(other.id)
        let evictionDeadline = ContinuousClock.now + .seconds(2)
        while evicted != nil && ContinuousClock.now < evictionDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(evicted, "Idle transcripts should be evicted, not cached in RAM")
        let clock = ContinuousClock(), start = clock.now
        await store.select(id)
        let elapsed = start.duration(to: clock.now)
        print("Cached selection: \(elapsed)")
        XCTAssertLessThan(elapsed, .milliseconds(500))
        XCTAssertNil(store.selected?.connection, "Reading cached history needs no agent process")
        XCTAssertEqual(store.selected?.transcript.items.last?.text, "Existing external answer")
        store.sessions[0].agentUpdatedAt = try XCTUnwrap(store.sessions[0].agentUpdatedAt).addingTimeInterval(1)
        let refresh = Task { await store.select(id) }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(store.selected?.state, .connecting)
        XCTAssertEqual(store.selected?.transcript.items.last?.text, "Existing external answer", "Keep cached content visible throughout replay")
        await refresh.value
        XCTAssertEqual(store.selected?.transcript.items.count, 2, "Replay must replace history without duplicates")
        await store.shutdown()
        let restarted = AppStore(directory: data); restarted.settings = store.settings
        restarted.sessions = try await SessionStorage(directory: data).list()
        await restarted.select(id)
        XCTAssertNil(restarted.selected?.connection)
        try await restarted.connect(XCTUnwrap(restarted.selected))
        let requests = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(requests.filter { $0["method"] == "session/load" }.count, 2)
        XCTAssertEqual(requests.filter { $0["method"] == "session/resume" }.count, 1)
        await restarted.shutdown()
    }
    @MainActor func testAgentHistoryDiscoversAllPagesAndLoadsOnlySelection() async throws {
        let root = try temporary(), catalog = root.appendingPathComponent("catalog.json"), audit = root.appendingPathComponent("audit.jsonl")
        let rows: JSONValue = ["sessions": .array((0..<5).map { i in
            ["sessionId": .string("external-\(i)"), "cwd": .string(root.path), "title": .string("External \(i)"), "updatedAt": "2026-09-30T10:00:00.123Z"]
        })]
        try JSONEncoder().encode(rows).write(to: catalog)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--list-path=" + catalog.path, "--resume", "--audit-path=" + audit.path]
        await store.restore(); await store.refreshSessionHistory()
        XCTAssertEqual(store.sessions.count, 5)
        let id = try XCTUnwrap(store.sessions.first?.id)
        store.togglePin(id); store.rename(id, title: "My title")
        await store.refreshSessionHistory()
        XCTAssertEqual(store.sessions.count, 5); XCTAssertTrue(store.sessions.first { $0.id == id }?.pinned == true)
        XCTAssertEqual(store.sessions.first { $0.id == id }?.title, "My title")
        var requests = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(requests.filter { $0["method"] == "session/list" }.count, 6)
        XCTAssertTrue(requests.filter { $0["method"] == "session/list" }.allSatisfy { $0["params"]["cwd"].isNull })
        XCTAssertTrue(requests.allSatisfy { ["initialize", "session/list"].contains($0["method"].string) })
        await store.select(id)
        let chat = try XCTUnwrap(store.selected)
        XCTAssertEqual(store.sessions.first { $0.id == id }?.title, "My title", "History replay must preserve a local rename")
        XCTAssertEqual(chat.transcript.items.filter { $0.kind == "user" }.map(\.text), ["Existing external question"])
        XCTAssertEqual(chat.transcript.items.filter { $0.kind == "assistant" }.map(\.text), ["Existing external answer"])
        requests = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(requests.filter { $0["method"] == "session/load" }.count, 1)
        XCTAssertFalse(requests.contains { ["session/new", "session/prompt", "session/resume"].contains($0["method"].string) })
        await store.archive(id); await store.refreshSessionHistory()
        XCTAssertTrue(store.sessions.first { $0.id == id }?.archived == true)
        await store.shutdown()
        let restored = AppStore(directory: root.appendingPathComponent("data")); restored.settings = store.settings
        await restored.restore(); await restored.refreshSessionHistory()
        XCTAssertEqual(restored.sessions.count, 5)
        XCTAssertTrue(restored.sessions.first { $0.id == id }?.archived == true)
        await restored.shutdown()
    }
    @MainActor func testAgentHistoryFailedPageKeepsPriorIndex() async throws {
        let root = try temporary(), catalog = root.appendingPathComponent("catalog.json")
        let rows: JSONValue = ["sessions": .array((0..<3).map { ["sessionId": .string("external-\($0)"), "cwd": .string(root.path)] })]
        try JSONEncoder().encode(rows).write(to: catalog)
        let store = AppStore(directory: root.appendingPathComponent("data")); await store.create(path: root.path, worktree: false)
        let existing = store.sessions[0].id
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--list-path=" + catalog.path, "--bad-list-page"]
        await store.refreshSessionHistory()
        XCTAssertEqual(store.sessions.map(\.id), [existing]); XCTAssertNotNil(store.sessionHistoryError)
        store.settings.arguments.removeLast(); store.settings.arguments.append("--repeat-list-cursor")
        await store.refreshSessionHistory()
        XCTAssertEqual(store.sessions.map(\.id), [existing]); XCTAssertNotNil(store.sessionHistoryError)
        await store.shutdown()
    }
    @MainActor func testHistoryUnsupportedInvalidMetadataAndShutdownDoNotChangeLocalHistory() async throws {
        let root = try temporary(), catalog = root.appendingPathComponent("catalog.json"), audit = root.appendingPathComponent("audit.jsonl")
        let store = AppStore(directory: root.appendingPathComponent("data")); await store.create(path: root.path, worktree: false)
        let id = store.sessions[0].id
        store.settings.executable = "/usr/bin/python3"
        let fixture = Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path
        store.settings.arguments = [fixture, "--audit-path=" + audit.path]
        await store.refreshSessionHistory()
        XCTAssertNil(store.sessionHistoryError); XCTAssertEqual(store.sessions.map(\.id), [id])
        XCTAssertFalse(try String(contentsOf: audit, encoding: .utf8).contains("session/list"))
        let malformed: JSONValue = ["sessions": [["sessionId": "external", "cwd": "relative"]]]
        try JSONEncoder().encode(malformed).write(to: catalog)
        store.settings.arguments = [fixture, "--list-path=" + catalog.path, "--audit-path=" + audit.path]
        await store.refreshSessionHistory()
        XCTAssertNotNil(store.sessionHistoryError); XCTAssertEqual(store.sessions.map(\.id), [id])
        let valid: JSONValue = ["sessions": [["sessionId": "external", "cwd": .string(root.path)]]]
        try JSONEncoder().encode(valid).write(to: catalog)
        store.settings.arguments.append("--stall-list")
        let refresh = Task { await store.refreshSessionHistory() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !store.refreshingSessionHistory && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.refreshingSessionHistory)
        await store.shutdown(); await refresh.value
        XCTAssertFalse(store.refreshingSessionHistory); XCTAssertEqual(store.sessions.map(\.id), [id])
        let requests = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        for pid in Set(requests.map { Int32($0["pid"].int) }) { XCTAssertTrue(kill(pid, 0) == -1 && errno == ESRCH) }
    }
    @MainActor func testTranscriptOnlySaveDoesNotInvalidateSidebar() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path]
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected); try await store.connect(chat)
        let peer = try XCTUnwrap(chat.connection)
        let unchanged = expectation(description: "Transcript updates must not invalidate sidebar metadata"); unchanged.isInverted = true
        withObservationTracking { _ = store.sidebarSnapshot.rows } onChange: { unchanged.fulfill() }
        _ = try await peer.request("fixture/update-only", params: [:])
        await fulfillment(of: [unchanged], timeout: 1.5)
        XCTAssertTrue(chat.transcript.items.contains { $0.text == "Transcript-only update" })
        await store.shutdown()
    }
    @MainActor func testDamagedLegacyTranscriptDoesNotBlockExternalDiscovery() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data"), catalog = root.appendingPathComponent("catalog.json")
        let store = AppStore(directory: data); await store.create(path: root.path, worktree: false)
        let original = store.sessions[0].id
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--list-path=" + catalog.path]
        store.sessions[0].agentExecutable = store.settings.executable; store.sessions[0].agentArguments = store.settings.arguments
        try Data("corrupt history".utf8).write(to: data.appendingPathComponent(original.uuidString + ".json"))
        let rows: JSONValue = ["sessions": [["sessionId": "external", "cwd": .string(root.path)]]]
        try JSONEncoder().encode(rows).write(to: catalog)
        await store.refreshSessionHistory()
        XCTAssertEqual(store.sessions.count, 2); XCTAssertTrue(store.sessions.contains { $0.id == original })
        XCTAssertTrue(store.sessions.contains { $0.remoteSessionID == "external" }); XCTAssertNotNil(store.sessionHistoryError)
        await store.shutdown()
    }
    @MainActor func testHomeCatalogFamilyTransitionsDoNotLaunchHiddenChoices() async throws {
        let root = try temporary(), marker = root.appendingPathComponent("modern-catalog")
        let store = AppStore(directory: root.appendingPathComponent("data")); store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--legacy-models", "--config-switch-path=" + marker.path]
        await store.restore(); store.newSessionDraft.projectPath = root.path; store.newSessionDraft.text = "Keep through refresh"
        await store.refreshHomeConfiguration()
        store.chooseHomeLegacy(model: false, id: "plan"); store.chooseHomeLegacy(model: true, id: "large")
        try Data().write(to: marker)
        await store.refreshHomeConfiguration(force: true)
        XCTAssertNil(store.newSessionDraft.configuration?.legacyValues, "Modern controls must not retain hidden legacy launch choices")
        XCTAssertEqual(store.newSessionDraft.text, "Keep through refresh")
        store.chooseHomeConfiguration(id: "model", value: "large"); store.chooseHomeConfiguration(id: "mode", value: "plan")
        await store.startFromHome()
        let modern = try XCTUnwrap(store.selected); try await finish(modern, store: store)
        XCTAssertEqual(modern.state, .ready)
        if let peer = modern.connection {
            let applied = try await peer.request("fixture/config", params: [:])
            XCTAssertEqual(applied["lastPrompt"]["model"], "large"); XCTAssertEqual(applied["lastPrompt"]["mode"], "plan")
        } else { XCTFail("Modern launch did not connect") }
        await store.openHome()
        try FileManager.default.removeItem(at: marker)
        store.newSessionDraft.text = "Legacy after refresh"
        await store.refreshHomeConfiguration(force: true)
        XCTAssertEqual(store.newSessionDraft.configuration?.values, [:], "Legacy controls must not retain hidden modern launch choices")
        store.chooseHomeLegacy(model: false, id: "plan"); store.chooseHomeLegacy(model: true, id: "large")
        await store.startFromHome()
        let legacy = try XCTUnwrap(store.selected); try await finish(legacy, store: store)
        XCTAssertEqual(legacy.state, .ready)
        if let peer = legacy.connection {
            let applied = try await peer.request("fixture/config", params: [:])
            XCTAssertEqual(applied["lastPrompt"], ["modeId": "plan", "modelId": "large"])
        } else { XCTFail("Legacy launch did not connect") }
        await store.shutdown()
    }
    @MainActor func testLegacyHomeMenusSaveChoicesAndIgnoreModernOrChangedAgent() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data"), audit = root.appendingPathComponent("audit.jsonl")
        let store = AppStore(directory: data); store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--legacy-models", "--audit-path=" + audit.path]
        await store.restore(); store.newSessionDraft.projectPath = root.path
        await store.refreshHomeConfiguration()
        XCTAssertEqual(store.homeLegacyState(model: false)["currentModeId"], "default")
        XCTAssertEqual(store.homeLegacyState(model: true)["currentModelId"], "small")
        store.chooseHomeLegacy(model: false, id: "plan"); store.chooseHomeLegacy(model: true, id: "large")
        store.chooseHomeLegacy(model: true, id: "not-advertised")
        XCTAssertEqual(store.homeLegacyState(model: true)["currentModelId"], "large")
        XCTAssertTrue(store.sessions.isEmpty)
        await store.shutdown()
        let restored = AppStore(directory: data); restored.settings = store.settings
        await restored.restore(); await restored.refreshHomeConfiguration()
        XCTAssertEqual(restored.homeLegacyState(model: false)["currentModeId"], "plan")
        XCTAssertEqual(restored.homeLegacyState(model: true)["currentModelId"], "large")
        let savedChoices = restored.newSessionDraft.configuration
        restored.settings.arguments += ["--config"]
        XCTAssertTrue(restored.homeLegacyState(model: false)["availableModes"].array.isEmpty)
        restored.chooseHomeLegacy(model: false, id: "default")
        XCTAssertEqual(restored.newSessionDraft.configuration, savedChoices)
        await restored.refreshHomeConfiguration()
        XCTAssertFalse(restored.homeConfigurationOptions.isEmpty)
        XCTAssertTrue(restored.homeLegacyState(model: false)["availableModes"].array.isEmpty, "Modern config options must take precedence over legacy state")
        XCTAssertTrue(restored.homeLegacyState(model: true)["availableModels"].array.isEmpty)
        await restored.shutdown()
        let calls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(calls.map { $0["method"].string }, ["initialize", "session/new", "initialize", "session/new"])
        for call in calls where call["method"].string == "initialize" {
            XCTAssertEqual(Darwin.kill(Int32(call["pid"].int), 0), -1); XCTAssertEqual(errno, ESRCH)
        }
    }
    @MainActor func testLegacyHomeChoicesApplyBeforePromptAndPersist() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data"), audit = root.appendingPathComponent("audit.jsonl")
        let arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--legacy-models", "--audit-path=" + audit.path]
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let draft: JSONValue = ["projectPath": .string(root.path), "text": "Legacy configured launch", "worktree": false,
            "configuration": ["executable": "/usr/bin/python3", "arguments": .array(arguments.map(JSONValue.string)), "values": [:], "legacyValues": ["modeId": "plan", "modelId": "large"]]]
        try JSONEncoder().encode(draft).write(to: data.appendingPathComponent("new-session-draft.json"))
        let store = AppStore(directory: data); store.settings.executable = "/usr/bin/python3"; store.settings.arguments = arguments
        await store.restore(); await store.refreshHomeConfiguration(); await store.shutdown()
        let restored = AppStore(directory: data); restored.settings = store.settings
        await restored.restore(); await restored.refreshHomeConfiguration(); await restored.startFromHome()
        let chat = try XCTUnwrap(restored.selected); try await finish(chat, store: restored)
        let applied = try await XCTUnwrap(chat.connection).request("fixture/config", params: [:])
        XCTAssertEqual(applied["lastPrompt"], ["modeId": "plan", "modelId": "large"], "Saved legacy choices must reach the agent before the first prompt")
        XCTAssertNil(chat.transcript.pendingConfiguration)
        await restored.shutdown()
        let calls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(calls.filter { $0["method"].string == "session/new" }.count, 2, "Discovery restart must use its saved legacy catalog")
        let methods = calls.map { $0["method"].string }
        XCTAssertLessThan(try XCTUnwrap(methods.firstIndex(of: "session/set_model")), try XCTUnwrap(methods.firstIndex(of: "session/set_mode")))
        XCTAssertLessThan(try XCTUnwrap(methods.firstIndex(of: "session/set_mode")), try XCTUnwrap(methods.firstIndex(of: "session/prompt")))
    }
    @MainActor func testInvalidOrRejectedLegacyHomeChoicesPreserveUnsentPrompt() async throws {
        for rejected in [false, true] {
            let root = try temporary(), data = root.appendingPathComponent("data"), audit = root.appendingPathComponent("audit.jsonl")
            let arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--legacy-models", "--audit-path=" + audit.path] + (rejected ? ["--reject-legacy"] : [])
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let draft: JSONValue = ["projectPath": .string(root.path), "text": "Keep legacy prompt", "worktree": false,
                "configuration": ["executable": "/usr/bin/python3", "arguments": .array(arguments.map(JSONValue.string)), "values": [:], "legacyValues": ["modeId": "plan", "modelId": .string(rejected ? "large" : "removed-model")]]]
            try JSONEncoder().encode(draft).write(to: data.appendingPathComponent("new-session-draft.json"))
            let store = AppStore(directory: data); store.settings.executable = "/usr/bin/python3"; store.settings.arguments = arguments
            await store.restore(); await store.startFromHome()
            let chat = try XCTUnwrap(store.selected); try await finish(chat, store: store)
            XCTAssertEqual(chat.state, .failed); XCTAssertEqual(chat.draft, "Keep legacy prompt")
            XCTAssertTrue(chat.transcript.items.isEmpty); XCTAssertNotNil(chat.transcript.pendingConfiguration)
            await store.shutdown()
            let calls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            XCTAssertFalse(calls.contains { $0["method"].string == "session/prompt" })
            if !rejected { XCTAssertFalse(calls.contains { $0["method"].string.hasPrefix("session/set_") }, "Validate stale IDs against fresh advertised choices") }
        }
    }
    @MainActor func testAdditionalFoldersSurviveLaunchReconnectAndFork() async throws {
        for resume in [false, true] {
            let root = try temporary(parent: URL(fileURLWithPath: "/private/tmp")), primary = root.appendingPathComponent("primary"), extra = root.appendingPathComponent("extra"), data = root.appendingPathComponent("data"), audit = root.appendingPathComponent("audit.jsonl")
            for folder in [primary, extra] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            let file = extra.appendingPathComponent("library.txt")
            try "shared library".write(to: file, atomically: true, encoding: .utf8)
            if resume {
                _ = try await Repository.run(["init", "-b", "main"], at: primary.path)
                _ = try await Repository.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "main"], at: primary.path)
            }
            let store = AppStore(directory: data)
            store.settings.executable = "/usr/bin/python3"
            store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--additional-directories", "--fork", "--audit-path=" + audit.path] + (resume ? ["--resume"] : [])
            await store.restore()
            let draft: JSONValue = ["projectPath": .string(primary.path), "additionalDirectories": [.string(extra.path)], "text": "Use shared library", "worktree": .bool(resume)]
            store.newSessionDraft = try JSONDecoder().decode(NewSessionDraft.self, from: JSONEncoder().encode(draft))
            await store.startFromHome()
            let chat = try XCTUnwrap(store.selected)
            if resume {
                let info = try XCTUnwrap(store.selectedInfo)
                XCTAssertTrue(info.projectPath.hasPrefix(try Workspace(root: data.path).root + "/worktrees/"))
                XCTAssertEqual(info.worktreeSourcePath, try Workspace(root: primary.path).root)
                XCTAssertEqual(info.projectName, "primary")
                XCTAssertEqual(store.sidebarProjects, [try Workspace(root: primary.path).root])
                let status = try await Repository.status(at: primary.path)
                XCTAssertTrue(status.files.isEmpty, "Launching a worktree must leave the main repository clean")
            }
            try await finish(chat, store: store)
            do { let text = try await chat.workspace.read(file.path); XCTAssertEqual(text, "shared library") }
            catch { XCTFail("Explicit additional folder was excluded: \(error)") }
            XCTAssertTrue(chat.files.contains(file.path), "Additional folder files must be available to the editor/context/artifacts")
            await store.shutdown()
            let restored = AppStore(directory: data); restored.settings = store.settings
            await restored.restore()
            let reopened = try XCTUnwrap(restored.selected)
            if resume { XCTAssertEqual(restored.selectedInfo?.worktreeSourcePath, try Workspace(root: primary.path).root) }
            restored.send(reopened, text: "Continue across folders"); try await finish(reopened, store: restored)
            _ = try await restored.fork(reopened)
            let fork = try XCTUnwrap(restored.selected)
            if resume { XCTAssertEqual(restored.selectedInfo?.worktreeSourcePath, try Workspace(root: primary.path).root) }
            restored.send(fork, text: "Continue fork across folders"); try await finish(fork, store: restored)
            do { let text = try await fork.workspace.read(file.path); XCTAssertEqual(text, "shared library") }
            catch { XCTFail("Fork lost selected folder: \(error)") }
            await restored.shutdown()
            let calls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
            let lifecycle = calls.filter { ["session/new", "session/load", "session/resume", "session/fork"].contains($0["method"].string) }
            XCTAssertEqual(lifecycle.count, 4)
            for call in lifecycle {
                XCTAssertEqual(call["params"]["additionalDirectories"], [.string(extra.path)], call["method"].string)
                XCTAssertEqual(call["params"]["cwd"].string, chat.workspace.root, call["method"].string)
            }
            let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: data.appendingPathComponent("new-session-draft.json")))
            XCTAssertEqual(saved["additionalDirectories"], [.string(extra.path)])
        }
    }
    @MainActor func testUnsupportedAdditionalFoldersPreservePromptWithoutSending() async throws {
        let root = try temporary(parent: URL(fileURLWithPath: "/private/tmp")), primary = root.appendingPathComponent("primary"), extra = root.appendingPathComponent("extra"), audit = root.appendingPathComponent("audit.jsonl")
        for folder in [primary, extra] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--audit-path=" + audit.path]
        await store.restore()
        let draft: JSONValue = ["projectPath": .string(primary.path), "additionalDirectories": [.string(extra.path)], "text": "Keep selected scope", "worktree": false]
        store.newSessionDraft = try JSONDecoder().decode(NewSessionDraft.self, from: JSONEncoder().encode(draft))
        await store.startFromHome()
        let chat = try XCTUnwrap(store.selected); try await finish(chat, store: store)
        XCTAssertEqual(chat.state, .failed)
        XCTAssertEqual(chat.draft, "Keep selected scope")
        XCTAssertTrue(chat.transcript.items.isEmpty)
        let calls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(calls.map { $0["method"].string }, ["initialize"])
        await store.shutdown()
    }
    @MainActor func testBusyAdditionalFolderBlocksChangingItsCheckout() async throws {
        let root = try temporary(), primary = root.appendingPathComponent("primary"), repo = root.appendingPathComponent("repo"), sub = repo.appendingPathComponent("sub")
        for folder in [primary, sub] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        _ = try await Repository.run(["init", "-b", "main"], at: repo.path)
        _ = try await Repository.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "main"], at: repo.path)
        _ = try await Repository.run(["branch", "feature"], at: repo.path)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: sub.path)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--additional-directories"]
        await store.create(path: primary.path, worktree: false, additionalDirectories: [alias.path])
        let source = try XCTUnwrap(store.selected)
        store.send(source, text: "Wait at approval")
        for _ in 0..<200 { if !source.approvals.isEmpty { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(source.approvals.isEmpty)
        await store.openHome(path: repo.path)
        store.newSessionDraft.branch = "feature"; store.newSessionDraft.text = "Keep checkout stable"
        await store.startFromHome()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertNil(store.selectedID)
        XCTAssertEqual(store.newSessionDraft.text, "Keep checkout stable")
        let current = try await Repository.run(["symbolic-ref", "--short", "HEAD"], at: repo.path)
        XCTAssertEqual(current.trimmingCharacters(in: .newlines), "main")
        try await finish(source, store: store)
        if let selected = store.selected { try await finish(selected, store: store) }
        await store.shutdown()
    }
    @MainActor func testHomeBranchSwitchCannotChangeActiveChatCheckoutThroughAlias() async throws {
        for ancestor in [false, true] {
        let root = try temporary(), repo = root.appendingPathComponent("repo"), sub = repo.appendingPathComponent("sub")
        if ancestor {
            _ = try await Repository.run(["init", "-b", "parent"], at: root.path)
            _ = try await Repository.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "parent"], at: root.path)
        }
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try await Repository.run(["init", "-b", "main"], at: repo.path)
        _ = try await Repository.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "main"], at: repo.path)
        _ = try await Repository.run(["branch", "feature"], at: repo.path)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: ancestor ? root.path : sub.path)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path]
        await store.create(path: alias.path, worktree: false)
        let source = try XCTUnwrap(store.selected)
        store.send(source, text: "Wait at approval")
        for _ in 0..<200 {
            if !source.approvals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(source.approvals.isEmpty)
        await store.openHome(path: repo.path)
        store.newSessionDraft.branch = "feature"; store.newSessionDraft.text = "Keep this unsent"; store.newSessionDraft.worktree = false
        await store.startFromHome()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertNil(store.selectedID)
        XCTAssertEqual(store.newSessionDraft.text, "Keep this unsent")
        XCTAssertNotNil(store.error)
        let current = try await Repository.run(["symbolic-ref", "--short", "HEAD"], at: repo.path)
        XCTAssertEqual(current.trimmingCharacters(in: .newlines), "main")
        store.error = nil; store.newSessionDraft.worktree = true
        await store.startFromHome()
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertTrue(source.busy)
        XCTAssertNotEqual(store.selectedInfo?.projectPath, repo.path)
        try await finish(try XCTUnwrap(store.selected), store: store)
        try await finish(source, store: store)
        await store.shutdown()
        }
    }
    @MainActor func testHomeCancellationAndShutdownCleanUnpublishedCheckoutPreparation() async throws {
        for (isolated, dirty, quit) in [(false, false, false), (true, false, false), (true, true, false), (true, false, true)] {
            let root = try temporary(), repo = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = try await Repository.run(["init", "-b", "main"], at: repo.path)
            _ = try await Repository.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "main"], at: repo.path)
            _ = try await Repository.run(["branch", "feature"], at: repo.path)
            let marker = root.appendingPathComponent("checkout-marker")
            let hook = repo.appendingPathComponent(".git/hooks/post-checkout")
            let quoted = marker.path.replacingOccurrences(of: "'", with: "'\\''")
            let edits = dirty ? "printf 'preserved edits' > scratch.txt\n" : ""
            // Hold the checkout until cancellation; a one-second hook can finish before the test resumes.
            try "#!/bin/sh\n\(edits)printf READY > '\(quoted)'\nsleep 60\n".write(to: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
            let store = AppStore(directory: root.appendingPathComponent("data"))
            store.settings.executable = "/usr/bin/python3"
            let audit = root.appendingPathComponent("audit.jsonl")
            store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--audit-path=" + audit.path]
            store.newSessionDraft = NewSessionDraft(projectPath: repo.path, text: "Keep unsent", worktree: isolated)
            store.newSessionDraft.branch = "feature"
            let clock = ContinuousClock(), start = ContinuousClock.now
            let launch = Task { await store.startFromHome() }
            // Checkout readiness exceeded ten seconds; await the condition within a bounded deadline.
            while start.duration(to: clock.now) < .seconds(30) {
                if FileManager.default.fileExists(atPath: marker.path) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "isolated=\(isolated) dirty=\(dirty) quit=\(quit) starting=\(store.startingSession) error=\(store.error ?? "none")")
            XCTAssertNil(store.selectedID)
            if quit { await store.shutdown() } else { await store.cancelHomeDiscovery() }
            await launch.value
            XCTAssertTrue(store.sessions.isEmpty)
            XCTAssertEqual(store.newSessionDraft.text, "Keep unsent")
            XCTAssertFalse(FileManager.default.fileExists(atPath: audit.path), "Cancelled preparation must not launch an ACP agent")
            let worktrees = try await Repository.run(["worktree", "list", "--porcelain"], at: repo.path)
            let paths = worktrees.components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst(9)) }
            XCTAssertEqual(paths.count, dirty ? 2 : 1)
            if dirty {
                XCTAssertNotNil(store.error, "Preserved worktree must be visible to the user")
                let primaryRoot = try Workspace(root: repo.path).root
                let remaining = try XCTUnwrap(paths.first { $0 != primaryRoot })
                XCTAssertTrue(remaining.hasPrefix(try Workspace(root: root.path).root + "/data/worktrees/"))
                XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: remaining).appendingPathComponent("scratch.txt"), encoding: .utf8), "preserved edits")
            }
            await store.shutdown()
        }
    }
    @MainActor func testHomeBranchSelectionControlsSessionCheckout() async throws {
        for isolated in [false, true] {
            let root = try temporary(), repo = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = try await Repository.run(["init", "-b", "main"], at: repo.path)
            _ = try await Repository.run(["config", "user.name", "Test"], at: repo.path)
            _ = try await Repository.run(["config", "user.email", "test@example.invalid"], at: repo.path)
            let file = repo.appendingPathComponent("branch.txt")
            try "main contents".write(to: file, atomically: true, encoding: .utf8)
            _ = try await Repository.run(["add", "branch.txt"], at: repo.path)
            _ = try await Repository.run(["commit", "-m", "main"], at: repo.path)
            _ = try await Repository.run(["switch", "-c", "feature"], at: repo.path)
            try "feature contents".write(to: file, atomically: true, encoding: .utf8)
            _ = try await Repository.run(["commit", "-am", "feature"], at: repo.path)
            _ = try await Repository.run(["switch", "main"], at: repo.path)
            if isolated { try "unsaved main work".write(to: file, atomically: true, encoding: .utf8) }
            let store = AppStore(directory: root.appendingPathComponent("data"))
            store.settings.executable = "/usr/bin/python3"
            store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path]
            let draft: JSONValue = ["projectPath": .string(repo.path), "text": "Selected branch", "worktree": .bool(isolated), "branch": "feature"]
            store.newSessionDraft = try JSONDecoder().decode(NewSessionDraft.self, from: JSONEncoder().encode(draft))
            await store.startFromHome()
            let info = try XCTUnwrap(store.selectedInfo)
            XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: info.projectPath).appendingPathComponent("branch.txt"), encoding: .utf8), "feature contents")
            let current = try await Repository.run(["symbolic-ref", "--short", "HEAD"], at: repo.path)
            XCTAssertEqual(current.trimmingCharacters(in: .newlines), isolated ? "main" : "feature")
            if isolated { XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unsaved main work") }
            try await finish(try XCTUnwrap(store.selected), store: store)
            await store.shutdown()
            let saved = try await SessionStorage(directory: root.appendingPathComponent("data")).loadNewSessionDraft()
            var restored = try XCTUnwrap(saved)
            XCTAssertEqual(restored.branch, "feature")
            restored.projectPath = root.path
            XCTAssertNil(restored.branch, "A saved branch must not follow a different project")
        }
    }
    @MainActor func testShutdownCancelsNamedBranchHookWithoutChangingDraft() async throws {
        let root = try temporary(), marker = root.appendingPathComponent("branch-hook-pids")
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        _ = try await Repository.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "base"], at: root.path)
        let hook = root.appendingPathComponent(".git/hooks/reference-transaction")
        try "#!/bin/sh\nif [ \"$1\" = prepared ]; then\n  printf '%s\\n' \"$$\" \"$PPID\" > '\(marker.path)'\n  sleep 60\nfi\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.newSessionDraft = NewSessionDraft(projectPath: root.path, text: "Keep this draft")
        addTeardownBlock { await store.shutdown() }
        var completed = false
        let operation = Task { let result = await store.createHomeBranch("pending"); completed = true; return result }
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var pids: [Int32] = []
        while pids.count != 2, !completed, clock.now < deadline {
            pids = (try? String(contentsOf: marker, encoding: .utf8))?.split(separator: "\n").compactMap { Int32($0) } ?? []
            if pids.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(pids.count, 2, store.error ?? "Branch hook did not become ready")
        await store.shutdown()
        for pid in pids { XCTAssertEqual(kill(pid, 0), -1, "Quit must wait for its owned Git and hook processes") }
        operation.cancel() // Cleanup even when the old untracked implementation fails above.
        let result = await operation.value
        XCTAssertFalse(result)
        XCTAssertNil(store.newSessionDraft.branch)
        XCTAssertEqual(store.newSessionDraft.text, "Keep this draft")
        let saved = try await SessionStorage(directory: root.appendingPathComponent("data")).loadNewSessionDraft()
        XCTAssertNil(saved?.branch)
        XCTAssertEqual(saved?.text, "Keep this draft")
    }
    @MainActor func testBranchPopoverBlocksHomeSubmission() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path]
        store.newSessionDraft = NewSessionDraft(projectPath: root.path, text: "Keep unsent while naming branch")
        store.showNewBranch = true
        await store.startFromHome()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.newSessionDraft.text, "Keep unsent while naming branch")
        await store.shutdown()
    }
    @MainActor func testHomeNamedBranchLaunchAndRestart() async throws {
        for isolated in [false, true] {
            let root = try temporary(), repo = root.appendingPathComponent("repo"), data = root.appendingPathComponent("data")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            _ = try await Repository.run(["init", "-b", "main"], at: repo.path)
            _ = try await Repository.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "base"], at: repo.path)
            let store = AppStore(directory: data)
            store.settings.executable = "/usr/bin/python3"
            store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path]
            store.newSessionDraft = NewSessionDraft(projectPath: repo.path, text: "Named branch task", worktree: isolated)
            let made = await store.createHomeBranch("feature/named")
            XCTAssertTrue(made, store.error ?? "")
            XCTAssertEqual(store.newSessionDraft.branch, "feature/named")
            XCTAssertEqual(store.newSessionDraft.text, "Named branch task")
            let current = try await Repository.run(["symbolic-ref", "--short", "HEAD"], at: repo.path)
            XCTAssertEqual(current.trimmingCharacters(in: .newlines), "main", "Creating a ref must not switch the checkout")
            let saved = try await SessionStorage(directory: data).loadNewSessionDraft()
            XCTAssertEqual(saved?.branch, "feature/named")
            XCTAssertEqual(saved?.text, "Named branch task")
            let duplicate = await store.createHomeBranch("feature/named")
            XCTAssertFalse(duplicate); XCTAssertNotNil(store.error)
            await store.startFromHome()
            try await finish(try XCTUnwrap(store.selected), store: store)
            let mainBranch = try await Repository.run(["symbolic-ref", "--short", "HEAD"], at: repo.path)
            XCTAssertEqual(mainBranch.trimmingCharacters(in: .newlines), isolated ? "main" : "feature/named")
            if isolated { XCTAssertNotEqual(store.selectedInfo?.projectPath, repo.path) }
            await store.shutdown()
            let restored = AppStore(directory: data)
            await restored.restore()
            XCTAssertEqual(restored.newSessionDraft.branch, "feature/named")
            await restored.shutdown()
        }
    }
    @MainActor func testHomeBranchConflictPreservesCheckoutAndUnsentPrompt() async throws {
        let root = try temporary()
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        _ = try await Repository.run(["config", "user.name", "Test"], at: root.path)
        _ = try await Repository.run(["config", "user.email", "test@example.invalid"], at: root.path)
        let file = root.appendingPathComponent("branch.txt")
        try "main".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Repository.run(["add", "branch.txt"], at: root.path)
        _ = try await Repository.run(["commit", "-m", "main"], at: root.path)
        _ = try await Repository.run(["switch", "-c", "feature"], at: root.path)
        try "feature".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Repository.run(["commit", "-am", "feature"], at: root.path)
        _ = try await Repository.run(["switch", "main"], at: root.path)
        try "keep my edits".write(to: file, atomically: true, encoding: .utf8)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path]
        let draft: JSONValue = ["projectPath": .string(root.path), "text": "Keep unsent", "worktree": false, "branch": "feature"]
        store.newSessionDraft = try JSONDecoder().decode(NewSessionDraft.self, from: JSONEncoder().encode(draft))
        await store.startFromHome()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.newSessionDraft.text, "Keep unsent")
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep my edits")
        await store.shutdown()
    }
    @MainActor func testCancelDuringDiscoveryReplacementPreventsRestart() async throws {
        let root = try temporary(), audit = root.appendingPathComponent("audit.jsonl")
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--config", "--stall-new", "--resist-term", "--audit-path=" + audit.path]
        await store.restore(); store.newSessionDraft = NewSessionDraft(projectPath: root.path, text: "Unsent")
        let first = Task { await store.refreshHomeConfiguration() }
        for _ in 0..<100 {
            if (try? String(contentsOf: audit, encoding: .utf8).split(separator: "\n").count) == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(store.discoveringHomeOptions)
        let replacement = Task { await store.refreshHomeConfiguration(force: true) }
        try await Task.sleep(for: .milliseconds(100))
        await store.cancelHomeDiscovery()
        await first.value; await replacement.value
        let calls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(calls.count, 2, "A newer Cancel must win while replacement awaits cleanup")
        XCTAssertTrue(store.homeConfigurationOptions.isEmpty)
        XCTAssertEqual(store.newSessionDraft.text, "Unsent")
        await store.shutdown()
    }
    @MainActor func testFreshHomeDiscoversConfigurationWithoutPromptOrHistory() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data"), store = AppStore(directory: data)
        store.settings.executable = "/usr/bin/python3"
        let audit = root.appendingPathComponent("audit.jsonl")
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--config", "--audit-path=" + audit.path]
        await store.restore()
        store.newSessionDraft.projectPath = root.path
        store.newSessionDraft.text = "Keep unsent"
        await store.refreshHomeConfiguration()
        XCTAssertEqual(store.homeConfigurationOptions.first { $0["id"].string == "model" }?["currentValue"], "small")
        XCTAssertEqual(store.homeConfigurationOptions.first { $0["id"].string == "mode" }?["currentValue"], "default")
        XCTAssertEqual(store.newSessionDraft.text, "Keep unsent")
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.selectedID)
        await store.shutdown()
        let restored = AppStore(directory: data); restored.settings = store.settings
        await restored.restore(); await restored.refreshHomeConfiguration()
        XCTAssertEqual(restored.homeConfigurationOptions.first { $0["id"].string == "model" }?["currentValue"], "small")
        XCTAssertTrue(restored.sessions.isEmpty)
        XCTAssertEqual(restored.newSessionDraft.text, "Keep unsent")
        let calls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(calls.map { $0["method"].string }, ["initialize", "session/new"], "Restart must use the saved catalog; no prompt or second process")
        XCTAssertEqual(Darwin.kill(Int32(calls[0]["pid"].int), 0), -1)
        XCTAssertEqual(errno, ESRCH)
        await restored.shutdown()
    }
    @MainActor func testHomeDiscoveryCancellationAndShutdownClosePeer() async throws {
        let root = try temporary(), audit = root.appendingPathComponent("audit.jsonl")
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--config", "--slow-new", "--audit-path=" + audit.path]
        await store.restore(); store.newSessionDraft = NewSessionDraft(projectPath: root.path, text: "Unsent")
        for count in [2, 4] {
            let discovery = Task { await store.refreshHomeConfiguration(force: true) }
            var calls: [JSONValue] = []
            for _ in 0..<100 {
                calls = (try? String(contentsOf: audit, encoding: .utf8))?.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? []
                if calls.count >= count { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(calls.count, count)
            if count == 2 { await store.cancelHomeDiscovery() } else { await store.shutdown() }
            await discovery.value
            XCTAssertFalse(store.discoveringHomeOptions)
            XCTAssertTrue(store.homeConfigurationOptions.isEmpty)
            XCTAssertEqual(store.newSessionDraft.text, "Unsent")
            XCTAssertTrue(store.sessions.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/agent-options.json").path))
            let pid = Int32(try XCTUnwrap(calls.last)["pid"].int)
            XCTAssertEqual(Darwin.kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
            if count == 2 {
                await store.refreshHomeConfiguration()
                let afterCancel = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n")
                XCTAssertEqual(afterCancel.count, 2, "Automatic Home tasks must not restart an explicitly cancelled discovery")
                XCTAssertTrue(store.homeConfigurationOptions.isEmpty)
            }
        }
    }
    @MainActor func testHomeDiscoveryCanAuthenticateWithoutCreatingChat() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--config", "--needs-auth"]
        await store.restore(); store.newSessionDraft.projectPath = root.path
        await store.refreshHomeConfiguration()
        XCTAssertTrue(store.homeDiscoveryError?.contains("Authentication required") == true)
        XCTAssertEqual(store.homeAuthMethods.first?["id"], "fixture-login")
        XCTAssertFalse(store.discoveringHomeOptions)
        await store.refreshHomeConfiguration(force: true, authentication: "fixture-login")
        XCTAssertNil(store.homeDiscoveryError)
        XCTAssertTrue(store.homeAuthMethods.isEmpty)
        XCTAssertEqual(store.homeConfigurationOptions.first { $0["id"].string == "model" }?["currentValue"], "small")
        XCTAssertTrue(store.sessions.isEmpty)
        await store.shutdown()
    }
    @MainActor func testHomeUsesRecentSessionOptionsBeforeDiscoveryCache() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--config"]
        await store.restore(); store.newSessionDraft.projectPath = root.path
        await store.refreshHomeConfiguration()
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        await store.setConfig(chat, id: "model", value: "large")
        await store.openHome()
        let effort = try XCTUnwrap(store.homeConfigurationOptions.first { $0["id"].string == "effort" })
        XCTAssertTrue(effort["options"].array.flatMap { $0["options"].array }.contains { $0["value"].string == "high" }, "The newer session catalog must expose newly available choices")
        await store.shutdown()
    }
    @MainActor func testHomeConfigurationAppliesBeforePromptAndSurvivesFailure() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data")
        let arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--config"]
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let values: [String: Any] = ["mode": "plan", "model": "large", "effort": "high", "fast": true]
        let draft: [String: Any] = ["projectPath": root.path, "text": "Configured launch", "worktree": false,
                                   "configuration": ["executable": "/usr/bin/python3", "arguments": arguments, "values": values]]
        try JSONSerialization.data(withJSONObject: draft).write(to: data.appendingPathComponent("new-session-draft.json"))
        let store = AppStore(directory: data)
        store.settings.executable = "/usr/bin/python3"; store.settings.arguments = arguments
        await store.restore(); await store.startFromHome()
        let chat = try XCTUnwrap(store.selected)
        try await finish(chat, store: store)
        let applied = try await XCTUnwrap(chat.connection).request("fixture/config", params: [:])
        XCTAssertEqual(applied["lastPrompt"], ["mode": "plan", "model": "large", "effort": "high", "fast": true])
        await store.openHome()
        await store.shutdown()
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: data.appendingPathComponent("new-session-draft.json"))) as! [String: Any]
        XCTAssertEqual((saved["configuration"] as? [String: Any])?["values"] as? NSDictionary, values as NSDictionary)
        let rejected = AppStore(directory: root.appendingPathComponent("rejected"))
        rejected.settings.executable = "/usr/bin/python3"; rejected.settings.arguments = arguments + ["--reject-config"]
        var failed = draft
        failed["configuration"] = ["executable": "/usr/bin/python3", "arguments": rejected.settings.arguments, "values": values]
        let rejectedData = root.appendingPathComponent("rejected")
        try FileManager.default.createDirectory(at: rejectedData, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: failed).write(to: rejectedData.appendingPathComponent("new-session-draft.json"))
        await rejected.restore(); await rejected.startFromHome()
        let rejectedChat = try XCTUnwrap(rejected.selected)
        try await finish(rejectedChat, store: rejected)
        XCTAssertEqual(rejectedChat.state, .failed)
        XCTAssertEqual(rejectedChat.draft, "Configured launch")
        XCTAssertTrue(rejectedChat.transcript.items.isEmpty, "Rejected configuration must not submit a prompt")
        await rejected.shutdown()
        let restored = AppStore(directory: rejectedData); restored.settings = rejected.settings
        await restored.restore()
        let restoredChat = try XCTUnwrap(restored.selected)
        do { try await restored.connect(restoredChat); XCTFail("Pending configuration must retry after restart") } catch { }
        XCTAssertEqual(restoredChat.draft, "Configured launch")
        restored.continueWithCurrentConfiguration(restoredChat)
        restored.send(restoredChat)
        try await finish(restoredChat, store: restored)
        XCTAssertEqual(restoredChat.state, .ready)
        XCTAssertEqual(restoredChat.transcript.items.first?.text, "Configured launch")
        XCTAssertNil(restoredChat.transcript.pendingConfiguration)
        await restored.shutdown()
    }
    @MainActor func testHomeCatalogUsesOnlyCurrentAgentAndDisplayedChoices() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--config"]
        await store.create(path: root.path, worktree: false)
        let source = try XCTUnwrap(store.selected)
        try await store.connect(source)
        await store.setConfig(source, id: "model", value: "large")
        await store.setConfig(source, id: "effort", value: "high")
        await store.openHome(path: root.path)
        XCTAssertEqual(store.homeConfigurationOptions.first { $0["id"].string == "model" }?["currentValue"], "large")
        XCTAssertEqual(store.newSessionDraft.configuration?.values["effort"], "high", "Every displayed choice must be applied, even without another click")
        XCTAssertNil(source.connection, "Opening Home must evict its idle peer")
        store.newSessionDraft.text = "Displayed configuration"
        await store.startFromHome()
        let launched = try XCTUnwrap(store.selected)
        try await finish(launched, store: store)
        let applied = try await XCTUnwrap(launched.connection).request("fixture/config", params: [:])
        XCTAssertEqual(applied["lastPrompt"]["model"], "large")
        XCTAssertEqual(applied["lastPrompt"]["effort"], "high")
        await store.openHome()
        let savedChoices = store.newSessionDraft.configuration
        store.settings.arguments += ["--different-agent"]
        XCTAssertTrue(store.homeConfigurationOptions.isEmpty)
        store.chooseHomeConfiguration(id: "mode", value: "plan")
        XCTAssertEqual(store.newSessionDraft.configuration, savedChoices, "Stale menus must not assign old IDs to a new agent")
        await store.refreshHomeConfiguration()
        XCTAssertEqual(store.homeConfigurationOptions.first { $0["id"].string == "model" }?["currentValue"], "small", "A changed agent must negotiate its own catalog")
        XCTAssertEqual(store.newSessionDraft.configuration?.arguments, store.settings.arguments)
        await store.shutdown()
    }
    @MainActor func testHomeDraftNavigationLaunchAndAttentionPersistence() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data"), store = AppStore(directory: data)
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path]
        await store.create(path: root.path, worktree: false)
        let original = try XCTUnwrap(store.selected)
        original.draft = "Original chat draft"
        original.state = .failed; original.lastError = "Needs verification input"
        await store.openHome(path: root.path)
        XCTAssertNil(store.selectedID)
        XCTAssertEqual(store.attentionSessions.first?.id, original.id)
        store.newSessionDraft.text = "Home prompt 🦉"
        await store.goBack()
        XCTAssertEqual(store.selectedID, original.id)
        XCTAssertEqual(store.selected?.draft, "Original chat draft")
        await store.goForward()
        XCTAssertNil(store.selectedID)
        XCTAssertEqual(store.newSessionDraft.text, "Home prompt 🦉")
        await store.shutdown()
        let restored = AppStore(directory: data)
        restored.settings = store.settings
        await restored.restore(); await restored.openHome()
        XCTAssertEqual(restored.newSessionDraft.projectPath, root.path)
        XCTAssertEqual(restored.newSessionDraft.text, "Home prompt 🦉")
        XCTAssertEqual(restored.attentionSessions.first?.lastError, "Needs verification input")
        restored.newSessionDraft.projectPath = root.appendingPathComponent("missing").path
        await restored.startFromHome()
        XCTAssertNil(restored.selectedID)
        XCTAssertEqual(restored.newSessionDraft.text, "Home prompt 🦉")
        XCTAssertEqual(restored.sessions.count, 1)
        restored.error = nil; restored.newSessionDraft.projectPath = root.path
        await restored.startFromHome()
        let launched = try XCTUnwrap(restored.selected)
        try await finish(launched, store: restored)
        XCTAssertEqual(launched.transcript.items.first?.text, "Home prompt 🦉")
        XCTAssertTrue(restored.newSessionDraft.text.isEmpty)
        restored.dismissAttention(original.id)
        XCTAssertFalse(restored.attentionSessions.contains { $0.id == original.id })
        restored.dismissAttention(launched.id)
        XCTAssertTrue(restored.attentionSessions.isEmpty)
        await restored.shutdown()
    }
    @MainActor func testHomeLaunchReservesPromptDuringSlowRefresh() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        try "file".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        _ = try await Repository.run(["add", "file"], at: root.path)
        let hook = root.appendingPathComponent("slow-monitor")
        try "#!/bin/sh\nsleep 1\nprintf 'token\\0'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try await Repository.run(["config", "core.fsmonitor", hook.path], at: root.path)
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path]
        await store.restore()
        store.newSessionDraft = NewSessionDraft(projectPath: root.path, text: "Launch prompt")
        let launch = Task { await store.startFromHome() }
        for _ in 0..<100 where store.selected == nil { try await Task.sleep(for: .milliseconds(10)) }
        let chat = try XCTUnwrap(store.selected)
        XCTAssertTrue(chat.busy, "Published launch must reserve the chat")
        XCTAssertEqual(chat.draft, "Launch prompt")
        chat.draft = "Next draft"
        store.send(chat)
        await launch.value
        try await finish(chat, store: store)
        XCTAssertEqual(chat.transcript.items.first?.text, "Launch prompt")
        XCTAssertEqual(chat.draft, "Next draft")
        XCTAssertTrue(store.canGoBack)
        await store.goBack()
        XCTAssertNil(store.selectedID)
        store.newSessionDraft.text = "Cancel launch"
        let cancelled = Task { await store.startFromHome() }
        for _ in 0..<100 where store.selected == nil { try await Task.sleep(for: .milliseconds(10)) }
        let cancelledChat = try XCTUnwrap(store.selected)
        store.stop(cancelledChat)
        await cancelled.value
        XCTAssertEqual(store.newSessionDraft.text, "Cancel launch")
        XCTAssertEqual(cancelledChat.draft, "Cancel launch")
        XCTAssertTrue(cancelledChat.transcript.items.isEmpty)
        XCTAssertNil(cancelledChat.connection)
        await store.shutdown()
    }
    @MainActor func testSelectedMessageForkSendsBoundaryAndRejectsUnknownAdapters() async throws {
        let root = try temporary(), audit = root.appendingPathComponent("fork-audit.jsonl")
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--fork", "--audit-path=" + audit.path]
        await store.create(path: root.path, worktree: false)
        let source = try XCTUnwrap(store.selected)
        try await store.connect(source)
        source.handshake["agentInfo"] = ["name": "@agentclientprotocol/claude-agent-acp", "version": "0.84.0"]
        let boundary = TranscriptItem(kind: "assistant", text: "First answer", messageID: "msg-first")
        let original = [TranscriptItem(kind: "user", text: "First question"), boundary, TranscriptItem(kind: "user", text: "Later question"), TranscriptItem(kind: "assistant", text: "Later answer", messageID: "msg-later")]
        source.transcript.items = original; source.draft = "Unsent source draft"
        source.transcript.plan = [["content": "Future work", "status": "pending"]]
        let forkID = try await store.fork(source, at: boundary.id)
        let branch = try XCTUnwrap(store.selected)
        XCTAssertEqual(branch.id, forkID)
        XCTAssertEqual(branch.transcript.items, Array(original.prefix(2)))
        XCTAssertTrue(branch.transcript.plan.isEmpty)
        XCTAssertEqual(source.transcript.items, original)
        XCTAssertEqual(source.draft, "Unsent source draft")
        let calls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let fork = try XCTUnwrap(calls.first { $0["method"].string == "session/fork" })
        XCTAssertEqual(fork["params"]["_meta"]["jetbrains"]["air"]["fork"], ["version": 1, "messageId": "msg-first"])
        try await store.connect(branch) // Fixture's own identity does not promise this extension.
        do { _ = try await store.fork(branch, at: boundary.id); XCTFail("Unknown adapters must not silently fork full context") } catch {}
        do { _ = try await store.fork(branch, at: UUID()); XCTFail("Missing boundaries must be rejected") } catch {}
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertEqual(branch.transcript.items, Array(original.prefix(2)))
        await store.shutdown()
    }
    @MainActor func testStopCancelsWholeAndSelectedMessageForks() async throws {
        for selectedBoundary in [false, true] {
            let root = try temporary(), audit = root.appendingPathComponent("audit.jsonl")
            let store = AppStore(directory: root.appendingPathComponent("data"))
            store.settings.executable = "/usr/bin/python3"
            store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--slow-fork", "--audit-path=" + audit.path]
            await store.create(path: root.path, worktree: false)
            let source = try XCTUnwrap(store.selected)
            try await store.connect(source)
            source.handshake["agentInfo"] = ["name": "@agentclientprotocol/claude-agent-acp", "version": "0.84.0"]
            let boundary = TranscriptItem(kind: "assistant", text: "Keep source", messageID: "msg-first")
            source.transcript.items = [boundary]; source.draft = "Keep draft"
            let operation = Task { try await store.fork(source, at: selectedBoundary ? boundary.id : nil) }
            var requested = false
            for _ in 0..<100 {
                if (try? String(contentsOf: audit, encoding: .utf8).contains("session/fork")) == true { requested = true; break }
                try await Task.sleep(for: .milliseconds(2))
            }
            XCTAssertTrue(requested)
            let generation = source.connectionGeneration
            store.stop(source)
            XCTAssertNotEqual(source.connectionGeneration, generation, "Stop must invalidate ownership before asynchronous peer cleanup")
            do { _ = try await operation.value; XCTFail("Stop must cancel fork before publication") } catch {}
            XCTAssertEqual(store.sessions.count, 1)
            XCTAssertEqual(store.selectedID, source.id)
            XCTAssertEqual(source.transcript.items, [boundary])
            XCTAssertEqual(source.draft, "Keep draft")
            XCTAssertFalse(source.busy)
            await store.shutdown()
        }
    }
    @MainActor func testForkRejectsInvalidatedConnectionWithPeerStillPresent() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data"), audit = root.appendingPathComponent("audit.jsonl")
        let store = AppStore(directory: data)
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--slow-fork", "--audit-path=" + audit.path]
        await store.create(path: root.path, worktree: false)
        let source = try XCTUnwrap(store.selected)
        try await store.connect(source)
        let peer = try XCTUnwrap(source.connection)
        let operation = Task { try await store.fork(source) }
        var requested = false
        for _ in 0..<100 {
            if (try? String(contentsOf: audit, encoding: .utf8).contains("session/fork")) == true { requested = true; break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(requested)
        // Reproduce cleanup's retained peer: ownership is gone but the RPC can still return.
        source.connectionGeneration = UUID()
        do { _ = try await operation.value; XCTFail("A retained peer must not publish after losing ownership") } catch {}
        XCTAssertTrue(source.connection === peer)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.selectedID, source.id)
        let saved = try FileManager.default.contentsOfDirectory(atPath: data.path).filter { UUID(uuidString: String($0.dropLast(5))) != nil }
        XCTAssertEqual(saved.count, 1, "Canceled forks must not leave an unpublished local transcript")
        await store.shutdown()
    }
    @MainActor func testForkUsesIndependentRemoteContextAndPreservesSource() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--fork"]
        await store.create(path: root.path, worktree: false)
        let source = try XCTUnwrap(store.selected)
        store.send(source, text: "Original conversation"); try await finish(source, store: store)
        let originalItems = source.transcript.items
        source.draft = "Keep this draft"
        source.fileDrafts["README.md"] = FileDraft(original: "old", text: "unsaved")
        let forkID = try await store.fork(source), branch = try XCTUnwrap(store.selected)
        XCTAssertEqual(branch.id, forkID); XCTAssertNotEqual(forkID, source.id)
        XCTAssertNil(source.connection, "An idle source peer should be evicted after selecting its fork")
        XCTAssertEqual(branch.transcript.remoteID, "fixture-fork")
        XCTAssertEqual(branch.transcript.items, originalItems)
        XCTAssertTrue(branch.draft.isEmpty); XCTAssertTrue(branch.fileDrafts.isEmpty)
        XCTAssertEqual(source.draft, "Keep this draft")
        XCTAssertEqual(source.fileDrafts["README.md"]?.text, "unsaved")
        store.send(branch, text: "Independent continuation"); try await finish(branch, store: store)
        XCTAssertEqual(branch.state, .ready, branch.lastError ?? "")
        XCTAssertEqual(branch.transcript.remoteID, "fixture-fork")
        XCTAssertEqual(branch.transcript.items.filter { $0.kind == "user" }.count, 2)
        XCTAssertEqual(source.transcript.items, originalItems)
        XCTAssertFalse(source.connection === branch.connection)
        XCTAssertEqual(store.sessions.first(where: { $0.id == forkID })?.agentArguments, store.settings.arguments)
        await store.shutdown()
        let restored = AppStore(directory: root.appendingPathComponent("data"))
        await restored.restore()
        XCTAssertEqual(restored.selectedID, forkID)
        XCTAssertEqual(restored.selected?.transcript.remoteID, "fixture-fork")
        await restored.shutdown()

        for flag in ["--no-resume", "--bad-fork"] {
            let rejecting = AppStore(directory: root.appendingPathComponent(flag))
            rejecting.settings = store.settings; rejecting.settings.arguments[1] = flag
            await rejecting.create(path: root.path, worktree: false)
            let chat = try XCTUnwrap(rejecting.selected)
            try await rejecting.connect(chat)
            do { _ = try await rejecting.fork(chat); XCTFail("Fork must reject unsupported/invalid context") }
            catch { XCTAssertEqual(rejecting.sessions.count, 1); XCTAssertEqual(rejecting.selectedID, chat.id); XCTAssertFalse(chat.busy) }
            await rejecting.shutdown()
        }
        let closing = AppStore(directory: root.appendingPathComponent("closing"))
        closing.settings = store.settings; closing.settings.arguments[1] = "--slow-fork"
        await closing.create(path: root.path, worktree: false)
        let closingChat = try XCTUnwrap(closing.selected)
        try await closing.connect(closingChat)
        let interrupted = Task { try await closing.fork(closingChat) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(closingChat.busy)
        await closing.archive(closingChat.id)
        do { _ = try await interrupted.value; XCTFail("Closing session must cancel fork publication") } catch {}
        XCTAssertEqual(closing.sessions.count, 1)
        XCTAssertTrue(closing.sessions[0].archived)
        XCTAssertNil(closing.selectedID)
        await closing.shutdown()
    }
    @MainActor func testSessionNavigationBranchesSkipsArchivesAndUsesSidebarOrder() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        await store.create(path: root.path, worktree: false); let first = try XCTUnwrap(store.selectedID)
        await store.create(path: root.path, worktree: false); let second = try XCTUnwrap(store.selectedID)
        await store.create(path: root.path, worktree: false); let third = try XCTUnwrap(store.selectedID)
        XCTAssertTrue(store.canGoBack); XCTAssertFalse(store.canGoForward)
        await store.goBack(); XCTAssertEqual(store.selectedID, second)
        await store.goBack(); XCTAssertEqual(store.selectedID, first); XCTAssertFalse(store.canGoBack)
        await store.goForward(); XCTAssertEqual(store.selectedID, second)
        await store.goBack(); await store.select(third)
        XCTAssertFalse(store.canGoForward)
        await store.goBack(); XCTAssertEqual(store.selectedID, first)
        await store.goForward(); XCTAssertEqual(store.selectedID, third)
        await store.archive(third)
        XCTAssertEqual(store.selectedID, second)
        await store.goBack(); XCTAssertEqual(store.selectedID, first)
        await store.goForward(); XCTAssertEqual(store.selectedID, second)
        store.togglePin(first)
        XCTAssertEqual(store.sidebarSessionOrder.first?.id, first)
        await store.previousSession(); XCTAssertEqual(store.selectedID, first)
        await store.nextSession(); XCTAssertEqual(store.selectedID, second)
        XCTAssertFalse(store.canGoToNextSession)
        let alpha = root.appendingPathComponent("alpha/duplicate"), beta = root.appendingPathComponent("beta/duplicate")
        for folder in [alpha, beta] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        await store.create(path: beta.path, worktree: false); let betaID = try XCTUnwrap(store.selectedID)
        await store.create(path: alpha.path, worktree: false); let alphaID = try XCTUnwrap(store.selectedID)
        for _ in 0..<20 { XCTAssertEqual(store.sidebarSessionOrder.filter { $0.projectName == "duplicate" }.map(\.id), [alphaID, betaID]) }
        await store.shutdown()
    }
    @MainActor func testArchiveKeepsItsIdentityWhileCleanupAndNewSessionOverlap() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        await store.create(path: root.path, worktree: false)
        let original = try XCTUnwrap(store.selected)
        _ = try await original.terminals.create(command: "/bin/sh", arguments: ["-c", "trap '' TERM HUP; echo READY; while :; do sleep 1; done"], directory: root.path, environment: [:])
        try await Task.sleep(for: .milliseconds(100))
        store.pane = "terminal"
        let archiving = Task { await store.archive(original.id) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(original.busy)
        await store.create(path: root.path, worktree: false)
        let newID = try XCTUnwrap(store.selectedID)
        await archiving.value
        XCTAssertTrue(store.sessions.first(where: { $0.id == original.id })?.archived == true)
        XCTAssertFalse(store.sessions.first(where: { $0.id == newID })?.archived ?? true)
        XCTAssertEqual(store.selectedID, newID)
        store.pane = "terminal"
        await store.archive(newID)
        XCTAssertNil(store.pane)
        await store.shutdown()
    }
    func temporary(parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let root = parent.appendingPathComponent("ccode-app-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    @MainActor func finish(_ chat: ChatSession, store: AppStore) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while chat.busy, ContinuousClock.now < deadline {
            for approval in chat.approvals { store.resolveApproval(chat, id: approval.id, option: "allow") }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !chat.busy else {
            let reason = "Fixture prompt did not finish: \(chat.state.rawValue); \(chat.lastError ?? "no agent error")"
            store.stop(chat); await store.disconnect(chat)
            throw ACPError.workspace(reason)
        }
    }
    @MainActor func testSecondPromptKeepsLivePeerWithoutResumeSupport() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--no-resume"]
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        for prompt in ["First", "Second"] {
            store.send(chat, text: prompt)
            try await finish(chat, store: store)
            XCTAssertEqual(chat.state, .ready, chat.lastError ?? "")
        }
        XCTAssertEqual(chat.transcript.items.filter { $0.kind == "user" }.count, 2)
        await store.shutdown()
    }
    @MainActor func testSlowPreviousSelectionCannotEvictNewSelection() async throws {
        let root = try temporary()
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for url in [a, b] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        _ = try await Repository.run(["init", "-b", "main"], at: a.path)
        try "file".write(to: a.appendingPathComponent("file"), atomically: true, encoding: .utf8)
        _ = try await Repository.run(["add", "file"], at: a.path)
        let hook = root.appendingPathComponent("slow-monitor")
        try "#!/bin/sh\nsleep 1\nprintf 'token\\0'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try await Repository.run(["config", "core.fsmonitor", hook.path], at: a.path)
        let first = SessionInfo(projectPath: a.path), second = SessionInfo(projectPath: b.path)
        let store = AppStore(directory: root.appendingPathComponent("data")); store.sessions = [first, second]
        let slow = Task { await store.select(first.id) }
        try await Task.sleep(for: .milliseconds(100))
        await store.select(second.id)
        await slow.value
        XCTAssertEqual(store.selectedID, second.id)
        XCTAssertNotNil(store.selected)
        await store.shutdown()
    }
    @MainActor func testAdvertisedAuthenticationUsesItsOpaqueMethodID() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--needs-auth"]
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        do { try await store.connect(chat); XCTFail("Expected authentication required") } catch { }
        XCTAssertEqual(chat.state, .failed)
        try await store.connect(chat, authentication: "fixture-login")
        XCTAssertEqual(chat.state, .ready)
        await store.shutdown()
    }
    @MainActor func testReconnectDoesNotDiscardHistoryWhenAgentReplaysNothing() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path]
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        store.send(chat, text: "Keep this history")
        try await finish(chat, store: store)
        await store.disconnect(chat)
        try await store.connect(chat)
        XCTAssertEqual(chat.transcript.items.first?.text, "Keep this history")
        await store.shutdown()
    }
    @MainActor func testStopBeforePromptTaskStartsPreservesDraft() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path]
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        chat.draft = "Do not submit this"
        store.send(chat); store.stop(chat)
        try await finish(chat, store: store)
        XCTAssertEqual(chat.draft, "Do not submit this")
        XCTAssertTrue(chat.transcript.items.isEmpty)
        await store.shutdown()
    }
}
