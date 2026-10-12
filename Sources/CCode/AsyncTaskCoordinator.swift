import Foundation
import CCodeCore

extension AppStore {
    func openAsyncTask(_ chat: ChatSession, id: AsyncTaskIdentity) {
        guard isChatVisible(chat.id), canDeliver(chat), chat.transcript.asyncTask(id) != nil else { return }
        chat.selectedSubagentID = nil; chat.selectedAsyncTaskID = id; setPane("tasks", for: chat)
    }
    func canStopAsyncTask(_ chat: ChatSession, id: AsyncTaskIdentity) -> Bool {
        let capability = chat.handshake["_meta"]["ccode"]["asyncTasks"]
        guard capability["version"] == 1, capability["stopMethod"] == "_session/async_task/stop",
              chat.connection != nil, chat.asyncTaskOwners.contains(id), !chat.stoppingAsyncTasks.contains(id),
              let task = chat.transcript.asyncTask(id), task.isRunning, task.canStop else { return false }
        // The provider control uses its root query and task ID. Conflicting routed IDs cannot authorize that request.
        return chat.asyncTaskOwners.filter { $0.task == id.task }.count == 1
    }
    func stopAsyncTask(_ chat: ChatSession, id: AsyncTaskIdentity) async {
        guard canStopAsyncTask(chat, id: id), let peer = chat.connection, let root = chat.transcript.remoteID else { return }
        let generation = chat.connectionGeneration
        chat.stoppingAsyncTasks.insert(id); chat.asyncTaskErrors.removeValue(forKey: id)
        defer { if chat.connectionGeneration == generation { chat.stoppingAsyncTasks.remove(id) } }
        do {
            let result = try await peer.request("_session/async_task/stop", params: ["sessionId": .string(root), "asyncTaskId": .string(id.task)], timeout: .seconds(20))
            guard chat.connectionGeneration == generation, chat.connection === peer, chat.asyncTaskOwners.contains(id) else { return }
            if result["stopped"] == true {
                // An actual provider acknowledgement, never an optimistic local Stop.
                if chat.transcript.asyncTask(id)?.isRunning == true {
                    _ = chat.transcript.applyAsyncWork(["sessionId": .string(id.owner), "update": ["sessionUpdate": "async_task_state_update", "asyncTaskId": .string(id.task), "state": "stopped"]], children: chat.childOwners, owners: &chat.asyncTaskOwners)
                }
                await save(chat)
            } else if chat.transcript.asyncTask(id)?.isRunning == true {
                chat.asyncTaskErrors[id] = "The agent could not stop this task. Check its current state before trying again."
            }
        } catch {
            if chat.connectionGeneration == generation, chat.connection === peer { chat.asyncTaskErrors[id] = error.localizedDescription }
        }
    }
    func readAsyncOutput(_ chat: ChatSession, id: AsyncTaskIdentity, endingAt: UInt64? = nil) async throws -> AsyncTaskOutput? {
        guard let task = chat.transcript.asyncTask(id) else { throw CancellationError() }
        guard let path = task.outputFilePath else { return nil }
        let generation = chat.connectionGeneration
        let live = chat.connection != nil && chat.asyncTaskOwners.contains(id)
        let result: AsyncTaskOutput
        if live {
            result = try await Task.detached(priority: .utility) { try AsyncTaskOutput.read(path: path, endingAt: endingAt) }.value
        } else {
            guard selected === chat, !chat.closing, let root = chat.transcript.remoteID,
                  let info = sessions.first(where: { $0.id == chat.id }),
                  AgentSettings.usesClaudeHistory(executable: info.agentExecutable ?? settings.executable, arguments: info.agentArguments ?? settings.arguments) || supportsMessageFork(chat) else {
                throw ACPError.workspace("Reconnect and wait for the agent to announce this task before reading its output.")
            }
            let native = try await storage.loadClaudeTranscript(sessionID: root, cwd: info.projectPath)
            guard selected === chat, !chat.closing, chat.connectionGeneration == generation, chat.transcript.remoteID == root else { throw CancellationError() }
            guard let source = native?.asyncTask(id), source.toolCallID == task.toolCallID,
                  source.description == task.description, source.taskType == task.taskType, source.outputFilePath == path else {
                throw ACPError.workspace("This output is no longer associated with the task's native history. Refresh the session.")
            }
            result = try await Task.detached(priority: .utility) { try AsyncTaskOutput.readClaudeHistory(path: path, taskID: id.task, rootID: root, endingAt: endingAt) }.value
            guard selected === chat, !chat.closing, chat.transcript.remoteID == root else { throw CancellationError() }
        }
        guard chat.connectionGeneration == generation, !live || chat.asyncTaskOwners.contains(id),
              let current = chat.transcript.asyncTask(id), current.outputFilePath == path,
              current.toolCallID == task.toolCallID, current.description == task.description else { throw CancellationError() }
        return result
    }
}
