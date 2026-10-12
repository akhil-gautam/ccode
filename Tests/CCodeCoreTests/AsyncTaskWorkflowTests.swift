import XCTest
import SwiftUI
import AppKit
import CCodeCore
@testable import CCode

final class AsyncTaskWorkflowTests: XCTestCase, @unchecked Sendable {
    @MainActor private func setup() async throws -> (AppStore, ChatSession) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(directory: directory.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/async_tasks.py").path]
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await store.create(path: directory.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        store.send(chat, text: "Start background tasks")
        let deadline = ContinuousClock.now + .seconds(10)
        while chat.busy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(chat.lastError)
        return (store, chat)
    }
    @MainActor func testTasksSurviveNavigationAndStopOnlyTheirOwnedChildTask() async throws {
        let (store, chat) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        let child = AsyncTaskIdentity(owner: "child", task: "checks")
        XCTAssertEqual(chat.transcript.asyncTasks?.count, 2)
        XCTAssertFalse(chat.busy, "Background work cannot block another main prompt")
        XCTAssertTrue(chat.hasLiveAgentWork)
        store.openAsyncTask(chat, id: child)
        XCTAssertEqual(chat.selectedAsyncTaskID, child)
        XCTAssertEqual(store.pane, "tasks")
        let output = try await store.readAsyncOutput(chat, id: child)
        XCTAssertTrue(output?.text.contains("Fixture task output: checks") == true)
        XCTAssertTrue(store.canStopAsyncTask(chat, id: child))
        async let first: Void = store.stopAsyncTask(chat, id: child)
        async let second: Void = store.stopAsyncTask(chat, id: child)
        _ = await (first, second)
        let state = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(state["stops"].array.count, 1)
        XCTAssertEqual(state["stops"].array.first?["sessionId"], "async-root", "Child task controls belong to its owning root query")
        XCTAssertEqual(state["cancels"], 0)
        XCTAssertEqual(chat.transcript.asyncTask(child)?.state, .stopped)
        XCTAssertEqual(chat.transcript.asyncTask(AsyncTaskIdentity(owner: "async-root", task: "build"))?.state, .running)
        await store.openHome()
        XCTAssertTrue(chat.connection === peer)
        _ = try await peer.request("fixture/complete", params: ["task": "build"])
        await store.openHome()
        XCTAssertNil(chat.connection, "Actually finished tasks permit idle cleanup")
    }
    @MainActor func testFailedStopRetainsTaskAndDisconnectRevokesOutputAndControls() async throws {
        let (store, chat) = try await setup()
        let peer = try XCTUnwrap(chat.connection), id = AsyncTaskIdentity(owner: "async-root", task: "build")
        _ = try await peer.request("fixture/fail-next-stop", params: [:])
        await store.stopAsyncTask(chat, id: id)
        XCTAssertEqual(chat.transcript.asyncTask(id)?.state, .running)
        XCTAssertTrue(chat.asyncTaskErrors[id]?.contains("Fixture stop failed") == true)
        XCTAssertTrue(store.canStopAsyncTask(chat, id: id))
        chat.handshake["_meta"]["ccode"]["asyncTasks"]["version"] = 2
        XCTAssertFalse(store.canStopAsyncTask(chat, id: id), "Unknown control contracts are not assumed")
        chat.handshake["_meta"]["ccode"]["asyncTasks"]["version"] = 1
        await store.disconnect(chat)
        XCTAssertEqual(chat.transcript.asyncTask(id)?.state, .disconnected)
        XCTAssertFalse(store.canStopAsyncTask(chat, id: id))
        do { _ = try await store.readAsyncOutput(chat, id: id); XCTFail("Stored output paths cannot authorize reads") }
        catch { }
    }
    @MainActor func testNativeTaskDetailUsesBoundedParentWidth() async throws {
        let (store, chat) = try await setup()
        store.openAsyncTask(chat, id: AsyncTaskIdentity(owner: "async-root", task: "build"))
        for width in [CGFloat(320), 640] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let host = NSHostingView(rootView: TasksPane(chat: chat, store: store).frame(width: width, height: 640))
                host.appearance = NSAppearance(named: appearance)
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 2)
            }
        }
    }
    @MainActor func testWholeForkRebasesHistoricalTaskCardsWithoutControlOwnership() async throws {
        let (store, chat) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        for task in ["build", "checks"] { _ = try await peer.request("fixture/complete", params: ["task": .string(task)]) }
        chat.handshake["agentCapabilities"]["sessionCapabilities"] = ["fork": [:], "resume": [:]]
        _ = try await store.fork(chat)
        let fork = try XCTUnwrap(store.selected), remote = try XCTUnwrap(fork.transcript.remoteID)
        XCTAssertEqual(fork.transcript.asyncTasks?.first?.id.owner, remote)
        XCTAssertEqual(fork.transcript.items.first { $0.kind == "async_task" }?.tool["ownerSessionId"], .string(remote))
        XCTAssertTrue(fork.asyncTaskOwners.isEmpty)
        XCTAssertFalse(store.canStopAsyncTask(fork, id: AsyncTaskIdentity(owner: remote, task: "build")))
        XCTAssertEqual(chat.transcript.asyncTasks?.first?.id.owner, "async-root")
    }
}
