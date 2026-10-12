import XCTest
import CCodeCore
@testable import CCode

final class CheckpointTests: XCTestCase {
    private let remote = UUID().uuidString
    private let connection = UUID().uuidString
    private let checkpoint = UUID().uuidString
    private func capability() -> JSONValue {
        ["version": 1, "connectionId": .string(connection), "previewMethod": "_ccode/checkpoint/preview", "notificationMethod": "_ccode/checkpoint"]
    }
    private func receipt(_ prompt: UUID) -> JSONValue {
        ["version": 1, "sessionId": .string(remote), "connectionId": .string(connection), "checkpointId": .string(checkpoint), "promptId": .string(prompt.uuidString)]
    }
    func testExactRootReceiptBindsOnlyUniqueSubmittedUserAndPersistsWithoutGrantingNewConnectionAuthority() throws {
        var transcript = SessionTranscript(remoteID: remote)
        let prompt = UUID()
        transcript.appendUser("Own prompt", id: prompt, deliveryState: .submitting)
        XCTAssertTrue(transcript.recordFileCheckpoint(receipt(prompt), capability: capability()))
        let saved = try XCTUnwrap(transcript.items[0].fileCheckpoint)
        XCTAssertEqual(saved.promptID, prompt); XCTAssertEqual(saved.checkpointID, checkpoint)
        XCTAssertEqual(saved.remoteID, remote); XCTAssertEqual(saved.connectionID, connection)
        XCTAssertFalse(transcript.recordFileCheckpoint(receipt(prompt), capability: capability()), "Duplicate receipt is idempotent")
        let restored = try JSONDecoder().decode(SessionTranscript.self, from: JSONEncoder().encode(transcript))
        XCTAssertEqual(restored.items[0].fileCheckpoint, saved)
        XCTAssertTrue(saved.matches(capability: capability(), remoteID: remote))
        var newConnection = capability(); newConnection["connectionId"] = .string(UUID().uuidString)
        XCTAssertFalse(saved.matches(capability: newConnection, remoteID: remote), "Persisted history cannot control another query")
        let legacy = try JSONDecoder().decode(TranscriptItem.self, from: Data("{\"id\":\"\(UUID())\",\"kind\":\"user\",\"text\":\"legacy\",\"tool\":{},\"blocks\":[]}".utf8))
        XCTAssertNil(legacy.fileCheckpoint)
    }
    func testForeignMalformedDuplicateAndUnknownReceiptsNeverBecomeAuthority() throws {
        let prompt = UUID()
        var transcript = SessionTranscript(remoteID: remote)
        transcript.appendUser("Own", id: prompt, deliveryState: .submitting)
        for key in ["sessionId", "connectionId", "promptId", "checkpointId"] {
            var wrong = receipt(prompt); wrong[key] = .string(key == "checkpointId" ? "malformed" : UUID().uuidString)
            XCTAssertFalse(transcript.recordFileCheckpoint(wrong, capability: capability()))
        }
        var unknownVersion = capability(); unknownVersion["version"] = 2
        XCTAssertFalse(transcript.recordFileCheckpoint(receipt(prompt), capability: unknownVersion))
        transcript.items[0].kind = "assistant"
        XCTAssertFalse(transcript.recordFileCheckpoint(receipt(prompt), capability: capability()))
        transcript.items[0].kind = "user"; transcript.items[0].deliveryState = nil
        XCTAssertFalse(transcript.recordFileCheckpoint(receipt(prompt), capability: capability()), "Imported user text is not a submitted prompt")
        transcript.items[0].deliveryState = .submitting; transcript.items.append(transcript.items[0])
        XCTAssertFalse(transcript.recordFileCheckpoint(receipt(prompt), capability: capability()), "Ambiguous local identity")
        transcript.items.removeLast()
        XCTAssertTrue(transcript.recordFileCheckpoint(receipt(prompt), capability: capability()))
        var conflicting = receipt(prompt); conflicting["checkpointId"] = .string(UUID().uuidString)
        XCTAssertFalse(transcript.recordFileCheckpoint(conflicting, capability: capability()))
        XCTAssertEqual(transcript.items[0].fileCheckpoint?.checkpointID, checkpoint)
    }
    func testPreviewValidatesExactIdentityBoundsAndIncompleteCoverage() throws {
        let prompt = UUID()
        let reference = try XCTUnwrap(FileCheckpointReference(receipt(prompt), capability: capability()))
        var value = receipt(prompt)
        value["canRewind"] = true; value["filesChanged"] = ["answer.py", "path with spaces/source.swift"]
        value["insertions"] = 2; value["deletions"] = 1; value["declaredComplete"] = false
        let preview = try FileCheckpointPreview(value, reference: reference)
        XCTAssertEqual(preview.paths.count, 2); XCTAssertEqual(preview.insertions, 2); XCTAssertEqual(preview.deletions, 1)
        XCTAssertTrue(preview.canRewind)
        for key in ["promptId", "checkpointId", "sessionId", "connectionId"] {
            var bad = value; bad[key] = .string(UUID().uuidString)
            XCTAssertThrowsError(try FileCheckpointPreview(bad, reference: reference))
        }
        var bad = value; bad["declaredComplete"] = true
        XCTAssertThrowsError(try FileCheckpointPreview(bad, reference: reference))
        bad = value; bad["insertions"] = -1
        XCTAssertThrowsError(try FileCheckpointPreview(bad, reference: reference))
        bad = value; bad["filesChanged"] = .array(Array(repeating: "file", count: 1025))
        XCTAssertThrowsError(try FileCheckpointPreview(bad, reference: reference))
        bad = value; bad["filesChanged"] = ["bad\0path"]
        XCTAssertThrowsError(try FileCheckpointPreview(bad, reference: reference))
    }
    func testRestoreResponseIsBoundToPreviewAndPrivateRecoveryStorageAndPersists() throws {
        let reference = try XCTUnwrap(FileCheckpointReference(receipt(UUID()), capability: capability()))
        var wire = reference.parameters
        wire["version"] = 1; wire["canRewind"] = true; wire["filesChanged"] = ["answer.py"]
        wire["insertions"] = 2; wire["deletions"] = 1; wire["declaredComplete"] = false
        wire["previewToken"] = .string(UUID().uuidString)
        let preview = try FileCheckpointPreview(wire, reference: reference)
        XCTAssertNotNil(preview.restoreParameters)
        var malformed = wire; malformed["previewToken"] = "not-a-token"
        XCTAssertThrowsError(try FileCheckpointPreview(malformed, reference: reference))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restore-model-\(UUID())")
        var response = reference.parameters
        response["version"] = 1; response["status"] = "completed"; response["skippedLinks"] = 0; response["declaredComplete"] = false
        response["recoveryDirectory"] = .string(root.appendingPathComponent("restore-abc123").path)
        let operation = FileCheckpointRestoration(reference: reference)
        let completed = try operation.finishing(response, recoveryRoot: root)
        XCTAssertEqual(completed.status, .completed); XCTAssertEqual(completed.id, operation.id)
        for key in ["sessionId", "promptId", "checkpointId", "connectionId"] {
            var bad = response; bad[key] = .string(UUID().uuidString)
            XCTAssertThrowsError(try operation.finishing(bad, recoveryRoot: root))
        }
        var bad = response; bad["recoveryDirectory"] = .string(root.appendingPathComponent("../foreign/restore-abc123").path)
        XCTAssertThrowsError(try operation.finishing(bad, recoveryRoot: root))
        bad = response; bad["status"] = "magic"
        XCTAssertThrowsError(try operation.finishing(bad, recoveryRoot: root))
        bad = response; bad["declaredComplete"] = true
        XCTAssertThrowsError(try operation.finishing(bad, recoveryRoot: root))
        var transcript = SessionTranscript(); transcript.fileRestorations = [operation, completed]
        let saved = try JSONDecoder().decode(SessionTranscript.self, from: JSONEncoder().encode(transcript))
        XCTAssertEqual(saved.fileRestorations, transcript.fileRestorations)
    }
}
