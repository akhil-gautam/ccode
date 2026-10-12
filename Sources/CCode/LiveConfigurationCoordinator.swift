import Foundation
import CCodeCore
extension AppStore {
    func liveConfigurationCapability(_ chat: ChatSession) -> LiveConfigurationCapability? {
        guard supportsMessageFork(chat), chat.connection != nil else { return nil }
        return LiveConfigurationCapability(chat.handshake["_meta"]["ccode"]["configurationManagement"])
    }
    func canChangeLiveConfiguration(_ chat: ChatSession) -> Bool {
        liveConfigurationCapability(chat) != nil && canDeliver(chat) && !chat.busy && !chat.hasLiveAgentWork && chat.pendingPrompts.isEmpty && chat.pendingSettings.isEmpty
    }
    func performLiveConfiguration(_ chat: ChatSession, operation: LiveConfigurationOperation) async throws -> LiveConfigurationResult {
        guard canDeliver(chat), !chat.closing, chat.liveConfigurationOperation == nil, let capability = liveConfigurationCapability(chat), let peer = chat.connection,
              let session = chat.transcript.remoteID, [.ready, .running].contains(chat.state), !operation.mutating || canChangeLiveConfiguration(chat) else {
            throw ACPError.workspace("Live configuration requires a connected compatible agent. Finish this session's work and queued changes before modifying its servers or extensions.")
        }
        let identity = UUID(), generation = chat.connectionGeneration
        let params = try capability.parameters(sessionID: session, operation: operation)
        chat.liveConfigurationOperation = identity
        let task = Task { @MainActor in
            defer {
                if chat.liveConfigurationOperation == identity { chat.liveConfigurationOperation = nil; chat.liveConfigurationTask = nil; driveDelivery(chat) }
            }
            do {
                let response = try await peer.request("_ccode/configuration", params: params, timeout: .seconds(60))
                try Task.checkCancellation()
                guard chat.connectionGeneration == generation, chat.connection === peer, chat.transcript.remoteID == session, !chat.closing else { throw CancellationError() }
                return try LiveConfigurationResult(response, capability: capability, sessionID: session, operation: operation)
            } catch { if operation.mutating { pauseDelivery(chat) }; throw error }
        }
        chat.liveConfigurationTask = task
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
