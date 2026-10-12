import Foundation

extension ClaudeTranscriptReader {
    /// Provider metadata, not prose, associates a launch with its on-disk child.
    /// A single family budget bounds the root, all metadata and nested children.
    static func loadDelegatedHistories(_ transcript: inout SessionTranscript, folder: URL, sessionID: String, budget: inout ReadBudget) throws -> Bool {
        guard let launches = transcript.subagents, !launches.isEmpty else { return true }
        let sessionFolder = folder.appendingPathComponent(sessionID)
        let directory = sessionFolder.appendingPathComponent("subagents")
        for path in [sessionFolder, directory] {
            guard let attributes = try? path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  attributes.isDirectory == true, attributes.isSymbolicLink != true else {
                if launches.allSatisfy({ ["failed", "cancelled"].contains($0.state) }) { transcript.subagents = nil; return true }
                return false
            }
        }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { return false }
        var metadata: [String: (agent: String, value: JSONValue)] = [:], count = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            count += 1
            guard count <= 1024 else { return false }
            let name = url.lastPathComponent
            guard name.hasPrefix("agent-"), name.hasSuffix(".meta.json") else { continue }
            let agent = String(name.dropFirst(6).dropLast(10))
            guard !agent.isEmpty, !agent.contains("/"), !agent.contains("\\"), !agent.contains("\0") else { return false }
            let value: JSONValue?
            do {
                value = try stableFile(url, maximumBytes: 64 * 1024, budget: &budget) { handle, size, budget in
                    guard budget.records < 100_000 else { throw ACPError.workspace("Local transcript family index is too large.") }
                    budget.records += 1
                    return try JSONDecoder().decode(JSONValue.self, from: handle.read(upToCount: size) ?? Data())
                }
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
            guard let value, let toolID = value["toolUseId"].optionalString, !toolID.isEmpty else { continue }
            guard metadata[toolID] == nil else { return false }
            metadata[toolID] = (agent, value)
        }
        let prefix = sessionID + ":replay-subagent:"
        var restored: [SubagentSession] = [], restoredTasks: [AgentAsyncTask] = [], seenAgents = Set<String>(), seenChildren = Set<String>()
        func restore(_ source: SubagentSession, parent: inout SessionTranscript, depth: Int, budget: inout ReadBudget) throws -> Bool {
            try Task.checkCancellation()
            guard depth <= 16, restored.count < 256, source.id.hasPrefix(prefix), seenChildren.insert(source.id).inserted else { return false }
            let toolID = String(source.id.dropFirst(prefix.count))
            guard let association = metadata[toolID] else {
                // A failed control call without launch metadata is an actual tool
                // failure, not evidence that a disconnected child ever existed.
                return ["failed", "cancelled"].contains(source.state)
            }
            guard seenAgents.insert(association.agent).inserted else { return false }
            let file = directory.appendingPathComponent("agent-" + association.agent + ".jsonl")
            guard var history = try readTranscriptFile(file, sessionID: sessionID, ownerID: source.id, agentID: association.agent, budget: &budget) else { return false }
            var child = source
            let nested = history.subagents ?? []
            history.subagents = nil
            restoredTasks += history.asyncTasks ?? []
            history.asyncTasks = nil
            if association.value["stoppedByUser"] == true { child.state = "cancelled" }
            guard let row = parent.items.firstIndex(where: { $0.kind == "tool" && $0.tool["toolCallId"] == .string(toolID) }) else { return false }
            parent.items[row] = TranscriptItem(kind: "subagent", tool: ["subagentSessionId": .string(child.id)])
            let index = restored.count
            restored.append(child)
            for launch in nested {
                guard launch.parentID == child.id, try restore(launch, parent: &history, depth: depth + 1, budget: &budget) else { return false }
            }
            restored[index].transcript = history
            return true
        }
        for launch in launches {
            guard launch.parentID == sessionID, try restore(launch, parent: &transcript, depth: 1, budget: &budget) else { return false }
        }
        transcript.subagents = restored.isEmpty ? nil : restored
        if !restoredTasks.isEmpty { transcript.asyncTasks = (transcript.asyncTasks ?? []) + restoredTasks }
        return true
    }
}
