import XCTest
import CCodeCore
import Darwin

final class AsyncTaskTests: XCTestCase {
    private func event(_ owner: String = "root", _ kind: String, _ value: JSONValue) -> JSONValue {
        var update = value; update["sessionUpdate"] = .string(kind)
        return ["sessionId": .string(owner), "update": update]
    }
    func testAsyncTasksKeepOwnerIdentityAndDoNotInventTranscriptCards() throws {
        var transcript = SessionTranscript(remoteID: "root"), children: Set<String> = [], tasks: Set<AsyncTaskIdentity> = []
        XCTAssertTrue(transcript.applyAgentWork(event("root", "subagent_spawned", ["subagentSessionId": "child"]), owners: &children))
        XCTAssertTrue(transcript.applyAsyncWork(event("root", "async_task_spawned", ["asyncTaskId": "same", "name": "Build", "taskType": "local_bash", "showInTranscript": false, "canStop": true]), children: children, owners: &tasks))
        XCTAssertTrue(transcript.applyAsyncWork(event("child", "async_task_spawned", ["asyncTaskId": "same", "name": "Child check", "taskType": "local_bash", "showInTranscript": true]), children: children, owners: &tasks))
        XCTAssertEqual(transcript.asyncTasks?.count, 2)
        XCTAssertEqual(transcript.items.filter { $0.kind == "async_task" }.count, 0)
        XCTAssertEqual(transcript.subagent("child")?.transcript.items.filter { $0.kind == "async_task" }.count, 1)
        let root = AsyncTaskIdentity(owner: "root", task: "same"), child = AsyncTaskIdentity(owner: "child", task: "same")
        XCTAssertTrue(transcript.applyAsyncWork(event("child", "async_task_progress", ["asyncTaskId": "same", "summary": "One test done", "lastToolName": "Bash", "usage": ["totalTokens": 17], "outputFilePath": "/tmp/child.output"]), children: children, owners: &tasks))
        XCTAssertEqual(transcript.asyncTask(child)?.summary, "One test done")
        XCTAssertNil(transcript.asyncTask(root)?.summary)
        XCTAssertFalse(transcript.applyAsyncWork(event("foreign", "async_task_spawned", ["asyncTaskId": "same"]), children: children, owners: &tasks))
        XCTAssertFalse(transcript.applyAsyncWork(event("root", "async_task_progress", ["asyncTaskId": "unknown"]), children: children, owners: &tasks))
        XCTAssertTrue(transcript.applyAsyncWork(event("child", "async_task_state_update", ["asyncTaskId": "same", "state": "completed", "summary": "All tests passed"]), children: children, owners: &tasks))
        XCTAssertFalse(transcript.asyncTask(child)?.isRunning ?? true)
        XCTAssertTrue(transcript.asyncTask(root)?.isRunning ?? false)
    }
    func testDuplicateTerminalSpawnAndRestartCannotBorrowControlOwnership() throws {
        var transcript = SessionTranscript(remoteID: "root"), owners: Set<AsyncTaskIdentity> = []
        let spawn = event("root", "async_task_spawned", ["asyncTaskId": "job", "showInTranscript": true, "canStop": true])
        XCTAssertTrue(transcript.applyAsyncWork(spawn, children: [], owners: &owners))
        XCTAssertTrue(transcript.applyAsyncWork(event("root", "async_task_state_update", ["asyncTaskId": "job", "state": "failed", "summary": "Build failed"]), children: [], owners: &owners))
        XCTAssertTrue(transcript.applyAsyncWork(spawn, children: [], owners: &owners))
        XCTAssertEqual(transcript.asyncTasks?.first?.state, .failed)
        XCTAssertEqual(transcript.items.filter { $0.kind == "async_task" }.count, 1)
        let identity = AsyncTaskIdentity(owner: "root", task: "job")
        XCTAssertTrue(transcript.applyAsyncWork(event("root", "async_task_spawned", ["asyncTaskId": "live", "canStop": true]), children: [], owners: &owners))
        transcript.disconnectAsyncTasks()
        let decoded = try JSONDecoder().decode(SessionTranscript.self, from: JSONEncoder().encode(transcript))
        XCTAssertEqual(decoded.asyncTask(identity)?.state, .failed)
        XCTAssertEqual(decoded.asyncTasks?.last?.state, .disconnected)
        var restored = decoded, freshOwners: Set<AsyncTaskIdentity> = []
        XCTAssertFalse(restored.applyAsyncWork(event("root", "async_task_progress", ["asyncTaskId": "live", "summary": "Old callback"]), children: [], owners: &freshOwners))
        XCTAssertTrue(restored.applyAsyncWork(event("root", "async_task_spawned", ["asyncTaskId": "live", "canStop": true]), children: [], owners: &freshOwners))
        XCTAssertEqual(restored.asyncTasks?.last?.state, .running)
        XCTAssertTrue(restored.applyAsyncWork(event("root", "async_task_state_update", ["asyncTaskId": "live", "state": "stopped"]), children: [], owners: &freshOwners))
        XCTAssertFalse(restored.applyAsyncWork(event("root", "async_task_state_update", ["asyncTaskId": "live", "state": "invented"]), children: [], owners: &freshOwners))
    }
    func testTaskOutputReadsBoundedTailAndRejectsSymlinkOrMissingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("job.output")
        try Data((String(repeating: "old line\n", count: 100) + "final: café ✓\n").utf8).write(to: output)
        let tail = try AsyncTaskOutput.read(path: output.path, maximumBytes: 64)
        XCTAssertTrue(tail.truncated)
        XCTAssertLessThanOrEqual(tail.text.utf8.count, 66)
        XCTAssertTrue(tail.text.hasSuffix("final: café ✓\n"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: output)
        XCTAssertThrowsError(try AsyncTaskOutput.read(path: link.path))
        XCTAssertThrowsError(try AsyncTaskOutput.read(path: root.appendingPathComponent("absent").path))
    }
    func testOlderOutputWindowsRemainReachableWhileTheFileGrows() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let text = String(repeating: "0123456789", count: 30)
        try Data(text.utf8).write(to: path)
        let latest = try AsyncTaskOutput.read(path: path.path, maximumBytes: 100)
        XCTAssertEqual(latest.offset, 200)
        XCTAssertEqual(latest.fileSize, 300)
        let older = try AsyncTaskOutput.read(path: path.path, maximumBytes: 100, endingAt: latest.offset)
        let first = try AsyncTaskOutput.read(path: path.path, maximumBytes: 100, endingAt: older.offset)
        XCTAssertEqual(first.offset, 0)
        XCTAssertEqual(first.text + older.text + latest.text, text)
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("new output".utf8)); try handle.close()
        let stable = try AsyncTaskOutput.read(path: path.path, maximumBytes: 100, endingAt: older.offset + UInt64(older.byteCount))
        XCTAssertEqual(stable.text, older.text)
        XCTAssertEqual(stable.fileSize, 310)
        let followed = try AsyncTaskOutput.read(path: path.path, maximumBytes: 100)
        XCTAssertTrue(followed.text.hasSuffix("new output"))
        XCTAssertEqual(followed.byteCount, 100)
    }
    @MainActor func testNonRegularOutputCannotHangAReader() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        defer {
            // Release a blocked old reader after the observed timeout, so this regression never leaks it.
            let writer = open(path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            try? FileManager.default.removeItem(atPath: path)
        }
        let rejected = expectation(description: "Reject FIFO without waiting for a writer")
        DispatchQueue.global().async {
            do { _ = try AsyncTaskOutput.read(path: path); XCTFail("FIFO output must be rejected") }
            catch { }
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 0.5)
    }
    func testHistoricalOutputRequiresExactSDKIdentityAndRejectsAncestorAndLeafLinks() throws {
        let session = UUID().uuidString
        let root = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())/ccode-output-reader-\(UUID())")
        let tasks = root.appendingPathComponent(session + "/tasks")
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = tasks.appendingPathComponent("job.output")
        try Data((String(repeating: "0123456789", count: 20_000) + "tail\n").utf8).write(to: file)
        let tail = try AsyncTaskOutput.readClaudeHistory(path: file.path, taskID: "job", rootID: session)
        XCTAssertEqual(tail.byteCount, 64 * 1024); XCTAssertTrue(tail.text.hasSuffix("tail\n"))
        let page = try AsyncTaskOutput.readClaudeHistory(path: file.path, taskID: "job", rootID: session, endingAt: tail.offset)
        XCTAssertEqual(page.offset + UInt64(page.byteCount), tail.offset)
        let alias = try AsyncTaskOutput.readClaudeHistory(path: file.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"), taskID: "job", rootID: session)
        XCTAssertEqual(alias.text, tail.text)
        for (path, task, owner) in [(file.path, "other", session), (file.path, "job", UUID().uuidString), (file.path, "../job", session), (file.path, "job", "invalid"), (tasks.path + "/../tasks/job.output", "job", session), (file.path.replacingOccurrences(of: "claude-\(getuid())", with: "claude-\(getuid() + 1)"), "job", session)] {
            XCTAssertThrowsError(try AsyncTaskOutput.readClaudeHistory(path: path, taskID: task, rootID: owner))
        }
        let link = tasks.appendingPathComponent("link.output")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try AsyncTaskOutput.readClaudeHistory(path: link.path, taskID: "link", rootID: session))
        let real = root.appendingPathComponent(session + "/original")
        try FileManager.default.moveItem(at: tasks, to: real)
        try FileManager.default.createSymbolicLink(at: tasks, withDestinationURL: real)
        XCTAssertThrowsError(try AsyncTaskOutput.readClaudeHistory(path: file.path, taskID: "job", rootID: session))
    }
}
