import XCTest
import CCodeCore
import Darwin

final class ClaudeTranscriptTests: XCTestCase {
    private func childFile(rootFile: URL, agent: String, tool: String, records: [JSONValue], stopped: Bool = false) throws -> URL {
        let folder = rootFile.deletingLastPathComponent().appendingPathComponent(sessionID + "/subagents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let metadata: JSONValue = ["toolUseId": .string(tool), "stoppedByUser": .bool(stopped)]
        try JSONEncoder().encode(metadata).write(to: folder.appendingPathComponent("agent-" + agent + ".meta.json"))
        let file = folder.appendingPathComponent("agent-" + agent + ".jsonl")
        var bytes = Data()
        for var record in records {
            record["sessionId"] = .string(sessionID); record["agentId"] = .string(agent); record["isSidechain"] = true
            bytes.append(try JSONEncoder().encode(record)); bytes.append(10)
        }
        try bytes.write(to: file)
        return file
    }
    func testDelegatedHistoryRestoresExactNestedOwnersToolsAndImmutableFiles() throws {
        let (root, file) = try fixture([
            ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Explore"]],
            ["type": "assistant", "uuid": "launch", "parentUuid": "u", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "launch-left", "name": "Agent", "input": ["name": "Explorer", "prompt": "Read the file"]]]]],
            ["type": "user", "uuid": "result", "parentUuid": "launch", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "launch-left", "content": "Explorer finished"]]]],
            ["type": "assistant", "uuid": "done", "parentUuid": "result", "message": ["role": "assistant", "content": "Root report"]]
        ])
        let left = try childFile(rootFile: file, agent: "left-agent", tool: "launch-left", records: [
            ["type": "user", "uuid": "cu", "parentUuid": nil, "message": ["role": "user", "content": "Read the file"]],
            ["type": "assistant", "uuid": "ca", "parentUuid": "cu", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "same-id", "name": "Read", "input": ["file_path": "/project/file.swift"]]]]],
            ["type": "user", "uuid": "cr", "parentUuid": "ca", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "same-id", "content": "Raw model copy"]]], "toolUseResult": ["type": "text", "file": ["content": "literal child file\n", "startLine": 3]]],
            ["type": "assistant", "uuid": "nested", "parentUuid": "cr", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "launch-nested", "name": "Task", "input": ["description": "Nested tester", "prompt": "Run a test"]]]]],
            ["type": "user", "uuid": "nested-result", "parentUuid": "nested", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "launch-nested", "is_error": true, "content": "Agent stopped"]]]],
            ["type": "assistant", "uuid": "child-done", "parentUuid": "nested-result", "message": ["role": "assistant", "content": "Explorer report"]]
        ])
        let nested = try childFile(rootFile: file, agent: "nested-agent", tool: "launch-nested", records: [
            ["type": "user", "uuid": "nu", "parentUuid": nil, "message": ["role": "user", "content": "Run a test"]],
            ["type": "assistant", "uuid": "na", "parentUuid": "nu", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "same-id", "name": "Bash", "input": ["command": "printf nested"]]]]],
            ["type": "user", "uuid": "nr", "parentUuid": "na", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "same-id", "content": "nested"]]]],
            ["type": "assistant", "uuid": "nd", "parentUuid": "nr", "message": ["role": "assistant", "content": "Nested report"]]
        ])
        let original = try [file, left, nested].map { try Data(contentsOf: $0) }
        let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: root))
        let leftID = sessionID + ":replay-subagent:launch-left", nestedID = sessionID + ":replay-subagent:launch-nested"
        let child = try XCTUnwrap(value.subagent(leftID)), grandchild = try XCTUnwrap(value.subagent(nestedID))
        XCTAssertEqual(value.subagents?.count, 2)
        XCTAssertEqual(child.parentID, sessionID); XCTAssertEqual(grandchild.parentID, leftID)
        XCTAssertEqual(child.name, "Explorer"); XCTAssertEqual(child.state, "completed")
        XCTAssertEqual(grandchild.state, "cancelled")
        XCTAssertEqual(child.capabilities, [:]); XCTAssertEqual(grandchild.capabilities, [:])
        XCTAssertEqual(child.transcript.items.last?.text, "Explorer report")
        XCTAssertEqual(grandchild.transcript.items.last?.text, "Nested report")
        XCTAssertEqual(child.transcript.items.first { $0.kind == "tool" }?.tool["content"].array.first?["content"]["text"], "3\tliteral child file")
        XCTAssertEqual(grandchild.transcript.items.first { $0.kind == "tool" }?.tool["rawOutput"], "nested")
        XCTAssertNil(child.transcript.subagents, "The root registry owns nested children once")
        XCTAssertEqual(value.items.filter { $0.kind == "assistant" }.map(\.text), ["Root report"])
        XCTAssertFalse(value.items.contains { $0.kind == "tool" }, "Agent control is a child entry, not a bare command")
        XCTAssertEqual(try [file, left, nested].map { try Data(contentsOf: $0) }, original)
    }
    func testHistoricalBackgroundLaunchNeverClaimsLiveOwnershipOrInventsCompletion() throws {
        for stopped in [false, true] {
            let (root, file) = try fixture([
                ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Start"]],
                ["type": "assistant", "uuid": "a", "parentUuid": "u", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "launch", "name": "Agent", "input": ["run_in_background": true, "prompt": "Continue work"]]]]],
                ["type": "user", "uuid": "r", "parentUuid": "a", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "launch", "content": "Background agent started successfully"]]]]
            ])
            _ = try childFile(rootFile: file, agent: "background", tool: "launch", records: [
                ["type": "user", "uuid": "cu", "parentUuid": nil, "message": ["role": "user", "content": "Continue work"]],
                ["type": "assistant", "uuid": "ca", "parentUuid": "cu", "message": ["role": "assistant", "content": "Some output"]]
            ], stopped: stopped)
            let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: root))
            let child = try XCTUnwrap(value.subagents?.first)
            XCTAssertEqual(child.state, stopped ? "cancelled" : "disconnected")
            XCTAssertEqual(child.capabilities, [:])
            XCTAssertFalse(child.isRunning)
        }
    }
    func testIncompleteForeignAmbiguousOrUnsafeChildHistoryFallsBackWithoutPartialRoot() throws {
        for variant in ["missing-meta", "missing-child", "wrong-agent", "wrong-session", "symlink", "directory-link", "bad-content", "oversized-meta", "ambiguous-meta", "cycle", "fifo"] {
            let (root, file) = try fixture([
                ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Explore"]],
                ["type": "assistant", "uuid": "a", "parentUuid": "u", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "launch", "name": "Agent", "input": ["prompt": "Inspect"]]]]],
                ["type": "user", "uuid": "r", "parentUuid": "a", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "launch", "content": "Done"]]]]
            ])
            let child = try childFile(rootFile: file, agent: "child", tool: "launch", records: [
                ["type": "user", "uuid": "cu", "parentUuid": nil, "message": ["role": "user", "content": "Inspect"]],
                ["type": "assistant", "uuid": "ca", "parentUuid": "cu", "message": ["role": "assistant", "content": "Child report"]]
            ])
            let original = try Data(contentsOf: file)
            let metadata = child.deletingLastPathComponent().appendingPathComponent("agent-child.meta.json")
            switch variant {
            case "missing-meta": try FileManager.default.removeItem(at: metadata)
            case "missing-child": try FileManager.default.removeItem(at: child)
            case "oversized-meta": try Data(repeating: 32, count: 70 * 1024).write(to: metadata)
            case "ambiguous-meta": try Data(contentsOf: metadata).write(to: metadata.deletingLastPathComponent().appendingPathComponent("agent-other.meta.json"))
            case "symlink":
                let outside = root.appendingPathComponent("outside.jsonl")
                try Data(contentsOf: child).write(to: outside)
                try FileManager.default.removeItem(at: child)
                try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
            case "directory-link":
                let outside = root.appendingPathComponent("outside-children")
                try FileManager.default.moveItem(at: child.deletingLastPathComponent(), to: outside)
                try FileManager.default.createSymbolicLink(at: child.deletingLastPathComponent(), withDestinationURL: outside)
            case "fifo":
                try FileManager.default.removeItem(at: child)
                XCTAssertEqual(mkfifo(child.path, 0o600), 0)
            default:
                var record: JSONValue = ["type": "assistant", "uuid": "ca", "parentUuid": nil, "sessionId": .string(sessionID), "agentId": "child", "isSidechain": true, "message": ["role": "assistant", "content": "Report"]]
                if variant == "wrong-agent" { record["agentId"] = "foreign" }
                if variant == "wrong-session" { record["sessionId"] = "bff43812-cb4c-43de-b015-77883faab5b2" }
                if variant == "bad-content" { record["message"]["content"] = [["type": "future-content"]] }
                if variant == "cycle" { record["message"]["content"] = [["type": "tool_use", "id": "launch", "name": "Agent", "input": ["prompt": "Cycle"]]] }
                var bytes = try JSONEncoder().encode(record); bytes.append(10); try bytes.write(to: child)
            }
            XCTAssertNil(try ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: root), variant)
            XCTAssertEqual(try Data(contentsOf: file), original, variant)
        }
    }
    func testCombinedChildFilesShareOneFamilyByteBudget() throws {
        let launches: [JSONValue] = (0..<5).map { ["type": "tool_use", "id": .string("launch-\($0)"), "name": "Agent", "input": ["prompt": "Inspect"]] }
        let (root, file) = try fixture([
            ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Explore"]],
            ["type": "assistant", "uuid": "a", "parentUuid": "u", "message": ["role": "assistant", "content": .array(launches)]]
        ])
        var padding = try JSONEncoder().encode(JSONValue.object(["type": "file-history-snapshot", "payload": .string(String(repeating: "x", count: 140_000))])); padding.append(10)
        for index in 0..<5 {
            let child = try childFile(rootFile: file, agent: "child-\(index)", tool: "launch-\(index)", records: [
                ["type": "user", "uuid": "cu", "parentUuid": nil, "message": ["role": "user", "content": "Inspect"]]
            ])
            let writer = try FileHandle(forWritingTo: child)
            try writer.seekToEnd()
            for _ in 0..<100 { try writer.write(contentsOf: padding) }
            try writer.close()
        }
        XCTAssertNil(try ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: root), "Five individually legal child files exceed the family's 64-MB budget")
    }
    func testRealDisposableProviderHistoryRestoresStoppedChildWithoutAnAgentProcess() throws {
        guard let path = ProcessInfo.processInfo.environment["CCODE_REAL_DELEGATED_HISTORY_DIRECTORY"] else { throw XCTSkip("Set CCODE_REAL_DELEGATED_HISTORY_DIRECTORY to the disposable child-Stop proof's provider folder.") }
        let folder = URL(fileURLWithPath: path)
        guard folder.lastPathComponent.contains("ccode-real-child-stop-") else { throw XCTSkip("This proof reads only its disposable child-Stop history.") }
        let rootFile = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first { $0.pathExtension == "jsonl" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil })
        let remote = rootFile.deletingPathExtension().lastPathComponent
        let childFolder = folder.appendingPathComponent(remote + "/subagents")
        let files = [rootFile] + (try FileManager.default.contentsOfDirectory(at: childFolder, includingPropertiesForKeys: nil)).filter { $0.pathExtension == "jsonl" || $0.lastPathComponent.hasSuffix(".meta.json") }
        let original = try files.map { try Data(contentsOf: $0) }
        let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: remote, cwd: "/unavailable/disposable/project", configurationDirectory: folder.deletingLastPathComponent().deletingLastPathComponent()))
        let child = try XCTUnwrap(value.subagents?.first)
        XCTAssertEqual(value.subagents?.count, 1)
        XCTAssertEqual(child.parentID, remote)
        XCTAssertEqual(child.state, "cancelled")
        XCTAssertEqual(child.capabilities, [:])
        XCTAssertTrue(child.transcript.items.contains { $0.kind == "tool" && $0.tool["rawInput"]["command"].string.contains("child-stop-proof.txt") })
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, original)
        print("Actual disposable SDK root/meta/sidechain history restored with child tools, cancelled state and unchanged bytes; no agent process launched.")
    }
    func testFailedLaunchWithoutAChildRemainsAnActualFailedTool() throws {
        let (root, file) = try fixture([
            ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Inspect"]],
            ["type": "assistant", "uuid": "bad", "parentUuid": "u", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "bad-launch", "name": "Agent", "input": ["prompt": "Bad launch"]]]]],
            ["type": "user", "uuid": "bad-result", "parentUuid": "bad", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "bad-launch", "is_error": true, "content": "Unknown agent type"]]]],
            ["type": "assistant", "uuid": "good", "parentUuid": "bad-result", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "good-launch", "name": "Agent", "input": ["prompt": "Good launch"]]]]],
            ["type": "user", "uuid": "good-result", "parentUuid": "good", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "good-launch", "content": "Done"]]]]
        ])
        _ = try childFile(rootFile: file, agent: "good-agent", tool: "good-launch", records: [
            ["type": "user", "uuid": "cu", "parentUuid": nil, "message": ["role": "user", "content": "Good launch"]],
            ["type": "assistant", "uuid": "ca", "parentUuid": "cu", "message": ["role": "assistant", "content": "Actual child report"]]
        ])
        let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: root))
        XCTAssertEqual(value.subagents?.count, 1)
        let failed = try XCTUnwrap(value.items.first { $0.kind == "tool" })
        XCTAssertEqual(failed.tool["status"], "failed")
        XCTAssertEqual(failed.tool["rawOutput"], "Unknown agent type")
        XCTAssertEqual(failed.tool["rawInput"]["prompt"], "Bad launch")
        XCTAssertEqual(value.items.filter { $0.kind == "subagent" }.count, 1)
    }
    private let sessionID = "31da61a1-8fba-4b7a-8e3e-5e3f67df73a3"
    private func fixture(_ records: [JSONValue], tail: String = "") throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("projects/encoded-worktree")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent(sessionID + ".jsonl")
        var data = Data()
        for var record in records {
            record["sessionId"] = .string(sessionID)
            data.append(try JSONEncoder().encode(record)); data.append(10)
        }
        data.append(Data(tail.utf8)); try data.write(to: file)
        return (root, file)
    }
    func testStructuredReadPublishesCleanNumberedContentWithoutChangingHistory() throws {
        let (root, file) = try fixture([
            ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Read the fixture"]],
            ["type": "assistant", "uuid": "a", "parentUuid": "u", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "read", "name": "Read", "input": ["file_path": "/project/file.swift", "offset": 7]]]]],
            ["type": "user", "uuid": "r", "parentUuid": "a", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "read", "content": "model copy\n<system-reminder>model-only note</system-reminder>"]]],
             "toolUseResult": ["type": "text", "file": ["content": "let value = 1\nprint(value)\n", "startLine": 20, "numLines": 2, "totalLines": 50, "truncatedByTokenCap": true]]]
        ])
        let original = try Data(contentsOf: file)
        let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: root))
        let tool = try XCTUnwrap(value.items.first { $0.kind == "tool" })
        XCTAssertEqual(tool.tool["content"].array.first?["content"]["text"], "20\tlet value = 1\n21\tprint(value)\n[File truncated: showing 2 of 50 lines]")
        XCTAssertTrue(tool.tool["rawOutput"].string.contains("model-only note"), "The original model-facing data remains intact; canonical content is the display source")
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
    func testReadMetadataNeverAttachesToBatchedOrFailedResults() throws {
        for failed in [false, true] {
            var blocks: [JSONValue] = [["type": "tool_result", "tool_use_id": "read", "content": "First raw result", "is_error": .bool(failed)]]
            if !failed { blocks.append(["type": "tool_result", "tool_use_id": "other", "content": "Other raw result"]) }
            let (root, _) = try fixture([
                ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Read"]],
                ["type": "assistant", "uuid": "a", "parentUuid": "u", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "read", "name": "Read", "input": [:]], ["type": "tool_use", "id": "other", "name": "Bash", "input": [:]]]]],
                ["type": "user", "uuid": "r", "parentUuid": "a", "message": ["role": "user", "content": .array(blocks)], "toolUseResult": ["type": "text", "file": ["content": "Must not attach", "startLine": 1]]]
            ])
            let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: root))
            XCTAssertTrue(value.items.filter { $0.kind == "tool" }.allSatisfy { $0.tool["content"].isNull })
            XCTAssertEqual(value.items.first { $0.tool["toolCallId"] == "read" }?.tool["rawOutput"], "First raw result")
        }
    }
    func testReadMetadataOffsetAndUnknownVariantsPreserveLiteralResults() throws {
        let variants: [(JSONValue, String?)] = [
            (["type": "text", "file": ["content": "first\n\nlast\n"]], "7\tfirst\n8\t\n9\tlast"),
            (["type": "text", "file": ["content": "\n", "truncatedByTokenCap": true]], "7\t\n[File truncated]"),
            (["type": "text", "file": ["content": ""]], nil),
            (["type": "image", "file": ["content": "Not file text"]], nil),
            (["type": "text", "file": ["content": "Unknown line", "startLine": -2]], nil),
            (["type": "text", "file": ["content": "Unknown line", "startLine": "two"]], nil)
        ]
        for (metadata, expected) in variants {
            let (root, _) = try fixture([
                ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Read"]],
                ["type": "assistant", "uuid": "a", "parentUuid": "u", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "read", "name": "Read", "input": ["offset": 7]]]]],
                ["type": "user", "uuid": "r", "parentUuid": "a", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "read", "content": "Literal raw result"]]], "toolUseResult": metadata]
            ])
            let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: root))
            let tool = try XCTUnwrap(value.items.first { $0.kind == "tool" })
            XCTAssertEqual(tool.tool["rawOutput"], "Literal raw result")
            XCTAssertEqual(tool.tool["content"].array.first?["content"]["text"].optionalString, expected)
        }
    }
    func testActiveBranchIncludesAssistantSiblingBlocksToolsAndAttachments() throws {
        let (root, file) = try fixture([
            ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Question"]],
            ["type": "assistant", "uuid": "old", "parentUuid": "u", "message": ["id": "discarded", "role": "assistant", "content": [["type": "text", "text": "Discarded branch"]]]],
            ["type": "assistant", "uuid": "a-text", "parentUuid": "u", "message": ["id": "response", "role": "assistant", "content": [["type": "text", "text": "Answer"]]]],
            ["type": "assistant", "uuid": "a-tool", "parentUuid": "u", "message": ["id": "response", "role": "assistant", "content": [["type": "tool_use", "id": "read", "name": "Read", "input": ["file_path": "/project/main.swift"]]]]],
            ["type": "user", "uuid": "result", "parentUuid": "a-tool", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "read", "content": "File contents"]]]],
            ["type": "assistant", "uuid": "done", "parentUuid": "result", "message": ["id": "done-response", "role": "assistant", "content": [["type": "thinking", "thinking": "Reasoning"], ["type": "text", "text": "Done"], ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "aW1hZ2U="]]]]],
            ["type": "assistant", "uuid": "child", "parentUuid": "done", "isSidechain": true, "message": ["role": "assistant", "content": "Subagent prose"]]
        ], tail: "{\"type\":\"assistant\",\"uuid\":\"unfinished")
        let original = try Data(contentsOf: file)
        let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/different/worktree", configurationDirectory: root))
        XCTAssertEqual(value.items.filter { $0.kind == "assistant" }.map(\.text), ["Answer", "Done"])
        XCTAssertEqual(value.items.filter { $0.kind == "user" }.map(\.text), ["Question"])
        XCTAssertEqual(value.items.map(\.kind), ["user", "assistant", "tool", "thought", "assistant"])
        XCTAssertEqual(value.items.first { $0.kind == "thought" }?.text, "Reasoning")
        XCTAssertEqual(value.items.first { $0.kind == "tool" }?.tool["status"].string, "completed")
        XCTAssertEqual(value.items.first { $0.kind == "tool" }?.tool["rawOutput"].string, "File contents")
        XCTAssertEqual(value.items.last?.blocks.first?["mimeType"].string, "image/png")
        XCTAssertEqual(try Data(contentsOf: file), original, "Reading must not modify Claude's history")
    }
    func testCompactionPreservesRetainedSegmentAndRejectsBrokenLineage() throws {
        let records: [JSONValue] = [
            ["type": "user", "uuid": "old", "parentUuid": nil, "message": ["role": "user", "content": "Compacted away"]],
            ["type": "user", "uuid": "retained", "parentUuid": "old", "message": ["role": "user", "content": "Retained question"]],
            ["type": "assistant", "uuid": "answer", "parentUuid": "retained", "message": ["role": "assistant", "content": "Retained answer"]],
            ["type": "system", "subtype": "compact_boundary", "uuid": "boundary", "parentUuid": nil, "compactMetadata": ["preservedSegment": ["headUuid": "retained", "tailUuid": "answer", "anchorUuid": "summary"]]],
            ["type": "user", "uuid": "summary", "parentUuid": "boundary", "isCompactSummary": true, "message": ["role": "user", "content": "Summary"]],
            ["type": "user", "uuid": "new", "parentUuid": "summary", "message": ["role": "user", "content": "New question"]]
        ]
        let (root, _) = try fixture(records)
        let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: root))
        XCTAssertEqual(value.items.map(\.text), ["Summary", "Retained question", "Retained answer", "New question"])
        let (broken, _) = try fixture([["type": "user", "uuid": "cycle", "parentUuid": "cycle", "message": ["role": "user", "content": "Never publish this"]]])
        XCTAssertNil(try ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: broken))
    }
    func testUnsupportedOrUnavailableHistoryFallsBackInsteadOfPublishingPartialContent() throws {
        let (root, file) = try fixture([
            ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Question"]],
            ["type": "assistant", "uuid": "a", "parentUuid": "u", "message": ["role": "assistant", "content": [["type": "future-content-type", "payload": "Unknown"]]]]
        ])
        XCTAssertNil(try ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: root))
        XCTAssertNil(try ClaudeTranscriptReader.load(sessionID: "../../outside", cwd: "/project", configurationDirectory: root))
        for content: JSONValue in [["future": "message"], 42, nil, ["unexpected primitive"]] {
            let (unfamiliar, _) = try fixture([
                ["type": "user", "uuid": "u", "parentUuid": nil, "message": ["role": "user", "content": "Question"]],
                ["type": "assistant", "uuid": "a", "parentUuid": "u", "message": ["role": "assistant", "content": content]]
            ])
            XCTAssertNil(try ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: unfamiliar))
        }
        try Data("corrupt complete record\n".utf8).write(to: file)
        XCTAssertNil(try ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: root))
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(try ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: root))
    }
    func testQueuedPromptsCommandLabelsAndVisiblePeerMessages() throws {
        let (root, _) = try fixture([
            ["type": "user", "uuid": "command", "parentUuid": nil, "message": ["role": "user", "content": "<command-name>/review</command-name><command-args>changes</command-args>"]],
            ["type": "attachment", "uuid": "queue", "parentUuid": "command", "attachment": ["type": "queued_command", "prompt": "Queued question", "source_uuid": "original-question"]],
            ["type": "assistant", "uuid": "answer", "parentUuid": "queue", "message": ["role": "assistant", "content": "Answer"]],
            ["type": "user", "uuid": "peer", "parentUuid": "answer", "isMeta": true, "origin": ["kind": "peer"], "message": ["role": "user", "content": "Peer report"]],
            ["type": "user", "uuid": "internal", "parentUuid": "peer", "isMeta": true, "message": ["role": "user", "content": "Internal reminder"]],
            ["type": "attachment", "uuid": "unanswered", "parentUuid": "internal", "attachment": ["type": "queued_command", "prompt": "Not submitted yet"]]
        ])
        let value = try XCTUnwrap(ClaudeTranscriptReader.load(sessionID: sessionID, cwd: "/project", configurationDirectory: root))
        XCTAssertEqual(value.items.map(\.text), ["/review changes", "Queued question", "Answer", "Peer report"])
        XCTAssertEqual(value.items[1].messageID, "original-question")
    }
}
