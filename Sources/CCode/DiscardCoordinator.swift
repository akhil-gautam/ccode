import Foundation
import AppKit
import CCodeCore

extension AppStore {
    func canDiscardChanges(_ chat: ChatSession) -> Bool {
        chat.workspace.environment.isLocal && canMutateWorkspace(chat)
    }
    func canMutateWorkspace(_ chat: ChatSession) -> Bool {
        canDeliver(chat) && sessions.contains { $0.id == chat.id && !$0.archived }
            && checkpointRestoreChats(chat).allSatisfy {
                !$0.busy && !$0.hasLiveAgentWork && !$0.loadingHistory && $0.pendingPrompts.isEmpty && $0.pendingSettings.isEmpty && $0.terminalTabs.isEmpty && !$0.previewActive
            }
    }
    func previewDiscardChanges(_ chat: ChatSession, paths: [String], scope: DiscardScope) async throws -> DiscardPreview {
        guard canDiscardChanges(chat) else { throw ACPError.workspace("Finish agent work, queued messages, settings and terminals in this workspace before discarding changes.") }
        let directory = try declaredWorkspaceDirectory(chat, path: chat.workspaceDirectory)
        let preview = try await Repository.previewDiscard(at: directory, paths: paths, scope: scope)
        try Task.checkCancellation()
        guard canDiscardChanges(chat), chat.workspaceDirectory == directory else { throw ACPError.workspace("Workspace activity changed. Finish current work and refresh the discard preview.") }
        return preview
    }
    func discardChanges(_ chat: ChatSession, preview: DiscardPreview) async throws -> DiscardResult {
        try Task.checkCancellation()
        guard canDiscardChanges(chat), preview.root == chat.workspaceDirectory,
              chat.transcript.discards?.contains(where: { $0.id == preview.id }) != true else {
            throw ACPError.workspace("This discard is unavailable. Finish current work and request a fresh preview.")
        }
        _ = try declaredWorkspaceDirectory(chat, path: preview.root)
        let owners = checkpointRestoreChats(chat), operation = DiscardResult(preparing: preview)
        for owner in owners { owner.restoringFiles = true; owner.discardOperation = operation.id }
        if chat.transcript.discards == nil { chat.transcript.discards = [] }
        chat.transcript.discards?.append(operation)
        let task = Task { @MainActor in
            var savedReceipt = false
            defer {
                for owner in owners where owner.discardOperation == operation.id {
                    owner.restoringFiles = false; owner.discardOperation = nil; owner.discardTask = nil
                }
                for owner in checkpointRestoreChats(chat) { driveDelivery(owner) }
            }
            do {
                try await persistDelivery(chat)
                savedReceipt = true
                var result = try await Repository.discard(preview, at: preview.root)
                result.startedAt = operation.startedAt
                if result.status != .completed {
                    for owner in checkpointRestoreChats(chat) { owner.deliveryPaused = true }
                }
                if let index = chat.transcript.discards?.firstIndex(where: { $0.id == operation.id }) { chat.transcript.discards?[index] = result }
                do { try await persistDelivery(chat) }
                catch {
                    result.details = (result.details.map { $0 + "\n" } ?? "") + "Could not save the final receipt: " + error.localizedDescription + ". Inspect the recovery manifest before another operation."
                    if let index = chat.transcript.discards?.firstIndex(where: { $0.id == operation.id }) { chat.transcript.discards?[index] = result }
                    for owner in checkpointRestoreChats(chat) { owner.deliveryPaused = true }
                    self.error = result.details
                }
                for owner in owners { await refreshWorkspace(owner) }
                return result
            } catch {
                if savedReceipt {
                    var rejected = operation; rejected.status = .rejected; rejected.details = error.localizedDescription
                    if let index = chat.transcript.discards?.firstIndex(where: { $0.id == operation.id }) { chat.transcript.discards?[index] = rejected }
                    for owner in checkpointRestoreChats(chat) { owner.deliveryPaused = true }
                    try? await persistDelivery(chat)
                } else {
                    chat.transcript.discards?.removeAll { $0.id == operation.id }
                }
                throw error
            }
        }
        for owner in owners { owner.discardTask = task }
        return try await task.value
    }
    func refreshDiscardPreview(_ chat: ChatSession, preview: DiscardPreview) async throws -> DiscardPreview {
        guard preview.root == chat.workspaceDirectory else { throw ACPError.workspace("Discard belongs to another workspace.") }
        return try await previewDiscardChanges(chat, paths: preview.selectedPaths, scope: preview.scope)
    }
    func showDiscardRecovery(_ result: DiscardResult, chat: ChatSession) async {
        do {
            guard chat.workspace.environment.isLocal else { throw ACPError.workspace("Remote recovery paths cannot be opened in Finder.") }
            let directory = try declaredWorkspaceDirectory(chat, path: result.root)
            let folder = try await Repository.discardRecoveryDirectory(result, at: directory)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { self.error = "Could not open recovery copies: " + error.localizedDescription }
    }
}
