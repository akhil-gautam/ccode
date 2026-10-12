import XCTest
import Foundation
import CCodeCore
@testable import CCode

final class RealScheduledWorkTests: XCTestCase {
    @MainActor func testRunNowMakesActualChangeWithSavedChoicesAndIndependentDraft() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_SCHEDULE_AGENT"], FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("Opt-in authenticated local routine proof") }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ccode-real-routine-\(UUID())"), project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("empty-history"))
        store.settings.executable = executable; store.settings.arguments = []
        addTeardownBlock { await store.shutdown() }
        await store.create(path: project.path, worktree: false)
        let original = try XCTUnwrap(store.selected)
        try await store.connect(original)
        let model = try XCTUnwrap(original.transcript.configOptions.first { $0["category"] == "model" }), sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(original, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(original.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(original, id: mode["id"].string, value: "default")
        XCTAssertNil(original.lastError)
        let configuration = try XCTUnwrap(store.confirmedConfiguration(original)), nonce = "routine-" + UUID().uuidString, target = project.appendingPathComponent("routine-proof.txt"), draft = "Independent unsent draft " + UUID().uuidString
        original.draft = draft; store.newSessionDraft.text = "Independent Home draft"
        let task = try ScheduledTask(name: "Disposable Run-now proof", instructions: "Use only the Write tool to create routine-proof.txt in the current project containing exactly \(nonce) followed by one newline. Do not run commands, delegate, read other files or modify anything else. Report completion.", projectPath: project.path, configuration: configuration)
        try await store.saveScheduledTask(task, expecting: nil)
        store.settings.executable = "/not-the-saved-agent"
        let runID = try await store.runScheduledTask(task.id)
        let deadline = ContinuousClock.now + .seconds(180)
        var accepted = 0
        while store.scheduledBook.runs.first(where: { $0.id == runID })?.state.isActive == true, ContinuousClock.now < deadline {
            if let chat = store.chat(runID) {
                for approval in chat.approvals {
                    let presentation = PermissionPresentation(tool: approval.toolCall), input = approval.toolCall["rawInput"]
                    guard presentation.toolName == "Write", input["file_path"].string == target.path,
                          input["content"].string == nonce + "\n" else {
                        store.resolveApproval(chat, id: approval.id, option: nil)
                        throw ACPError.workspace("Unexpected routine proof permission: " + presentation.toolName)
                    }
                    let option = approval.request["options"].array.first { $0["kind"] == "allow_once" }
                    store.resolveApproval(chat, id: approval.id, option: option?["optionId"].optionalString); accepted += 1
                }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard let run = store.scheduledBook.runs.first(where: { $0.id == runID }), run.state == .completed else {
            try? await store.cancelScheduledRun(runID)
            throw ACPError.workspace(store.chat(runID)?.lastError ?? "Actual routine did not complete")
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), nonce + "\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: project.path).filter { $0 != ".claude" }, ["routine-proof.txt"])
        XCTAssertEqual(store.selectedID, original.id); XCTAssertEqual(original.draft, draft); XCTAssertEqual(store.newSessionDraft.text, "Independent Home draft")
        XCTAssertEqual(store.sessions.first { $0.id == runID }?.scheduledOrigin?.runID, runID)
        XCTAssertEqual(store.chat(runID)?.transcript.configOptions.first { $0["id"] == model["id"] }?["currentValue"], sonnet["value"])
        XCTAssertGreaterThan(accepted, 0)
        let recovered = try await SessionStorage(directory: root.appendingPathComponent("data")).loadScheduledBook()
        XCTAssertEqual(recovered.runs.first { $0.id == runID }?.state, .completed)
        let proof: JSONValue = ["run_id": .string(runID.uuidString), "result": .string(nonce), "saved_agent_used": true, "draft_preserved": true, "selected_chat_preserved": true, "completed_persisted": true, "permission_requests": .number(Double(accepted)), "native_acceptance": false]
        try JSONEncoder().encode(proof).write(to: root.appendingPathComponent("verified-routine.json"))
        await store.shutdown(); print("Actual routine proof: \(root.path)")
    }
}
