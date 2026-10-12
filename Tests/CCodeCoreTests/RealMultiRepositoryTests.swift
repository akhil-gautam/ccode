import XCTest
import Foundation
import Darwin
import CCodeCore
@testable import CCode

final class RealMultiRepositoryTests: XCTestCase, @unchecked Sendable {
    // Opt-in proof: an actual agent must consume a token present only in an
    // additional-folder editor snapshot, edit that folder and keep primary cwd.
    @MainActor func testActualAgentConsumesAdditionalFolderSnapshotWithoutRedirectingPrimaryFile() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else {
            throw XCTSkip("Set CCODE_REAL_AGENT to the authenticated pinned ACP executable.")
        }
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ccode-real-multi-root-\(UUID())")
        let primary = base.appendingPathComponent("primary"), extra = base.appendingPathComponent("extra")
        for directory in [primary, extra] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try await Repository.run(["init", "-b", "main"], at: directory.path)
        }
        let primaryFile = primary.appendingPathComponent("answer.py"), target = extra.appendingPathComponent("answer.py")
        let primaryText = "def value():\n    return \"primary untouched\"\n"
        let original = "def value():\n    return \"before\"\n"
        try primaryText.write(to: primaryFile, atomically: true, encoding: .utf8)
        try original.write(to: target, atomically: true, encoding: .utf8)
        let snapshotText = "# Required token: multi43\n" + original
        let store = AppStore(directory: base.appendingPathComponent("data"), claudeDirectory: base.appendingPathComponent("empty-claude"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown() }
        await store.create(path: primary.path, worktree: false, additionalDirectories: [extra.path])
        let chat = try XCTUnwrap(store.selected)
        try await store.selectWorkspaceFolder(chat, path: extra.path)
        let key = try await store.loadWorkspaceFile(chat, path: "answer.py")
        chat.fileDrafts[key]?.text = snapshotText
        let snapshot = try await chat.workspace.selectedFileContext(path: target.path, text: snapshotText, range: NSRange(location: 0, length: (snapshotText as NSString).length))
        guard await store.attachSelectedContext(snapshot, to: chat) else { throw ACPError.workspace(store.error ?? "Could not attach selected context") }
        XCTAssertEqual(chat.attachments.count, 1)
        try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(chat, id: mode["id"].string, value: "default")
        XCTAssertNil(chat.lastError)
        let result = extra.appendingPathComponent("result.json")
        let script = "import importlib.util,json,os; s=importlib.util.spec_from_file_location(\"target\",\"\(target.path)\"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); json.dump({\"value\":m.value(),\"cwd\":os.getcwd()},open(\"\(result.path)\",\"w\"))"
        let command = "/usr/bin/python3 -c '" + script + "'"
        chat.draft = "Keep unrelated composer text"
        print("Actual additional-folder proof directory: \(base.path)")
        store.send(chat, text: "The attached editor selection names the required token. Edit only its additional-folder answer.py at \(target.path) so value() returns that token. Keep the primary cwd file with the same name unchanged. Use Read and Edit or Write on the target, then Bash exactly:\n\(command)\nDo not cd, use agents/skills/network, modify other files or ask questions. Finish after the command succeeds.")
        let deadline = ContinuousClock.now + .seconds(150)
        while chat.busy, ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let tool = approval.toolCall, name = PermissionPresentation(tool: tool).toolName
                let allowed = ["Read", "Edit", "Write"].contains(name) && tool["rawInput"]["file_path"].string == target.path
                    || name == "Bash" && tool["rawInput"]["command"].string == command
                guard allowed else {
                    store.resolveApproval(chat, id: approval.id, option: nil)
                    throw ACPError.workspace("Unexpected multi-root permission: \(name) \(tool["rawInput"].pretty)")
                }
                let option = approval.request["options"].array.first { $0["kind"] == "allow_once" }
                store.resolveApproval(chat, id: approval.id, option: option?["optionId"].optionalString)
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard !chat.busy, chat.state == .ready else { throw ACPError.workspace(chat.lastError ?? "Actual additional-folder turn did not finish") }
        let report = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: result))
        XCTAssertEqual(report["value"], "multi43")
        XCTAssertEqual(report["cwd"], .string(primary.path))
        XCTAssertEqual(try String(contentsOf: primaryFile, encoding: .utf8), primaryText)
        XCTAssertEqual(chat.workspace.root, primary.path)
        XCTAssertEqual(chat.workspaceDirectory, extra.path)
        XCTAssertEqual(chat.draft, "Keep unrelated composer text")
        XCTAssertEqual(chat.fileDrafts[key]?.text, snapshotText)
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "tool" && $0.tool["status"] == "completed" && $0.tool["rawInput"]["command"].string == command })
        let check = TerminalService()
        let id = try await check.create(command: "/usr/bin/python3", arguments: ["-c", "import importlib.util; s=importlib.util.spec_from_file_location('target',\(String(reflecting: target.path))); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); assert m.value() == 'multi43'"], directory: primary.path)
        let exit = try await check.wait(id); await check.close()
        XCTAssertEqual(exit["exitCode"].int, 0)
        await store.save(chat)
        let saved = try await store.storage.load(chat.id)
        let reopened = try ChatSession(id: chat.id, path: primary.path, transcript: saved, additionalDirectories: [extra.path])
        XCTAssertEqual(reopened.workspaceDirectory, extra.path)
        XCTAssertEqual(reopened.draft, "Keep unrelated composer text")
        XCTAssertEqual(reopened.fileDrafts[key]?.text, snapshotText)
        print("Actual additional-folder edit and independent Python check passed; primary file/cwd and unsent composer/editor drafts preserved. Native acceptance remains separate.")
    }
}
