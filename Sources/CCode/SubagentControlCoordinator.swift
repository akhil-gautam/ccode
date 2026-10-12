import Foundation
import CCodeCore

extension AppStore {
    func canStopSubagent(_ chat: ChatSession, id: String) -> Bool {
        let contract = chat.handshake["_meta"]["ccode"]["nativeSubagentStop"]
        guard !chat.closing, chat.connection != nil, chat.transcript.remoteID != nil,
              contract["version"] == 1, contract["stopMethod"] == "_session/async_task/stop",
              chat.childOwners.contains(id), !chat.stoppingSubagents.contains(id),
              let child = chat.transcript.subagent(id), child.isRunning else { return false }
        let control = child.capabilities["_meta"]["ccode"]["stopTask"]
        guard control["version"] == 1, control["method"] == contract["stopMethod"],
              let handle = control["taskId"].optionalString, handle.hasPrefix("ccode-subagent:"),
              handle.count > "ccode-subagent:".count else { return false }
        return (chat.transcript.subagents ?? []).filter {
            chat.childOwners.contains($0.id) && $0.capabilities["_meta"]["ccode"]["stopTask"]["taskId"] == .string(handle)
        }.count == 1 && !chat.asyncTaskOwners.contains { $0.task == handle }
    }

    func stopSubagent(_ chat: ChatSession, id: String) async {
        guard canStopSubagent(chat, id: id), let peer = chat.connection,
              let root = chat.transcript.remoteID, let child = chat.transcript.subagent(id) else { return }
        let generation = chat.connectionGeneration
        let handle = child.capabilities["_meta"]["ccode"]["stopTask"]["taskId"]
        chat.stoppingSubagents.insert(id); chat.subagentStopErrors.removeValue(forKey: id)
        defer { if chat.connectionGeneration == generation { chat.stoppingSubagents.remove(id) } }
        do {
            let result = try await peer.request("_session/async_task/stop", params: ["sessionId": .string(root), "asyncTaskId": handle], timeout: .seconds(20))
            guard chat.connectionGeneration == generation, chat.connection === peer, chat.childOwners.contains(id),
                  chat.transcript.subagent(id)?.capabilities["_meta"]["ccode"]["stopTask"]["taskId"] == handle else { return }
            if result["stopped"] == true {
                if chat.transcript.subagent(id)?.isRunning == true {
                    _ = chat.transcript.applyAgentWork(["sessionId": .string(child.parentID), "update": ["sessionUpdate": "subagent_state_update", "subagentSessionId": .string(id), "state": "cancelled"]], owners: &chat.childOwners)
                }
                // Only this stopped child's decisions are cancelled; never its parent or sibling callbacks.
                for approval in chat.approvals where approval.request["sessionId"] == .string(id) {
                    resolveApproval(chat, id: approval.id, option: nil)
                }
                for interaction in chat.interactions where interaction.request.sessionID == id {
                    try? resolveInteraction(chat, id: interaction.id, action: .cancel)
                }
                chat.urlInteractions.removeAll { $0.sessionID == id }
                await save(chat)
            } else if chat.transcript.subagent(id)?.isRunning == true {
                chat.subagentStopErrors[id] = "The agent could not stop this subagent. Check its current state before trying again."
            }
        } catch {
            if chat.connectionGeneration == generation, chat.connection === peer { chat.subagentStopErrors[id] = error.localizedDescription }
        }
    }
}
