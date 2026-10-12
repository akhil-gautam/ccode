import XCTest
import Foundation
import CCodeCore
@testable import CCode

final class ConversationBranchTests: XCTestCase, @unchecked Sendable {
    func testStoredOriginKeepsActualSourceAndBoundaryAndLegacySessionsDecode() throws {
        let source = SessionInfo(projectPath: "/project", title: "Original")
        var edit = SessionInfo(projectPath: "/project", title: "Edited")
        let item = UUID()
        edit.origin = ConversationOrigin(kind: .edit, sourceSessionID: source.id, sourceRemoteID: "provider-source", sourceItemID: item, boundaryMessageID: "retained-assistant", startsFresh: false)
        let decoded = try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(edit))
        XCTAssertEqual(decoded.origin, edit.origin)
        XCTAssertEqual(decoded.origin?.sourceItemID, item)
        let legacy = try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(source))
        XCTAssertNil(legacy.origin)
    }
    func testRelatedVersionsIncludeRootSiblingNestedAndArchivedButNotUnrelated() {
        var root = SessionInfo(projectPath: "/project", title: "Original")
        root.updatedAt = Date(timeIntervalSince1970: 1)
        var edit = SessionInfo(projectPath: root.projectPath, title: "Edit")
        edit.origin = ConversationOrigin(kind: .edit, sourceSessionID: root.id, startsFresh: true, createdAt: Date(timeIntervalSince1970: 2))
        edit.updatedAt = Date(timeIntervalSince1970: 2)
        var retry = SessionInfo(projectPath: root.projectPath, title: "Retry")
        retry.origin = ConversationOrigin(kind: .retry, sourceSessionID: root.id, startsFresh: true, createdAt: Date(timeIntervalSince1970: 3))
        retry.updatedAt = Date(timeIntervalSince1970: 3); retry.archived = true
        var nested = SessionInfo(projectPath: root.projectPath, title: "Nested fork")
        nested.origin = ConversationOrigin(kind: .fork, sourceSessionID: edit.id, startsFresh: false, createdAt: Date(timeIntervalSince1970: 4))
        nested.updatedAt = Date(timeIntervalSince1970: 4)
        let unrelated = SessionInfo(projectPath: root.projectPath, title: "Unrelated")
        XCTAssertEqual(ConversationBranch.related(to: nested.id, in: [unrelated, nested, retry, root, edit]).map(\.id), [root.id, edit.id, retry.id, nested.id])
        XCTAssertEqual(ConversationBranch.related(to: root.id, in: [nested, retry, root, edit]).map(\.id), [root.id, edit.id, retry.id, nested.id])
        edit.updatedAt = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(ConversationBranch.related(to: root.id, in: [nested, retry, root, edit]).map(\.id), [root.id, edit.id, retry.id, nested.id], "Using a version must not reorder the lineage")
    }
    func testMissingCrossWorkspaceCyclicAndDuplicateOriginsDoNotInventRelationships() {
        var root = SessionInfo(projectPath: "/project")
        var orphan = SessionInfo(projectPath: root.projectPath)
        orphan.origin = ConversationOrigin(kind: .fork, sourceSessionID: UUID(), startsFresh: false)
        var foreign = SessionInfo(projectPath: "/other")
        foreign.origin = ConversationOrigin(kind: .edit, sourceSessionID: root.id, startsFresh: true)
        XCTAssertEqual(ConversationBranch.related(to: root.id, in: [root, orphan, foreign]).map(\.id), [root.id])
        XCTAssertEqual(ConversationBranch.related(to: orphan.id, in: [root, orphan]).map(\.id), [orphan.id])
        var cycle = SessionInfo(projectPath: root.projectPath)
        cycle.origin = ConversationOrigin(kind: .fork, sourceSessionID: root.id, startsFresh: false)
        root.origin = ConversationOrigin(kind: .fork, sourceSessionID: cycle.id, startsFresh: false)
        XCTAssertEqual(ConversationBranch.related(to: root.id, in: [root, cycle]).map(\.id), [root.id])
        XCTAssertEqual(ConversationBranch.related(to: root.id, in: [root, root, cycle]).map(\.id), [root.id])
    }
    @MainActor func testActualForkRecordsSourceAndSelectedBoundaryAcrossRestartWithoutChangingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-origin-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = root.appendingPathComponent("data")
        let store = AppStore(directory: data)
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--fork"]
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let source = try XCTUnwrap(store.selected)
        try await store.connect(source)
        source.handshake["agentInfo"] = ["name": "@agentclientprotocol/claude-agent-acp", "version": "0.84.0"]
        let boundary = TranscriptItem(kind: "assistant", text: "Retained answer", messageID: "actual-boundary")
        source.transcript.items = [boundary]
        source.draft = "Preserve source draft"
        let remote = source.transcript.remoteID
        let fork = try await store.fork(source, at: boundary.id)
        let origin = try XCTUnwrap(store.sessions.first { $0.id == fork }?.origin)
        XCTAssertEqual(origin.kind, .fork)
        XCTAssertEqual(origin.sourceSessionID, source.id)
        XCTAssertEqual(origin.sourceRemoteID, remote)
        XCTAssertEqual(origin.sourceItemID, boundary.id)
        XCTAssertEqual(origin.boundaryMessageID, "actual-boundary")
        XCTAssertFalse(origin.startsFresh)
        XCTAssertEqual(source.draft, "Preserve source draft")
        XCTAssertNil(store.sessions.first { $0.id == source.id }?.origin)
        await store.shutdown()
        let restored = AppStore(directory: data); restored.settings = store.settings
        addTeardownBlock { await restored.shutdown() }
        await restored.restore()
        XCTAssertEqual(restored.sessions.first { $0.id == fork }?.origin, origin)
        XCTAssertEqual(ConversationBranch.related(to: fork, in: restored.sessions).map(\.id), [source.id, fork])
        await restored.select(source.id)
        XCTAssertEqual(restored.selected?.draft, "Preserve source draft")
    }
}
