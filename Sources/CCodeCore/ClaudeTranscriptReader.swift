import Foundation
import Darwin

/// Reads only the selected local Claude transcript; never starts or writes to an agent.
public enum ClaudeTranscriptReader {
    private struct ToolUse { let name: String; let startLine: Int; let childID: String?; let background: Bool; let command: String?; let targetTask: String? }
    struct ReadBudget { var bytes = 0; var records = 0 }
    private struct Entry {
        let id: String
        var parent: String?
        let offset: UInt64
        let length: Int
        let type: String
        let eligible: Bool
        var visible: Bool
        let queued: Bool
        let sourceID: String?
        let messageID: String?
        let toolIDs: [String]
        let resultIDs: [String]
    }
    public static func load(sessionID: String, cwd: String, configurationDirectory: URL) throws -> SessionTranscript? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        let projects = configurationDirectory.appendingPathComponent("projects")
        let encoded = cwd.replacingOccurrences(of: "[^a-zA-Z0-9]", with: "-", options: .regularExpression)
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        let candidates = [projects.appendingPathComponent(encoded)] + folders.sorted { $0.path < $1.path }
        for folder in candidates {
            try Task.checkCancellation()
            guard let properties = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), properties.isDirectory == true, properties.isSymbolicLink != true else { continue }
            let file = folder.appendingPathComponent(sessionID + ".jsonl")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                var budget = ReadBudget()
                guard var transcript = try readTranscriptFile(file, sessionID: sessionID, ownerID: sessionID, agentID: nil, budget: &budget),
                      try loadDelegatedHistories(&transcript, folder: folder, sessionID: sessionID, budget: &budget) else { return nil }
                return transcript
            } catch is CancellationError { throw CancellationError() }
            catch { return nil }
        }
        return nil
    }
    static func stableFile<T>(_ file: URL, maximumBytes: Int, budget: inout ReadBudget, body: (FileHandle, Int, inout ReadBudget) throws -> T) throws -> T? {
        try Task.checkCancellation()
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat(), named = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0,
              before.st_size <= maximumBytes, before.st_size <= 64 * 1024 * 1024 - budget.bytes else { return nil }
        budget.bytes += Int(before.st_size)
        let value = try body(handle, Int(before.st_size), &budget)
        guard fstat(descriptor, &after) == 0, lstat(file.path, &named) == 0,
              named.st_dev == before.st_dev, named.st_ino == before.st_ino, named.st_mode & S_IFMT == S_IFREG,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { return nil }
        return value
    }
    static func readTranscriptFile(_ file: URL, sessionID: String, ownerID: String, agentID: String?, budget: inout ReadBudget) throws -> SessionTranscript? {
        try stableFile(file, maximumBytes: 64 * 1024 * 1024, budget: &budget) { handle, size, budget in
            try read(handle, size: size, sessionID: sessionID, ownerID: ownerID, agentID: agentID, budget: &budget)
        } ?? nil
    }
    private static func read(_ handle: FileHandle, size: Int, sessionID: String, ownerID: String, agentID: String?, budget: inout ReadBudget) throws -> SessionTranscript? {
        var entries: [String: Entry] = [:], compactions: [JSONValue] = []
        let decoder = JSONDecoder()
        try lines(handle, size: size) { line, offset, complete in
            try Task.checkCancellation()
            guard !line.isEmpty else { return }
            guard budget.records < 100_000 else { throw ACPError.workspace("Local transcript family index is too large.") }
            budget.records += 1
            guard let record = try? decoder.decode(JSONValue.self, from: line) else {
                if !complete { return } // A writer may still be appending the final JSONL record.
                throw ACPError.workspace("Unreadable local transcript record.")
            }
            guard record["sessionId"].isNull || record["sessionId"].string == sessionID else { throw ACPError.workspace("Transcript belongs to another session.") }
            let type = record["type"].string
            guard ["user", "assistant", "system", "attachment", "progress"].contains(type), let id = record["uuid"].optionalString, !id.isEmpty else { return }
            guard entries.count < 100_000 else { throw ACPError.workspace("Local transcript index is too large.") }
            if type == "system", record["subtype"].string == "compact_boundary" { compactions.append(record["compactMetadata"]) }
            let blocks = record["message"]["content"].array
            if let agentID, ["user", "assistant"].contains(type),
               record["agentId"] != .string(agentID) || !record["isSidechain"].bool {
                throw ACPError.workspace("Child transcript belongs to another agent.")
            }
            let eligible = (agentID != nil || !record["isSidechain"].bool) && record["teamName"].isNull && type != "progress" && record["attachment"]["type"].string != "fork_briefing"
            entries[id] = Entry(id: id, parent: record["parentUuid"].optionalString, offset: offset, length: line.count, type: type,
                eligible: eligible, visible: eligible && (!record["isMeta"].bool || record["isCompactSummary"].bool || ["channel", "observer", "observer-activity", "slack-ping", "peer"].contains(record["origin"]["kind"].string)),
                queued: record["attachment"]["type"].string == "queued_command", sourceID: record["attachment"]["source_uuid"].optionalString,
                messageID: type == "assistant" ? record["message"]["id"].optionalString : nil,
                toolIDs: blocks.filter { ["tool_use", "server_tool_use", "mcp_tool_use"].contains($0["type"].string) }.compactMap { $0["id"].optionalString },
                resultIDs: blocks.compactMap { $0["tool_use_id"].optionalString })
        }
        var children: [String: Set<String>] = [:]
        for entry in entries.values { if let parent = entry.parent { children[parent, default: []].insert(entry.id) } }
        func reparent(_ id: String, to parent: String?) {
            if let previous = entries[id]?.parent { children[previous]?.remove(id) }
            entries[id]?.parent = parent
            if let parent { children[parent, default: []].insert(id) }
        }
        for metadata in compactions {
            try Task.checkCancellation()
            let preserved = metadata["preservedMessages"], segment = metadata["preservedSegment"]
            let ids = preserved["uuids"].array.map(\.string)
            if !preserved.isNull {
                if ids.isEmpty { continue }
                guard ids.allSatisfy({ entries[$0] != nil }), let anchor = preserved["anchorUuid"].optionalString else { throw ACPError.workspace("Unsupported compaction lineage.") }
                var parent = anchor
                for id in ids { reparent(id, to: parent); parent = id }
                for id in children[anchor] ?? [] where id != ids.first { reparent(id, to: ids.last) }
            } else if !segment.isNull {
                guard let head = segment["headUuid"].optionalString, let tail = segment["tailUuid"].optionalString,
                      let anchor = segment["anchorUuid"].optionalString, entries[head] != nil, entries[tail] != nil else { throw ACPError.workspace("Unsupported compaction segment.") }
                reparent(head, to: anchor)
                for id in children[anchor] ?? [] where id != head { reparent(id, to: tail) }
            }
        }
        let parents = Set(entries.values.filter(\.eligible).compactMap(\.parent))
        let leaves = entries.values.filter { $0.eligible && !parents.contains($0.id) }.sorted { $0.offset > $1.offset }
        var chain: [Entry] = []
        for leaf in leaves {
            var current: Entry? = leaf, visited: Set<String> = [], candidate: [Entry] = []
            while let entry = current {
                try Task.checkCancellation()
                guard visited.insert(entry.id).inserted else { throw ACPError.workspace("Cyclic transcript lineage.") }
                candidate.append(entry)
                if let parent = entry.parent {
                    guard let ancestor = entries[parent] else { throw ACPError.workspace("Incomplete transcript lineage.") }
                    current = ancestor
                } else { current = nil }
            }
            if candidate.contains(where: { $0.visible && ["user", "assistant"].contains($0.type) }) { chain = candidate.reversed(); break }
        }
        guard !chain.isEmpty else { return nil }
        let chainIDs = Set(chain.map(\.id))
        var replied = false
        for index in chain.indices.reversed() {
            if chain[index].type == "assistant" || !chain[index].resultIDs.isEmpty { replied = true }
            else if chain[index].type == "user", chain[index].visible { replied = false }
            if chain[index].queued, !replied || chain[index].sourceID.map(chainIDs.contains) == true { chain[index].visible = false }
        }
        // Claude persists parallel blocks of one assistant response as sibling records.
        let messageIDs = Set(chain.compactMap(\.messageID))
        var selected = Set(chain.map(\.id))
        let siblings = entries.values.filter { $0.eligible && $0.messageID.map(messageIDs.contains) == true }
        let toolIDs = Set(siblings.flatMap(\.toolIDs))
        for entry in siblings { selected.insert(entry.id) }
        for entry in entries.values where entry.eligible && !entry.resultIDs.isEmpty && !Set(entry.resultIDs).isDisjoint(with: toolIDs) { selected.insert(entry.id) }
        var owners: [String: String] = [:], lastPositions: [String: Int] = [:], extras: [String: [Entry]] = [:]
        for entry in siblings { for tool in entry.toolIDs { owners[tool] = entry.messageID } }
        for (index, entry) in chain.enumerated() { if let messageID = entry.messageID { lastPositions[messageID] = index } }
        for entry in entries.values where selected.contains(entry.id) && !chainIDs.contains(entry.id) {
            let owner = entry.messageID ?? entry.resultIDs.compactMap { owners[$0] }.first
            if let owner { extras[owner, default: []].append(entry) }
        }
        var result = SessionTranscript(remoteID: ownerID), tools: [String: ToolUse] = [:]
        let responses = Dictionary(grouping: siblings, by: { $0.messageID ?? $0.id })
        var publishedResponses: Set<String> = []
        for (index, entry) in chain.enumerated() {
            if let messageID = entry.messageID {
                if publishedResponses.insert(messageID).inserted {
                    for block in (responses[messageID] ?? [entry]).sorted(by: { $0.offset < $1.offset }) { try publish(block, handle: handle, decoder: decoder, rootID: sessionID, result: &result, tools: &tools) }
                }
            } else { try publish(entry, handle: handle, decoder: decoder, rootID: sessionID, result: &result, tools: &tools) }
            if let messageID = entry.messageID, lastPositions[messageID] == index {
                for extra in (extras.removeValue(forKey: messageID) ?? []).sorted(by: { $0.offset < $1.offset }) {
                    if extra.messageID != nil { continue }
                    try publish(extra, handle: handle, decoder: decoder, rootID: sessionID, result: &result, tools: &tools)
                }
            }
        }
        result.beginTurn()
        return result
    }
    private static func publish(_ entry: Entry, handle: FileHandle, decoder: JSONDecoder, rootID: String, result: inout SessionTranscript, tools: inout [String: ToolUse]) throws {
        guard entry.visible, entry.queued || ["user", "assistant"].contains(entry.type) else { return }
        try Task.checkCancellation()
        try handle.seek(toOffset: entry.offset)
        let record = try decoder.decode(JSONValue.self, from: handle.read(upToCount: entry.length) ?? Data())
        let role = entry.queued ? "user" : entry.type
        guard entry.queued || record["message"]["role"].string == role else { throw ACPError.workspace("Unknown transcript message role.") }
        let messageID = entry.queued ? (entry.sourceID ?? entry.id) : (entry.messageID ?? entry.id)
        let content = entry.queued ? record["attachment"]["prompt"] : record["message"]["content"]
        let blocks: [JSONValue]
        switch content {
        case .string(let text): blocks = [["type": "text", "text": .string(text)]]
        case .array(let values): blocks = values
        default: throw ACPError.workspace("Unrecognized transcript message content.")
        }
        // Message-level metadata has no tool ID. Match the provider's single-result attribution rule.
        let singleResult = blocks.lazy.filter { $0["type"] == "tool_result" }.count == 1
        for block in blocks {
            var update: JSONValue
            switch block["type"].string {
            case "text", "text_delta":
                var text = block["text"].string
                if role == "user" {
                    let original = text
                    text = text.replacingOccurrences(of: "<(system-reminder|local-command-stdout|local-command-stderr|command-name|command-message|command-args)>[\\s\\S]*?</\\1>", with: "", options: .regularExpression)
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !original.contains("<local-command-stdout>"), !original.contains("<local-command-stderr>"),
                       let range = original.range(of: "(?<=<command-name>)[\\s\\S]*?(?=</command-name>)", options: .regularExpression) {
                        let name = String(original[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if name.hasPrefix("/"), !["/context", "/heapdump", "/extra-usage", "/compact", "/model", "/status", "/usage"].contains(String(name.split(separator: " ").first ?? "")) {
                            let arguments = original.range(of: "(?<=<command-args>)[\\s\\S]*?(?=</command-args>)", options: .regularExpression).map { String(original[$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                            text = arguments.isEmpty ? name : name + " " + arguments
                        }
                    }
                }
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                update = ["sessionUpdate": .string(role == "user" ? "user_message_chunk" : "agent_message_chunk"), "messageId": .string(messageID), "content": ["type": "text", "text": .string(text)]]
            case "thinking", "thinking_delta":
                if block["thinking"].string.isEmpty { continue }
                update = ["sessionUpdate": "agent_thought_chunk", "messageId": .string(messageID), "content": ["type": "text", "text": block["thinking"]]]
            case "redacted_thinking": continue
            case "image":
                let source = block["source"]
                guard source["type"].string == "base64" else { throw ACPError.workspace("Unsupported image source.") }
                update = ["sessionUpdate": .string(role == "user" ? "user_message_chunk" : "agent_message_chunk"), "messageId": .string(messageID), "content": ["type": "image", "data": source["data"], "mimeType": source["media_type"], "name": "Image attachment"]]
            case "tool_use", "server_tool_use", "mcp_tool_use":
                let name = block["name"].string, id = block["id"].string
                guard !id.isEmpty else { throw ACPError.workspace("Missing tool identity.") }
                let childID = ["Agent", "Task"].contains(name) ? rootID + ":replay-subagent:" + id : nil
                tools[id] = ToolUse(name: name, startLine: block["input"]["offset"].exactInteger.flatMap { $0 > 0 ? $0 : nil } ?? 1, childID: childID, background: block["input"]["run_in_background"].bool,
                                    command: name == "Bash" ? block["input"]["command"].optionalString : nil,
                                    targetTask: name == "TaskStop" ? block["input"]["task_id"].optionalString ?? block["input"]["shell_id"].optionalString : nil)
                if let childID {
                    guard result.subagent(childID) == nil else { throw ACPError.workspace("Repeated subagent launch identity.") }
                    let input = block["input"]
                    var child = SubagentSession(id: childID, parentID: result.remoteID ?? rootID)
                    child.name = ["name", "description", "subagent_type"].compactMap { input[$0].optionalString }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Restored agent"
                    child.task = ["prompt", "description"].compactMap { input[$0].optionalString }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Delegated task restored from session history"
                    child.prompt = input["prompt"].optionalString; child.state = "disconnected"
                    if result.subagents == nil { result.subagents = [] }
                    result.subagents?.append(child)
                    // Keep the real control call until metadata proves that a child
                    // was launched. Failed launches may have no child transcript.
                }
                if name == "TodoWrite" {
                    result.plan = block["input"]["todos"].array.map { ["content": $0["content"], "priority": "medium", "status": $0["status"]] }
                    continue
                }
                let kind = ["Read": "read", "Edit": "edit", "Write": "edit", "Bash": "execute", "Grep": "search", "Glob": "search", "WebSearch": "search", "WebFetch": "fetch"][name] ?? "other"
                update = ["sessionUpdate": "tool_call", "toolCallId": .string(id), "title": .string(name), "kind": .string(kind), "status": "in_progress", "rawInput": block["input"]]
            case "tool_result", "mcp_tool_result", "tool_search_tool_result", "web_fetch_tool_result", "web_search_tool_result", "code_execution_tool_result", "bash_code_execution_tool_result", "text_editor_code_execution_tool_result":
                let id = block["tool_use_id"].string
                if tools[id]?.name == "TodoWrite" { continue }
                if let tool = tools[id] {
                    if block["type"] == "tool_result", !block["is_error"].bool, singleResult {
                        if tool.name == "Bash" { try restoreBashTask(metadata: record["toolUseResult"], toolID: id, command: tool.command, content: block["content"], transcript: &result) }
                        if tool.name == "TaskStop" { restoreTaskStop(metadata: record["toolUseResult"], target: tool.targetTask, transcript: &result) }
                    }
                    if let childID = tool.childID, let index = result.subagents?.firstIndex(where: { $0.id == childID }) {
                        if block["is_error"].bool {
                            let text = block["content"].optionalString ?? block["content"].array.compactMap { $0["text"].optionalString }.joined(separator: " ")
                            result.subagents?[index].state = text.range(of: "\\b(cancelled|canceled|interrupted|stopped|killed)\\b", options: [.regularExpression, .caseInsensitive]) != nil ? "cancelled" : "failed"
                        } else if !tool.background { result.subagents?[index].state = "completed" }
                    }
                    update = ["sessionUpdate": "tool_call_update", "toolCallId": .string(id), "status": .string(block["is_error"].bool ? "failed" : "completed"), "rawOutput": block["content"]]
                    if tool.name == "Read", block["type"] == "tool_result", !block["is_error"].bool, singleResult,
                       let text = try readContent(record["toolUseResult"], startLine: tool.startLine) {
                        update["content"] = [["type": "content", "content": ["type": "text", "text": .string(text)]]]
                    }
                } else { throw ACPError.workspace("Unresolved tool result.") }
            default: throw ACPError.workspace("Unrecognized transcript content.")
            }
            _ = result.apply(["sessionId": .string(result.remoteID ?? ""), "update": update])
        }
    }
    private static func readContent(_ metadata: JSONValue, startLine fallback: Int) throws -> String? {
        guard metadata["type"] == "text", let content = metadata["file"]["content"].optionalString, !content.isEmpty else { return nil }
        let file = metadata["file"], startLine: Int
        if file["startLine"].isNull { startLine = fallback }
        else {
            guard let line = file["startLine"].exactInteger, line > 0 else { return nil }
            startLine = line
        }
        // Keep literal file lines, removing only the one terminating newline; avoid a second array of every line.
        let text = content.hasSuffix("\n") ? content.dropLast() : content[...]
        var numbered = "", cursor = text.startIndex, index = 0
        repeat {
            if index % 128 == 0 { try Task.checkCancellation() }
            let end = text[cursor...].firstIndex(of: "\n")
            if index > 0 { numbered.append("\n") }
            numbered.append("\(startLine + index)\t")
            numbered.append(contentsOf: text[cursor..<(end ?? text.endIndex)])
            guard let end else { break }
            cursor = text.index(after: end); index += 1
        } while true
        if file["truncatedByTokenCap"].bool {
            let detail: String
            if let count = file["numLines"].exactInteger, count >= 0, let total = file["totalLines"].exactInteger, total >= count {
                detail = ": showing \(count) of \(total) lines"
            } else { detail = "" }
            numbered.append("\n[File truncated\(detail)]")
        }
        return numbered
    }
    private static func lines(_ handle: FileHandle, size: Int, body: (Data, UInt64, Bool) throws -> Void) throws {
        var buffer = Data(), base: UInt64 = 0, read = 0
        while read < size {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: min(64 * 1024, size - read)), !chunk.isEmpty else { break }
            read += chunk.count; buffer.append(chunk)
            var cursor = buffer.startIndex
            while let end = buffer[cursor...].firstIndex(of: 10) {
                guard end - cursor <= 8 * 1024 * 1024 else { throw ACPError.workspace("Local transcript record is too large.") }
                try body(Data(buffer[cursor..<end]), base + UInt64(cursor - buffer.startIndex), true)
                cursor = end + 1
            }
            base += UInt64(cursor - buffer.startIndex)
            buffer.removeSubrange(buffer.startIndex..<cursor)
            guard buffer.count <= 8 * 1024 * 1024 else { throw ACPError.workspace("Local transcript record is too large.") }
        }
        if !buffer.isEmpty { try body(buffer, base, false) }
    }
}
