import XCTest
import Foundation
import CCodeCore
import SwiftUI
import AppKit
@testable import CCode

final class FailureRecoveryTests: XCTestCase, @unchecked Sendable {
    func testTypedProviderErrorsDoNotInferFromAssistantProse() throws {
        let cases: [(String, AgentFailure.Kind)] = [
            ("authentication_failed", .authentication), ("oauth_org_not_allowed", .authentication),
            ("billing_error", .quota), ("rate_limit", .rateLimit), ("overloaded", .overloaded),
            ("max_output_tokens", .context), ("worker_shutdown", .connection),
            ("verification_required", .access), ("cloud_credential_error", .access),
            ("invalid_request", .request), ("unknown", .provider)
        ]
        for (kind, expected) in cases {
            let failure = AgentFailure(error: ACPError.remoteFailure(-32603, "Exact provider explanation", ["errorKind": .string(kind)]))
            XCTAssertEqual(failure.kind, expected)
            XCTAssertTrue(failure.details.contains("Exact provider explanation"))
        }
        XCTAssertEqual(AgentFailure(error: ACPError.workspace("Discuss billing_error and overloaded")).kind, .provider)
        XCTAssertEqual(AgentFailure(error: ACPError.remote(-32000, "Managed policy forbids this setting")).kind, .provider)
        XCTAssertEqual(AgentFailure(error: ACPError.remote(-32000, "Authentication required")).kind, .authentication)
        XCTAssertEqual(AgentFailure(error: ACPError.remoteFailure(-32603, "Reported failure", ["errorKind": "billing_error"]), providerMetadata: false).kind, .provider)
        XCTAssertEqual(AgentFailure(error: ACPError.remoteFailure(-32000, "Authentication required: subscription unsupported", ["reason": "claude_subscription_not_supported"])).kind, .access)
    }
    @MainActor private func setup(_ flags: [String]) async throws -> (AppStore, ChatSession, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "delivery", withExtension: "py", subdirectory: "Fixtures")!.path, "--no-steering"] + flags
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        return (store, try XCTUnwrap(store.selected), root)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Expected failure recovery state did not arrive")
    }
    @MainActor func testProviderFailureRetainsUnknownDeliveryAndReconnectNeverRetriesIt() async throws {
        let (store, chat, _) = try await setup(["--fail-prompt=overloaded"])
        chat.draft = "Change implementation"; store.send(chat)
        try await wait { chat.state == .failed && !chat.busy }
        let failure = try XCTUnwrap(chat.failure)
        XCTAssertEqual(failure.kind, .overloaded)
        XCTAssertEqual(failure.deliveryID, chat.pendingPrompts.first?.id)
        XCTAssertEqual(chat.pendingPrompts.first?.state, .uncertain)
        XCTAssertTrue(chat.deliveryPaused)
        chat.draft = "Unrelated next draft"
        await store.recoverConnection(chat)
        XCTAssertEqual(chat.state, .ready)
        XCTAssertEqual(chat.draft, "Unrelated next draft")
        XCTAssertEqual(chat.pendingPrompts.first?.state, .uncertain)
        let state = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertTrue(state["prompts"].array.isEmpty, "Reconnect must not submit either the failed turn or the draft")
    }
    @MainActor func testAuthenticationRecoveryKeepsUnsentDraftAndDoesNotRunIt() async throws {
        let (store, chat, _) = try await setup(["--auth-setup"])
        chat.draft = "Keep this unsent task"; store.send(chat)
        try await wait { chat.state == .failed && !chat.busy }
        XCTAssertEqual(chat.failure?.kind, .authentication)
        XCTAssertEqual(chat.draft, "Keep this unsent task")
        XCTAssertTrue(chat.pendingPrompts.isEmpty)
        await store.recoverConnection(chat, authentication: "fixture-login")
        XCTAssertEqual(chat.state, .ready)
        XCTAssertNil(chat.failure)
        XCTAssertEqual(chat.draft, "Keep this unsent task")
        let state = try await XCTUnwrap(chat.connection).request("fixture/state", params: [:])
        XCTAssertTrue(state["prompts"].array.isEmpty)
    }
    @MainActor func testFailureKindAndInterruptedRequestSurviveRestart() async throws {
        let (store, chat, root) = try await setup(["--fail-prompt=rate_limit"])
        store.send(chat, text: "Interrupted task")
        try await wait { chat.state == .failed && !chat.busy }
        let id = try XCTUnwrap(chat.failure?.deliveryID)
        await store.shutdown()
        let restored = AppStore(directory: root.appendingPathComponent("data"))
        addTeardownBlock { await restored.shutdown() }
        await restored.restore(); await restored.select(chat.id)
        let reopened = try XCTUnwrap(restored.selected)
        XCTAssertEqual(reopened.failure?.kind, .rateLimit)
        XCTAssertEqual(reopened.failure?.deliveryID, id)
        XCTAssertNil(reopened.connection)
        XCTAssertTrue(reopened.deliveryPaused)
        try restored.restorePendingPrompt(reopened, id: id)
        XCTAssertEqual(reopened.draft, "Interrupted task")
        XCTAssertTrue(reopened.pendingPrompts.isEmpty)
        XCTAssertEqual(reopened.transcript.items.first { $0.id == id }?.deliveryState, .uncertain)
    }
    @MainActor func testFailureCardFitsCompactLightAndDarkWithoutLosingActions() throws {
        let root = FileManager.default.temporaryDirectory
        let store = AppStore(directory: root.appendingPathComponent("unused-failure-fit-" + UUID().uuidString))
        let chat = try ChatSession(id: UUID(), path: root.path, transcript: SessionTranscript())
        chat.lastError = "Authentication required (ACP -32000)"
        chat.failure = AgentFailure(error: ACPError.remote(-32000, "Authentication required"))
        chat.handshake = ["authMethods": [["id": "fixture-login", "name": "Sign in", "type": "agent"]]]
        for scheme: ColorScheme in [.light, .dark] {
            let host = NSHostingView(rootView: FailureCard(chat: chat, store: store).frame(width: 300).environment(\.colorScheme, scheme))
            XCTAssertLessThan(host.fittingSize.height, 280)
            XCTAssertGreaterThan(host.fittingSize.height, 30)
        }
    }
}
