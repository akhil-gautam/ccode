import XCTest
import Foundation
import AppKit
import CoreText
@testable import CCode
import CCodeCore

final class RealAgentTests: XCTestCase {
    @MainActor func testRealForcedReplayRetainsActualStoppedChildAndFailedLaunch() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let executable = env["CCODE_REAL_AGENT"], let path = env["CCODE_REAL_DELEGATED_HISTORY_DIRECTORY"] else {
            throw XCTSkip("Set CCODE_REAL_AGENT and CCODE_REAL_DELEGATED_HISTORY_DIRECTORY to replay the disposable child-Stop proof.")
        }
        let folder = URL(fileURLWithPath: path)
        guard folder.lastPathComponent.contains("ccode-real-child-stop-") else { throw XCTSkip("Read only the disposable child-Stop proof.") }
        let rootFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first {
            $0.pathExtension == "jsonl" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
        })
        let sourceID = rootFile.deletingPathExtension().lastPathComponent
        let childFolder = folder.appendingPathComponent(sourceID + "/subagents")
        let files = [rootFile] + (try FileManager.default.contentsOfDirectory(at: childFolder, includingPropertiesForKeys: nil)).filter {
            $0.pathExtension == "jsonl" || $0.lastPathComponent.hasSuffix(".meta.json")
        }
        let original = try files.map { try Data(contentsOf: $0) }
        let config = folder.deletingLastPathComponent().deletingLastPathComponent()
        // session/load starts an SDK control query which appends mode/cost records.
        // Clone only this controlled proof family under a fresh session identity.
        let remote = UUID().uuidString.lowercased()
        let copy = folder.deletingLastPathComponent().appendingPathComponent("ccode-replay-proof-\(UUID())")
        let copiedChildren = copy.appendingPathComponent(remote + "/subagents")
        try FileManager.default.createDirectory(at: copiedChildren, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        func copyRecords(_ data: Data, to target: URL) throws {
            var result = Data()
            for line in data.split(separator: 10) {
                var record = try JSONDecoder().decode(JSONValue.self, from: Data(line))
                if record["sessionId"] == .string(sourceID) { record["sessionId"] = .string(remote) }
                result.append(try JSONEncoder().encode(record)); result.append(10)
            }
            try result.write(to: target)
        }
        let copiedRoot = copy.appendingPathComponent(remote + ".jsonl")
        try copyRecords(original[0], to: copiedRoot)
        for (file, bytes) in zip(files.dropFirst(), original.dropFirst()) {
            let target = copiedChildren.appendingPathComponent(file.lastPathComponent)
            if file.pathExtension == "jsonl" { try copyRecords(bytes, to: target) }
            else { try bytes.write(to: target) }
        }
        func messages() throws -> [JSONValue] {
            try Data(contentsOf: copiedRoot).split(separator: 10).map { try JSONDecoder().decode(JSONValue.self, from: Data($0)) }.filter {
                $0["type"] == "user" || $0["type"] == "assistant"
            }
        }
        let originalMessages = try messages()
        let native = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: remote, cwd: "/unavailable/disposable/project", configurationDirectory: config))
        let child = try XCTUnwrap(native.subagents?.first)
        XCTAssertEqual(child.state, "cancelled")
        let failed = try XCTUnwrap(native.items.first { $0.kind == "tool" && $0.tool["status"] == "failed" })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-family-replay-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(directory: directory.appendingPathComponent("data"), claudeDirectory: config)
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await store.create(path: directory.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        chat.transcript = native; chat.draft = "Keep this unsent replay draft"
        try await store.connect(chat, reloadHistory: true)
        XCTAssertEqual(chat.state, .ready)
        XCTAssertEqual(chat.transcript.remoteID, remote)
        XCTAssertEqual(chat.transcript.subagents?.count, 1, "An unannounced failed launch must not invent an empty child")
        let replayed = try XCTUnwrap(chat.transcript.subagent(child.id))
        XCTAssertEqual(replayed.state, "cancelled", "A background launch acknowledgement cannot overwrite actual stoppedByUser metadata")
        XCTAssertEqual(replayed.parentID, remote)
        XCTAssertEqual(replayed.capabilities, [:])
        XCTAssertTrue(replayed.transcript.items.contains { $0.kind == "tool" && $0.tool["rawInput"]["command"].string.contains("child-stop-proof.txt") })
        XCTAssertFalse(chat.transcript.items.contains { $0.kind == "tool" && $0.tool["rawInput"]["command"].string.contains("child-stop-proof.txt") })
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "tool" && $0.tool["toolCallId"] == failed.tool["toolCallId"] && $0.tool["status"] == "failed" })
        XCTAssertFalse(store.canStopSubagent(chat, id: child.id))
        XCTAssertEqual(chat.childOwners, Set([child.id]))
        XCTAssertEqual(chat.draft, "Keep this unsent replay draft")
        await store.shutdown()
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, original)
        XCTAssertEqual(try messages(), originalMessages, "SDK bookkeeping may append; conversation records must stay intact")
        print("Actual provider session/load exercised with an isolated cloned SDK history and no model prompt.")
    }
    @MainActor func testRealIndividualSubagentStopPreservesParentAndActualChildWork() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-child-stop-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(directory: directory.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await store.create(path: directory.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(chat, id: mode["id"].string, value: "default")
        let token = UUID().uuidString
        let command = "/usr/bin/python3 -u -c 'import pathlib,time; pathlib.Path(\"child-stop-proof.txt\").write_text(\"\(token)\"); print(\"child-started:\(token)\", flush=True); time.sleep(90); pathlib.Path(\"child-after-sleep.txt\").write_text(\"finished\")'"
        let proof = URL(fileURLWithPath: chat.workspace.root).appendingPathComponent("child-stop-proof.txt")
        store.send(chat, text: "Launch exactly one general-purpose subagent using Agent with run_in_background:true, named Stop proof. Its only task is: execute Bash exactly once with run_in_background:false and this exact command: \(command)\nNo other commands, files, agents or network. You, the parent, must immediately report started and finish without waiting, polling, stopping or messaging the child. The native client will stop that child after its proof file exists.")
        let deadline = ContinuousClock.now + .seconds(100)
        while ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let call = approval.toolCall, name = PermissionPresentation(tool: call).toolName
                let allowed = (name == "Agent" || name == "Task") && call["rawInput"]["run_in_background"] == true && call["rawInput"]["prompt"].string.contains(command)
                    || name == "Bash" && call["rawInput"]["command"] == .string(command)
                let option = approval.request["options"].array.first { $0["kind"] == .string(allowed ? "allow_once" : "reject_once") }
                store.resolveApproval(chat, id: approval.id, option: option?["optionId"].optionalString)
                if !allowed { throw ACPError.workspace("Unexpected child Stop proof action: \(name)") }
            }
            if FileManager.default.fileExists(atPath: proof.path), chat.transcript.subagents?.contains(where: { $0.isRunning && store.canStopSubagent(chat, id: $0.id) }) == true { break }
            if chat.state == .failed { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(try String(contentsOf: proof, encoding: .utf8), token, "Child must perform real approved work before Stop")
        let child = try XCTUnwrap(chat.transcript.subagents?.first { $0.isRunning && store.canStopSubagent(chat, id: $0.id) })
        XCTAssertEqual(chat.transcript.subagents?.count, 1)
        let peer = try XCTUnwrap(chat.connection), remote = try XCTUnwrap(chat.transcript.remoteID)
        await store.stopSubagent(chat, id: child.id)
        XCTAssertNil(chat.subagentStopErrors[child.id])
        XCTAssertEqual(chat.transcript.subagent(child.id)?.state, "cancelled")
        let stoppedTools = try XCTUnwrap(chat.transcript.subagent(child.id)).transcript.items.filter { $0.kind == "tool" }
        XCTAssertFalse(stoppedTools.isEmpty, "The proof must include actual child tool work")
        XCTAssertFalse(stoppedTools.contains { $0.isToolRunning }, "Stopped child tools must not remain visually running")
        XCTAssertTrue(chat.connection === peer)
        XCTAssertEqual(chat.transcript.remoteID, remote)
        try await finish(chat, store: store)
        store.send(chat, text: "Reply exactly child-stopped-parent-connected. No tools.")
        try await finish(chat, store: store)
        XCTAssertTrue(chat.transcript.items.last { $0.kind == "assistant" }?.text.contains("child-stopped-parent-connected") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: chat.workspace.root).appendingPathComponent("child-after-sleep.txt").path))
        print("Real child Stop: actual approved child file write, individual cancelled acknowledgement, original parent query and subsequent prompt verified.")
    }
    @MainActor func testRealBackgroundCommandOutputAndIndividualStopPreserveParent() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-background-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(directory: directory.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await store.create(path: directory.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(chat, id: mode["id"].string, value: "default")
        let token = UUID().uuidString
        let command = "/usr/bin/python3 -u -c 'import pathlib,time; print(\"ccode-background:\(token)\", flush=True); pathlib.Path(\"task-proof.txt\").write_text(\"\(token)\"); time.sleep(90)'"
        store.send(chat, text: "Use Bash exactly once with run_in_background:true and this exact command: \(command)\nImmediately report that you started it and finish your response. Do not wait, poll, read files, stop the task, launch agents, run any other command or use network. The native client will inspect and stop this disposable task.")
        let deadline = ContinuousClock.now + .seconds(100)
        while chat.busy, ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let permitted = PermissionPresentation(tool: approval.toolCall).toolName == "Bash" && approval.toolCall["rawInput"]["command"] == .string(command)
                let option = approval.request["options"].array.first { $0["kind"] == .string(permitted ? "allow_once" : "reject_once") }
                store.resolveApproval(chat, id: approval.id, option: option?["optionId"].optionalString)
            }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertFalse(chat.busy, "Main turn must finish while the command remains active")
        XCTAssertNil(chat.lastError)
        let task = try XCTUnwrap(chat.transcript.asyncTasks?.first { $0.isRunning })
        XCTAssertTrue(store.canStopAsyncTask(chat, id: task.id))
        let output = try await store.readAsyncOutput(chat, id: task.id)
        XCTAssertTrue(output?.text.contains("ccode-background:" + token) == true)
        let proof = URL(fileURLWithPath: chat.workspace.root).appendingPathComponent("task-proof.txt")
        XCTAssertEqual(try String(contentsOf: proof, encoding: .utf8), token)
        let peer = try XCTUnwrap(chat.connection), remote = try XCTUnwrap(chat.transcript.remoteID)
        await store.stopAsyncTask(chat, id: task.id)
        XCTAssertNil(chat.asyncTaskErrors[task.id])
        XCTAssertEqual(chat.transcript.asyncTask(task.id)?.state, .stopped)
        XCTAssertTrue(chat.connection === peer)
        XCTAssertEqual(chat.transcript.remoteID, remote)
        store.send(chat, text: "Reply exactly parent-still-connected, no tools.")
        try await finish(chat, store: store)
        XCTAssertTrue(chat.transcript.items.last { $0.kind == "assistant" }?.text.contains("parent-still-connected") == true)
        print("Real background acceptance: actual background Bash, exact output/file proof, individual stopped acknowledgement and subsequent parent prompt passed.")
    }
    @MainActor func testRealSubagentReadControlsParentWriteAndHasSeparateTranscript() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-child-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        let token = UUID().uuidString
        let input = URL(fileURLWithPath: chat.workspace.root).appendingPathComponent("child-token.txt")
        let output = URL(fileURLWithPath: chat.workspace.root).appendingPathComponent("child-result.txt")
        try token.write(to: input, atomically: true, encoding: .utf8)
        try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        let manual = try XCTUnwrap(mode["options"].array.first { $0["value"] == "default" })
        await store.setConfig(chat, id: mode["id"].string, value: manual["value"])
        store.send(chat, text: "Use the Agent tool to launch exactly one foreground subagent named Token-reader. Tell it to use Read on \(input.path) and return the exact token. You, the parent, must not read that file yourself. After its result returns, use Write to put exactly that token in \(output.path), with no newline. No shell commands, network, other files or nested agents. Then briefly report completion.")
        let deadline = ContinuousClock.now + .seconds(120)
        while chat.busy, ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let call = approval.toolCall, name = PermissionPresentation(tool: call).toolName
                let path = call["rawInput"]["file_path"].optionalString
                guard name == "Agent" || name == "Read" && path == input.path || name == "Write" && path == output.path,
                      let option = approval.request["options"].array.first(where: { $0["kind"] == "allow_once" }) else {
                    store.resolveApproval(chat, id: approval.id, option: nil)
                    throw ACPError.workspace("Unexpected subagent acceptance action: \(name) \(call["title"].string)")
                }
                store.resolveApproval(chat, id: approval.id, option: option["optionId"].string)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(chat.busy); XCTAssertEqual(chat.state, .ready, chat.lastError ?? "")
        if chat.transcript.subagents == nil {
            print("Subagent diagnostic provider: \(chat.handshake["agentInfo"].pretty)")
            for item in chat.transcript.items {
                print("Subagent diagnostic row: \(item.kind) \(PermissionPresentation(tool: item.tool).toolName) \(item.tool["status"].string) parent=\(item.tool["_meta"]["claudeCode"]["parentToolUseId"].string) text=\(item.text.prefix(800))")
            }
        }
        let child = try XCTUnwrap(chat.transcript.subagents?.first, "The actual provider must announce the delegated child")
        XCTAssertEqual(chat.transcript.subagents?.count, 1)
        XCTAssertEqual(child.parentID, chat.transcript.remoteID)
        XCTAssertEqual(child.state, "completed")
        XCTAssertTrue(child.transcript.items.contains { $0.kind == "tool" && PermissionPresentation(tool: $0.tool).toolName == "Read" && $0.tool["status"] == "completed" })
        XCTAssertTrue(child.transcript.items.contains { $0.kind == "assistant" && $0.text.contains(token) })
        XCTAssertFalse(chat.transcript.items.contains { $0.kind == "tool" && PermissionPresentation(tool: $0.tool).toolName == "Read" })
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), token)
        print("Real subagent acceptance: child announcement, separate Read/transcript, completed lifecycle and parent Write with the exact child token passed.")
    }
    @MainActor func testAdvertisedCompactKeepsSessionIdentityAndRetainedContext() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-compact-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let token = UUID().uuidString
        let notes = (1...120).map { "Historical note \($0): This disposable chat is testing context compaction, with no file or command work." }.joined(separator: "\n")
        store.send(chat, text: "Remember ContextToken: \(token). The token is the only fact we need later. Reply only stored; no tools.\n\(notes)")
        try await finish(chat, store: store)
        let identity = try XCTUnwrap(chat.transcript.remoteID)
        let command = try XCTUnwrap(PromptCompletion.commands(matching: "compact", catalog: chat.transcript.commands).first { $0["name"].string == "compact" }, "The actual agent must advertise compact")
        let query = try XCTUnwrap(PromptCompletion.query(in: "/comp Preserve ContextToken exactly", selection: NSRange(location: 5, length: 0)))
        chat.draft = query.applyingCommand(command["name"].string, to: "/comp Preserve ContextToken exactly")
        store.send(chat)
        try await finish(chat, store: store)
        let compact = try XCTUnwrap(chat.transcript.items.last { $0.kind == "tool" && $0.tool["title"].string == "Compact conversation" }, "The provider must report actual compaction, not merely accept a slash prompt")
        XCTAssertEqual(compact.tool["status"].string, "completed", compact.tool.pretty)
        XCTAssertEqual(chat.transcript.remoteID, identity)
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "user" && $0.text == "/compact Preserve ContextToken exactly" })
        store.send(chat, text: "What exact ContextToken did I ask you to remember? Reply with only that token, no tools.")
        try await finish(chat, store: store)
        XCTAssertTrue(chat.transcript.items.last(where: { $0.kind == "assistant" })?.text.contains(token) == true)
        XCTAssertEqual(chat.transcript.remoteID, identity)
        print("Real advertised compact acceptance: arguments, completed command, stable session identity and retained context passed.")
    }
    @MainActor func testHomeImageAndContextAfterRestartControlActualWrite() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-home-media-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = root.appendingPathComponent("data"), store = AppStore(directory: data)
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.restore(); await store.openHome(path: root.path)
        let model = try XCTUnwrap(store.homeConfigurationOptions.first { $0["category"] == "model" }, store.homeDiscoveryError ?? "No Home models")
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        store.chooseHomeConfiguration(id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(store.homeConfigurationOptions.first { $0["category"] == "mode" })
        store.chooseHomeConfiguration(id: mode["id"].string, value: "default")
        let token = UUID().uuidString, source = root.appendingPathComponent("Home source 界.txt")
        try "Snapshot token: \(token)\n".write(to: source, atomically: true, encoding: .utf8)
        let candidates = try await XCTUnwrap(store.homeWorkspace).contextCandidates(matching: "Home source 界")
        let accepted = await store.attachHomeContext(try XCTUnwrap(candidates.first))
        XCTAssertTrue(accepted, store.error ?? "")
        let blue = Bool.random(), expected = blue ? "blue" : "red"
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        memset(pixels, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        for row in 0..<96 { for column in 0..<96 { pixels[row * bitmap.bytesPerRow + column * 3 + (blue ? 2 : 0)] = 255 } }
        store.attachHomeInputs([.image(try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:])))])
        await store.homeAttachmentTask?.value
        XCTAssertEqual(store.newSessionDraft.attachments?.count, 2)
        store.newSessionDraft.text = "This is a disposable verification project. From the attached text snapshot, find the value after Snapshot token:. From the attached solid-color image, identify its color as blue or red. Use Write to create home-result.txt containing exactly TOKEN|COLOR with the actual values. Do not read files, run commands, use skills or agents. Reply with the same contents."
        try FileManager.default.removeItem(at: source)
        await store.shutdown()
        let restored = AppStore(directory: data); restored.settings = store.settings
        addTeardownBlock { await restored.shutdown() }
        await restored.restore(); await restored.startFromHome()
        let chat = try XCTUnwrap(restored.selected)
        let output = URL(fileURLWithPath: chat.workspace.root).appendingPathComponent("home-result.txt")
        let approvals = try await finish(chat, store: restored, allowedFile: output.path)
        XCTAssertGreaterThanOrEqual(approvals, 1)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), token + "|" + expected)
        XCTAssertEqual(chat.transcript.items.filter { $0.kind == "user" }.count, 1)
        XCTAssertEqual(chat.transcript.items.first?.promptAttachments?.count, 2)
        XCTAssertNil(restored.newSessionDraft.attachments)
        print("Real Home media acceptance: persisted source-deleted context and TIFF image controlled one approved Write after restart.")
    }
    @MainActor func testProjectSkillUsesTheAttachedContextSnapshotForAnActualWrite() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-context-\(UUID())")
        let skill = root.appendingPathComponent(".claude/skills/context-proof")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try """
        ---
        name: context-proof
        description: Verify a supplied immutable context snapshot by writing its token.
        disable-model-invocation: true
        ---
        This is a disposable verification project. Use the attached text snapshot to find the value after Snapshot token:. Use Write to create context-result.txt containing only that exact value, then reply with it. Do not read files, run commands, start agents, or invoke other skills. Arguments: $ARGUMENTS
        """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let source = root.appendingPathComponent("context source 界.txt"), token = UUID().uuidString
        try "Snapshot token: \(token)\n".write(to: source, atomically: true, encoding: .utf8)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(chat, id: mode["id"].string, value: "default")
        guard chat.lastError == nil else { throw ACPError.workspace(chat.lastError!) }
        let deadline = ContinuousClock.now + .seconds(120)
        while !chat.transcript.commands.contains(where: { $0["name"].string == "context-proof" }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let command = try XCTUnwrap(PromptCompletion.commands(matching: "context-proof", catalog: chat.transcript.commands).first, "The actual project skill must be advertised")
        let candidates = try await chat.workspace.contextCandidates(matching: "context source 界")
        let accepted = await store.attachContext(try XCTUnwrap(candidates.first), to: chat)
        XCTAssertTrue(accepted)
        try FileManager.default.removeItem(at: source)
        let query = try XCTUnwrap(PromptCompletion.query(in: "/context-p verify-context", selection: NSRange(location: 10, length: 0)))
        chat.draft = query.applyingCommand(command["name"].string, to: "/context-p verify-context")
        store.send(chat)
        let output = URL(fileURLWithPath: chat.workspace.root).appendingPathComponent("context-result.txt")
        var approved = false
        while chat.busy, ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let path = approval.toolCall["rawInput"]["file_path"].string
                guard path == output.path || path == "context-result.txt",
                      let option = approval.request["options"].array.first(where: { $0["kind"] == "allow_once" }) else {
                    store.resolveApproval(chat, id: approval.id, option: nil)
                    throw ACPError.workspace("Unexpected tool in context verification: \(approval.toolCall["title"].string)")
                }
                store.resolveApproval(chat, id: approval.id, option: option["optionId"].string); approved = true
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(approved, "The real Write must receive an actual approval")
        XCTAssertEqual(chat.state, .ready, chat.lastError ?? "Context skill did not finish")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), token)
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "user" && $0.text == "/context-proof verify-context" })
    }
    @MainActor func testBusyEffortChangeAppliesBeforeRealQueuedFollowup() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(chat, id: mode["id"].string, value: "default")
        guard chat.lastError == nil else { throw ACPError.workspace(chat.lastError!) }
        let effort = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "thought_level" }, "Real adapter must advertise an effort choice for this check")
        let target = try XCTUnwrap(effort["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["value"] != effort["currentValue"] })
        let output = URL(fileURLWithPath: chat.workspace.root).appendingPathComponent("settings.txt")
        store.send(chat, text: "Use AskUserQuestion now to ask which token to write, with exactly two single-select options: cobalt42 and amber17. Wait for my answer. Then use Write to create settings.txt containing only my chosen token and reply with it. Do not use Bash, agents, skills or other tools. This is a disposable verification project.")
        let deadline = ContinuousClock.now + .seconds(120)
        while chat.interactions.isEmpty, chat.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let question = try XCTUnwrap(chat.interactions.first, chat.lastError ?? "Claude did not ask")
        await store.setConfig(chat, id: effort["id"].string, value: target["value"])
        XCTAssertEqual(chat.pendingSettings.first?.value, target["value"])
        XCTAssertEqual(chat.transcript.configOptions.first { $0["id"] == effort["id"] }?["currentValue"], effort["currentValue"], "Active turn retains its applied setting")
        let followup = "Reply with only settings-updated. Do not use any tools."
        store.send(chat, text: followup, policy: .nextTurn)
        XCTAssertFalse(chat.transcript.items.contains { $0.kind == "user" && $0.text == followup })
        var answers = question.request.defaultContent.object
        let field = try XCTUnwrap(question.request.fields.first { $0.choices.contains { $0.value == "amber17" } })
        answers[field.id] = "amber17"
        try store.resolveInteraction(chat, id: question.id, action: .accept, content: .object(answers))
        var writeApproved = false
        while chat.busy || !chat.pendingSettings.isEmpty || !chat.pendingPrompts.isEmpty, ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let tool = approval.toolCall
                let path = tool["rawInput"]["file_path"].string
                guard path == output.path || path == "settings.txt", let option = approval.request["options"].array.first(where: { $0["kind"] == "allow_once" }) else {
                    store.resolveApproval(chat, id: approval.id, option: nil)
                    throw ACPError.workspace("Unexpected permission during settings acceptance: \(tool["title"].string)")
                }
                store.resolveApproval(chat, id: approval.id, option: option["optionId"].string); writeApproved = true
            }
            if chat.settingsPaused { throw ACPError.workspace(chat.pendingSettings.first?.error ?? chat.lastError ?? "Real setting rejected") }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(writeApproved)
        XCTAssertEqual(chat.state, .ready, chat.lastError ?? "Settings follow-up did not finish")
        XCTAssertTrue(chat.pendingSettings.isEmpty && chat.pendingPrompts.isEmpty)
        XCTAssertEqual(chat.transcript.configOptions.first { $0["id"] == effort["id"] }?["currentValue"], target["value"])
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "amber17")
        XCTAssertEqual(chat.transcript.items.filter { $0.kind == "user" && $0.text == followup }.count, 1)
        XCTAssertTrue(chat.transcript.items.last(where: { $0.kind == "assistant" })?.text.contains("settings-updated") == true)
        print("Real ACP settings acceptance: active question/Write retained current effort; pending effort confirmed before one queued follow-up.")
    }
    @MainActor func testPlanRevisionThenApprovalControlsRealImplementationAndTest() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-plan-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"].string == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"].string == "mode" })
        let manual = try XCTUnwrap(mode["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["value"].string == "default" })
        await store.setConfig(chat, id: mode["id"].string, value: manual["value"])
        guard chat.lastError == nil else { throw ACPError.workspace(chat.lastError!) }
        let workspace = URL(fileURLWithPath: chat.workspace.root)
        let output = workspace.appendingPathComponent("implementation.py")
        let results = workspace.appendingPathComponent("test-result.txt")
        store.send(chat, text: "EnterPlanMode first and draft a very short plan using your plan file, then ExitPlanMode to request my approval. The task is to create implementation.py defining value() returning the string json. After approval, use Write to create it and Bash to run /usr/bin/python3 -c 'from implementation import value; assert value() == \"json\"; open(\"test-result.txt\", \"w\").write(value())'. Wait for my plan approval before writing implementation.py or running tests. If I revise the requested return string, update both implementation and assertion. No other tasks, skills or agents; this is a disposable test project.")
        let deadline = ContinuousClock.now + .seconds(180)
        var entered = false, revised = false, approvedRevision = false, wrote = false, tested = false
        while chat.busy, ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let tool = approval.toolCall
                let name = PermissionPresentation(tool: tool).toolName
                if name == "EnterPlanMode" {
                    let option = try XCTUnwrap(approval.request["options"].array.first { $0["kind"].string == "allow_once" })
                    store.resolveApproval(chat, id: approval.id, option: option["optionId"].string); entered = true
                } else if name == "ExitPlanMode" {
                    if PermissionPresentation(tool: tool).plan == nil {
                        print("Missing real plan preview: \(tool.pretty)")
                        for item in chat.transcript.items where item.kind == "tool" {
                            print("Plan diagnostic tool: \(PermissionPresentation(tool: item.tool).toolName), \(item.tool["status"].string), \(item.tool["rawInput"]["file_path"].string), input keys: \(item.tool["rawInput"].object.keys.sorted())")
                        }
                    }
                    let plan = try XCTUnwrap(PermissionPresentation(tool: tool).plan, "The real provider must supply the plan for review")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
                    if !revised {
                        revised = true
                        await store.revisePlan(chat, id: approval.id, feedback: "Revise the plan: value() must return sqlite instead of json. The test must assert sqlite and write sqlite to test-result.txt. You must update the actual plan file itself using Edit or Write: replace the original json requirement and assertion with sqlite in that file. Then use ExitPlanMode again to request my approval before implementing this revised plan. Do not only describe the change in chat; update the plan file that ExitPlanMode presents.")
                    } else {
                        guard plan.localizedCaseInsensitiveContains("sqlite") else { throw ACPError.workspace("Fresh plan did not reflect the feedback; refusing to approve stale plan: \(plan)") }
                        let option = try XCTUnwrap(approval.request["options"].array.first { $0["kind"].string == "allow_once" })
                        store.resolveApproval(chat, id: approval.id, option: option["optionId"].string); approvedRevision = true
                    }
                } else {
                    let path = tool["rawInput"]["file_path"].string
                    let command = tool["rawInput"]["command"].string
                    let allowedWrite = approvedRevision && (path == output.path || path == "implementation.py")
                    let allowedTest = approvedRevision && command.hasPrefix("/usr/bin/python3 -c ") && command.contains("sqlite") && command.contains("test-result.txt")
                    guard allowedWrite || allowedTest, let option = approval.request["options"].array.first(where: { $0["kind"].string == "allow_once" }) else {
                        store.resolveApproval(chat, id: approval.id, option: nil)
                        throw ACPError.workspace("Unexpected permission in plan acceptance: \(name) \(tool["title"].string)")
                    }
                    store.resolveApproval(chat, id: approval.id, option: option["optionId"].string)
                    wrote = wrote || allowedWrite; tested = tested || allowedTest
                }
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        // Claude may allow EnterPlanMode and a sandboxed test without a callback.
        // Completed tool reports, fresh plan permission and file effects are required.
        let completed = chat.transcript.items.filter { $0.kind == "tool" && $0.tool["status"] == "completed" }.map(\.tool)
        entered = entered || completed.contains { PermissionPresentation(tool: $0).toolName == "EnterPlanMode" }
        wrote = wrote || completed.contains { PermissionPresentation(tool: $0).toolName == "Write" && $0["rawInput"]["file_path"].string == output.path }
        tested = tested || completed.contains { PermissionPresentation(tool: $0).toolName == "Bash" && $0["rawInput"]["command"].string.contains("test-result.txt") && $0["rawInput"]["command"].string.contains("sqlite") }
        guard entered && revised && approvedRevision && wrote && tested else { throw ACPError.workspace("Incomplete real plan acceptance: entered=\(entered), revised=\(revised), approved=\(approvedRevision), wrote=\(wrote), tested=\(tested)") }
        XCTAssertEqual(chat.state, .ready, chat.lastError ?? "Real plan workflow did not finish")
        XCTAssertEqual(try String(contentsOf: results, encoding: .utf8), "sqlite")
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("sqlite"))
        XCTAssertTrue(chat.pendingPrompts.isEmpty)
        print("Real ACP plan acceptance: EnterPlanMode → revision → fresh approval → actual Write → passing Python assertion.")
    }
    @MainActor func testBusyCorrectionControlsRealClaudeWriteWithoutAnotherTurn() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-steering-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        XCTAssertTrue(store.supportsSteering(chat))
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"].string == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"].string == "mode" })
        let manual = try XCTUnwrap(mode["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["value"].string == "default" })
        await store.setConfig(chat, id: mode["id"].string, value: manual["value"])
        let output = URL(fileURLWithPath: chat.workspace.root).appendingPathComponent("steering.txt")
        store.send(chat, text: "Use AskUserQuestion now to ask which token to write, with exactly two single-select options: cobalt42 and amber17. Wait for the user's answer. Then use Write to create steering.txt containing only that token. If a subsequent user correction changes the requested token, follow that correction. Do not use Bash, agents, skills, or other tools.")
        let deadline = ContinuousClock.now + .seconds(120)
        while chat.interactions.isEmpty, chat.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let question = try XCTUnwrap(chat.interactions.first, chat.lastError ?? "Claude did not ask the required question")
        let correction = "Correction: write steer99 into steering.txt regardless of which option I select. Reply with steer99."
        store.send(chat, text: correction)
        while !chat.transcript.items.contains(where: { $0.text == correction && $0.deliveryState == .acknowledged }), chat.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(chat.transcript.items.contains { $0.text == correction && $0.deliveryState == .acknowledged }, "The real adapter must acknowledge steering")
        var answers = question.request.defaultContent.object
        let field = try XCTUnwrap(question.request.fields.first { $0.choices.contains { $0.value == "cobalt42" } })
        answers[field.id] = "cobalt42"
        try store.resolveInteraction(chat, id: question.id, action: .accept, content: .object(answers))
        var writeApproved = false
        while chat.busy, ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let tool = approval.request["toolCall"]
                let paths = [tool["rawInput"]["file_path"].string, tool["rawInput"]["path"].string] + tool["locations"].array.map { $0["path"].string }
                guard paths.contains(output.path) || paths.contains("steering.txt"), let option = approval.request["options"].array.first(where: { $0["kind"].string == "allow_once" }) else {
                    store.resolveApproval(chat, id: approval.id, option: nil)
                    throw ACPError.workspace("Unexpected permission in steering acceptance: \(tool["title"].string)")
                }
                store.resolveApproval(chat, id: approval.id, option: option["optionId"].string)
                writeApproved = true
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(chat.state, .ready, chat.lastError ?? "Steered turn did not finish")
        XCTAssertTrue(writeApproved)
        XCTAssertTrue(chat.pendingPrompts.isEmpty)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "steer99")
        XCTAssertEqual(chat.transcript.items.filter { $0.kind == "user" && $0.text == correction }.count, 1)
        print("Real ACP steering acceptance: active-turn correction controlled the actual approved file Write.")
    }
    @MainActor func testInteractiveQuestionAnswerReachesClaudeAndControlsWrite() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-question-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"].string == "model" })
        let models = model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }
        let sonnet = try XCTUnwrap(models.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"].string == "mode" })
        let modes = mode["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }
        let manual = try XCTUnwrap(modes.first { $0["name"].string.localizedCaseInsensitiveContains("manual") || $0["value"].string == "default" })
        await store.setConfig(chat, id: mode["id"].string, value: manual["value"])
        XCTAssertNil(chat.lastError)
        let output = URL(fileURLWithPath: chat.workspace.root).appendingPathComponent("verification.txt")
        store.send(chat, text: "Use AskUserQuestion now to ask which token to write, with exactly two single-select options: cobalt42 and amber17. Wait for the user's answer. Then use the Write tool to create verification.txt in the current directory containing only the chosen token, and reply with that token. Do not use Bash, agents, skills, or any other tools.")
        let deadline = ContinuousClock.now + .seconds(120)
        var answered = false, writeApproved = false
        while chat.busy, ContinuousClock.now < deadline {
            for interaction in chat.interactions {
                var answers = interaction.request.defaultContent.object
                let field = try XCTUnwrap(interaction.request.fields.first { $0.choices.contains { $0.value == "amber17" } })
                answers[field.id] = "amber17"
                try store.resolveInteraction(chat, id: interaction.id, action: .accept, content: .object(answers))
                answered = true
            }
            for approval in chat.approvals {
                let tool = approval.request["toolCall"]
                let paths = [tool["rawInput"]["file_path"].string, tool["rawInput"]["path"].string] + tool["locations"].array.map { $0["path"].string }
                guard paths.contains(output.path) || paths.contains("verification.txt"),
                      let option = approval.request["options"].array.first(where: { $0["kind"].string == "allow_once" }) else {
                    store.resolveApproval(chat, id: approval.id, option: nil)
                    throw ACPError.workspace("Unexpected permission in question acceptance: \(tool["title"].string)")
                }
                store.resolveApproval(chat, id: approval.id, option: option["optionId"].string)
                writeApproved = true
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(answered, "Claude must actually invoke AskUserQuestion")
        XCTAssertTrue(writeApproved, "The actual selected write must reach its permission workflow")
        XCTAssertEqual(chat.state, .ready, chat.lastError ?? "Question acceptance did not finish")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "amber17")
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "assistant" && $0.text.contains("amber17") })
        print("Real ACP question acceptance: submitted choice reached Claude and controlled the approved Write.")
    }
    // Opt-in: four short text-only turns; retries and edits must exclude the original later prompt.
    @MainActor func testEditAndRetryExcludeOriginalPrompt() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-revision-\(UUID())")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown() }
        await store.create(path: project.path, worktree: false)
        let source = try XCTUnwrap(store.selected)
        try await store.connect(source)
        let model = try XCTUnwrap(source.transcript.configOptions.first { $0["category"].string == "model" })
        let options = model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }
        let sonnet = try XCTUnwrap(options.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(source, id: model["id"].string, value: sonnet["value"])
        guard source.lastError == nil, source.transcript.configOptions.first(where: { $0["id"].string == model["id"].string })?["currentValue"] == sonnet["value"] else { throw ACPError.workspace(source.lastError ?? "Revision check must use Sonnet.") }
        let early = "EARLY_" + UUID().uuidString, later = "LATER_" + UUID().uuidString
        store.send(source, text: "My first token is \(early). Reply with this first token, then any later token I have given in this conversation. If no later token was given, write NONE. Do not use tools or guess.")
        try await finish(source, store: store)
        let firstResponse = try XCTUnwrap(source.transcript.items.last { $0.kind == "assistant" })
        XCTAssertTrue(firstResponse.text.contains(early)); XCTAssertTrue(firstResponse.text.contains("NONE"))
        store.send(source, text: "My later token is \(later). Remember it and reply with only that later token. Do not use tools.")
        try await finish(source, store: store)
        let laterPrompt = try XCTUnwrap(source.transcript.items.last { $0.kind == "user" })
        let history = source.transcript.items, remoteID = source.transcript.remoteID
        source.draft = "Preserve source draft"
        let retryID = try await store.retryResponse(source, at: firstResponse.id)
        let retry = try XCTUnwrap(store.selected)
        XCTAssertEqual(retry.id, retryID)
        let retryOrigin = try XCTUnwrap(store.sessions.first { $0.id == retryID }?.origin)
        XCTAssertEqual(retryOrigin.kind, .retry)
        XCTAssertEqual(retryOrigin.sourceSessionID, source.id)
        XCTAssertEqual(retryOrigin.sourceRemoteID, remoteID)
        XCTAssertEqual(retryOrigin.sourceItemID, firstResponse.id)
        XCTAssertTrue(retryOrigin.startsFresh)
        XCTAssertNil(retryOrigin.boundaryMessageID)
        try await finish(retry, store: store)
        let retryAnswer = try XCTUnwrap(retry.transcript.items.last { $0.kind == "assistant" }?.text)
        XCTAssertTrue(retryAnswer.contains(early)); XCTAssertTrue(retryAnswer.contains("NONE")); XCTAssertFalse(retryAnswer.contains(later))
        XCTAssertNotEqual(retry.transcript.remoteID, remoteID)
        XCTAssertEqual(retry.transcript.items.filter { $0.kind == "user" }.count, 1)
        XCTAssertEqual(retry.transcript.configOptions.first { $0["id"].string == model["id"].string }?["currentValue"], sonnet["value"])
        await store.select(source.id)
        let reopened = try XCTUnwrap(store.selected)
        let editID = try await store.editMessage(reopened, at: laterPrompt.id)
        let edit = try XCTUnwrap(store.selected)
        XCTAssertEqual(edit.id, editID); XCTAssertEqual(edit.draft, laterPrompt.text)
        let editOrigin = try XCTUnwrap(store.sessions.first { $0.id == editID }?.origin)
        XCTAssertEqual(editOrigin.kind, .edit)
        XCTAssertEqual(editOrigin.sourceSessionID, source.id)
        XCTAssertEqual(editOrigin.sourceRemoteID, remoteID)
        XCTAssertEqual(editOrigin.sourceItemID, laterPrompt.id)
        XCTAssertEqual(editOrigin.boundaryMessageID, firstResponse.messageID)
        XCTAssertFalse(editOrigin.startsFresh)
        XCTAssertEqual(Set(ConversationBranch.related(to: editID, in: store.sessions).map(\.id)), Set([source.id, retryID, editID]))
        edit.draft = "State my first token and my later token if I already gave one. If I have not given a later token, write NONE. Do not use tools or guess."
        store.send(edit); try await finish(edit, store: store)
        let editAnswer = try XCTUnwrap(edit.transcript.items.last { $0.kind == "assistant" }?.text)
        XCTAssertTrue(editAnswer.contains(early)); XCTAssertTrue(editAnswer.contains("NONE")); XCTAssertFalse(editAnswer.contains(later))
        XCTAssertNotEqual(edit.transcript.remoteID, remoteID)
        XCTAssertEqual(reopened.transcript.items, history); XCTAssertEqual(reopened.draft, "Preserve source draft")
        XCTAssertEqual(source.transcript.items, history); XCTAssertEqual(source.draft, "Preserve source draft")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
        await store.archive(edit.id); await store.archive(retry.id); await store.archive(source.id)
        print("Real edit/retry: first-response retry has fresh context; edited later prompt retains early context and excludes replaced/future turns; source history/draft unchanged, no tools or project files.")
    }
    // Opt-in: one visual prompt, with synthetic PDF codes outside the empty workspace.
    @MainActor func testPDFPagesReachRealModelInOrder() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-pdf-\(UUID())")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("pages.pdf")
        let codes = ["ALPHA-" + UUID().uuidString.prefix(6), "BETA-" + UUID().uuidString.prefix(6)]
        var box = CGRect(x: 0, y: 0, width: 480, height: 240)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        for code in codes {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
            context.textPosition = CGPoint(x: 30, y: 105)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: code, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 42, nil)]))
            CTLineDraw(line, context); context.endPDFPage()
        }
        context.closePDF()
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown() }
        await store.create(path: project.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"].string == "model" })
        let options = model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }
        let sonnet = try XCTUnwrap(options.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        guard chat.lastError == nil, chat.transcript.configOptions.first(where: { $0["id"].string == model["id"].string })?["currentValue"] == sonnet["value"] else { throw ACPError.workspace(chat.lastError ?? "PDF check must use Sonnet.") }
        store.attach(pdf, to: chat); await chat.attachmentTask?.value
        XCTAssertEqual(chat.attachments.count, 1, store.error ?? "")
        chat.draft = "Read both attached PDF pages. Reply with only the printed codes, one per line, in page order. Do not use tools."
        store.send(chat); try await finish(chat, store: store)
        let response = try XCTUnwrap(chat.transcript.items.last { $0.kind == "assistant" }?.text)
        let first = try XCTUnwrap(response.range(of: codes[0])), second = try XCTUnwrap(response.range(of: codes[1]))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertTrue(chat.attachments.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
        await store.archive(chat.id); await store.shutdown()
        print("Real PDF comprehension: both synthetic codes read in page order; codes existed only in page images, no tools or project files.")
    }
    // Opt-in: three short text-only turns in an empty disposable project.
    @MainActor func testSelectedMessageForkExcludesLaterContext() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-boundary-\(UUID())")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown() }
        await store.create(path: project.path, worktree: false)
        let source = try XCTUnwrap(store.selected)
        try await store.connect(source)
        let model = try XCTUnwrap(source.transcript.configOptions.first { $0["category"].string == "model" })
        let options = model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }
        let sonnet = try XCTUnwrap(options.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(source, id: model["id"].string, value: sonnet["value"])
        guard source.lastError == nil, source.transcript.configOptions.first(where: { $0["id"].string == model["id"].string })?["currentValue"] == sonnet["value"] else { throw ACPError.workspace(source.lastError ?? "Real-agent check must use the selected Sonnet model.") }
        let early = "EARLY_" + UUID().uuidString, later = "LATER_" + UUID().uuidString
        store.send(source, text: "Remember my first token: \(early). Reply with exactly that token. Do not use tools.")
        try await finish(source, store: store)
        let boundary = try XCTUnwrap(source.transcript.items.last { $0.kind == "assistant" })
        XCTAssertTrue(boundary.text.contains(early))
        store.send(source, text: "Remember my later token: \(later). Reply with exactly that token. Do not use tools.")
        try await finish(source, store: store)
        XCTAssertTrue(source.transcript.items.last { $0.kind == "assistant" }?.text.contains(later) == true)
        let original = source.transcript.items
        source.draft = "Keep my unsent draft"
        let forkID = try await store.fork(source, at: boundary.id)
        let branch = try XCTUnwrap(store.selected)
        XCTAssertEqual(branch.id, forkID); XCTAssertNotEqual(branch.transcript.remoteID, source.transcript.remoteID)
        XCTAssertEqual(branch.transcript.items, Array(original.prefix(through: try XCTUnwrap(original.firstIndex { $0.id == boundary.id }))))
        store.send(branch, text: "State my first token, then my later token if I gave one. If no later token was given, write NONE for it. Do not use tools or guess tokens.")
        try await finish(branch, store: store)
        let response = try XCTUnwrap(branch.transcript.items.last { $0.kind == "assistant" }?.text)
        XCTAssertTrue(response.contains(early)); XCTAssertTrue(response.uppercased().contains("NONE")); XCTAssertFalse(response.contains(later))
        XCTAssertEqual(source.transcript.items, original); XCTAssertEqual(source.draft, "Keep my unsent draft")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: project.path).isEmpty)
        await store.archive(branch.id); await store.archive(source.id)
        await store.shutdown()
        print("Real selected-message fork: earlier token recalled, later token excluded, source transcript/draft unchanged; no project files or tools.")
    }
    // Explicit opt-in: this check submits three short prompts to the configured real agent.
    @MainActor func testWorktreeMessagingRestoreAndFork() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else { throw XCTSkip("Set CCODE_REAL_AGENT to an authenticated ACP executable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-agent-\(UUID())")
        let project = root.appendingPathComponent("project"), data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-b", "main"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "initial"]] {
            _ = try await Repository.run(args, at: project.path)
        }
        let store = AppStore(directory: data)
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown() }
        await store.openHome(path: project.path)
        let model = try XCTUnwrap(store.homeConfigurationOptions.first { $0["category"].string == "model" })
        let choices = model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }
        let sonnet = try XCTUnwrap(choices.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        store.chooseHomeConfiguration(id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(store.homeConfigurationOptions.first { $0["category"].string == "mode" })
        let manual = try XCTUnwrap(mode["options"].array.first { $0["name"].string == "Manual" })
        store.chooseHomeConfiguration(id: mode["id"].string, value: manual["value"])
        store.newSessionDraft.worktree = true
        store.newSessionDraft.text = "Use the Write tool to create verification.txt in the current working directory containing exactly cobalt42. Do not use Bash or other tools. Then reply with cobalt42. Remember this token for the next turn."
        await store.startFromHome()
        let id = try XCTUnwrap(store.selectedID), chat = try XCTUnwrap(store.selected)
        let file = URL(fileURLWithPath: chat.workspace.root).appendingPathComponent("verification.txt")
        let approvals = try await finish(chat, store: store, allowedFile: file.path)
        XCTAssertGreaterThan(approvals, 0, "Manual mode must ask before the agent writes")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "cobalt42")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("verification.txt").path))
        let mainStatus = try await Repository.status(at: project.path)
        XCTAssertEqual(mainStatus.branch, "main"); XCTAssertTrue(mainStatus.files.isEmpty)
        XCTAssertEqual(store.sidebarProjects, [try Workspace(root: project.path).root])
        let remoteID = try XCTUnwrap(chat.transcript.remoteID)
        await store.shutdown()
        let restored = AppStore(directory: data); restored.settings = store.settings
        addTeardownBlock { await restored.shutdown() }
        await restored.restore(); await restored.select(id)
        let reopened = try XCTUnwrap(restored.selected)
        restored.send(reopened, text: "What exact token did you write previously? Reply with only the token; do not use tools.")
        try await finish(reopened, store: restored)
        XCTAssertTrue(reopened.transcript.items.last(where: { $0.kind == "assistant" })?.text.contains("cobalt42") == true)
        XCTAssertEqual(reopened.transcript.remoteID, remoteID)
        _ = try await restored.fork(reopened)
        let fork = try XCTUnwrap(restored.selected)
        XCTAssertNotEqual(fork.transcript.remoteID, remoteID)
        restored.send(fork, text: "Recall the token from the original conversation. Reply with only the token; do not use tools.")
        try await finish(fork, store: restored)
        XCTAssertTrue(fork.transcript.items.last(where: { $0.kind == "assistant" })?.text.contains("cobalt42") == true)
        XCTAssertEqual(reopened.transcript.items.filter { $0.kind == "user" }.count, 2)
        XCTAssertEqual(restored.selectedInfo?.worktreeSourcePath, try Workspace(root: project.path).root)
        await restored.shutdown()
        print("Real ACP acceptance: isolated Write, clean main checkout, persisted resume, independent fork and token recall passed.")
    }

    @discardableResult @MainActor private func finish(_ chat: ChatSession, store: AppStore, allowedFile: String? = nil) async throws -> Int {
        let deadline = ContinuousClock.now + .seconds(120)
        var approvals = 0
        while chat.busy, ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let call = approval.request["toolCall"]
                let paths = [call["rawInput"]["file_path"].string, call["rawInput"]["path"].string] + call["locations"].array.map { $0["path"].string }
                guard let allowedFile, paths.contains(allowedFile) || paths.contains("verification.txt"),
                      let option = approval.request["options"].array.first(where: { $0["kind"].string == "allow_once" }) else {
                    store.resolveApproval(chat, id: approval.id, option: nil)
                    throw ACPError.workspace("Unexpected real-agent permission request: \(call["title"].string)")
                }
                store.resolveApproval(chat, id: approval.id, option: option["optionId"].string)
                approvals += 1
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        guard !chat.busy, chat.state == .ready else { throw ACPError.workspace(chat.lastError ?? "Real-agent prompt timed out") }
        return approvals
    }
}
