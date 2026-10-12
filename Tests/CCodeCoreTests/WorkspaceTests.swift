import Foundation
import XCTest
import Darwin
@testable import CCodeCore

final class WorkspaceTests: XCTestCase, @unchecked Sendable {
    func testBoundedFileCatalogIncludesAdditionalFolderDespiteLargePrimary() async throws {
        let root = try temporary(), extra = try temporary()
        for index in 0..<4 { try "primary".write(to: root.appendingPathComponent("file-\(index).txt"), atomically: true, encoding: .utf8) }
        try "extra".write(to: extra.appendingPathComponent("library.txt"), atomically: true, encoding: .utf8)
        let workspace = try Workspace(root: root.path, additionalDirectories: [extra.path])
        let files = try await workspace.files(limit: 3)
        XCTAssertEqual(files.count, 3)
        XCTAssertTrue(files.contains { $0.hasSuffix("/library.txt") })
    }
    func testExplicitWorkspaceRootsKeepOutsidePathsAndSymlinksExcluded() async throws {
        let root = try temporary(), extra = try temporary(), outside = try temporary()
        let alias = root.appendingPathComponent("shared")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: extra.path)
        let workspace = try Workspace(root: root.path, additionalDirectories: [extra.path, alias.path, root.path])
        XCTAssertEqual(workspace.roots.count, 2)
        let primary = root.appendingPathComponent("main.txt").path, library = extra.appendingPathComponent("nested/library.txt").path
        try await workspace.write(primary, content: "main")
        try await workspace.write(library, content: "library")
        let read = try await workspace.read(alias.appendingPathComponent("nested/library.txt").path)
        XCTAssertEqual(read, "library")
        try FileManager.default.createSymbolicLink(atPath: extra.appendingPathComponent("escape").path, withDestinationPath: outside.path)
        for path in [outside.appendingPathComponent("forbidden.txt").path, extra.path + "-sibling/forbidden.txt", extra.appendingPathComponent("escape/forbidden.txt").path] {
            do { try await workspace.write(path, content: "no"); XCTFail("Escaped selected roots") } catch { }
        }
        let files = try await workspace.files()
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.contains("main.txt"))
        let external = try XCTUnwrap(files.first { $0.hasSuffix("/nested/library.txt") })
        let externalText = try await workspace.read(workspace.filePath(external))
        XCTAssertEqual(externalText, "library")
        let limited = try await workspace.files(limit: 1); XCTAssertEqual(limited.count, 1)
        for invalid in ["relative-folder", outside.appendingPathComponent("missing").path, primary] {
            do { _ = try Workspace(root: root.path, additionalDirectories: [invalid]); XCTFail("Accepted invalid folder") } catch { }
        }
    }
    func testCancelledTerminalCreationCannotSpawnCommand() async throws {
        let root = try temporary(), terminals = TerminalService()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                let id = try await terminals.create(command: "/usr/bin/true", directory: root.path)
                try await terminals.release(id)
                XCTFail("Cancelled task started a command")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await cancelled.value
        await terminals.close()
    }
    func testBranchCatalogRemoteTrackingAndStaleSelection() async throws {
        let root = try temporary()
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        _ = try await Repository.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "main"], at: root.path)
        _ = try await Repository.run(["config", "remote.origin.url", root.path], at: root.path)
        _ = try await Repository.run(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"], at: root.path)
        _ = try await Repository.run(["update-ref", "refs/remotes/origin/topic", "HEAD"], at: root.path)
        _ = try await Repository.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/topic"], at: root.path)
        let names = try await Repository.branches(at: root.path)
        XCTAssertEqual(names, ["main", "origin/topic"])
        try await Repository.switchBranch(at: root.path, branch: "origin/topic")
        let upstream = try await Repository.run(["rev-parse", "--abbrev-ref", "@{upstream}"], at: root.path)
        XCTAssertEqual(upstream.trimmingCharacters(in: .newlines), "origin/topic")
        _ = try await Repository.run(["switch", "main"], at: root.path)
        _ = try await Repository.run(["branch", "-D", "topic"], at: root.path)
        _ = try await Repository.run(["update-ref", "-d", "refs/remotes/origin/topic"], at: root.path)
        for invalid in ["origin/topic", "--help", "main~1"] {
            do { _ = try await Repository.createWorktree(at: root.path, name: "invalid", branch: invalid); XCTFail("Accepted unavailable branch") } catch { }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".ccode-worktrees").path))
        let current = try await Repository.run(["symbolic-ref", "--short", "HEAD"], at: root.path)
        XCTAssertEqual(current.trimmingCharacters(in: .newlines), "main")
    }
    func testNamedBranchCreationValidatesRefsAndPreservesCheckout() async throws {
        let root = try temporary()
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        _ = try await Repository.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "main"], at: root.path)
        let main = try await Repository.run(["rev-parse", "HEAD"], at: root.path)
        _ = try await Repository.run(["switch", "-c", "base"], at: root.path)
        _ = try await Repository.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "base"], at: root.path)
        let base = try await Repository.run(["rev-parse", "HEAD"], at: root.path)
        _ = try await Repository.run(["switch", "main"], at: root.path)
        let dirty = root.appendingPathComponent("unsaved.txt")
        try "Keep me".write(to: dirty, atomically: true, encoding: .utf8)
        try await Repository.createBranch(at: root.path, name: "feature/named", from: "base")
        try await Repository.createBranch(at: root.path, name: "from-current")
        let named = try await Repository.run(["rev-parse", "refs/heads/feature/named"], at: root.path)
        let current = try await Repository.run(["rev-parse", "refs/heads/from-current"], at: root.path)
        XCTAssertEqual(named, base); XCTAssertEqual(current, main)
        for name in ["feature/named", "--help", "@{-1}", "HEAD", "a..b", "a b", " leading", ""] {
            do { try await Repository.createBranch(at: root.path, name: name); XCTFail("Accepted invalid or existing branch: \(name)") } catch {}
        }
        do { try await Repository.createBranch(at: root.path, name: "missing-base", from: "deleted"); XCTFail("Accepted missing base") } catch {}
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await Repository.createBranch(at: root.path, name: "cancelled"); XCTFail("Created branch after cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        }
        await canceled.value
        let branches = try await Repository.branches(at: root.path)
        XCTAssertEqual(Set(branches), Set(["main", "base", "feature/named", "from-current"]))
        let head = try await Repository.run(["symbolic-ref", "--short", "HEAD"], at: root.path)
        XCTAssertEqual(head.trimmingCharacters(in: .newlines), "main")
        XCTAssertEqual(try String(contentsOf: dirty, encoding: .utf8), "Keep me")
    }
    func testDiffLinesTrackBothFilesAcrossHunksAndHeaderLikeContent() {
        let text = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -10,2 +20,3 @@\n same\n---content\n+++content\n+new\n\\ No newline at end of file\n@@ -40 +50 @@\n-old\n+next\n"
        let lines = Repository.diffLines(text)
        XCTAssertEqual(lines[4].oldLine, 10); XCTAssertEqual(lines[4].newLine, 20)
        XCTAssertEqual(lines[5].oldLine, 11); XCTAssertNil(lines[5].newLine)
        XCTAssertNil(lines[6].oldLine); XCTAssertEqual(lines[6].newLine, 21)
        XCTAssertEqual(lines[7].newLine, 22)
        XCTAssertNil(lines[8].newLine)
        XCTAssertEqual(lines[10].oldLine, 40); XCTAssertEqual(lines[11].newLine, 50)
        XCTAssertEqual(lines[5].source(stagedOnly: true), "original HEAD")
        XCTAssertEqual(lines[6].source(stagedOnly: true), "staged index")
        XCTAssertEqual(lines[6].source(stagedOnly: false), "working file")
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testWorkspaceScopeSlicesAndConflicts() async throws {
        let root = try temporary(), outside = try temporary()
        let workspace = try Workspace(root: root.path)
        let path = root.appendingPathComponent("nested/file.txt").path
        try await workspace.write(path, content: "one\ntwo\nthree\n")
        let slice = try await workspace.read(path, line: 2, limit: 1)
        XCTAssertEqual(slice, "two")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: outside.path)
        for invalid in [outside.appendingPathComponent("x").path, root.path + "-sibling/file", root.appendingPathComponent("escape/x").path, root.appendingPathComponent("../outside").path] {
            do { try await workspace.write(invalid, content: "no"); XCTFail("Escaped workspace") } catch { }
        }
        do { try await workspace.write(path, content: "new", expecting: "stale"); XCTFail("Lost changed file") } catch { }
        let text = try await workspace.read(path)
        XCTAssertEqual(text, "one\ntwo\nthree\n")
        let files = try await workspace.files()
        XCTAssertEqual(files, ["nested/file.txt"])
    }

    func testTerminalLifecycleAndBoundedOutput() async throws {
        let root = try temporary(), terminals = TerminalService()
        let id = try await terminals.create(command: "/bin/sh", arguments: ["-c", "printf 123456789; exit 7"], directory: root.path, byteLimit: 5)
        let status = try await terminals.wait(id)
        XCTAssertEqual(status["exitCode"].int, 7)
        let output = try await terminals.output(id)
        XCTAssertEqual(output["output"].string, "56789")
        XCTAssertTrue(output["truncated"].bool)
        try await terminals.release(id)
        do { _ = try await terminals.output(id); XCTFail("Released terminal remained valid") } catch { }
        let running = try await terminals.create(command: "/bin/sleep", arguments: ["30"], directory: root.path)
        try await terminals.kill(running)
        _ = try await terminals.wait(running)
        try await terminals.release(running)
        await terminals.close()
    }

    func testReleaseCleansDescendantsAfterLeaderExit() async throws {
        let root = try temporary(), terminals = TerminalService()
        let id = try await terminals.create(command: "/bin/sh", arguments: ["-c", "sleep 10 & echo $!; exit 0"], directory: root.path)
        _ = try await terminals.wait(id)
        let output = try await terminals.output(id)
        let pid = try XCTUnwrap(Int32(output["output"].string.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(Darwin.kill(pid, 0), 0)
        try await terminals.release(id)
        for _ in 0..<100 {
            if Darwin.kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "Background child survived terminal release")
        await terminals.close()
    }
    func testCloseWaitsForSignalResistantChildCleanup() async throws {
        let root = try temporary(), terminals = TerminalService()
        let id = try await terminals.create(command: "/bin/sh", arguments: ["-c", "trap '' TERM; echo $$; sleep 30"], directory: root.path)
        var pid: Int32?
        for _ in 0..<100 {
            let output = try await terminals.output(id)
            pid = Int32(output["output"].string.trimmingCharacters(in: .whitespacesAndNewlines))
            if pid != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let child = try XCTUnwrap(pid)
        await terminals.close()
        XCTAssertNotEqual(Darwin.kill(child, 0), 0, "Shutdown returned while the child was alive")
    }

    func testRepositoryDiffAndWorktreeIsolation() async throws {
        let root = try temporary()
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        _ = try await Repository.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "initial"], at: root.path)
        try "hello\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let status = try await Repository.status(at: root.path)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.files.first?.path, "new.txt")
        let diff = try await Repository.diff(at: root.path, path: "new.txt")
        XCTAssertTrue(diff.contains("+hello"))
        let managed = try temporary()
        let worktree = try await Repository.createWorktree(at: root.path, name: "session-test", storageDirectory: managed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree))
        XCTAssertNotEqual(worktree, root.path)
        XCTAssertTrue(worktree.hasPrefix(try Workspace(root: managed.path).root + "/"))
        XCTAssertFalse(worktree.hasPrefix(try Workspace(root: root.path).root + "/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".ccode-worktrees").path))
        try "isolated change".write(to: URL(fileURLWithPath: worktree).appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("agent.txt").path))
        let mainStatus = try await Repository.status(at: root.path)
        XCTAssertEqual(mainStatus.files.map(\.path), ["new.txt"])
        let mainBranch = try await Repository.run(["symbolic-ref", "--short", "HEAD"], at: root.path)
        XCTAssertEqual(mainBranch.trimmingCharacters(in: .newlines), "main")
        do {
            _ = try await Repository.createWorktree(at: root.path, name: "inside", storageDirectory: root.appendingPathComponent("managed"))
            XCTFail("Created worktree inside the main repository")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("managed").path))
        let alias = managed.appendingPathComponent("repo-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        do {
            _ = try await Repository.createWorktree(at: root.path, name: "aliased", storageDirectory: alias.appendingPathComponent("managed"))
            XCTFail("Created worktree inside the main repository through a symlink")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("managed").path))
    }

    func testGitStageUnstageCommitUsesLiteralScopedPaths() async throws {
        let root = try temporary()
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        _ = try await Repository.run(["config", "user.name", "Test"], at: root.path)
        _ = try await Repository.run(["config", "user.email", "test@example.invalid"], at: root.path)
        for name in ["a[1].txt", "a1.txt"] { try name.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try await Repository.stage(at: root.path, path: "a[1].txt")
        var status = try await Repository.status(at: root.path)
        XCTAssertEqual(status.files.first { $0.path == "a[1].txt" }?.indexStatus, "A")
        XCTAssertEqual(status.files.first { $0.path == "a1.txt" }?.status, "??")
        try await Repository.unstage(at: root.path, path: "a[1].txt")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a[1].txt"), encoding: .utf8), "a[1].txt")
        try await Repository.stage(at: root.path, path: "a[1].txt")
        try await Repository.commit(at: root.path, message: "Literal file")
        try "changed".write(to: root.appendingPathComponent("a[1].txt"), atomically: true, encoding: .utf8)
        try await Repository.stage(at: root.path, path: "a[1].txt")
        try await Repository.unstage(at: root.path, path: "a[1].txt")
        status = try await Repository.status(at: root.path)
        XCTAssertEqual(status.files.first { $0.path == "a[1].txt" }?.indexStatus, " ")
        XCTAssertEqual(status.files.first { $0.path == "a[1].txt" }?.worktreeStatus, "M")
        let diff = try await Repository.diff(at: root.path, path: "a[1].txt")
        XCTAssertTrue(diff.contains("+changed"))
        XCTAssertFalse(diff.contains("a1.txt"))
        try await Repository.stage(at: root.path, path: "a[1].txt")
        try "a[1].txt".write(to: root.appendingPathComponent("a[1].txt"), atomically: true, encoding: .utf8)
        let staged = try await Repository.diff(at: root.path, path: "a[1].txt", stagedOnly: true)
        XCTAssertTrue(staged.contains("+changed"))
        let combined = try await Repository.diff(at: root.path, path: "a[1].txt")
        XCTAssertFalse(combined.contains("+changed"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("a[1].txt"))
        try await Repository.stage(at: root.path, path: "a[1].txt")
        let deleted = try await Repository.diff(at: root.path, path: "a[1].txt")
        XCTAssertTrue(deleted.contains("-a[1].txt"))
        let nested = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "inside".write(to: nested.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        try await Repository.stage(at: nested.path, path: "inside.txt")
        let nestedStatus = try await Repository.status(at: nested.path)
        XCTAssertEqual(nestedStatus.files.map(\.path), ["inside.txt"])
        do { try await Repository.commit(at: nested.path, message: "Outside index"); XCTFail("Committed outside nested project") } catch { }
        try await Repository.commit(at: root.path, message: "Finish staged changes")
        try FileManager.default.moveItem(at: nested.appendingPathComponent("inside.txt"), to: nested.appendingPathComponent("renamed.txt"))
        try await Repository.stage(at: nested.path, path: "inside.txt")
        try await Repository.stage(at: nested.path, path: "renamed.txt")
        let renamedStatus = try await Repository.status(at: nested.path)
        let renamed = try XCTUnwrap(renamedStatus.files.first)
        XCTAssertEqual(renamed.indexStatus, "R")
        XCTAssertEqual(renamed.originalPath, "inside.txt")
        try await Repository.unstage(at: nested.path, path: renamed.path, originalPath: renamed.originalPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("renamed.txt").path))
        do { try await Repository.stage(at: root.path, path: "../escape"); XCTFail("Escaped repository") } catch { }
    }
}
