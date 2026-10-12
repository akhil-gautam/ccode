import Foundation
import AppKit
import CCodeCore

struct FileCheckpointPreviewRequest: Identifiable {
    let id = UUID()
    let chat: ChatSession
    let itemID: UUID
}

extension AppStore {
    func fileCheckpointCapability(_ chat: ChatSession) -> JSONValue {
        supportsMessageFork(chat) ? chat.handshake["_meta"]["ccode"]["fileCheckpoints"] : .null
    }
    func canPreviewFileCheckpoint(_ chat: ChatSession, at itemID: UUID) -> Bool {
        guard canDeliver(chat), !chat.busy, !chat.hasLiveAgentWork, chat.connection != nil,
              let item = chat.transcript.items.first(where: { $0.id == itemID }), item.kind == "user",
              chat.transcript.items.filter({ $0.id == itemID }).count == 1,
              let reference = item.fileCheckpoint, reference.promptID == itemID else { return false }
        return reference.matches(capability: fileCheckpointCapability(chat), remoteID: chat.transcript.remoteID)
    }
    func previewFileCheckpoint(_ chat: ChatSession, at itemID: UUID) async throws -> FileCheckpointPreview {
        guard canPreviewFileCheckpoint(chat, at: itemID), let peer = chat.connection,
              let reference = chat.transcript.items.first(where: { $0.id == itemID })?.fileCheckpoint else {
            throw ACPError.workspace("This file checkpoint is unavailable. Finish current work and use a message captured by this connection.")
        }
        let generation = chat.connectionGeneration
        let result = try await peer.request("_ccode/checkpoint/preview", params: reference.parameters, timeout: .seconds(20))
        guard chat.connectionGeneration == generation, chat.connection === peer, canPreviewFileCheckpoint(chat, at: itemID),
              chat.transcript.items.first(where: { $0.id == itemID })?.fileCheckpoint == reference else { throw CancellationError() }
        return try FileCheckpointPreview(result, reference: reference)
    }
    func receiveFileCheckpoint(_ value: JSONValue, chat: ChatSession) {
        guard !chat.closing, !chat.loadingHistory,
              chat.transcript.recordFileCheckpoint(value, capability: fileCheckpointCapability(chat)) else { return }
        Task { await save(chat) }
    }
    func canRestoreFileCheckpoint(_ chat: ChatSession, preview: FileCheckpointPreview) -> Bool {
        canPreviewFileCheckpoint(chat, at: preview.reference.promptID) && preview.restoreParameters != nil
            && chat.transcript.items.first(where: { $0.id == preview.reference.promptID })?.fileCheckpoint == preview.reference
            && fileCheckpointCapability(chat)["restoreMethod"] == "_ccode/checkpoint/restore"
            && checkpointRestoreChats(chat).allSatisfy { !$0.busy && !$0.hasLiveAgentWork }
    }
    func restoreFileCheckpoint(_ chat: ChatSession, preview: FileCheckpointPreview) async -> FileCheckpointRestoration? {
        guard canRestoreFileCheckpoint(chat, preview: preview), let peer = chat.connection,
              let params = preview.restoreParameters else { return nil }
        let peers = checkpointRestoreChats(chat), generation = chat.connectionGeneration
        let operation = FileCheckpointRestoration(reference: preview.reference)
        for owner in peers { owner.restoringFiles = true; owner.fileRestoreOperation = operation.id }
        if chat.transcript.fileRestorations == nil { chat.transcript.fileRestorations = [] }
        chat.transcript.fileRestorations?.append(operation)
        let task = Task { @MainActor in
            var result = operation, submitted = false
            defer {
                for owner in peers where owner.fileRestoreOperation == operation.id {
                    owner.restoringFiles = false; owner.fileRestoreOperation = nil; owner.fileRestoreTask = nil
                }
                for owner in checkpointRestoreChats(chat) { driveDelivery(owner) }
            }
            do {
                chat.transcript.draftText = chat.draft.isEmpty ? nil : chat.draft
                chat.transcript.draftAttachments = chat.attachments.isEmpty ? nil : chat.attachments
                chat.transcript.editorDrafts = chat.fileDrafts.filter { $0.value.text != $0.value.original }
                try await storage.save(chat.transcript, id: chat.id)
                let recovery = try await storage.prepareCheckpointRecoveryDirectory()
                guard chat.connectionGeneration == generation, chat.connection === peer else { throw CancellationError() }
                submitted = true
                let response = try await peer.request("_ccode/checkpoint/restore", params: params, timeout: nil)
                result = try operation.finishing(response, recoveryRoot: recovery)
                guard chat.connectionGeneration == generation, chat.connection === peer else { throw CancellationError() }
            } catch {
                if let failure = error as? ACPError, case .disconnected = failure { await peer.close() }
                let preconditionRejected = (error as? ACPError)?.rpcCode == -32602 || (error as? ACPError)?.rpcCode == -32601
                result.status = submitted && !preconditionRejected ? .uncertain : .rejected
                result.details = error.localizedDescription
            }
            if let index = chat.transcript.fileRestorations?.firstIndex(where: { $0.id == operation.id }) { chat.transcript.fileRestorations?[index] = result }
            await save(chat)
            for owner in peers { await refreshWorkspace(owner) }
            return result
        }
        for owner in peers { owner.fileRestoreTask = task }
        return await task.value
    }
    func showCheckpointRecovery(_ result: FileCheckpointRestoration) async {
        guard let path = result.recoveryDirectory else { return }
        do {
            let root = try await storage.prepareCheckpointRecoveryDirectory()
            let folder = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard folder.deletingLastPathComponent().path == root.path, folder.lastPathComponent.hasPrefix("restore-") else {
                throw ACPError.workspace("Recovery copies are outside this app’s storage.")
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } catch { self.error = "Could not open recovery copies: \(error.localizedDescription)" }
    }
    func showCheckpointRecoveryFolder() async {
        do { NSWorkspace.shared.activateFileViewerSelecting([try await storage.prepareCheckpointRecoveryDirectory()]) }
        catch { self.error = "Could not open recovery storage: \(error.localizedDescription)" }
    }
}
