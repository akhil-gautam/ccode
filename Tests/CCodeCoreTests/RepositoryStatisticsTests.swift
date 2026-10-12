import XCTest
import AppKit
import SwiftUI
@testable import CCodeCore
@testable import CCode

final class RepositoryStatisticsTests: XCTestCase, @unchecked Sendable {
    private func repository(commit: Bool = true) async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-statistics-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        if commit {
            try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("text.txt"), atomically: true, encoding: .utf8)
            try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.bin"))
            try await Repository.stage(at: root.path, path: "text.txt"); try await Repository.stage(at: root.path, path: "binary.bin")
            _ = try await Repository.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "Initial"], at: root.path)
        }
        return root
    }
    func testAllAndStagedCountsUseTheirActualSourcesAndIncludeUntracked() async throws {
        let root = try await repository(), file = root.appendingPathComponent("text.txt")
        try "one\nstaged\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try await Repository.stage(at: root.path, path: "text.txt")
        try "one\nworking\nthree\nextra\n".write(to: file, atomically: true, encoding: .utf8)
        try "fresh\nlast".write(to: root.appendingPathComponent("fresh\tline\n界.txt"), atomically: true, encoding: .utf8)
        try Data([0, 3, 4]).write(to: root.appendingPathComponent("binary.bin"))
        let all = try await Repository.changeStatistics(at: root.path)
        XCTAssertEqual(all["text.txt"], FileChangeStatistics(additions: 2, deletions: 1))
        XCTAssertEqual(all["fresh\tline\n界.txt"], FileChangeStatistics(additions: 2, deletions: 0))
        XCTAssertEqual(all["binary.bin"], FileChangeStatistics(additions: nil, deletions: nil))
        let staged = try await Repository.changeStatistics(at: root.path, stagedOnly: true)
        XCTAssertEqual(staged, ["text.txt": FileChangeStatistics(additions: 1, deletions: 1)])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one\nworking\nthree\nextra\n")
    }
    func testUnbornAndAddedThenDeletedCountsDoNotDoubleCountIndex() async throws {
        let root = try await repository(commit: false), file = root.appendingPathComponent("new.txt")
        try "staged\n".write(to: file, atomically: true, encoding: .utf8)
        try await Repository.stage(at: root.path, path: "new.txt")
        try "working\nextra\n".write(to: file, atomically: true, encoding: .utf8)
        let all = try await Repository.changeStatistics(at: root.path), staged = try await Repository.changeStatistics(at: root.path, stagedOnly: true)
        XCTAssertEqual(all["new.txt"], FileChangeStatistics(additions: 2, deletions: 0))
        XCTAssertEqual(staged["new.txt"], FileChangeStatistics(additions: 1, deletions: 0))
        try FileManager.default.removeItem(at: file)
        let deleted = try await Repository.changeStatistics(at: root.path)
        XCTAssertEqual(deleted["new.txt"], FileChangeStatistics(additions: 0, deletions: 0))
    }
    func testRenameNulRecordsAndDeletedFilesHaveOneDestinationIdentity() async throws {
        let root = try await repository(), name = "renamed\twith\n界.txt"
        _ = try await Repository.run(["mv", "--", "text.txt", name], at: root.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("binary.bin"))
        let stats = try await Repository.changeStatistics(at: root.path)
        XCTAssertEqual(stats[name], FileChangeStatistics(additions: 0, deletions: 0))
        XCTAssertNil(stats["text.txt"])
        XCTAssertEqual(stats["binary.bin"], FileChangeStatistics(additions: nil, deletions: nil))
        let staged = try await Repository.changeStatistics(at: root.path, stagedOnly: true)
        XCTAssertEqual(staged, [name: FileChangeStatistics(additions: 0, deletions: 0)])
    }
    func testNestedRepositoryStatisticsStayInsideSelectedFolder() async throws {
        let root = try await repository(), nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "inside\n".write(to: nested.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        try "outside\n".write(to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        let stats = try await Repository.changeStatistics(at: nested.path)
        XCTAssertEqual(stats, ["inside.txt": FileChangeStatistics(additions: 1, deletions: 0)])
    }
    func testMetadataAndBinaryUntrackedAreNotGuessedLineCounts() async throws {
        let root = try await repository()
        _ = try await Repository.run(["config", "core.filemode", "true"], at: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("text.txt").path)
        try Data([0, 255, 1]).write(to: root.appendingPathComponent("fresh.bin"))
        let stats = try await Repository.changeStatistics(at: root.path)
        XCTAssertEqual(stats["text.txt"], FileChangeStatistics(additions: 0, deletions: 0))
        XCTAssertEqual(stats["fresh.bin"], FileChangeStatistics(additions: nil, deletions: nil))
    }
    @MainActor func testWorkspaceRefreshPublishesStatsWithoutChangingDrafts() async throws {
        let root = try await repository(), store = AppStore(directory: root.appendingPathComponent(".data"))
        addTeardownBlock { await store.shutdown() }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        chat.draft = "Unsent"; chat.fileDrafts["text.txt"] = FileDraft(original: "one\ntwo\nthree\n", text: "Editor buffer")
        try "one\nchanged\nthree\n".write(to: root.appendingPathComponent("text.txt"), atomically: true, encoding: .utf8)
        await store.refreshWorkspace(chat)
        await chat.workspaceStatisticsTask?.value
        XCTAssertEqual(chat.changeStatistics?["text.txt"], FileChangeStatistics(additions: 1, deletions: 1))
        XCTAssertNil(chat.changeStatisticsError)
        XCTAssertEqual(chat.draft, "Unsent"); XCTAssertEqual(chat.fileDrafts["text.txt"]?.text, "Editor buffer")
    }
    @MainActor func testRefreshReplacesOwnedCountTaskAndShutdownDrainsIt() async throws {
        let root = try await repository(), data = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-stats-data-\(UUID())")
        let store = AppStore(directory: data)
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: data) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected), file = root.appendingPathComponent("text.txt")
        try "one\nfirst\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        await store.refreshWorkspace(chat)
        let previous = chat.workspaceStatisticsTask
        try "one\nsecond\nthree\nextra\n".write(to: file, atomically: true, encoding: .utf8)
        await store.refreshWorkspace(chat)
        await chat.workspaceStatisticsTask?.value; await previous?.value
        XCTAssertEqual(chat.changeStatistics?["text.txt"], FileChangeStatistics(additions: 2, deletions: 1))
        await store.refreshWorkspace(chat)
        await store.shutdown()
        XCTAssertNil(chat.workspaceStatisticsTask)
        XCTAssertNil(chat.workspaceStatisticsID)
    }

    func testUntrackedLinkCannotCountOutsideWorkspaceAndEmptyFilesHaveZeroLines() async throws {
        let root = try await repository(), outside = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-stats-outside-\(UUID())")
        try "private outside\n".write(to: outside, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try Data().write(to: root.appendingPathComponent("empty.txt"))
        let empty = try await Repository.changeStatistics(at: root.path)
        XCTAssertEqual(empty["empty.txt"], FileChangeStatistics(additions: 0, deletions: 0))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: outside.path)
        do { _ = try await Repository.changeStatistics(at: root.path); XCTFail("Outside link cannot be read for counts") } catch {}
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private outside\n")
    }
    @MainActor func testCountLabelsFitCompactAndWideInLightAndDark() {
        for scheme in [ColorScheme.light, .dark] {
            for width: CGFloat in [180, 320] {
                for values in [[FileChangeStatistics(additions: nil, deletions: nil)], [FileChangeStatistics(additions: 124, deletions: 29), FileChangeStatistics(additions: nil, deletions: nil)]] {
                    let host = NSHostingView(rootView: ChangeStatisticsLabel(values: values).frame(width: width, alignment: .leading).environment(\.colorScheme, scheme))
                    XCTAssertGreaterThan(host.fittingSize.height, 10)
                    XCTAssertLessThan(host.fittingSize.height, 35, "Counts must stay on one line")
                    XCTAssertLessThanOrEqual(host.fittingSize.width, width)
                }
            }
        }
    }

}
