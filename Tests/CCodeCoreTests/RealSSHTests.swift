import XCTest
import Foundation
@testable import CCodeCore
@testable import CCode

final class RealSSHTests: XCTestCase {
    @MainActor func testActualAgentEditsThroughEncryptedSSHAndRestoresSession() async throws {
        guard let proofPath = ProcessInfo.processInfo.environment["CCODE_SSH_LOOPBACK_PROOF"],
              let executable = ProcessInfo.processInfo.environment["CCODE_REAL_SSH_AGENT"] else { throw XCTSkip("Opt-in authenticated SSH provider proof") }
        let proofURL = URL(fileURLWithPath: proofPath)
        let metadata = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: proofURL))
        let server = URL(fileURLWithPath: metadata["directory"].string)
        guard server.path.hasPrefix(FileManager.default.currentDirectoryPath + "/.build/ssh-loopback-"), metadata["configuration_check_exit"].exactInteger == 0 else { throw ACPError.workspace("Use the disposable SSH acceptance server") }
        let arguments = try JSONDecoder().decode([String].self, from: Data((ProcessInfo.processInfo.environment["CCODE_REAL_SSH_ARGUMENTS"] ?? "[]").utf8))
        let root = server.appendingPathComponent("real-project"), data = server.appendingPathComponent("real-data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: data, claudeDirectory: server.appendingPathComponent("empty-history"), sshExecutable: server.appendingPathComponent("ssh-wrapper").path)
        addTeardownBlock { await store.shutdown() }
        let host = try SSHConfiguration(name: "Real SSH acceptance", host: "ccode-disposable-loopback")
        let sessionID = try await store.createSSHWorkspace(host: host, path: root.path, executable: executable, arguments: arguments)
        let chat = try XCTUnwrap(store.selected)
        let nonce = "ssh-" + UUID().uuidString, contextPath = root.appendingPathComponent("context.txt").path, target = root.appendingPathComponent("ssh-result.txt").path
        try await chat.workspace.write(contextPath, content: "Required result: " + nonce)
        guard await store.attachContext(ContextCandidate(root: root.path, path: contextPath, kind: .file), to: chat) else { throw ACPError.workspace(store.error ?? "SSH context attachment failed") }
        try await store.connect(chat)
        let model = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let sonnet = try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat, id: model["id"].string, value: sonnet["value"])
        let mode = try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(chat, id: mode["id"].string, value: "default")
        XCTAssertNil(chat.lastError)
        store.send(chat, text: "The attached context specifies the required result. Use only Write to create ssh-result.txt in this project containing that result followed by one newline. Do not read other files, run commands, use skills, delegate, access the network or modify anything else. Report completion.")
        let deadline = ContinuousClock.now + .seconds(150)
        var approvals = 0
        while chat.busy, ContinuousClock.now < deadline {
            for approval in chat.approvals {
                let presentation = PermissionPresentation(tool: approval.toolCall), input = approval.toolCall["rawInput"]
                guard presentation.toolName == "Write", input["file_path"].string == target, input["content"].string == nonce + "\n" else {
                    store.resolveApproval(chat, id: approval.id, option: nil)
                    throw ACPError.workspace("Unexpected SSH proof permission: " + presentation.toolName)
                }
                let option = approval.request["options"].array.first { $0["kind"] == "allow_once" }
                store.resolveApproval(chat, id: approval.id, option: option?["optionId"].optionalString); approvals += 1
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard !chat.busy, chat.state == .ready else { store.stop(chat); throw ACPError.workspace(chat.lastError ?? "SSH proof did not finish") }
        XCTAssertGreaterThan(approvals, 0)
        let actual = try await chat.workspace.read(target); XCTAssertEqual(actual, nonce + "\n")
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), nonce + "\n")
        let providerID = try XCTUnwrap(chat.transcript.remoteID)
        await store.save(chat); await store.shutdown()
        let restored = AppStore(directory: data, claudeDirectory: server.appendingPathComponent("empty-history"), sshExecutable: server.appendingPathComponent("ssh-wrapper").path)
        addTeardownBlock { await restored.shutdown() }
        await restored.restore(); await restored.select(sessionID)
        let reopened = try XCTUnwrap(restored.selected)
        try await restored.connect(reopened)
        XCTAssertEqual(reopened.transcript.remoteID, providerID)
        XCTAssertEqual(reopened.workspace.environment, chat.workspace.environment)
        let key = try await restored.loadWorkspaceFile(reopened, path: "ssh-result.txt")
        reopened.fileDrafts[key]?.text = nonce + "\nremote editor verified\n"
        try await restored.saveWorkspaceFile(reopened, key: key)
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), nonce + "\nremote editor verified\n")
        await restored.shutdown()
        guard testRun?.failureCount == 0 else { return }
        let receipt: JSONValue = ["accepted": true, "authenticatedSSH": true, "actualClaudeAgent": true, "remoteAttachmentConsumed": true, "writePermissionRequests": .number(Double(approvals)), "result": .string(nonce), "providerSessionID": .string(providerID), "restartSameProviderSession": true, "remoteEditorSaved": true, "nativeAccepted": false, "differentMachineAccepted": false]
        try JSONEncoder().encode(receipt).write(to: server.appendingPathComponent("verified-real-agent.json"), options: .atomic)
    }
}
