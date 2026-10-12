import Foundation

extension ClaudeTranscriptReader {
    static func restoreBashTask(metadata: JSONValue, toolID: String, command: String?, content: JSONValue, transcript: inout SessionTranscript) throws {
        guard let owner = transcript.remoteID, let id = metadata["backgroundTaskId"].optionalString,
              validHistoricalTaskID(id), let command, !command.isEmpty else { return }
        let identity = AsyncTaskIdentity(owner: owner, task: id)
        guard transcript.asyncTask(identity) == nil else { throw ACPError.workspace("Ambiguous historical background task identity.") }
        var task = AgentAsyncTask(id: identity)
        task.taskType = "local_bash"; task.name = String(command.prefix(160)); task.description = command
        task.toolCallID = toolID; task.state = .disconnected; task.canStop = false
        let text = content.optionalString ?? content.array.compactMap { $0["text"].optionalString }.joined(separator: "\n")
        let marker = "Output is being written to: ", ending = ". You will be notified"
        if let start = text.range(of: marker), let end = text.range(of: ending, range: start.upperBound..<text.endIndex) {
            let path = String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), path.hasSuffix("/tasks/" + id + ".output") { task.outputFilePath = path }
        }
        if transcript.asyncTasks == nil { transcript.asyncTasks = [] }
        transcript.asyncTasks?.append(task)
    }
    static func restoreTaskStop(metadata: JSONValue, target: String?, transcript: inout SessionTranscript) {
        guard let owner = transcript.remoteID, let target, validHistoricalTaskID(target),
              metadata["task_id"] == .string(target), metadata["task_type"] == "local_bash",
              let index = transcript.asyncTasks?.firstIndex(where: { $0.id == AsyncTaskIdentity(owner: owner, task: target) }) else { return }
        transcript.asyncTasks?[index].state = .stopped
    }
    static func validHistoricalTaskID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil
    }
}

extension SessionTranscript {
    /// Combine a fresh recognized family with this client's saved task outcomes.
    /// Task ID alone is insufficient: launches may differ across history revisions.
    public mutating func mergeClaudeHistoricalTasks(from saved: SessionTranscript) {
        guard let root = remoteID, saved.remoteID == root else { return }
        let owners = Set([root] + (subagents ?? []).map(\.id))
        var tasks = asyncTasks ?? []
        for old in saved.asyncTasks ?? [] where owners.contains(old.id.owner) {
            if let index = tasks.firstIndex(where: { $0.id == old.id }) {
                if tasks[index].state == .disconnected, [.completed, .failed, .stopped].contains(old.state),
                   tasks[index].toolCallID == old.toolCallID, tasks[index].description == old.description,
                   tasks[index].outputFilePath == old.outputFilePath, tasks[index].taskType == old.taskType {
                    tasks[index].state = old.state
                    tasks[index].summary = old.summary; tasks[index].usage = old.usage; tasks[index].lastToolName = old.lastToolName
                }
            } else {
                var historical = old
                if historical.isRunning { historical.state = .disconnected }
                historical.canStop = false; tasks.append(historical)
            }
        }
        for index in tasks.indices { tasks[index].canStop = false }
        asyncTasks = tasks.isEmpty ? nil : tasks
    }
    /// Add recognized archived tasks only where replay retained the exact Bash
    /// launch. Existing provider-announced tasks and their controls stay intact.
    @discardableResult public mutating func restoreClaudeAsyncReplay(with native: SessionTranscript) -> Bool {
        guard let root = remoteID, UUID(uuidString: root) != nil, native.remoteID == root,
              let source = native.asyncTasks, !source.isEmpty,
              Set(source.map(\.id)).count == source.count else { return false }
        for task in source {
            guard !task.isRunning, !task.canStop, let tool = task.toolCallID,
                  task.id.owner == root || subagent(task.id.owner)?.parentID == native.subagent(task.id.owner)?.parentID,
                  agentItems(owner: task.id.owner).contains(where: {
                      $0.kind == "tool" && $0.tool["toolCallId"] == .string(tool) && $0.tool["rawInput"]["command"] == .string(task.description)
                  }) else { return false }
        }
        if asyncTasks == nil { asyncTasks = [] }
        for task in source where asyncTask(task.id) == nil { asyncTasks?.append(task) }
        return true
    }
}
