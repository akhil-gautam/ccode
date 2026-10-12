import Foundation
import Darwin

public struct AsyncTaskIdentity: Codable, Hashable, Sendable {
    public let owner: String
    public let task: String
    public init(owner: String, task: String) { self.owner = owner; self.task = task }
}
public enum AsyncTaskState: String, Codable, Sendable {
    case running, paused, completed, failed, stopped, disconnected
    public var isRunning: Bool { self == .running || self == .paused }
    public var displayTitle: String { self == .disconnected ? "Status unknown" : rawValue.capitalized }
}
public struct AgentAsyncTask: Codable, Identifiable, Sendable {
    public var id: AsyncTaskIdentity
    public var name = "Background task"
    public var taskType = ""
    public var description = ""
    public var summary: String?
    public var lastToolName: String?
    public var usage: JSONValue = [:]
    public var outputFilePath: String?
    public var toolCallID: String?
    public var showInTranscript = false
    public var canStop = false
    public var state: AsyncTaskState = .running
    public var isRunning: Bool { state.isRunning }
    public init(id: AsyncTaskIdentity) { self.id = id }
}

extension SessionTranscript {
    public func asyncTask(_ id: AsyncTaskIdentity) -> AgentAsyncTask? { asyncTasks?.first { $0.id == id } }
    public mutating func disconnectAsyncTasks() {
        guard let tasks = asyncTasks else { return }
        for index in tasks.indices where tasks[index].isRunning { asyncTasks?[index].state = .disconnected }
    }
    public mutating func rebaseAsyncTasks(from old: String?, to new: String?) {
        guard let old, let new, old != new else { return }
        for index in (asyncTasks ?? []).indices where asyncTasks?[index].id.owner == old {
            if let task = asyncTasks?[index].id.task { asyncTasks?[index].id = AsyncTaskIdentity(owner: new, task: task) }
        }
        for index in items.indices where items[index].kind == "async_task" && items[index].tool["ownerSessionId"] == .string(old) {
            items[index].tool["ownerSessionId"] = .string(new)
        }
    }
    /// Announcements authorize one live connection only. Disk history never grants live control.
    @discardableResult public mutating func applyAsyncWork(_ params: JSONValue, children: Set<String>, owners: inout Set<AsyncTaskIdentity>) -> Bool {
        guard let root = remoteID, let owner = params["sessionId"].optionalString,
              owner == root || (children.contains(owner) && subagent(owner) != nil),
              let task = params["update"]["asyncTaskId"].optionalString, !task.isEmpty else { return false }
        let id = AsyncTaskIdentity(owner: owner, task: task), update = params["update"], kind = update["sessionUpdate"].string
        guard ["async_task_spawned", "async_task_progress", "async_task_state_update"].contains(kind) else { return false }
        if kind == "async_task_spawned" {
            if asyncTasks == nil { asyncTasks = [] }
            if asyncTask(id) == nil { asyncTasks?.append(AgentAsyncTask(id: id)) }
        } else if !owners.contains(id) { return false }
        guard let index = asyncTasks?.firstIndex(where: { $0.id == id }) else { return false }
        if kind == "async_task_state_update" {
            guard let state = AsyncTaskState(rawValue: update["state"].string), state != .disconnected else { return false }
            asyncTasks?[index].state = state
        }
        if kind == "async_task_spawned" {
            if !owners.contains(id), asyncTasks?[index].state == .disconnected { asyncTasks?[index].state = .running }
            if let name = update["name"].optionalString, !name.isEmpty { asyncTasks?[index].name = name }
            if let type = update["taskType"].optionalString { asyncTasks?[index].taskType = type }
            asyncTasks?[index].canStop = update["canStop"].bool
            if update["showInTranscript"].bool, asyncTasks?[index].showInTranscript != true {
                asyncTasks?[index].showInTranscript = true
                _ = appendAgentItem(TranscriptItem(kind: "async_task", tool: ["asyncTaskId": .string(task), "ownerSessionId": .string(owner)]), owner: owner)
            }
            owners.insert(id)
        }
        if let description = update["description"].optionalString { asyncTasks?[index].description = description }
        if let summary = update["summary"].optionalString { asyncTasks?[index].summary = summary }
        if let name = update["lastToolName"].optionalString { asyncTasks?[index].lastToolName = name }
        if case .object = update["usage"] { asyncTasks?[index].usage = update["usage"] }
        if let path = update["outputFilePath"].optionalString, !path.isEmpty { asyncTasks?[index].outputFilePath = path }
        if let tool = update["toolCallId"].optionalString, !tool.isEmpty { asyncTasks?[index].toolCallID = tool }
        return true
    }
}

public struct AsyncTaskOutput: Sendable {
    public let text: String
    public let truncated: Bool
    public let offset: UInt64
    public let byteCount: Int
    public let fileSize: UInt64
    /// Only the selected, currently owned task is read. No log bodies are retained in the registry.
    public static func read(path: String, maximumBytes: Int = 64 * 1024, endingAt: UInt64? = nil) throws -> AsyncTaskOutput {
        guard path.hasPrefix("/"), !path.utf8.contains(0), maximumBytes > 0, maximumBytes <= 64 * 1024 else { throw ACPError.workspace("Invalid task output path or limit.") }
        // A FIFO must reach the regular-file check without waiting for a writer.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ACPError.workspace("Task output is not available yet.") }
        return try readDescriptor(descriptor, path: path, maximumBytes: maximumBytes, endingAt: endingAt)
    }
    /// A freshly recognized native launch may read its SDK output without starting
    /// an agent. Traverse the UID/session/task location without following links.
    public static func readClaudeHistory(path: String, taskID: String, rootID: String, maximumBytes: Int = 64 * 1024, endingAt: UInt64? = nil) throws -> AsyncTaskOutput {
        let normalized = path.hasPrefix("/tmp/") ? "/private" + path : path
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.utf8.contains(0), maximumBytes > 0, maximumBytes <= 64 * 1024,
              ClaudeTranscriptReader.validHistoricalTaskID(taskID), let root = UUID(uuidString: rootID),
              parts.count == 8, parts[0].isEmpty, parts[1] == "private", parts[2] == "tmp",
              parts[3] == "claude-\(getuid())", !parts[4].isEmpty,
              !parts.contains(where: { $0 == "." || $0 == ".." }),
              UUID(uuidString: String(parts[5])) == root, parts[6] == "tasks", parts[7] == "\(taskID).output" else {
            throw ACPError.workspace("Historical output does not match this Claude task's local SDK location.")
        }
        var directory = open("/private/tmp/" + parts[3], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ACPError.workspace("Historical task output is no longer available.") }
        defer { close(directory) }
        for component in parts[4...6] {
            var attributes = stat()
            guard fstat(directory, &attributes) == 0, attributes.st_uid == getuid() else { throw ACPError.workspace("Historical output directory belongs to another user.") }
            let next = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ACPError.workspace("Historical task output directory is unavailable or linked.") }
            close(directory); directory = next
        }
        var attributes = stat()
        guard fstat(directory, &attributes) == 0, attributes.st_uid == getuid() else { throw ACPError.workspace("Historical output directory belongs to another user.") }
        let descriptor = openat(directory, String(parts[7]), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ACPError.workspace("Historical task output is no longer available.") }
        return try readDescriptor(descriptor, path: normalized, maximumBytes: maximumBytes, endingAt: endingAt, requireCurrentUser: true)
    }
    private static func readDescriptor(_ descriptor: Int32, path: String, maximumBytes: Int, endingAt: UInt64?, requireCurrentUser: Bool = false) throws -> AsyncTaskOutput {
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var before = stat(), named = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0,
              !requireCurrentUser || before.st_uid == getuid() else { throw ACPError.workspace("Task output must be a regular file belonging to its user.") }
        try Task.checkCancellation()
        let size = UInt64(before.st_size), end = min(endingAt ?? size, size)
        let offset = end > UInt64(maximumBytes) ? end - UInt64(maximumBytes) : 0
        try file.seek(toOffset: offset)
        let data = try file.read(upToCount: Int(end - offset)) ?? Data()
        guard lstat(path, &named) == 0, named.st_mode & S_IFMT == S_IFREG, before.st_dev == named.st_dev, before.st_ino == named.st_ino else { throw ACPError.workspace("Task output changed while reading. Refresh to try again.") }
        try Task.checkCancellation()
        return AsyncTaskOutput(text: String(decoding: data, as: UTF8.self), truncated: offset > 0 || offset + UInt64(data.count) < size, offset: offset, byteCount: data.count, fileSize: size)
    }
}
