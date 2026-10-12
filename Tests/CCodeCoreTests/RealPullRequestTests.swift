import XCTest
@testable import CCodeCore

final class RealPullRequestTests: XCTestCase, @unchecked Sendable {
    // Live, read-only CLI integration. Never creates/pushes/merges a remote PR.
    func testAuthenticatedGitHubStatusUsesActualPRAndCheckSchema() async throws {
        guard let slug = ProcessInfo.processInfo.environment["CCODE_REAL_PR_REPO"],
              let numberText = ProcessInfo.processInfo.environment["CCODE_REAL_PR_NUMBER"], let number = Int(numberText), number > 0 else { throw XCTSkip("Set CCODE_REAL_PR_REPO and CCODE_REAL_PR_NUMBER for authenticated read-only proof.") }
        let pieces = slug.split(separator: "/").map(String.init)
        guard pieces.count == 2 else { throw ACPError.workspace("Use owner/repository.") }
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ccode-real-pr-\(UUID())"), root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cli = TerminalService()
        let id = try await cli.create(command: "/opt/homebrew/bin/gh", arguments: ["pr", "view", numberText, "--repo", slug, "--json", "number,url,title,body,state,headRefName,headRefOid,baseRefName,baseRefOid,isCrossRepository"], directory: root.path)
        defer { Task { await cli.close() } }
        let exit = try await cli.wait(id), output = try await cli.output(id)
        guard exit["exitCode"].int == 0, !output["truncated"].bool else { throw ACPError.workspace("Actual GitHub PR read failed.") }
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(output["output"].string.utf8))
        guard !value["isCrossRepository"].bool else { throw XCTSkip("Select a same-repository head for this integration proof.") }
        _ = try await Repository.run(["init", "-b", value["headRefName"].string], at: root.path)
        _ = try await Repository.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "--allow-empty", "-m", "Owned read-only fixture"], at: root.path)
        _ = try await Repository.run(["remote", "add", "origin", "https://github.com/" + slug + ".git"], at: root.path)
        let canonical = try Workspace(root: root.path).root
        let git = try await Repository.run(["rev-parse", "--absolute-git-dir"], at: canonical).trimmingCharacters(in: .newlines)
        let repository = PullRequestRepository(directory: canonical, gitDirectory: git, remote: "origin", remoteURL: "https://github.com/" + slug + ".git", host: "github.com", owner: pieces[0], name: pieces[1], branch: value["headRefName"].string, headSHA: value["headRefOid"].string, base: value["baseRefName"].string, baseSHA: value["baseRefOid"].string)
        let seed = PullRequest(repository: repository, number: number, url: value["url"].string, title: value["title"].string, body: value["body"].string, state: .open, headSHA: value["headRefOid"].string, baseSHA: value["baseRefOid"].string, autoMergeEnabled: false, mergeSHA: nil, checks: [])
        let service = PullRequestService()
        let actual = try await service.status(seed)
        XCTAssertEqual(actual.number, number); XCTAssertEqual(actual.url, "https://github.com/\(slug)/pull/\(number)")
        XCTAssertEqual(actual.headSHA, value["headRefOid"].string); XCTAssertFalse(actual.checks.isEmpty)
        // This fixture intentionally lacks the public remote commit locally: read access cannot grant a write.
        do { _ = try await service.merge(actual, method: .squash, auto: true); XCTFail("Remote mutation accepted from a different local HEAD") } catch {}
        try JSONEncoder().encode(actual).write(to: base.appendingPathComponent("verified-status.json"), options: .atomic)
        print("READ_ONLY_PR_PROOF=\(base.path)")
    }
}
