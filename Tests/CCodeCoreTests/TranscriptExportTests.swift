import XCTest
import CCodeCore

final class TranscriptExportTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-export-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testExportRetainsNestedToolsTasksContextAndPortableSnapshotsWithoutUnsentDrafts() async throws {
        let root = try directory(), storage = SessionStorage(directory: root.appendingPathComponent("data"))
        let original = root.appendingPathComponent("context (copy).txt")
        try Data("immutable context ✓\n".utf8).write(to: original)
        let attachment = try await storage.importAttachment(original)
        try FileManager.default.removeItem(at: original)
        var transcript = SessionTranscript(remoteID: "root")
        transcript.appendUser("Inspect context", attachments: [attachment], startedSession: true)
        transcript.items[0].deliveryState = .acknowledged
        transcript.items.append(TranscriptItem(kind: "assistant", text: "Root report"))
        transcript.items.append(TranscriptItem(kind: "subagent", tool: ["subagentSessionId": "child"]))
        transcript.draftText = "UNSENT_PRIVATE_DRAFT"
        transcript.editorDrafts = ["private.txt": EditorDraft(original: "", text: "UNSENT_EDITOR_DRAFT")]
        var child = SubagentSession(id: "child", parentID: "root")
        child.name = "Explorer"; child.state = "completed"
        child.transcript.items = [TranscriptItem(kind: "tool", tool: ["toolCallId": "same", "title": "Bash", "rawInput": ["command": "printf child"], "rawOutput": "child result\n```\n", "status": "completed"]), TranscriptItem(kind: "subagent", tool: ["subagentSessionId": "grandchild"])]
        var grandchild = SubagentSession(id: "grandchild", parentID: "child")
        grandchild.name = "Tester"; grandchild.state = "cancelled"
        grandchild.transcript.items = [TranscriptItem(kind: "assistant", text: "Nested report"), TranscriptItem(kind: "tool", tool: ["toolCallId": "same", "title": "Read", "rawOutput": "nested tool result"])]
        transcript.subagents = [child, grandchild]
        var task = AgentAsyncTask(id: AsyncTaskIdentity(owner: "grandchild", task: "job"))
        task.state = .stopped; task.description = "nested check"
        transcript.asyncTasks = [task]; transcript.plan = [["content": "Verify result", "status": "completed"]]
        let before = try JSONEncoder().encode(transcript)
        let sessionID = UUID()
        try await storage.save(transcript, id: sessionID)
        let persisted = try await storage.load(sessionID)
        let output = root.appendingPathComponent("Conversation (copy) #100%20.md")
        let result = try await storage.exportTranscript(persisted, title: "Export proof", to: output)
        let markdown = try String(contentsOf: output, encoding: .utf8)
        for expected in ["Inspect context", "Root report", "Explorer", "Tester", "Nested report", "printf child", "child result", "nested tool result", "nested check", "stopped", "Verify result"] { XCTAssertTrue(markdown.contains(expected), expected) }
        XCTAssertFalse(markdown.contains("UNSENT_PRIVATE_DRAFT")); XCTAssertFalse(markdown.contains("UNSENT_EDITOR_DRAFT"))
        XCTAssertTrue(markdown.contains("Delivery: acknowledged"))
        let assets = try XCTUnwrap(result.assetsDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(files.first), encoding: .utf8), "immutable context ✓\n")
        XCTAssertTrue(markdown.contains(attachment.id.uuidString)); XCTAssertFalse(markdown.contains(original.absoluteString))
        let expression = try NSRegularExpression(pattern: "\\]\\(([^)]+)\\)")
        let matching = try XCTUnwrap(expression.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).first { match in
            guard let range = Range(match.range(at: 1), in: markdown) else { return false }
            return markdown[range].contains(attachment.id.uuidString)
        })
        let range = try XCTUnwrap(Range(matching.range(at: 1), in: markdown))
        let linked = try XCTUnwrap(URL(string: String(markdown[range]), relativeTo: output)?.absoluteURL)
        XCTAssertEqual(try String(contentsOf: linked, encoding: .utf8), "immutable context ✓\n", "The exported Markdown link resolves even with spaces, parentheses, hash and percent in its filename")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(transcript)), try JSONDecoder().decode(JSONValue.self, from: before))
    }
    func testImportedResourceReferencesCannotReadArbitraryLocalFiles() async throws {
        let root = try directory(), storage = SessionStorage(directory: root.appendingPathComponent("data"))
        let privateFile = root.appendingPathComponent("private.txt")
        try Data("DO_NOT_COPY_PRIVATE_FILE".utf8).write(to: privateFile)
        var transcript = SessionTranscript(remoteID: "root")
        transcript.items = [TranscriptItem(kind: "user", text: "Imported reference", blocks: [["type": "resource_link", "uri": .string(privateFile.absoluteString), "name": "Reference"]])]
        let output = root.appendingPathComponent("imported.md")
        let result = try await storage.exportTranscript(transcript, title: "References", to: output)
        let markdown = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Imported reference")); XCTAssertTrue(markdown.contains("Reference"))
        XCTAssertFalse(markdown.contains("DO_NOT_COPY_PRIVATE_FILE")); XCTAssertNil(result.assetsDirectory)
        XCTAssertEqual(try String(contentsOf: privateFile, encoding: .utf8), "DO_NOT_COPY_PRIVATE_FILE")
    }
    func testMissingSnapshotLeavesExistingExportAndDestinationDirectoryUntouched() async throws {
        let root = try directory(), storage = SessionStorage(directory: root.appendingPathComponent("data"))
        let original = root.appendingPathComponent("context.txt")
        try Data("context".utf8).write(to: original)
        let attachment = try await storage.importAttachment(original)
        try await storage.discardAttachment(attachment)
        var transcript = SessionTranscript(remoteID: "root")
        transcript.appendUser("Context", attachments: [attachment])
        let output = root.appendingPathComponent("existing.md")
        try Data("existing export".utf8).write(to: output)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        do { _ = try await storage.exportTranscript(transcript, title: "Failure", to: output); XCTFail("Missing snapshot must not produce a successful partial export") }
        catch { }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "existing export")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), names)
    }
    func testMalformedChildLineageCannotHangOrOverwriteAnExport() async throws {
        let root = try directory(), storage = SessionStorage(directory: root.appendingPathComponent("data"))
        for children in [[SubagentSession(id: "a", parentID: "b"), SubagentSession(id: "b", parentID: "a")], [SubagentSession(id: "a", parentID: "root"), SubagentSession(id: "a", parentID: "root")], [SubagentSession(id: "a", parentID: "missing")]] {
            var transcript = SessionTranscript(remoteID: "root"); transcript.subagents = children
            let output = root.appendingPathComponent("malformed.md")
            try Data("preserve".utf8).write(to: output)
            do { _ = try await storage.exportTranscript(transcript, title: "Malformed", to: output); XCTFail("Invalid lineage") }
            catch { }
            XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "preserve")
        }
    }
    func testPublishFailureCleansOnlyItsNewAssetsAndPreservesExistingDirectory() async throws {
        let root = try directory(), storage = SessionStorage(directory: root.appendingPathComponent("data"))
        let original = root.appendingPathComponent("context.txt")
        try Data("context".utf8).write(to: original)
        let attachment = try await storage.importAttachment(original)
        var transcript = SessionTranscript(remoteID: "root"); transcript.appendUser("Context", attachments: [attachment])
        let destination = root.appendingPathComponent("existing-directory.md")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let unrelated = destination.appendingPathComponent("preserve.txt")
        try Data("unrelated".utf8).write(to: unrelated)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        do { _ = try await storage.exportTranscript(transcript, title: "Failure", to: destination); XCTFail("Cannot replace a directory with an export") }
        catch { }
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "unrelated")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), names)
    }
    func testRealNativeDelegatedHistoryExportPreservesSourceWithoutStartingAgent() async throws {
        guard let path = ProcessInfo.processInfo.environment["CCODE_REAL_DELEGATED_HISTORY_DIRECTORY"] else { throw XCTSkip("Set CCODE_REAL_DELEGATED_HISTORY_DIRECTORY to the disposable child-Stop proof.") }
        let source = URL(fileURLWithPath: path)
        guard source.lastPathComponent.contains("ccode-real-child-stop-") else { throw XCTSkip("Export only the controlled child-Stop history.") }
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil })
        let id = file.deletingPathExtension().lastPathComponent
        let childFolder = source.appendingPathComponent(id + "/subagents")
        let children = (try? FileManager.default.contentsOfDirectory(at: childFolder, includingPropertiesForKeys: nil)) ?? []
        let files = [file] + children.filter { $0.pathExtension == "jsonl" || $0.lastPathComponent.hasSuffix(".meta.json") }
        let original = try files.map { try Data(contentsOf: $0) }
        let native = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: id, cwd: "/unavailable/disposable/project", configurationDirectory: source.deletingLastPathComponent().deletingLastPathComponent()))
        let root = try directory(), storage = SessionStorage(directory: root.appendingPathComponent("data"))
        let output = root.appendingPathComponent("actual.md")
        _ = try await storage.exportTranscript(native, title: "Actual delegated history", to: output)
        let markdown = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(markdown.contains("child-stop-proof.txt")); XCTAssertTrue(markdown.contains("cancelled"))
        for child in native.subagents ?? [] { XCTAssertTrue(markdown.contains(child.name)) }
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, original)
    }
}
