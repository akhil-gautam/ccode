import XCTest
@testable import CCodeCore

final class DiscardTests: XCTestCase, @unchecked Sendable {
    private func repository(commit: Bool = true) async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-discard-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        if commit {
            for name in ["first.txt", "other.txt"] { try "original\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            _ = try await Repository.run(["add", "."], at: root.path)
            _ = try await Repository.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "Initial"], at: root.path)
        }
        return root
    }
    private func text(_ root: URL, _ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
    private func write(_ root: URL, _ path: String, _ value: String) throws { try value.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
    func testWorkspaceReadsDoNotRewriteIndexOrInvalidateFreshDiscardPreview() async throws {
        let root = try await repository()
        try write(root, "first.txt", "working\n")
        let preview = try await Repository.previewDiscard(at: root.path, paths: ["first.txt"], scope: .working)
        let index = root.appendingPathComponent(".git/index"), before = try Data(contentsOf: index)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: root.appendingPathComponent("other.txt").path)
        _ = try await Repository.status(at: root.path)
        _ = try await Repository.changeStatistics(at: root.path)
        XCTAssertEqual(try Data(contentsOf: index), before, "Read-only workspace refresh must not rewrite Git's cached index metadata")
        let result = try await Repository.discard(preview, at: root.path)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try text(root, "first.txt"), "original\n")
    }
    func testSymlinkedIndexCannotAuthorizeDiscardIntoForeignStorage() async throws {
        let root = try await repository(), index = root.appendingPathComponent(".git/index")
        let foreign = root.deletingLastPathComponent().appendingPathComponent("ccode-foreign-index-\(UUID())")
        let original = try Data(contentsOf: index)
        try original.write(to: foreign)
        addTeardownBlock { try? FileManager.default.removeItem(at: foreign) }
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: foreign)
        try write(root, "first.txt", "working\n")
        do { _ = try await Repository.previewDiscard(at: root.path, paths: ["first.txt"], scope: .all); XCTFail("Symlinked index must refuse before recovery or mutation") } catch {}
        XCTAssertEqual(try Data(contentsOf: foreign), original)
        XCTAssertEqual(try text(root, "first.txt"), "working\n")
    }
    func testWorkingDiscardRestoresIndexAndRetainsStagedAndOtherChanges() async throws {
        let root = try await repository()
        try write(root, "first.txt", "staged\n"); try await Repository.stage(at: root.path, path: "first.txt")
        try write(root, "first.txt", "working\n"); try write(root, "other.txt", "unrelated\n")
        let beforeIndex = try await Repository.run(["ls-files", "--stage", "-z"], at: root.path)
        let preview = try await Repository.previewDiscard(at: root.path, paths: ["first.txt"], scope: .working)
        XCTAssertTrue(preview.diff.contains("-staged")); XCTAssertTrue(preview.diff.contains("+working"))
        XCTAssertEqual(try text(root, "first.txt"), "working\n", "Preview must not mutate files")
        let result = try await Repository.discard(preview, at: root.path)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try text(root, "first.txt"), "staged\n"); XCTAssertEqual(try text(root, "other.txt"), "unrelated\n")
        let index = try await Repository.run(["ls-files", "--stage", "-z"], at: root.path)
        XCTAssertEqual(index, beforeIndex)
        XCTAssertEqual(try text(URL(fileURLWithPath: result.recoveryDirectory), "working/first.txt"), "working\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.recoveryDirectory + "/manifest.json"))
    }
    func testAllDiscardRestoresHeadAndOnlySelectedIndexEntries() async throws {
        let root = try await repository()
        try write(root, "first.txt", "staged\n"); try write(root, "other.txt", "other staged\n")
        _ = try await Repository.run(["add", "."], at: root.path)
        try write(root, "first.txt", "working\n")
        let preview = try await Repository.previewDiscard(at: root.path, paths: ["first.txt"], scope: .all)
        let result = try await Repository.discard(preview, at: root.path)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try text(root, "first.txt"), "original\n"); XCTAssertEqual(try text(root, "other.txt"), "other staged\n")
        let status = try await Repository.status(at: root.path)
        XCTAssertEqual(status.files.map(\.path), ["other.txt"]); XCTAssertTrue(status.files[0].staged)
        XCTAssertEqual(try text(URL(fileURLWithPath: result.recoveryDirectory), "working/first.txt"), "working\n")
        XCTAssertEqual(try text(URL(fileURLWithPath: result.recoveryDirectory), "staged/first.txt"), "staged\n")
    }
    func testUntrackedBinaryLiteralFilenameIsRemovedIntoRecovery() async throws {
        let root = try await repository(), path = "literal[*]\t界\n.bin", bytes = Data([0, 255, 128, 1])
        try bytes.write(to: root.appendingPathComponent(path))
        let preview = try await Repository.previewDiscard(at: root.path, paths: [path], scope: .working)
        let result = try await Repository.discard(preview, at: root.path)
        XCTAssertEqual(result.status, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.recoveryDirectory).appendingPathComponent("working/" + path)), bytes)
        XCTAssertEqual(try text(root, "first.txt"), "original\n")
        let status = try await Repository.status(at: root.path); XCTAssertTrue(status.files.isEmpty, "Recovery files stay in Git metadata")
    }
    func testStaleFileIndexAndHeadRefuseBeforeDiscarding() async throws {
        let root = try await repository()
        try write(root, "first.txt", "previewed\n")
        let preview = try await Repository.previewDiscard(at: root.path, paths: ["first.txt"], scope: .all)
        try write(root, "first.txt", "external\n")
        do { _ = try await Repository.discard(preview, at: root.path); XCTFail("Stale file") } catch {}
        XCTAssertEqual(try text(root, "first.txt"), "external\n")
        let indexPreview = try await Repository.previewDiscard(at: root.path, paths: ["first.txt"], scope: .all)
        try write(root, "other.txt", "external staged\n"); try await Repository.stage(at: root.path, path: "other.txt")
        do { _ = try await Repository.discard(indexPreview, at: root.path); XCTFail("Stale index") } catch {}
        XCTAssertEqual(try text(root, "first.txt"), "external\n")
        let headPreview = try await Repository.previewDiscard(at: root.path, paths: ["first.txt"], scope: .working)
        _ = try await Repository.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "--allow-empty", "-m", "Moved HEAD"], at: root.path)
        do { _ = try await Repository.discard(headPreview, at: root.path); XCTFail("Stale HEAD") } catch {}
        XCTAssertEqual(try text(root, "first.txt"), "external\n")
    }
    func testAllRenameDiscardPreviewsBothPathsAndRestoresOriginal() async throws {
        let root = try await repository(), destination = "renamed.txt"
        _ = try await Repository.run(["mv", "first.txt", destination], at: root.path)
        try write(root, destination, "edited rename\n")
        let preview = try await Repository.previewDiscard(at: root.path, paths: [destination], scope: .all)
        XCTAssertEqual(Set(preview.paths), Set([destination, "first.txt"]))
        let result = try await Repository.discard(preview, at: root.path)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try text(root, "first.txt"), "original\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(destination).path))
        XCTAssertEqual(try text(URL(fileURLWithPath: result.recoveryDirectory), "working/" + destination), "edited rename\n")
        let status = try await Repository.status(at: root.path); XCTAssertTrue(status.files.isEmpty)
    }
    func testUnbornAllDiscardRemovesSelectedAddedFileAndPreservesOtherIndexEntry() async throws {
        let root = try await repository(commit: false)
        try write(root, "new.txt", "staged new\n"); try write(root, "other.txt", "retain\n")
        _ = try await Repository.run(["add", "."], at: root.path)
        try write(root, "new.txt", "working new\n")
        let preview = try await Repository.previewDiscard(at: root.path, paths: ["new.txt"], scope: .all)
        let result = try await Repository.discard(preview, at: root.path)
        XCTAssertEqual(result.status, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
        let status = try await Repository.status(at: root.path); XCTAssertEqual(status.files.map(\.path), ["other.txt"])
        XCTAssertEqual(try text(URL(fileURLWithPath: result.recoveryDirectory), "staged/new.txt"), "staged new\n")
    }
    func testForeignRootEscapeLinkAndCancelledApplyCannotDiscard() async throws {
        let root = try await repository(), other = try await repository()
        try write(root, "first.txt", "dirty\n")
        let preview = try await Repository.previewDiscard(at: root.path, paths: ["first.txt"], scope: .working)
        do { _ = try await Repository.discard(preview, at: other.path); XCTFail("Foreign root") } catch {}
        for path in ["../other", "/etc/passwd", "", ".git/config"] {
            do { _ = try await Repository.previewDiscard(at: root.path, paths: [path], scope: .all); XCTFail("Invalid path") } catch {}
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: other.appendingPathComponent("first.txt").path)
        do { _ = try await Repository.previewDiscard(at: root.path, paths: ["escape"], scope: .all); XCTFail("Outside link") } catch {}
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await Repository.discard(preview, at: root.path); XCTFail("Cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        }
        await cancelled.value
        XCTAssertEqual(try text(root, "first.txt"), "dirty\n")
        XCTAssertEqual(try text(other, "first.txt"), "original\n")
    }
    func testDeletedParentFolderIsRecreatedForSelectedTrackedFile() async throws {
        let root = try await repository(), directory = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(root, "nested/deleted.txt", "retain bytes\n")
        try await Repository.stage(at: root.path, path: "nested/deleted.txt")
        _ = try await Repository.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "Nested"], at: root.path)
        try FileManager.default.removeItem(at: directory)
        let preview = try await Repository.previewDiscard(at: root.path, paths: ["nested/deleted.txt"], scope: .working)
        let result = try await Repository.discard(preview, at: root.path)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try text(root, "nested/deleted.txt"), "retain bytes\n")
    }
    func testBinaryAndExecutableModeRestoreExactBytesFromIndex() async throws {
        let root = try await repository(), path = "asset.bin", file = root.appendingPathComponent(path)
        let expected = Data([0, 128, 255, 1]), modified = Data([0, 200, 255, 2])
        try expected.write(to: file)
        _ = try await Repository.run(["config", "core.filemode", "true"], at: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        try await Repository.stage(at: root.path, path: path)
        _ = try await Repository.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "Binary"], at: root.path)
        try modified.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let preview = try await Repository.previewDiscard(at: root.path, paths: [path], scope: .working)
        let result = try await Repository.discard(preview, at: root.path)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try Data(contentsOf: file), expected)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.recoveryDirectory).appendingPathComponent("working/" + path)), modified)
    }
    func testGitLockRefusesWithoutMutationAndPartialFailureRetainsCopies() async throws {
        let root = try await repository(), lock = root.appendingPathComponent(".git/index.lock")
        try write(root, "first.txt", "dirty\n")
        let preview = try await Repository.previewDiscard(at: root.path, paths: ["first.txt"], scope: .working)
        try "another Git process".write(to: lock, atomically: true, encoding: .utf8)
        do { _ = try await Repository.discard(preview, at: root.path); XCTFail("Existing lock") } catch {}
        XCTAssertEqual(try text(root, "first.txt"), "dirty\n")
        XCTAssertEqual(try text(root, ".git/index.lock"), "another Git process")
        try FileManager.default.removeItem(at: lock)
        let folder = root.appendingPathComponent("restricted")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(root, "restricted/second.txt", "before\n")
        try await Repository.stage(at: root.path, path: "restricted/second.txt")
        _ = try await Repository.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "Restricted"], at: root.path)
        try write(root, "restricted/second.txt", "preserve\n")
        let partial = try await Repository.previewDiscard(at: root.path, paths: ["first.txt", "restricted/second.txt"], scope: .working)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let result = try await Repository.discard(partial, at: root.path)
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(try text(root, "first.txt"), "original\n")
        XCTAssertEqual(try text(root, "restricted/second.txt"), "preserve\n")
        XCTAssertEqual(try text(URL(fileURLWithPath: result.recoveryDirectory), "working/first.txt"), "dirty\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }
    func testNestedRootAllDiscardUsesCorrectGitPrefixAndPreservesOutsideFile() async throws {
        let root = try await repository(), nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write(root, "nested/inside.txt", "before\n")
        try await Repository.stage(at: root.path, path: "nested/inside.txt")
        _ = try await Repository.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "Nested"], at: root.path)
        try write(root, "nested/inside.txt", "staged\n"); try await Repository.stage(at: nested.path, path: "inside.txt")
        try write(root, "nested/inside.txt", "working\n"); try write(root, "other.txt", "outside dirty\n")
        let preview = try await Repository.previewDiscard(at: nested.path, paths: ["inside.txt"], scope: .all)
        let result = try await Repository.discard(preview, at: nested.path)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(try text(root, "nested/inside.txt"), "before\n")
        XCTAssertEqual(try text(root, "other.txt"), "outside dirty\n")
        XCTAssertEqual(try text(URL(fileURLWithPath: result.recoveryDirectory), "working/nested/inside.txt"), "working\n")
    }

}
