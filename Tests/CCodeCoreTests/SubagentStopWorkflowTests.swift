import XCTest
import AppKit
import SwiftUI
@testable import CCode
import CCodeCore

final class SubagentStopWorkflowTests: XCTestCase {
    @MainActor private func setup() async throws -> (AppStore, ChatSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-child-stop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "subagent_stop", withExtension: "py", subdirectory: "Fixtures")!.path]
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        store.send(chat, text: "Start children")
        try await wait { !chat.busy }
        XCTAssertNil(chat.lastError)
        return (store, chat)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    @MainActor func testOwnedSingleFlightStopPreservesParentSiblingAndNextPrompt() async throws {
        let (store, chat) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        XCTAssertTrue(store.canStopSubagent(chat, id: "left"))
        async let one: Void = store.stopSubagent(chat, id: "left")
        async let two: Void = store.stopSubagent(chat, id: "left")
        _ = await (one, two)
        let state = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(state["stops"].array.count, 1)
        XCTAssertEqual(state["stops"].array.first?["sessionId"], "stop-root")
        XCTAssertEqual(state["stops"].array.first?["asyncTaskId"], "ccode-subagent:fixture-left")
        XCTAssertEqual(state["cancels"], 0)
        XCTAssertEqual(chat.transcript.subagent("left")?.state, "cancelled")
        XCTAssertEqual(chat.transcript.subagent("right")?.state, "running")
        XCTAssertFalse(store.canStopSubagent(chat, id: "left"))
        await store.openHome()
        XCTAssertTrue(chat.connection === peer)
        await store.select(chat.id)
        store.send(chat, text: "Continue parent")
        try await wait { !chat.busy }
        XCTAssertTrue(chat.connection === peer)
        XCTAssertEqual(chat.transcript.items.last { $0.kind == "assistant" }?.text, "Parent response")
    }
    @MainActor func testChildStopAndDisconnectPreserveScopedToolReceiptsAfterRestart() async throws {
        let (store, chat) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/child-tools", params: [:])
        try await wait { chat.transcript.subagent("right")?.transcript.items.last?.kind == "tool" }
        await store.stopSubagent(chat, id: "left")
        XCTAssertEqual(chat.transcript.subagent("left")?.transcript.items.last?.toolInterruption, .stopped)
        XCTAssertEqual(chat.transcript.subagent("left")?.transcript.items.last?.isToolRunning, false)
        XCTAssertEqual(chat.transcript.subagent("right")?.transcript.items.last?.isToolRunning, true)
        XCTAssertEqual(chat.transcript.items.last?.isToolRunning, true)
        await store.disconnect(chat)
        XCTAssertEqual(chat.transcript.subagent("left")?.transcript.items.last?.toolInterruption, .stopped)
        XCTAssertEqual(chat.transcript.subagent("right")?.transcript.items.last?.toolInterruption, .disconnected)
        XCTAssertEqual(chat.transcript.items.last?.toolInterruption, .disconnected)
        let persisted = try await store.storage.load(chat.id)
        let restored = try ChatSession(id: chat.id, path: chat.workspace.root, transcript: persisted)
        XCTAssertEqual(restored.transcript.subagent("left")?.transcript.items.last?.toolInterruption, .stopped)
        XCTAssertEqual(restored.transcript.subagent("right")?.transcript.items.last?.isToolRunning, false)
        XCTAssertEqual(restored.transcript.subagent("left")?.transcript.items.last?.tool["status"], "in_progress")
    }
    @MainActor func testRejectedStopPreservesActualStateAndAllowsExplicitRetry() async throws {
        let (store, chat) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        for kind in ["error", "false"] {
            _ = try await peer.request("fixture/fail-next-stop", params: ["kind": .string(kind)])
            await store.stopSubagent(chat, id: "left")
            XCTAssertEqual(chat.transcript.subagent("left")?.state, "running")
            XCTAssertNotNil(chat.subagentStopErrors["left"])
            XCTAssertTrue(store.canStopSubagent(chat, id: "left"))
        }
        await store.stopSubagent(chat, id: "left")
        XCTAssertNil(chat.subagentStopErrors["left"])
        XCTAssertEqual(chat.transcript.subagent("left")?.state, "cancelled")
    }
    @MainActor func testUnknownContractAndDisconnectedHistoryNeverAuthorizeControl() async throws {
        let (store, chat) = try await setup()
        XCTAssertFalse(store.canStopSubagent(chat, id: "foreign"))
        chat.handshake["_meta"]["ccode"]["nativeSubagentStop"]["version"] = 2
        XCTAssertFalse(store.canStopSubagent(chat, id: "left"))
        await store.stopSubagent(chat, id: "left")
        let state = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertEqual(state["stops"].array.count, 0)
        chat.handshake["_meta"]["ccode"]["nativeSubagentStop"]["version"] = 1
        await store.disconnect(chat)
        XCTAssertFalse(store.canStopSubagent(chat, id: "left"))
        XCTAssertEqual(chat.transcript.subagent("left")?.state, "disconnected")
        XCTAssertTrue(chat.stoppingSubagents.isEmpty)
    }
    @MainActor func testChildStopControlFitsCompactAndWideTasksPane() async throws {
        let (store, chat) = try await setup()
        store.openSubagent(chat, id: "left")
        for width in [CGFloat(320), 640] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let host = NSHostingView(rootView: TasksPane(chat: chat, store: store))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 640)
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 2)
            }
        }
    }
    @MainActor func testStopCancelsOnlyItsOwnUnansweredDecisions() async throws {
        let (store, chat) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/decisions", params: [:])
        try await wait { chat.approvals.count == 3 && chat.interactions.count == 3 }
        await store.stopSubagent(chat, id: "left")
        XCTAssertEqual(Set(chat.approvals.map { $0.request["sessionId"].string }), ["stop-root", "right"])
        XCTAssertEqual(Set(chat.interactions.map { $0.request.sessionID }), ["stop-root", "right"])
        let state = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(state["replies"].array.count, 2)
        XCTAssertEqual(Set(state["replies"].array.map { $0["id"].string }), ["permission-left", "question-left"])
        XCTAssertEqual(state["replies"].array.first { $0["id"] == "permission-left" }?["result"]["outcome"]["outcome"], "cancelled")
        XCTAssertEqual(state["replies"].array.first { $0["id"] == "question-left" }?["result"]["action"], "cancel")
    }
    @MainActor func testDisconnectDuringStopIgnoresTheOldAcknowledgement() async throws {
        let (store, chat) = try await setup()
        async let stop: Void = store.stopSubagent(chat, id: "left")
        try await wait { chat.stoppingSubagents.contains("left") }
        await store.disconnect(chat)
        await stop
        XCTAssertEqual(chat.transcript.subagent("left")?.state, "disconnected")
        XCTAssertTrue(chat.stoppingSubagents.isEmpty)
        XCTAssertNil(chat.subagentStopErrors["left"])
    }
    @MainActor func testDuplicateOrMalformedHandlesCannotAuthorizeAStop() async throws {
        let (store, chat) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        let handle = try XCTUnwrap(chat.transcript.subagent("left"))
            .capabilities["_meta"]["ccode"]["stopTask"]["taskId"]
        let right = try XCTUnwrap(chat.transcript.subagents?.firstIndex { $0.id == "right" })
        chat.transcript.subagents?[right].capabilities["_meta"]["ccode"]["stopTask"]["taskId"] = handle
        XCTAssertFalse(store.canStopSubagent(chat, id: "left"))
        await store.stopSubagent(chat, id: "left")
        chat.transcript.subagents?[right].capabilities["_meta"]["ccode"]["stopTask"]["taskId"] = "sdk-raw-id"
        XCTAssertFalse(store.canStopSubagent(chat, id: "right"))
        let state = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(state["stops"].array.count, 0)
    }
}
