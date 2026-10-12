import XCTest
import Foundation
import CCodeCore
@testable import CCode

final class WorkingChatWorkflowTests: XCTestCase, @unchecked Sendable {
    // Opt-in acceptance: breaks if decisions/plan feedback/continuation reach a
    // different session, lose user context, or do not affect actual file work.
    @MainActor func testRealClarificationPlanRevisionCodeTestReviewFollowupAndRestart() async throws {
        guard let executable = ProcessInfo.processInfo.environment["CCODE_REAL_AGENT"] else {
            throw XCTSkip("Set CCODE_REAL_AGENT to the authenticated pinned ACP executable.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-real-working-loop-\(UUID())")
        let project = root.appendingPathComponent("project"), data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "Disposable working-chat proof.\n".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await Repository.run(["init", "-b", "main"], at: project.path)
        _ = try await Repository.run(["add", "README.md"], at: project.path)
        _ = try await Repository.run(["-c", "user.name=ccode QA", "-c", "user.email=ccode-qa@example.invalid", "commit", "-m", "Initial disposable fixture"], at: project.path)
        let originalReadme = try Data(contentsOf: project.appendingPathComponent("README.md"))
        let nodeEntry = ProcessInfo.processInfo.environment["CCODE_REAL_NODE_ENTRY"] == "1"
        let launchExecutable = nodeEntry ? try XCTUnwrap(AgentSettings.locate("node")) : executable
        let launchArguments = nodeEntry ? [URL(fileURLWithPath: executable).resolvingSymlinksInPath().path] : []
        let store = AppStore(directory: data)
        store.settings.executable = launchExecutable; store.settings.arguments = launchArguments
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: project.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(chat, id: mode["id"].string, value: "default")
        XCTAssertNil(chat.lastError)
        let output = project.appendingPathComponent("answer.py"), result = project.appendingPathComponent("test-result.txt")
        store.send(chat, text: "We will build answer.py with value() returning a selected token. First use AskUserQuestion to ask which token, with exactly two single-select options cobalt42 and amber17. Wait for my answer, then reply with the selected token and finish. Do not plan, write files, run commands, use agents or skills yet.")
        try await wait(chat) { !chat.interactions.isEmpty || !chat.busy }
        let question = try XCTUnwrap(chat.interactions.first, chat.lastError ?? "Required clarification did not arrive")
        var answers = question.request.defaultContent.object
        let field = try XCTUnwrap(question.request.fields.first { $0.choices.contains { $0.value == "cobalt42" } })
        answers[field.id] = "cobalt42"
        try store.resolveInteraction(chat, id: question.id, action: .accept, content: .object(answers))
        try await finish(chat, store: store, allowedToken: nil)
        XCTAssertTrue(chat.transcript.items.last { $0.kind == "assistant" }?.text.contains("cobalt42") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        print("Working loop: actual clarification answer reached the same agent.")

        store.send(chat, text: "Now EnterPlanMode and write a very short plan in your plan file for the token I selected. ExitPlanMode to request my approval. After approval use Write to create answer.py defining value(), then Bash exactly /usr/bin/python3 -c 'from answer import value; assert value() == \"cobalt42\"; open(\"test-result.txt\", \"w\").write(value())'. If I revise the plan, update the actual plan file, request fresh approval, and change the implementation and assertion. Do not edit answer.py or run tests before approval. No other files/tasks/agents/skills/network.")
        var revised = false, approved = false
        let deadline = ContinuousClock.now + .seconds(200)
        while chat.busy, ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let tool = approval.toolCall, name = PermissionPresentation(tool: tool).toolName
                if name == "EnterPlanMode" {
                    approve(approval, chat: chat, store: store)
                } else if name == "ExitPlanMode" {
                    let plan = try XCTUnwrap(PermissionPresentation(tool: tool).plan, "Actual plan must be available for review")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "Code must wait for approval")
                    if !revised {
                        XCTAssertTrue(plan.contains("cobalt42"), "Planning must retain the clarification answer")
                        revised = true
                        await store.revisePlan(chat, id: approval.id, feedback: "Change the requested token to amber17. Update your actual plan file to replace cobalt42 with amber17, including the assertion. Use ExitPlanMode again and wait for my fresh approval before implementation.")
                    } else {
                        guard plan.contains("amber17") else { throw ACPError.workspace("Revised plan does not contain the requested token") }
                        approved = true; approve(approval, chat: chat, store: store)
                    }
                } else {
                    try resolveWork(approval, chat: chat, store: store, token: approved ? "amber17" : nil)
                }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard !chat.busy, chat.state == .ready, revised, approved else { throw ACPError.workspace(chat.lastError ?? "Plan/revision/implementation did not complete") }
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "amber17")
        let firstDiff = try await Repository.diff(at: project.path, path: "answer.py")
        XCTAssertTrue(firstDiff.contains("+")); XCTAssertTrue(firstDiff.contains("amber17"))
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "tool" && $0.tool["status"] == "completed" && PermissionPresentation(tool: $0.tool).toolName == "Bash" && $0.tool["rawInput"]["command"].string.contains("test-result.txt") })
        print("Working loop: revised plan approved, actual code/test result and Git diff verified.")

        store.send(chat, text: "Review feedback on answer.py: change value() to return reviewed33. Edit only answer.py, then run exactly /usr/bin/python3 -c 'from answer import value; assert value() == \"reviewed33\"; open(\"test-result.txt\", \"w\").write(value())'. No agents, skills, network or other files. Finish when the assertion passes.")
        try await finish(chat, store: store, allowedToken: "reviewed33")
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "reviewed33")
        let correctedDiff = try await Repository.diff(at: project.path, path: "answer.py")
        XCTAssertTrue(correctedDiff.contains("reviewed33"))
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("README.md")), originalReadme)
        let terminal = TerminalService()
        let command = try await terminal.create(command: "/usr/bin/python3", arguments: ["-c", "from answer import value; assert value() == 'reviewed33'"], directory: project.path)
        let testStatus = try await terminal.wait(command)
        await terminal.close()
        XCTAssertEqual(testStatus["exitCode"], 0, "Independently execute the actual resulting Python code")
        let id = chat.id, remote = chat.transcript.remoteID
        chat.draft = "Keep this unsent follow-up"
        await store.save(chat); await store.shutdown()
        let reopened = AppStore(directory: data)
        reopened.settings.executable = launchExecutable; reopened.settings.arguments = launchArguments
        addTeardownBlock { await reopened.shutdown() }
        await reopened.restore(); await reopened.select(id)
        let resumed = try XCTUnwrap(reopened.selected)
        XCTAssertEqual(resumed.draft, "Keep this unsent follow-up")
        try await reopened.connect(resumed)
        XCTAssertEqual(resumed.transcript.remoteID, remote)
        XCTAssertEqual(resumed.transcript.configOptions.first { $0["id"] == model["id"] }?["currentValue"], sonnet["value"], "Actual resumed process must retain the selected model")
        XCTAssertEqual(resumed.transcript.configOptions.first { $0["id"] == mode["id"] }?["currentValue"], "default", "Actual resumed process must retain Manual permissions")
        reopened.send(resumed, text: "Without tools or file reads, report the token I initially selected, the revised approved plan token and the later review-feedback token. Reply only with these three tokens in that order.")
        try await finish(resumed, store: reopened, allowedToken: nil)
        let response = try XCTUnwrap(resumed.transcript.items.last { $0.kind == "assistant" }).text
        XCTAssertTrue(response.contains("cobalt42")); XCTAssertTrue(response.contains("amber17")); XCTAssertTrue(response.contains("reviewed33"))
        XCTAssertEqual(resumed.draft, "Keep this unsent follow-up")
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("README.md")), originalReadme)
        print("Working loop: review caused a second real edit, independent test passed, saved session recalled all decisions after restart, unsent draft preserved. Explicit Node entry: \(nodeEntry). Native UI acceptance remains separate.")
    }

    @MainActor private func wait(_ chat: ChatSession, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
        guard condition() else { throw ACPError.workspace(chat.lastError ?? "Working-chat state timed out") }
    }
    @MainActor private func approve(_ approval: Approval, chat: ChatSession, store: AppStore) {
        let option = approval.request["options"].array.first { $0["kind"] == "allow_once" }
        store.resolveApproval(chat, id: approval.id, option: option?["optionId"].optionalString)
    }
    @MainActor private func resolveWork(_ approval: Approval, chat: ChatSession, store: AppStore, token: String?) throws {
        let tool = approval.toolCall, name = PermissionPresentation(tool: tool).toolName
        let path = tool["rawInput"]["file_path"].string, command = tool["rawInput"]["command"].string
        let allowedFile = token != nil && ["Write", "Edit", "Read"].contains(name) && (path == "answer.py" || path == URL(fileURLWithPath: chat.workspace.root).appendingPathComponent("answer.py").path)
        let allowedCommand = token != nil && name == "Bash" && command.hasPrefix("/usr/bin/python3 -c ") && command.contains("from answer import value") && command.contains(token!) && command.contains("test-result.txt")
        guard allowedFile || allowedCommand else {
            store.resolveApproval(chat, id: approval.id, option: nil)
            throw ACPError.workspace("Unexpected working-loop permission: \(name)")
        }
        approve(approval, chat: chat, store: store)
    }
    @MainActor private func finish(_ chat: ChatSession, store: AppStore, allowedToken: String?) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while chat.busy, ContinuousClock.now < deadline {
            for approval in chat.approvals { try resolveWork(approval, chat: chat, store: store, token: allowedToken) }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard !chat.busy, chat.state == .ready else { throw ACPError.workspace(chat.lastError ?? "Working-chat turn did not finish") }
    }
}
