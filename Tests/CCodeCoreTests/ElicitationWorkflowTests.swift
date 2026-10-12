import XCTest
import Foundation
import CCodeCore
@testable import CCode

final class ElicitationWorkflowTests: XCTestCase, @unchecked Sendable {
    @MainActor private func setup() async throws -> (AppStore, ChatSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-interaction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "elicitation", withExtension: "py", subdirectory: "Fixtures")!.path]
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        try await store.connect(chat)
        return (store, chat)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Expected interaction state did not arrive")
    }

    @MainActor func testAnswersReachProviderExactlyOnceAndInvalidAnswersKeepCard() async throws {
        let (store, chat) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        let state = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(state["capabilities"]["elicitation"]["form"], [:])
        chat.draft = "Ask me before changing storage"
        store.send(chat)
        try await wait { !chat.interactions.isEmpty || chat.state == .failed }
        let interaction = try XCTUnwrap(chat.interactions.first)
        XCTAssertThrowsError(try store.resolveInteraction(chat, id: interaction.id, action: .accept, content: ["storage": "unknown"]))
        XCTAssertEqual(chat.interactions.count, 1)
        try store.resolveInteraction(chat, id: interaction.id, action: .accept, content: ["storage": "sqlite", "note": "Preserve imports"])
        try store.resolveInteraction(chat, id: interaction.id, action: .accept, content: ["storage": "files"])
        try await wait { !chat.busy }
        let result = try await peer.request("fixture/state", params: [:])
        XCTAssertEqual(result["replies"].array.count, 1)
        XCTAssertEqual(result["replies"].array.first?["result"]["content"], ["storage": "sqlite", "note": "Preserve imports"])
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "interaction" && $0.tool["action"] == "accept" })
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "assistant" && $0.text.contains("sqlite") })
        XCTAssertTrue(chat.interactions.isEmpty)
    }

    @MainActor func testStopAndDisconnectCancelOutstandingQuestion() async throws {
        for disconnect in [false, true] {
            let (store, chat) = try await setup()
            let peer = try XCTUnwrap(chat.connection)
            store.send(chat, text: "Ask a question")
            try await wait { !chat.interactions.isEmpty || chat.state == .failed }
            XCTAssertEqual(chat.interactions.count, 1)
            if disconnect { await store.disconnect(chat) }
            else { store.stop(chat); try await wait { !chat.busy } }
            XCTAssertTrue(chat.interactions.isEmpty)
            if !disconnect {
                let result = try await peer.request("fixture/state", params: [:])
                XCTAssertEqual(result["replies"].array.count, 1)
                XCTAssertEqual(result["replies"].array.first?["result"]["action"], "cancel")
            }
        }
    }

    @MainActor func testTwoChatsCannotResolveEachOthersQuestionAndWrongScopeRejects() async throws {
        let (leftStore, left) = try await setup(), (rightStore, right) = try await setup()
        leftStore.send(left, text: "Ask left"); rightStore.send(right, text: "Ask right")
        try await wait { !left.interactions.isEmpty && !right.interactions.isEmpty }
        let first = try XCTUnwrap(left.interactions.first), second = try XCTUnwrap(right.interactions.first)
        try rightStore.resolveInteraction(right, id: first.id, action: .accept, content: ["storage": "sqlite"])
        XCTAssertEqual(right.interactions.count, 1)
        try leftStore.resolveInteraction(left, id: first.id, action: .decline)
        try rightStore.resolveInteraction(right, id: second.id, action: .accept, content: ["storage": "files"])
        try await wait { !left.busy && !right.busy }
        leftStore.send(left, text: "wrong owner")
        try await wait { !left.busy }
        XCTAssertTrue(left.interactions.isEmpty)
        let state = try await XCTUnwrap(left.connection).request("fixture/state", params: [:])
        XCTAssertEqual(state["replies"].array.last?["error"]["code"], -32602)
    }

    @MainActor func testURLAcceptanceWaitsForMatchingCompletionAndUnknownIDsAreIgnored() async throws {
        let (store, chat) = try await setup()
        let peer = try XCTUnwrap(chat.connection)
        store.send(chat, text: "url")
        try await wait { !chat.interactions.isEmpty || chat.state == .failed }
        let pending = try XCTUnwrap(chat.interactions.first)
        XCTAssertEqual(pending.request.url?.host, "example.com")
        XCTAssertTrue(chat.urlInteractions.isEmpty, "No URL should open or become accepted without a user decision")
        try store.resolveInteraction(chat, id: pending.id, action: .accept)
        XCTAssertEqual(chat.urlInteractions.first?.id, "auth-id")
        _ = try await peer.request("fixture/complete-url", params: ["elicitationId": "unknown"])
        try await wait { !chat.busy }
        XCTAssertEqual(chat.urlInteractions.first?.id, "auth-id", "Unknown completion must not settle a different interaction")
        XCTAssertTrue(store.attentionSessions.contains { $0.id == chat.id })
        await store.openHome()
        XCTAssertTrue(chat.connection === peer, "Pending external completion must survive navigation")
        _ = try await peer.request("fixture/complete-url", params: ["elicitationId": "auth-id"])
        XCTAssertTrue(chat.urlInteractions.isEmpty)
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "notice" && $0.text.contains("External interaction completed") })
        XCTAssertFalse(store.attentionSessions.contains { $0.id == chat.id })
        await store.openHome()
        XCTAssertNil(chat.connection, "A completed external interaction must not retain an idle peer")
    }

    @MainActor func testRequestScopedQuestionDuringSessionSetup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-request-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "elicitation", withExtension: "py", subdirectory: "Fixtures")!.path, "--request-scope"]
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        let connecting = Task { try await store.connect(chat) }
        try await wait { !chat.interactions.isEmpty || chat.state == .failed }
        let interaction = try XCTUnwrap(chat.interactions.first)
        XCTAssertNotNil(interaction.request.requestID)
        XCTAssertNil(chat.transcript.remoteID)
        try store.resolveInteraction(chat, id: interaction.id, action: .accept, content: ["ready": true])
        try await connecting.value
        XCTAssertEqual(chat.state, .ready)
    }
}
