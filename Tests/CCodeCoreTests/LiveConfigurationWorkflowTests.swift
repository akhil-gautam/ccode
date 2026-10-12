import XCTest
import CCodeCore
@testable import CCode
final class LiveConfigurationWorkflowTests: XCTestCase {
    @MainActor private func fixture() async throws -> (AppStore, ChatSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-live-config-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("empty-history"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "live_configuration", withExtension: "py", subdirectory: "Fixtures")!.path]
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected); try await store.connect(chat)
        return (store, chat, root)
    }
    @MainActor func testLiveServerControlsPreserveDraftAndSerializeBeforeQueuedPrompt() async throws {
        let (store, chat, root) = try await fixture()
        chat.draft = "Keep this draft"
        let result = try await store.performLiveConfiguration(chat, operation: .status)
        XCTAssertEqual(result.servers.first?.status, .connected)
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/hold", params: [:])
        let change = Task { try await store.performLiveConfiguration(chat, operation: .toggle(name: "fixture", enabled: false)) }
        let until = ContinuousClock.now + .seconds(3)
        while chat.liveConfigurationOperation == nil, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(chat.busy)
        do { _ = try await store.performLiveConfiguration(chat, operation: .reconnect(name: "fixture")); XCTFail("Concurrent server mutation accepted") } catch {}
        store.send(chat, text: "Follow up after configuration")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("prompts.txt").path))
        let disabled = try await change.value; XCTAssertEqual(disabled.servers.first?.status, .disabled)
        let done = ContinuousClock.now + .seconds(5)
        while chat.busy || !chat.pendingPrompts.isEmpty, ContinuousClock.now < done { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("prompts.txt"), encoding: .utf8), "1")
        XCTAssertEqual(chat.draft, "Keep this draft")
        XCTAssertNil(chat.liveConfigurationOperation)
        let enabled = try await store.performLiveConfiguration(chat, operation: .reconnect(name: "fixture")); XCTAssertEqual(enabled.servers.first?.status, .connected)
    }
    @MainActor func testDisconnectRejectsLateStatusAndUnknownCapabilityBeforeRPC() async throws {
        let (store, chat, _) = try await fixture()
        let peer = try XCTUnwrap(chat.connection)
        chat.handshake["_meta"]["ccode"]["configurationManagement"]["version"] = 2
        do { _ = try await store.performLiveConfiguration(chat, operation: .status); XCTFail("Unknown capability accepted") } catch {}
        chat.handshake["_meta"]["ccode"]["configurationManagement"]["version"] = 1
        _ = try await peer.request("fixture/hold", params: [:])
        let read = Task { try await store.performLiveConfiguration(chat, operation: .status) }
        let until = ContinuousClock.now + .seconds(3)
        while chat.liveConfigurationOperation == nil, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(chat.liveConfigurationOperation)
        await store.disconnect(chat)
        do { _ = try await read.value; XCTFail("Late disconnected status accepted") } catch {}
        XCTAssertNil(chat.connection); XCTAssertNil(chat.liveConfigurationOperation)
        do { _ = try await store.performLiveConfiguration(chat, operation: .status); XCTFail("Stored capability authorized a disconnected request") } catch {}
    }
    @MainActor func testCancelledMutationPausesQueuedWorkUntilExplicitRefreshAndResume() async throws {
        let (store, chat, root) = try await fixture()
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/hold", params: [:])
        let change = Task { try await store.performLiveConfiguration(chat, operation: .toggle(name: "fixture", enabled: false)) }
        let until = ContinuousClock.now + .seconds(3)
        while chat.liveConfigurationOperation == nil, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(chat.liveConfigurationOperation)
        store.send(chat, text: "Queued after uncertain change")
        change.cancel()
        do { _ = try await change.value; XCTFail("Cancelled mutation returned success") } catch {}
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(chat.deliveryPaused, "An unconfirmed server mutation cannot silently release queued work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("prompts.txt").path))
        let actual = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(actual["status"], "disabled", "A cancelled response is not evidence that the provider rolled the mutation back")
        XCTAssertEqual(chat.pendingPrompts.first?.text, "Queued after uncertain change")
    }
    @MainActor func testGlobalStopCancelsConfigurationControlAndPreservesQueuedWork() async throws {
        let (store, chat, root) = try await fixture()
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/hold", params: [:])
        let change = Task { try await store.performLiveConfiguration(chat, operation: .toggle(name: "fixture", enabled: false)) }
        let until = ContinuousClock.now + .seconds(3)
        while chat.liveConfigurationOperation == nil, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(chat.liveConfigurationOperation)
        store.send(chat, text: "Queued after uncertain change")
        store.stop(chat)
        do { _ = try await change.value; XCTFail("Cancelled mutation returned success") } catch {}
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(chat.deliveryPaused, "An unconfirmed server mutation cannot silently release queued work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("prompts.txt").path))
        let actual = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(actual["status"], "disabled", "A cancelled response is not evidence that the provider rolled the mutation back")
        XCTAssertEqual(chat.pendingPrompts.first?.text, "Queued after uncertain change")
    }
    @MainActor func testMalformedMutationReceiptKeepsQueuedWorkPaused() async throws {
        let (store, chat, root) = try await fixture()
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/hold", params: [:])
        _ = try await peer.request("fixture/bad-response", params: [:])
        let change = Task { try await store.performLiveConfiguration(chat, operation: .toggle(name: "fixture", enabled: false)) }
        let until = ContinuousClock.now + .seconds(3)
        while chat.liveConfigurationOperation == nil, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(chat.liveConfigurationOperation)
        store.send(chat, text: "Queued after invalid receipt")
        do { _ = try await change.value; XCTFail("Foreign response accepted") } catch {}
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(chat.deliveryPaused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("prompts.txt").path))
        XCTAssertEqual(chat.pendingPrompts.first?.text, "Queued after invalid receipt")
    }
}
