import XCTest
@testable import CCodeCore

final class PullRequestTests: XCTestCase, @unchecked Sendable {
    // Wrong remote, implicit fork/push, body interpolation or HEAD drift must change these outcomes.
    func testPreviewAndCreateUseExactBodyAndExistingPRDoesNotCreateAgain() async throws {
        let f = try await fixture()
        let preview = try await f.service.preview(at: f.root.path, remote: "origin", base: "main", title: "Fix shell `literal`", body: "Line one\n$(touch injected)\n'quote'\n")
        XCTAssertEqual(preview.repository.slug, "github.com/ccode-fixture/project")
        XCTAssertEqual(preview.repository.branch, "feature/owned")
        XCTAssertTrue(preview.diff.contains("+feature"))
        XCTAssertEqual(preview.existing, nil)
        let pr = try await f.service.create(preview, push: false)
        XCTAssertEqual(pr.number, 41); XCTAssertEqual(pr.state, .open)
        XCTAssertEqual(try String(contentsOf: f.dir.appendingPathComponent("body.txt"), encoding: .utf8), preview.body)
        let audit = try f.audit()
        let create = try XCTUnwrap(audit.first { $0.prefix(2) == ["pr", "create"] })
        XCTAssertTrue(create.contains("--body-file")); XCTAssertTrue(create.contains("feature/owned"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: create[try XCTUnwrap(create.firstIndex(of: "--body-file")) + 1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("injected").path))
        let existing = try await f.service.preview(at: f.root.path, remote: "origin", base: "main", title: "Again", body: "Again")
        XCTAssertEqual(existing.existing?.number, 41)
        do { _ = try await f.service.create(existing, push: false); XCTFail("Duplicate creation") } catch {}
        XCTAssertEqual(try f.audit().filter { $0.prefix(2) == ["pr", "create"] }.count, 1)
    }

    func testBranchAndRemoteDriftRefuseBeforeExternalMutation() async throws {
        let f = try await fixture()
        let preview = try await f.preview()
        _ = try await Repository.run(["checkout", "main"], at: f.root.path)
        do { _ = try await f.service.create(preview, push: true); XCTFail("Stale branch") } catch {}
        _ = try await Repository.run(["checkout", "feature/owned"], at: f.root.path)
        _ = try await Repository.run(["remote", "set-url", "origin", "https://github.com/other/foreign.git"], at: f.root.path)
        do { _ = try await f.service.create(preview, push: true); XCTFail("Rebound remote") } catch {}
        XCTAssertFalse(try f.audit().contains { $0.prefix(2) == ["pr", "create"] })
    }

    func testMultipleRemotesAuthAndMissingCLIProduceActionableRefusal() async throws {
        let f = try await fixture()
        _ = try await Repository.run(["remote", "add", "second", "https://github.com/ccode-fixture/second.git"], at: f.root.path)
        do { _ = try await f.service.preview(at: f.root.path, title: "T", body: "B"); XCTFail("Must choose remote") } catch { XCTAssertTrue(error.localizedDescription.contains("remote")) }
        try f.mode("auth-error")
        do { _ = try await f.preview(); XCTFail("Expired authentication") } catch { XCTAssertTrue(error.localizedDescription.contains("auth")) }
        let missing = PullRequestService(executable: f.dir.appendingPathComponent("absent-gh").path)
        do { _ = try await missing.preview(at: f.root.path, remote: "origin", title: "T", body: "B"); XCTFail("Missing CLI") } catch {}
        XCTAssertFalse(try f.audit().contains { $0.prefix(2) == ["pr", "create"] })
    }

    func testFailedAndPendingChecksAreStatesAndLogsUseVerifiedRunIdentity() async throws {
        let f = try await fixture(), preview = try await f.preview()
        let pr = try await f.service.create(preview, push: false)
        try f.mode("failed")
        let failed = try await f.service.status(pr)
        XCTAssertEqual(failed.checks.map(\.bucket), [.fail])
        let logs = try await f.service.failureLogs(failed)
        XCTAssertTrue(logs.contains("AssertionError: expected 43"))
        XCTAssertTrue(logs.contains("unit"))
        try f.mode("pending")
        let pending = try await f.service.status(pr)
        XCTAssertEqual(pending.checks.map(\.bucket), [.pending])
        try f.mode("foreign-link")
        let foreign = try await f.service.status(pr)
        do { _ = try await f.service.failureLogs(foreign); XCTFail("Foreign workflow log identity") } catch {}
        XCTAssertEqual(try f.audit().filter { $0.prefix(2) == ["run", "view"] }.count, 1)
    }

    func testChangedPRHeadAndClosedPRCannotAuthorizeMerge() async throws {
        let f = try await fixture(), preview = try await f.preview()
        let pr = try await f.service.create(preview, push: false)
        try f.mode("changed-head")
        do { _ = try await f.service.merge(pr, method: .squash, auto: true); XCTFail("Changed head") } catch {}
        try f.mode("closed")
        do { _ = try await f.service.merge(pr, method: .squash, auto: true); XCTFail("Closed PR") } catch {}
        XCTAssertFalse(try f.audit().contains { $0.prefix(2) == ["pr", "merge"] })
    }

    func testAcceptedAutoMergeIsPendingUntilVerifiedMergedAndRestrictionsRefuse() async throws {
        let f = try await fixture(), preview = try await f.preview()
        let pr = try await f.service.create(preview, push: false)
        let waiting = try await f.service.merge(pr, method: .squash, auto: true)
        XCTAssertEqual(waiting.state, .open); XCTAssertTrue(waiting.autoMergeEnabled)
        let merge = try XCTUnwrap(try f.audit().first { $0.prefix(2) == ["pr", "merge"] })
        XCTAssertTrue(merge.contains("--auto")); XCTAssertTrue(merge.contains(pr.headSHA)); XCTAssertFalse(merge.contains("--admin"))
        try f.mode("merged")
        let merged = try await f.service.status(pr)
        XCTAssertEqual(merged.state, .merged)
        try f.mode("restricted")
        do { _ = try await f.service.merge(pr, method: .squash, auto: true); XCTFail("Repository restriction") } catch {}
        XCTAssertEqual(try f.audit().filter { $0.prefix(2) == ["pr", "merge"] }.count, 1)
    }

    func testCancellationAndDeadlineReapOwnedGHProcess() async throws {
        let f = try await fixture(timeout: .milliseconds(300))
        try f.mode("hang")
        do { _ = try await f.preview(); XCTFail("Command exceeded deadline") } catch {}
        if let pid = try? String(contentsOf: f.dir.appendingPathComponent("pid"), encoding: .utf8), let value = Int32(pid.trimmingCharacters(in: .whitespacesAndNewlines)) { XCTAssertEqual(kill(value, 0), -1) }
        let long = PullRequestService(executable: f.gh.path, environment: f.environment, commandTimeout: .seconds(30))
        let task = Task { try await long.preview(at: f.root.path, remote: "origin", title: "T", body: "B") }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled command returned preview") } catch {}
        if let pid = try? String(contentsOf: f.dir.appendingPathComponent("pid"), encoding: .utf8), let value = Int32(pid.trimmingCharacters(in: .whitespacesAndNewlines)) { XCTAssertEqual(kill(value, 0), -1) }
    }

    func testDisableAutoMergeConfirmsServerPolicyIsRemoved() async throws {
        let f = try await fixture(), preview = try await f.preview()
        let pr = try await f.service.create(preview, push: false)
        _ = try await f.service.merge(pr, method: .squash, auto: true)
        let disabled = try await f.service.disableAutoMerge(pr)
        XCTAssertFalse(disabled.autoMergeEnabled); XCTAssertEqual(disabled.state, .open)
        let calls = try f.audit().filter { $0.prefix(2) == ["pr", "merge"] }
        XCTAssertEqual(calls.count, 2); XCTAssertTrue(calls[1].contains("--disable-auto"))
    }
    func testRewrittenPushDestinationRefusesBeforePRMutation() async throws {
        let f = try await fixture(), preview = try await f.preview()
        _ = try await Repository.run(["config", "url.https://github.com/foreign/redirect.insteadOf", "https://github.com/ccode-fixture/project.git"], at: f.root.path)
        do { _ = try await f.service.create(preview, push: false); XCTFail("Hidden push rewrite") } catch {}
        XCTAssertFalse(try f.audit().contains { $0.prefix(2) == ["pr", "create"] })
    }
    func testPublishPushesExactPreviewedCommitIntoOwnedBareRepository() async throws {
        let f = try await fixture(), bare = f.dir.appendingPathComponent("published.git"), ssh = f.dir.appendingPathComponent("owned-ssh")
        _ = try await Repository.run(["init", "--bare", bare.path], at: f.root.path)
        _ = try await Repository.run(["remote", "set-url", "origin", "git@github.com:ccode-fixture/project.git"], at: f.root.path)
        try "#!/bin/sh\nexec /usr/bin/git-receive-pack \"$CCODE_PR_BARE\"\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let env = f.environment.merging(["GIT_SSH_COMMAND": ssh.path, "GIT_SSH_VARIANT": "simple", "CCODE_PR_BARE": bare.path]) { _, new in new }
        let service = PullRequestService(executable: f.gh.path, environment: env)
        let preview = try await service.preview(at: f.root.path, remote: "origin", base: "main", title: "Owned", body: "Body")
        let pr = try await service.create(preview, push: true)
        let published = try await Repository.run(["rev-parse", "refs/heads/feature/owned"], at: bare.path)
        XCTAssertEqual(published.trimmingCharacters(in: .whitespacesAndNewlines), preview.repository.headSHA)
        XCTAssertEqual(pr.headSHA, preview.repository.headSHA)
    }

    func testPublishExistingPRPushesNewCommitWithoutCreatingDuplicateAndRejectsStalePreview() async throws {
        let f = try await fixture(), bare = f.dir.appendingPathComponent("updated.git"), ssh = f.dir.appendingPathComponent("update-ssh")
        _ = try await Repository.run(["init", "--bare", bare.path], at: f.root.path)
        _ = try await Repository.run(["remote", "set-url", "origin", "git@github.com:ccode-fixture/project.git"], at: f.root.path)
        try "#!/bin/sh\nexec /usr/bin/git-receive-pack \"$CCODE_PR_BARE\"\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let env = f.environment.merging(["GIT_SSH_COMMAND": ssh.path, "GIT_SSH_VARIANT": "simple", "CCODE_PR_BARE": bare.path]) { _, new in new }
        let service = PullRequestService(executable: f.gh.path, environment: env)
        let first = try await service.preview(at: f.root.path, remote: "origin", base: "main", title: "Owned", body: "Body")
        let original = try await service.create(first, push: true)
        try "CI fixed\n".write(to: f.root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        _ = try await Repository.run(["add", "."], at: f.root.path)
        _ = try await Repository.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "Fix CI"], at: f.root.path)
        let second = try await service.preview(at: f.root.path, remote: "origin", base: "main", title: "Owned", body: "Body")
        XCTAssertEqual(second.existing?.headSHA, original.headSHA)
        let updated = try await service.publish(second)
        XCTAssertEqual(updated.number, original.number); XCTAssertEqual(updated.headSHA, second.repository.headSHA)
        XCTAssertNotEqual(updated.headSHA, original.headSHA)
        let published = try await Repository.run(["rev-parse", "refs/heads/feature/owned"], at: bare.path)
        XCTAssertEqual(published.trimmingCharacters(in: .newlines), second.repository.headSHA)
        XCTAssertEqual(try f.audit().filter { $0.prefix(2) == ["pr", "create"] }.count, 1)
        _ = try await Repository.run(["checkout", "main"], at: f.root.path)
        do { _ = try await service.publish(second); XCTFail("Publish from a stale local branch") } catch {}
        let after = try await Repository.run(["rev-parse", "refs/heads/feature/owned"], at: bare.path)
        XCTAssertEqual(after, published)
    }

    private func fixture(timeout: Duration = .seconds(10)) async throws -> Fixture {
        let value = try await Fixture.make(timeout: timeout)
        addTeardownBlock { try? FileManager.default.removeItem(at: value.dir) }
        return value
    }

    struct Fixture: Sendable {
        let dir: URL, root: URL, gh: URL, service: PullRequestService
        var environment: [String: String] { ["CCODE_PR_FIXTURE": dir.path] }
        func mode(_ value: String) throws { try value.write(to: dir.appendingPathComponent("mode"), atomically: true, encoding: .utf8) }
        func preview() async throws -> PullRequestPreview { try await service.preview(at: root.path, remote: "origin", base: "main", title: "Owned title", body: "Owned body\n") }
        func audit() throws -> [[String]] { try String(contentsOf: dir.appendingPathComponent("audit"), encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) } }
        static func make(timeout: Duration = .seconds(10)) async throws -> Fixture {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-pr-\(UUID())"), root = dir.appendingPathComponent("project"), gh = dir.appendingPathComponent("gh")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try await Repository.run(["init", "-b", "main"], at: root.path)
            try "initial\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            _ = try await Repository.run(["add", "."], at: root.path)
            _ = try await Repository.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "Initial"], at: root.path)
            _ = try await Repository.run(["checkout", "-b", "feature/owned"], at: root.path)
            try "feature\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
            _ = try await Repository.run(["add", "."], at: root.path)
            _ = try await Repository.run(["-c", "user.name=QA", "-c", "user.email=qa@example.invalid", "commit", "-m", "Feature"], at: root.path)
            _ = try await Repository.run(["remote", "add", "origin", "https://github.com/ccode-fixture/project.git"], at: root.path)
            try "".write(to: dir.appendingPathComponent("audit"), atomically: true, encoding: .utf8)
            try script.write(to: gh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
            return Fixture(dir: dir, root: root, gh: gh, service: PullRequestService(executable: gh.path, environment: ["CCODE_PR_FIXTURE": dir.path], commandTimeout: timeout))
        }
        private static let script = #"""
#!/usr/bin/python3
import json, os, pathlib, subprocess, sys, time
p = pathlib.Path(os.environ['CCODE_PR_FIXTURE']); a = sys.argv[1:]
with (p/'audit').open('a') as out: out.write(json.dumps(a)+'\n')
m = (p/'mode').read_text() if (p/'mode').exists() else ''
if m == 'hang':
 (p/'pid').write_text(str(os.getpid())); time.sleep(60); sys.exit(9)
if a[:2] == ['auth','status']:
 if m == 'auth-error': print('authentication expired'); sys.exit(4)
 sys.exit(0)
if a[:2] == ['repo','view']:
 print(json.dumps({'nameWithOwner':'ccode-fixture/project','url':'https://github.com/ccode-fixture/project','defaultBranchRef':{'name':'main'},'viewerPermission':'WRITE','mergeCommitAllowed':True,'squashMergeAllowed':m!='restricted','rebaseMergeAllowed':True})); sys.exit(0)
head = subprocess.check_output(['/usr/bin/git','rev-parse','feature/owned'],cwd=p/'project',text=True).strip()
base = subprocess.check_output(['/usr/bin/git','rev-parse','main'],cwd=p/'project',text=True).strip()
if os.environ.get('CCODE_PR_BARE'):
 try: head = subprocess.check_output(['/usr/bin/git','rev-parse','refs/heads/feature/owned'],cwd=os.environ['CCODE_PR_BARE'],text=True,stderr=subprocess.DEVNULL).strip()
 except subprocess.CalledProcessError: pass
pr = {'number':41,'url':'https://github.com/ccode-fixture/project/pull/41','title':'Owned title','body':'Owned body\n','state':'MERGED' if m=='merged' else 'CLOSED' if m=='closed' else 'OPEN','headRefName':'feature/owned','headRefOid':'f'*40 if m=='changed-head' else head,'baseRefName':'main','baseRefOid':base,'headRepository':{'name':'project'},'headRepositoryOwner':{'login':'ccode-fixture'},'isCrossRepository':False,'isDraft':False,'autoMergeRequest':{'enabledAt':'2026-10-05T00:00:00Z'} if (p/'auto').exists() else None,'mergeCommit':{'oid':'a'*40} if m=='merged' else None,'mergedAt':'2026-10-05T00:00:00Z' if m=='merged' else None}
if a[0] == 'api':
 print(json.dumps({'commit':{'sha':base if a[1].endswith('/main') else head}})); sys.exit(0)
if a[:2] == ['pr','list']: print(json.dumps([pr] if (p/'created').exists() else [])); sys.exit(0)
if a[:2] == ['pr','create']:
 if m == 'create-hang':
  (p/'created').touch(); (p/'pid').write_text(str(os.getpid())); time.sleep(60); sys.exit(9)
 assert a[a.index('--repo')+1]=='github.com/ccode-fixture/project'
 assert a[a.index('--head')+1]=='feature/owned' and a[a.index('--base')+1]=='main'
 (p/'body.txt').write_bytes(pathlib.Path(a[a.index('--body-file')+1]).read_bytes()); (p/'created').touch(); print(pr['url']); sys.exit(0)
if a[:2] == ['pr','view']: print(json.dumps(pr)); sys.exit(0)
if a[:2] == ['pr','checks']:
 bucket = 'fail' if m in ['failed','foreign-link'] else 'pending' if m=='pending' else 'pass'
 link = 'https://github.com/other/foreign/actions/runs/900/jobs/901' if m=='foreign-link' else 'https://github.com/ccode-fixture/project/actions/runs/900/jobs/901'
 print(json.dumps([{'name':'unit','bucket':bucket,'state':'FAILURE' if bucket=='fail' else 'PENDING' if bucket=='pending' else 'SUCCESS','link':link,'workflow':'Tests','description':'','event':'pull_request','startedAt':'2026-10-05T00:00:00Z','completedAt':''}])); sys.exit(1 if bucket=='fail' else 8 if bucket=='pending' else 0)
if a[:2] == ['run','view']:
 assert a[2]=='900' and '--log-failed' in a
 print('unit: AssertionError: expected 43'); sys.exit(0)
if a[:2] == ['pr','merge']:
 assert a[a.index('--match-head-commit')+1] == head and '--admin' not in a
 if '--disable-auto' in a:
  if (p/'auto').exists(): (p/'auto').unlink()
 else: (p/'auto').touch()
 sys.exit(0)
print('unexpected argv: '+repr(a)); sys.exit(99)
"""#
    }
}
