import XCTest
import Foundation
import CCodeCore
import SwiftUI
import AppKit
import Observation
@testable import CCode

final class PromptDeliveryTests: XCTestCase, @unchecked Sendable {
    @MainActor func testInterruptedActiveRequestBecomesVisibleWhenSubmissionFinishes() async throws {
        let (store, chat, _) = try await setup()
        let (executable, arguments) = try store.promptOwner(chat)
        var prompt = try PendingPrompt(text: "Interrupted root request", attachments: [], policy: .nextTurn, executable: executable, arguments: arguments, remoteID: chat.transcript.remoteID)
        prompt.state = .uncertain
        chat.pendingPrompts = [prompt]; chat.promptDeliveryID = prompt.id
        let visible = expectation(description: "Pending-message view is invalidated when the active submission ends")
        withObservationTracking {
            _ = chat.pendingPrompts.filter { $0.id != chat.promptDeliveryID }
        } onChange: { visible.fulfill() }
        chat.promptDeliveryID = nil
        await fulfillment(of: [visible], timeout: 0.3)
    }
    @MainActor private func setup(_ arguments: [String] = []) async throws -> (AppStore, ChatSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-delivery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "delivery", withExtension: "py", subdirectory: "Fixtures")!.path] + arguments
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        return (store, chat, root)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Expected delivery state did not arrive")
    }
    @MainActor func testBusyCorrectionUsesVerifiedSteeringWithoutAnotherPrompt() async throws {
        let (store, chat, _) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "hold original task")
        try await wait { chat.state == .running }
        chat.draft = "Use the existing storage format"
        store.send(chat)
        try await wait { chat.draft.isEmpty }
        try await wait { chat.transcript.items.contains { $0.text == "Use the existing storage format" && $0.deliveryState == .acknowledged } }
        // Completion must cover the correction too, without an extra queued turn.
        _ = try await peer.request("fixture/finish", params: [:])
        try await wait { !chat.busy }
        let state = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(state["prompts"].array.count, 1)
        XCTAssertEqual(state["steers"].array.count, 1)
        XCTAssertEqual(state["steers"].array.first?["prompt"].array.first?["text"], "Use the existing storage format")
        XCTAssertEqual(state["steers"].array.first?["_meta"]["steering"]["idleBehavior"], "promptRequired")
        XCTAssertEqual(chat.transcript.items.filter { $0.kind == "user" }.map(\.text), ["hold original task", "Use the existing storage format"])
    }

    @MainActor func testUnsupportedSteeringQueuesAndRunsOnlyAfterActiveTurn() async throws {
        let (store, chat, _) = try await setup(["--no-steering"])
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        chat.draft = "Queued follow-up"; store.send(chat)
        XCTAssertEqual(chat.pendingPrompts.filter { $0.state == .queued }.map(\.text), ["Queued follow-up"])
        let before = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(before["prompts"].array.count, 1)
        XCTAssertTrue(before["steers"].array.isEmpty)
        _ = try await peer.request("fixture/finish", params: [:])
        try await wait { !chat.busy && chat.pendingPrompts.isEmpty }
        let after = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(after["prompts"].array.map { $0["prompt"].array.first?["text"].string }, ["hold original", "Queued follow-up"])
    }

    @MainActor func testQueueEditsRemovalsAndAttachmentSnapshotReachProvider() async throws {
        let (store, chat, root) = try await setup(["--no-steering"])
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        let file = root.appendingPathComponent("context.txt")
        try "Original snapshot".write(to: file, atomically: true, encoding: .utf8)
        store.attach(file, to: chat)
        try await wait { !chat.attachingFiles }
        chat.draft = "Use attachment"; store.send(chat)
        let queued = try XCTUnwrap(chat.pendingPrompts.first { $0.state == .queued })
        XCTAssertTrue(chat.attachments.isEmpty)
        XCTAssertEqual(queued.attachments.count, 1)
        try "Changed source".write(to: file, atomically: true, encoding: .utf8)
        try store.editQueuedPrompt(chat, id: queued.id, text: "Edited queued prompt")
        store.send(chat, text: "Remove this one")
        let remove = try XCTUnwrap(chat.pendingPrompts.last)
        store.removeQueuedPrompt(chat, id: remove.id)
        _ = try await peer.request("fixture/finish", params: [:])
        try await wait { !chat.busy && chat.pendingPrompts.isEmpty }
        let state = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(state["prompts"].array.count, 2)
        XCTAssertEqual(state["prompts"].array.last?["prompt"].array.map { $0["text"].string }, ["Edited queued prompt", "File: context.txt\nOriginal snapshot"])
    }

    @MainActor func testStopPausesQueueAndRestartNeverSendsItAutomatically() async throws {
        let (store, chat, root) = try await setup(["--no-steering"])
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        store.send(chat, text: "Pending after stop")
        store.stop(chat)
        try await wait { !chat.busy }
        XCTAssertTrue(chat.deliveryPaused)
        XCTAssertEqual(chat.pendingPrompts.map(\.text), ["Pending after stop"])
        await store.shutdown()
        let restored = AppStore(directory: root.appendingPathComponent("data"))
        addTeardownBlock { await restored.shutdown() }
        await restored.restore()
        await restored.select(chat.id)
        let reopened = try XCTUnwrap(restored.selected)
        XCTAssertEqual(reopened.pendingPrompts.map(\.text), ["Pending after stop"])
        XCTAssertTrue(reopened.deliveryPaused)
        XCTAssertNil(reopened.connection)
        restored.resumeQueuedPrompts(reopened)
        try await wait { !reopened.busy && reopened.pendingPrompts.isEmpty }
        XCTAssertEqual(reopened.transcript.items.filter { $0.kind == "user" }.map(\.text), ["hold original", "Pending after stop"])
    }

    @MainActor func testIdleRaceFallsBackToOneOwnedPrompt() async throws {
        let (store, chat, _) = try await setup(["--idle-race"])
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        store.send(chat, text: "Correction at completion")
        try await wait { !chat.busy && chat.pendingPrompts.isEmpty }
        let state = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(state["steers"].array.count, 1)
        XCTAssertEqual(state["prompts"].array.count, 2)
        XCTAssertEqual(chat.transcript.items.filter { $0.kind == "user" && $0.text == "Correction at completion" }.count, 1)
    }

    @MainActor func testLostAcknowledgementStaysUncertainWithoutReplay() async throws {
        let (store, chat, root) = try await setup(["--lose-steering"])
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        store.send(chat, text: "May have been delivered")
        try await wait { chat.state == .failed && chat.pendingPrompts.contains { $0.text == "May have been delivered" && $0.state == .uncertain } }
        await store.shutdown()
        let restored = AppStore(directory: root.appendingPathComponent("data"))
        addTeardownBlock { await restored.shutdown() }
        await restored.restore(); await restored.select(chat.id)
        let reopened = try XCTUnwrap(restored.selected)
        XCTAssertTrue(reopened.deliveryPaused)
        XCTAssertTrue(reopened.pendingPrompts.contains { $0.text == "May have been delivered" && $0.state == .uncertain })
        restored.resumeQueuedPrompts(reopened)
        XCTAssertNil(reopened.connection, "Resume must not replay ambiguous submissions")
    }

    @MainActor func testStopDuringSteeringCannotReplayUnacknowledgedCorrection() async throws {
        let (store, chat, _) = try await setup(["--delay-steering"])
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        store.send(chat, text: "Correction in flight")
        try await wait { chat.pendingPrompts.contains { $0.text == "Correction in flight" && $0.state == .submitting } }
        store.stop(chat)
        try await wait { !chat.busy }
        _ = try await peer.request("fixture/ack-steering", params: [:])
        XCTAssertTrue(chat.deliveryPaused)
        XCTAssertTrue(chat.pendingPrompts.contains { $0.text == "Correction in flight" && $0.state == .uncertain })
        store.send(chat, text: "Fresh explicit turn")
        try await wait { !chat.busy }
        XCTAssertEqual(chat.state, .ready)
        let state = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(state["prompts"].array.count, 2)
        XCTAssertEqual(state["steers"].array.count, 1)
    }

    @MainActor func testVerifiedProviderUserUpdatesAreRetainedWithoutDuplicateReplay() async throws {
        let (_, chat, _) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/user-update", params: [:])
        _ = try await peer.request("fixture/user-update", params: [:])
        try await wait { chat.transcript.items.contains { $0.messageID == "external-user-1" } }
        XCTAssertEqual(chat.transcript.items.filter { $0.messageID == "external-user-1" }.count, 1)
        XCTAssertEqual(chat.transcript.items.first { $0.messageID == "external-user-1" }?.text, "Actual provider-side follow-up")
    }

    @MainActor func testDeliveryQueueRemainsBoundedInCompactAndWideLayouts() async throws {
        let (store, chat, _) = try await setup(["--no-steering"])
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        for index in 0..<12 { store.send(chat, text: "Pending message \(index)") }
        store.stop(chat)
        try await wait { !chat.busy }
        for width in [340.0, 720.0] {
            for dark in [false, true] {
                let host = NSHostingView(rootView: PendingPromptsView(chat: chat, store: store).frame(width: width).environment(\.colorScheme, dark ? .dark : .light))
                host.frame.size.width = width
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThan(host.fittingSize.height, 260, "Pending messages must not displace the composer off screen")
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
            }
        }
    }

    @MainActor func testQueueCannotChangeProviderOwnershipAndRestorationPreservesDraft() async throws {
        let (store, chat, _) = try await setup(["--no-steering"])
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        store.send(chat, text: "Review me first")
        store.stop(chat); try await wait { !chat.busy }
        let queued = try XCTUnwrap(chat.pendingPrompts.first)
        let index = try XCTUnwrap(store.sessions.firstIndex { $0.id == chat.id })
        store.sessions[index].agentArguments = []
        store.resumeQueuedPrompts(chat)
        try await wait { chat.pendingPrompts.first?.state == .failed }
        XCTAssertFalse(chat.transcript.items.contains { $0.text == "Review me first" })
        chat.draft = "Keep my newer draft"
        XCTAssertThrowsError(try store.restorePendingPrompt(chat, id: queued.id))
        XCTAssertEqual(chat.draft, "Keep my newer draft")
        chat.draft = ""
        try store.restorePendingPrompt(chat, id: queued.id)
        XCTAssertEqual(chat.draft, "Review me first")
        XCTAssertTrue(chat.pendingPrompts.isEmpty)
    }

    @MainActor func testEditingQueueDuringReconnectCannotSendAnOlderSnapshot() async throws {
        let (store, chat, _) = try await setup(["--no-steering", "--question-load"])
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        store.send(chat, text: "Old queued text")
        store.stop(chat); try await wait { !chat.busy }
        await store.disconnect(chat)
        let queued = try XCTUnwrap(chat.pendingPrompts.first)
        store.resumeQueuedPrompts(chat)
        try await wait { !chat.interactions.isEmpty }
        try store.editQueuedPrompt(chat, id: queued.id, text: "Latest queued text")
        let question = try XCTUnwrap(chat.interactions.first)
        try store.resolveInteraction(chat, id: question.id, action: .accept, content: ["ready": true])
        try await wait { !chat.busy && chat.pendingPrompts.isEmpty }
        let state = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertEqual(state["prompts"].array.first?["prompt"].array.first?["text"], "Latest queued text")
        XCTAssertFalse(chat.transcript.items.contains { $0.kind == "user" && $0.text == "Old queued text" })
    }

    @MainActor func testTwoCorrectionsAreDeliveredInOrderAndExplicitNextTurnWaits() async throws {
        let (store, chat, _) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "hold original")
        try await wait { chat.state == .running }
        store.send(chat, text: "First correction")
        store.send(chat, text: "Second correction")
        store.send(chat, text: "Explicit next turn", policy: .nextTurn)
        try await wait { chat.transcript.items.filter { $0.deliveryState == .acknowledged }.count == 2 }
        let active = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(active["steers"].array.map { $0["prompt"].array.first?["text"].string }, ["First correction", "Second correction"])
        XCTAssertEqual(active["prompts"].array.count, 1)
        _ = try await peer.request("fixture/finish", params: [:])
        try await wait { !chat.busy && chat.pendingPrompts.isEmpty }
        let finished = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(finished["prompts"].array.last?["prompt"].array.first?["text"], "Explicit next turn")
    }

    @MainActor func testRejectedOrUnknownVersionSteeringUsesNextTurnQueue() async throws {
        for reject in [false, true] {
            let (store, chat, _) = try await setup(reject ? ["--reject-steering"] : [])
            let peer = try XCTUnwrap(chat.connection)
            if !reject { chat.handshake["agentInfo"]["version"] = "0.85.0" }
            store.send(chat, text: "hold original")
            try await wait { chat.state == .running }
            store.send(chat, text: "Deferred correction")
            try await wait { chat.pendingPrompts.contains { $0.text == "Deferred correction" && $0.policy == .nextTurn && $0.state == .queued } }
            _ = try await peer.request("fixture/finish", params: [:])
            try await wait { !chat.busy && chat.pendingPrompts.isEmpty }
            let finished = try await peer.request("fixture/state", params: [:])
            XCTAssertEqual(finished["steers"].array.count, reject ? 1 : 0)
            XCTAssertEqual(finished["prompts"].array.count, 2)
            XCTAssertFalse(chat.transcript.items.contains { $0.deliveryState == .uncertain })
        }
    }

    @MainActor func testStopBeforeWireSubmissionCannotStartTheTaskAfterCancel() async throws {
        let (store, chat, _) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "Establish session")
        try await wait { !chat.busy }
        let stopped = expectation(description: "Stop at the submission boundary")
        withObservationTracking { _ = chat.state } onChange: {
            Task { @MainActor in
                store.stop(chat)
                stopped.fulfill()
            }
        }
        chat.draft = "Do not start after Stop"
        store.send(chat)
        await fulfillment(of: [stopped], timeout: 2)
        try await wait { !chat.busy }
        let state = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(state["prompts"].array.count, 1, "Stop before the RPC is submitted must prevent execution")
        XCTAssertEqual(chat.draft, "Do not start after Stop")
        XCTAssertFalse(chat.pendingPrompts.contains { $0.state == .uncertain }, "Locally prevented submission has a known outcome")
    }
}
