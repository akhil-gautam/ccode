import XCTest
import SwiftUI
import AppKit
import CCodeCore
@testable import CCode

final class LaunchChoiceRecoveryTests: XCTestCase, @unchecked Sendable {
    @MainActor func testRemovingUnavailableChoiceRetainsOtherChoicesAndDraftWithoutSending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-launch-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--config", "--model-hides-fast"]
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let choices = SessionConfiguration(executable: store.settings.executable, arguments: store.settings.arguments, values: ["model": "large", "mode": "plan", "fast": false])
        await store.create(path: root.path, worktree: false, configuration: choices)
        let chat = try XCTUnwrap(store.selected)
        chat.draft = "Retain my actual task"; chat.fileDrafts["unsaved.txt"] = EditorDraft(original: "", text: "Retain editor")
        do { try await store.connect(chat); XCTFail("Explicit unavailable fast choice should not be ignored") } catch { }
        XCTAssertNotNil(chat.transcript.pendingConfiguration); XCTAssertNil(chat.transcript.remoteID)
        store.removeLaunchChoice(chat, key: "fast", legacy: false)
        await store.save(chat)
        let saved = try await store.storage.load(chat.id)
        XCTAssertEqual(saved.pendingConfiguration?.values, ["model": "large", "mode": "plan"])
        XCTAssertEqual(saved.draftText, "Retain my actual task"); XCTAssertEqual(saved.editorDrafts?["unsaved.txt"]?.text, "Retain editor")
        XCTAssertTrue(chat.transcript.items.isEmpty); XCTAssertNil(chat.connection, "Removing a choice must not reconnect or send")
        try await store.connect(chat)
        XCTAssertEqual(chat.transcript.configOptions.first { $0["id"] == "model" }?["currentValue"], "large")
        XCTAssertEqual(chat.transcript.configOptions.first { $0["id"] == "mode" }?["currentValue"], "plan")
        XCTAssertNil(chat.transcript.pendingConfiguration); XCTAssertEqual(chat.draft, "Retain my actual task")
        XCTAssertTrue(chat.transcript.items.isEmpty)
    }
    @MainActor func testChoiceRecoveryDoesNotAlterAnActiveSessionOrDiscardUnselectedValues() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-launch-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        var choices = SessionConfiguration(executable: store.settings.executable, arguments: store.settings.arguments, values: ["fast": false])
        choices.legacyValues = ["modelId": "saved-model", "modeId": "default"]
        chat.transcript.pendingConfiguration = choices; chat.state = .running
        store.removeLaunchChoice(chat, key: "fast", legacy: false)
        XCTAssertEqual(chat.transcript.pendingConfiguration, choices)
        chat.state = .idle
        store.removeLaunchChoice(chat, key: "modelId", legacy: true)
        XCTAssertEqual(chat.transcript.pendingConfiguration?.values, ["fast": false])
        XCTAssertEqual(chat.transcript.pendingConfiguration?.legacyValues, ["modeId": "default"])
        store.removeLaunchChoice(chat, key: "missing", legacy: false)
        XCTAssertEqual(chat.transcript.pendingConfiguration?.values, ["fast": false])
        store.removeLaunchChoice(chat, key: "fast", legacy: false)
        store.removeLaunchChoice(chat, key: "modeId", legacy: true)
        XCTAssertNil(chat.transcript.pendingConfiguration)
    }
}
