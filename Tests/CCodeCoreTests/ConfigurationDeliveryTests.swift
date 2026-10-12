import XCTest
import Foundation
import CCodeCore
import SwiftUI
import AppKit
@testable import CCode

final class ConfigurationDeliveryTests: XCTestCase, @unchecked Sendable {
    @MainActor private func setup(_ flags: [String] = []) async throws -> (AppStore, ChatSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-setting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "delivery", withExtension: "py", subdirectory: "Fixtures")!.path, "--config-workflow", "--no-steering"] + flags
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        return (store, chat, root)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Expected settings state did not arrive")
    }
    @MainActor func testConfirmedChoicesSurviveFreshPeerAndRestartWithoutSendingDraft() async throws {
        let (store, chat, root) = try await setup()
        store.send(chat, text: "Record a completed conversation before changing settings")
        try await wait { !chat.busy && chat.transcript.remoteUnprompted != true }
        await store.setConfig(chat, id: "model", value: "large")
        await store.setConfig(chat, id: "effort", value: "high")
        await store.setConfig(chat, id: "fast", value: true)
        chat.draft = "Keep this unsent draft"
        await store.disconnect(chat)
        try await store.connect(chat)
        var wire = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertEqual(chat.transcript.configOptions.first { $0["id"] == "model" }?["currentValue"], "large")
        XCTAssertEqual(chat.transcript.configOptions.first { $0["id"] == "effort" }?["currentValue"], "high")
        XCTAssertEqual(chat.transcript.configOptions.first { $0["id"] == "fast" }?["currentValue"], true)
        XCTAssertEqual(wire["settingCalls"].array.map { $0["params"]["configId"].string }, ["model", "effort", "fast"])
        XCTAssertTrue(wire["prompts"].array.isEmpty)
        XCTAssertEqual(chat.draft, "Keep this unsent draft")
        XCTAssertNil(chat.transcript.pendingConfiguration)
        await store.shutdown()
        let reopened = AppStore(directory: root.appendingPathComponent("data"))
        addTeardownBlock { await reopened.shutdown() }
        await reopened.restore(); await reopened.select(chat.id)
        let saved = try XCTUnwrap(reopened.selected)
        try await reopened.connect(saved)
        wire = try await XCTUnwrap(saved.connection).request("fixture/state", params: [:])
        XCTAssertEqual(saved.transcript.configOptions.first { $0["id"] == "model" }?["currentValue"], "large")
        XCTAssertEqual(saved.transcript.configOptions.first { $0["id"] == "effort" }?["currentValue"], "high")
        XCTAssertEqual(saved.transcript.configOptions.first { $0["id"] == "fast" }?["currentValue"], true)
        XCTAssertTrue(wire["prompts"].array.isEmpty)
        XCTAssertEqual(saved.draft, "Keep this unsent draft")
    }
    @MainActor func testConfirmedLegacyModelAndModeSurviveReconnect() async throws {
        let (store, chat, _) = try await setup(["--legacy-settings"])
        store.send(chat, text: "Record a completed conversation before changing settings")
        try await wait { !chat.busy && chat.transcript.remoteUnprompted != true }
        await store.setLegacy(chat, key: "modelId", id: "large")
        await store.setLegacy(chat, key: "modeId", id: "plan")
        await store.disconnect(chat)
        try await store.connect(chat)
        XCTAssertEqual(chat.transcript.models["currentModelId"], "large")
        XCTAssertEqual(chat.transcript.modes["currentModeId"], "plan")
        let wire = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertTrue(wire["prompts"].array.isEmpty)
        XCTAssertEqual(wire["settingCalls"].array.map { $0["method"].string }, ["session/set_model", "session/set_mode"])
    }
    @MainActor func testRejectedResumeRetainsModelAppliedBeforeUnavailableEffort() async throws {
        let (store, chat, _) = try await setup(["--load-hides-effort"])
        store.send(chat, text: "Make the conversation durable")
        try await wait { !chat.busy && chat.transcript.remoteUnprompted != true }
        await store.setConfig(chat, id: "model", value: "large")
        await store.setConfig(chat, id: "effort", value: "high")
        chat.draft = "Keep this unsent draft"
        await store.disconnect(chat)
        do { try await store.connect(chat); XCTFail("Unavailable saved effort must be refused before any prompt") } catch { }
        XCTAssertEqual(chat.transcript.pendingConfiguration?.values["model"], "large", "A fresh peer must apply the model again even if it succeeded before this setup failure")
        XCTAssertEqual(chat.transcript.pendingConfiguration?.values["effort"], "high")
        XCTAssertNil(chat.connection)
        store.removeLaunchChoice(chat, key: "effort", legacy: false)
        try await store.connect(chat)
        XCTAssertEqual(chat.transcript.configOptions.first { $0["id"] == "model" }?["currentValue"], "large")
        XCTAssertEqual(chat.transcript.configOptions.first { $0["id"] == "effort" }?["currentValue"], "normal")
        let wire = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertTrue(wire["prompts"].array.isEmpty)
        XCTAssertEqual(chat.draft, "Keep this unsent draft")
    }
    @MainActor func testBusyChoicesApplyAtBoundaryBeforeQueuedWork() async throws {
        let (store, chat, _) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        await store.setConfig(chat, id: "fast", value: true)
        await store.setConfig(chat, id: "model", value: "large")
        XCTAssertEqual(chat.pendingSettings.count, 2)
        XCTAssertEqual(chat.transcript.configOptions.first { $0["id"] == "model" }?["currentValue"], "small")
        store.send(chat, text: "Next task", policy: .nextTurn)
        _ = try await peer.request("fixture/finish", params: [:])
        try await wait { !chat.busy && chat.pendingPrompts.isEmpty && chat.pendingSettings.isEmpty }
        let wire = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(wire["timeline"].array.map { $0["kind"].string }, ["prompt", "setting", "setting", "prompt"])
        XCTAssertEqual(wire["settingCalls"].array.map { $0["params"]["configId"].string }, ["model", "fast"])
        XCTAssertEqual(wire["settingCalls"].array.last?["params"]["type"], "boolean")
        XCTAssertEqual(wire["timeline"].array.last?["config"]["model"], "large")
        XCTAssertEqual(wire["timeline"].array.last?["config"]["fast"], true)
        XCTAssertNil(chat.transcript.pendingConfiguration, "Live changes must not reuse first-launch configuration")
    }
    @MainActor func testDependentChoiceRejectionPausesWorkAfterModelChanges() async throws {
        let (store, chat, _) = try await setup(["--initial-large", "--model-hides-effort"])
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        await store.setConfig(chat, id: "effort", value: "high")
        await store.setConfig(chat, id: "model", value: "small")
        store.send(chat, text: "Do not run with rejected effort", policy: .nextTurn)
        _ = try await peer.request("fixture/finish", params: [:])
        try await wait { chat.settingsPaused && !chat.busy }
        XCTAssertEqual(chat.pendingSettings.first?.key, "effort")
        XCTAssertEqual(chat.pendingSettings.first?.state, .failed)
        XCTAssertTrue(chat.deliveryPaused)
        let wire = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(wire["prompts"].array.count, 1)
        XCTAssertEqual(wire["settingCalls"].array.count, 1, "Unavailable effort must never go onto the wire")
        store.removePendingSetting(chat, id: try XCTUnwrap(chat.pendingSettings.first).id)
        store.resumeQueuedPrompts(chat)
        try await wait { !chat.busy && chat.pendingPrompts.isEmpty }
    }
    @MainActor func testManagedPolicyRejectionLeavesAppliedValueAndDoesNotRetryTask() async throws {
        let (store, chat, _) = try await setup(["--reject-config"])
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        await store.setConfig(chat, id: "model", value: "large")
        store.send(chat, text: "Queued task", policy: .nextTurn)
        _ = try await peer.request("fixture/finish", params: [:])
        try await wait { !chat.busy && chat.settingsPaused }
        XCTAssertEqual(chat.pendingSettings.first?.state, .failed)
        XCTAssertTrue(chat.pendingSettings.first?.error?.contains("Managed policy") == true)
        XCTAssertEqual(chat.transcript.configOptions.first { $0["id"] == "model" }?["currentValue"], "small")
        let wire = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(wire["prompts"].array.count, 1)
        XCTAssertEqual(wire["settingCalls"].array.count, 1)
    }
    @MainActor func testStopAndLateAcknowledgementRequireExplicitSettingReview() async throws {
        let (store, chat, _) = try await setup(["--delay-config"])
        let peer = try XCTUnwrap(chat.connection)
        let choosing = Task { await store.setConfig(chat, id: "model", value: "large") }
        try await wait { chat.pendingSettings.first?.state == .applying }
        // Ask the fixture to confirm the setter reached the wire before Stop.
        var wire = try await peer.request("fixture/state", params: [:])
        while wire["settingCalls"].array.isEmpty { try await Task.sleep(for: .milliseconds(10)); wire = try await peer.request("fixture/state", params: [:]) }
        store.stop(chat)
        await choosing.value
        XCTAssertTrue(chat.settingsPaused)
        XCTAssertEqual(chat.pendingSettings.first?.state, .uncertain)
        _ = try await peer.request("fixture/ack-config", params: [:])
        try await wait { chat.transcript.configOptions.first { $0["id"] == "model" }?["currentValue"] == "large" }
        XCTAssertFalse(chat.pendingSettings.isEmpty)
        await store.applyPendingSettings(chat)
        XCTAssertTrue(chat.pendingSettings.isEmpty)
        wire = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(wire["settingCalls"].array.count, 1, "Reconcile an already-applied value without another setter")
    }
    @MainActor func testInterruptedSettingsPersistPausedAcrossRestart() async throws {
        let (store, chat, root) = try await setup(["--lose-config"])
        await store.setConfig(chat, id: "model", value: "large")
        try await wait { !chat.busy }
        XCTAssertEqual(chat.pendingSettings.first?.state, .uncertain)
        await store.shutdown()
        let reopened = AppStore(directory: root.appendingPathComponent("data"))
        addTeardownBlock { await reopened.shutdown() }
        await reopened.restore(); await reopened.select(chat.id)
        let saved = try XCTUnwrap(reopened.selected)
        XCTAssertNil(saved.connection)
        XCTAssertTrue(saved.settingsPaused)
        XCTAssertEqual(saved.pendingSettings.first?.state, .uncertain)
        XCTAssertEqual(saved.pendingSettings.first?.value, "large")
    }
    @MainActor func testUnacknowledgedSetterIsClosedBeforeAnExplicitRetry() async throws {
        let (store, chat, _) = try await setup(["--delay-config"])
        let old = try XCTUnwrap(chat.connection)
        let choosing = Task { await store.setConfig(chat, id: "model", value: "large") }
        try await wait { chat.pendingSettings.first?.state == .applying }
        store.stop(chat); await choosing.value
        let applying = Task { await store.applyPendingSettings(chat) }
        try await wait { chat.connection !== old && chat.pendingSettings.first?.state == .applying }
        let fresh = try XCTUnwrap(chat.connection)
        var wire = try await fresh.request("fixture/state", params: [:])
        let deadline = ContinuousClock.now + .seconds(3)
        while wire["settingCalls"].array.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)); wire = try await fresh.request("fixture/state", params: [:]) }
        _ = try await fresh.request("fixture/ack-config", params: [:])
        await applying.value
        XCTAssertTrue(chat.pendingSettings.isEmpty)
        do { _ = try await old.request("fixture/ack-config", params: [:]); XCTFail("Old setter can still apply after retry") } catch { }
    }
    @MainActor func testLegacyChoicesUseTheirActualSettersAtIdleBoundary() async throws {
        let (store, chat, _) = try await setup(["--legacy-settings"])
        let peer = try XCTUnwrap(chat.connection)
        XCTAssertTrue(chat.transcript.configOptions.isEmpty)
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        await store.setLegacy(chat, key: "modeId", id: "plan")
        await store.setLegacy(chat, key: "modelId", id: "large")
        store.send(chat, text: "Legacy follow-up", policy: .nextTurn)
        _ = try await peer.request("fixture/finish", params: [:])
        try await wait { !chat.busy && chat.pendingPrompts.isEmpty && chat.pendingSettings.isEmpty }
        let wire = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(wire["settingCalls"].array.map { $0["method"].string }, ["session/set_model", "session/set_mode"])
        XCTAssertEqual(wire["timeline"].array.last?["legacy"], ["modelId": "large", "modeId": "plan"])
    }
    @MainActor func testPendingSettingsFitCompactAndWideLightAndDarkLayouts() async throws {
        let (store, chat, _) = try await setup()
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        await store.setConfig(chat, id: "model", value: "large")
        await store.setConfig(chat, id: "effort", value: "high")
        for scheme in [ColorScheme.light, .dark] {
            for width: CGFloat in [320, 820] {
                let host = NSHostingView(rootView: PendingSettingsView(chat: chat, store: store).frame(width: width).environment(\.colorScheme, scheme))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
                XCTAssertGreaterThan(host.fittingSize.height, 50)
                XCTAssertLessThan(host.fittingSize.height, 260)
            }
        }
    }
    @MainActor func testAgentOwnershipChangeCannotApplyQueuedSetting() async throws {
        let (store, chat, _) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        await store.setConfig(chat, id: "model", value: "large")
        store.sessions[try XCTUnwrap(store.sessions.firstIndex { $0.id == chat.id })].agentArguments?.append("--different-agent")
        _ = try await peer.request("fixture/finish", params: [:])
        try await wait { !chat.busy && chat.settingsPaused }
        XCTAssertEqual(chat.pendingSettings.first?.state, .failed)
        XCTAssertTrue(chat.pendingSettings.first?.error?.contains("different agent") == true)
        let wire = try await peer.request("fixture/state", params: [:])
        XCTAssertTrue(wire["settingCalls"].array.isEmpty)
    }
    @MainActor func testSaveFailureRetainsPendingChoiceWithoutChangingAgentAndCanRecover() async throws {
        let (store, chat, root) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        let data = root.appendingPathComponent("data"), backup = root.appendingPathComponent("data-backup")
        try FileManager.default.moveItem(at: data, to: backup)
        try "Blocked store".write(to: data, atomically: true, encoding: .utf8)
        chat.draft = "Unrelated draft"
        await store.setConfig(chat, id: "model", value: "large")
        XCTAssertEqual(chat.pendingSettings.first?.state, .failed)
        XCTAssertTrue(chat.settingsPaused)
        XCTAssertEqual(chat.draft, "Unrelated draft")
        _ = try await peer.request("fixture/finish", params: [:])
        try await wait { !chat.busy }
        let before = try await peer.request("fixture/state", params: [:])
        XCTAssertTrue(before["settingCalls"].array.isEmpty)
        try FileManager.default.removeItem(at: data)
        try FileManager.default.moveItem(at: backup, to: data)
        await store.applyPendingSettings(chat)
        XCTAssertTrue(chat.pendingSettings.isEmpty)
        XCTAssertTrue(chat.deliveryPaused, "Applying settings cannot resume work paused by the save failure")
        let after = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(after["settingCalls"].array.count, 1)
    }
    @MainActor func testRepeatedChoicesCoalesceAndUnknownChoicesCannotEnterQueue() async throws {
        let (store, chat, _) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        await store.setConfig(chat, id: "model", value: "large")
        await store.setConfig(chat, id: "model", value: "small")
        await store.setConfig(chat, id: "model", value: "large")
        await store.setConfig(chat, id: "model", value: "unoffered")
        XCTAssertEqual(chat.pendingSettings.count, 1)
        XCTAssertEqual(chat.pendingSettings.first?.value, "large")
        XCTAssertNotNil(chat.lastError)
        _ = try await peer.request("fixture/finish", params: [:])
        try await wait { !chat.busy && chat.pendingSettings.isEmpty }
        let wire = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(wire["settingCalls"].array.count, 1)
        XCTAssertEqual(wire["settingCalls"].array.first?["params"]["value"], "large")
    }
}
