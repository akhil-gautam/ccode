import XCTest
import AppKit
import SwiftUI
@testable import CCodeCore
@testable import CCode

@MainActor private final class AttentionDelivery: SessionNotificationDelivery {
    var notices: [SessionNotice] = []
    var cleared: [UUID] = []
    func deliver(_ notice: SessionNotice) { notices.append(notice) }
    func clear(sessionID: UUID) { cleared.append(sessionID) }
}

final class SessionAttentionTests: XCTestCase {
    func testStatusFilterUsesLiveOwnershipAndPersistedUnreadCompletion() throws {
        let working = SessionInfo(projectPath: "/one", title: "Running")
        var finished = SessionInfo(projectPath: "/two", title: "Done")
        finished.attention = SessionAttentionReceipt(kind: .completed)
        var failed = SessionInfo(projectPath: "/one", title: "Failure"); failed.lastError = "failed"
        let idle = SessionInfo(projectPath: "/three")
        let statuses: [UUID: SessionActivity] = [working.id: .working, failed.id: .needsAttention]
        let all = [working, finished, failed, idle]
        XCTAssertEqual(SidebarSnapshot(sessions: all, activities: statuses, status: .working).visible.map(\.id), [working.id])
        XCTAssertEqual(SidebarSnapshot(sessions: all, activities: statuses, status: .needsAttention).visible.map(\.id), [failed.id])
        XCTAssertEqual(SidebarSnapshot(sessions: all, activities: statuses, status: .completed).visible.map(\.id), [finished.id])
        XCTAssertEqual(SidebarSnapshot(sessions: all, activities: statuses, status: .idle).visible.map(\.id), [idle.id])
        XCTAssertTrue(SidebarSnapshot(sessions: all, search: "Done", activities: statuses, status: .working).visible.isEmpty)
        let decoded = try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(finished))
        XCTAssertEqual(decoded.attention, finished.attention)
        XCTAssertNil(try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(idle)).attention)
    }

    @MainActor func testBackgroundPermissionCompletionAndNotificationClickStayOwned() async throws {
        let (root, store, info) = try await fixture()
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let delivery = AttentionDelivery(); store.attentionNotifications = delivery
        store.sessionIsBeingViewed = { _ in false }
        let chat = try XCTUnwrap(store.selected)
        store.send(chat, text: "independent-proof")
        try await wait { chat.approvals.count == 1 }
        XCTAssertEqual(store.sessionActivity(info.id), .needsAttention)
        XCTAssertEqual(delivery.notices.map(\.receipt.kind), [.needsInput])
        store.dismissAttention(info.id)
        XCTAssertEqual(store.attentionSessions.map(\.id), [info.id], "Dismiss cannot authorize or erase a pending decision")
        let receipt = try XCTUnwrap(delivery.notices.first)
        await store.openHome()
        let unknown = await store.openSessionNotification(sessionID: info.id, receiptID: UUID())
        XCTAssertFalse(unknown)
        XCTAssertNil(store.selectedID)
        let openedDecision = await store.openSessionNotification(sessionID: info.id, receiptID: receipt.receipt.id)
        XCTAssertTrue(openedDecision)
        XCTAssertEqual(store.selectedID, info.id)
        XCTAssertEqual(chat.approvals.count, 1, "Notification routing must not answer the decision or send a prompt")
        store.resolveApproval(chat, id: try XCTUnwrap(chat.approvals.first).id, option: "allow")
        try await wait { !chat.busy }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("proof.txt"), encoding: .utf8), "independent-proof")
        XCTAssertEqual(store.sessionActivity(info.id), .completed)
        XCTAssertEqual(delivery.notices.map(\.receipt.kind), [.needsInput, .completed])
        XCTAssertEqual(delivery.notices.last?.body, "Response finished")
        let completion = try XCTUnwrap(delivery.notices.last)
        let stale = await store.openSessionNotification(sessionID: info.id, receiptID: receipt.receipt.id)
        XCTAssertFalse(stale, "Old decision receipt must not route a newer completion")
        store.sessionIsBeingViewed = { _ in true }
        let openedCompletion = await store.openSessionNotification(sessionID: info.id, receiptID: completion.receipt.id)
        XCTAssertTrue(openedCompletion)
        XCTAssertNil(store.sessions.first { $0.id == info.id }?.attention)
        XCTAssertEqual(store.sessionActivity(info.id), .idle)
        await store.save(chat)
        let persisted = try await SessionStorage(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("empty")).list()
        XCTAssertNil(persisted.first { $0.id == info.id }?.attention)
    }

    @MainActor func testViewedCompletionAndCancelledTurnDoNotNotifyFinished() async throws {
        let (root, store, info) = try await fixture()
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let delivery = AttentionDelivery(); store.attentionNotifications = delivery
        store.sessionIsBeingViewed = { _ in true }
        let chat = try XCTUnwrap(store.selected)
        store.send(chat, text: "visible-proof")
        try await wait { chat.approvals.count == 1 }
        store.resolveApproval(chat, id: try XCTUnwrap(chat.approvals.first).id, option: "allow")
        try await wait { !chat.busy }
        XCTAssertTrue(delivery.notices.isEmpty)
        XCTAssertEqual(store.sessionActivity(info.id), .idle)
        store.sessionIsBeingViewed = { _ in false }
        store.send(chat, text: "cancelled-proof")
        try await wait { chat.approvals.count == 1 }
        store.stop(chat)
        try await wait { !chat.busy }
        XCTAssertFalse(delivery.notices.contains { $0.receipt.kind == .completed })
        XCTAssertNotEqual(store.sessionActivity(info.id), .completed)
    }

    @MainActor func testNewTurnInvalidatesOldReceiptAndEveryUnseenCompletionGetsItsOwnIdentity() async throws {
        let (root, store, info) = try await fixture()
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let delivery = AttentionDelivery(); store.attentionNotifications = delivery
        store.sessionIsBeingViewed = { _ in false }
        let chat = try XCTUnwrap(store.selected)
        store.send(chat, text: "first")
        try await wait { chat.approvals.count == 1 }
        store.resolveApproval(chat, id: try XCTUnwrap(chat.approvals.first).id, option: "allow")
        try await wait { !chat.busy }
        let first = try XCTUnwrap(delivery.notices.last)
        store.sessionIsBeingViewed = { _ in true }
        store.send(chat, text: "second")
        try await wait { chat.approvals.count == 1 }
        let stale = await store.openSessionNotification(sessionID: info.id, receiptID: first.receipt.id)
        XCTAssertFalse(stale)
        store.resolveApproval(chat, id: try XCTUnwrap(chat.approvals.first).id, option: "allow")
        try await wait { !chat.busy }
        XCTAssertNil(store.sessions.first { $0.id == info.id }?.attention, "An already-viewed newer completion cannot retain the previous unread state")
        XCTAssertNotEqual(store.sessionActivity(info.id), .completed)
    }

    @MainActor func testToolFreeNewTurnClearsPreviousUnreadCompletion() async throws {
        let (root, store, info) = try await fixture(noDecision: true)
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let delivery = AttentionDelivery(); store.attentionNotifications = delivery
        store.sessionIsBeingViewed = { _ in false }
        let chat = try XCTUnwrap(store.selected)
        store.send(chat, text: "first no tools")
        try await wait { !chat.busy }
        let first = try XCTUnwrap(delivery.notices.last)
        store.sessionIsBeingViewed = { _ in true }
        store.send(chat, text: "second no tools")
        try await wait { !chat.busy }
        XCTAssertNil(store.sessions.first { $0.id == info.id }?.attention)
        XCTAssertNotEqual(store.sessionActivity(info.id), .completed)
        let stale = await store.openSessionNotification(sessionID: info.id, receiptID: first.receipt.id)
        XCTAssertFalse(stale)
    }

    @MainActor func testBackgroundTasksRemainWorkingUntilTheLastOwnedTaskFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-attention-jobs-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("empty"))
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "async_tasks", withExtension: "py", subdirectory: "Fixtures"))
        store.settings.executable = "/usr/bin/python3"; store.settings.arguments = [fixture.path]
        let delivery = AttentionDelivery(); store.attentionNotifications = delivery; store.sessionIsBeingViewed = { _ in false }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        store.send(chat, text: "Start owned work")
        try await wait { !chat.busy }
        XCTAssertEqual(store.sessionActivity(chat.id), .working)
        XCTAssertTrue(delivery.notices.isEmpty, "Running children cannot be presented as finished work")
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/complete", params: ["task": "build"])
        try await wait { chat.transcript.asyncTasks?.first { $0.id.task == "build" }?.state == .completed }
        XCTAssertEqual(store.sessionActivity(chat.id), .working)
        XCTAssertTrue(delivery.notices.isEmpty)
        _ = try await peer.request("fixture/complete", params: ["task": "checks"])
        try await wait { !chat.hasLiveAgentWork }
        XCTAssertEqual(store.sessionActivity(chat.id), .completed)
        XCTAssertEqual(delivery.notices.map(\.receipt.kind), [.completed])
        store.sessionStatusFilter = .working
        XCTAssertTrue(store.visibleSessions.isEmpty, "The cached sidebar must reflect child completion immediately")
        store.openSessionSearch()
        XCTAssertEqual(store.sessionSearchResults.map(\.id), [chat.id], "Search remains global despite a status filter")
    }

    @MainActor func testFilterControlsFitSmallLightAndDarkSidebars() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-attention-ui-\(UUID())")
        let store = AppStore(directory: root, claudeDirectory: root.appendingPathComponent("empty"))
        defer { try? FileManager.default.removeItem(at: root) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for status in [SessionActivity?.none, .some(.needsAttention), .some(.completed)] {
                store.sessionStatusFilter = status
                let host = NSHostingView(rootView: SessionStatusFilters(store: store).frame(width: 214))
                host.appearance = NSAppearance(named: appearance); host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, 216)
                XCTAssertLessThanOrEqual(host.fittingSize.height, 28)
            }
        }
        await store.shutdown()
    }

    @MainActor private func fixture(noDecision: Bool = false) async throws -> (URL, AppStore, SessionInfo) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-attention-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = try XCTUnwrap(Bundle.module.url(forResource: "parallel_work", withExtension: "py", subdirectory: "Fixtures"))
        var info = SessionInfo(projectPath: root.path, title: "Owned proof")
        info.agentExecutable = "/usr/bin/python3"; info.agentArguments = [script.path, "proof"] + (noDecision ? ["--no-decision"] : [])
        let store = AppStore(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("empty"))
        try await SessionStorage(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("empty")).saveIndex([info])
        await store.restore()
        return (root, store, info)
    }
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Owned attention transition did not finish")
        throw ACPError.workspace("Attention fixture timed out")
    }
}
