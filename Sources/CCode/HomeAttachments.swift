import AppKit
import CCodeCore

extension AppStore {
    var homeWorkspace: Workspace? { try? Workspace(root: newSessionDraft.projectPath, additionalDirectories: newSessionDraft.additionalDirectories ?? []) }

    func attachHomeFiles() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { attachHomeInputs(panel.urls.map(AttachmentInput.file)) }
    }
    @discardableResult func attachHomeProviders(_ providers: [NSItemProvider]) -> Bool {
        let supported = providers.filter(AttachmentInput.supported)
        guard !supported.isEmpty else { return false }
        attachHomeInputs(supported.map(AttachmentInput.provider)); return true
    }
    func attachHomeInputs(_ inputs: [AttachmentInput]) {
        guard canImportHomeAttachments, homeAttachmentTask?.isCancelled != true else { return }
        guard (newSessionDraft.attachments?.count ?? 0) + pendingHomeAttachmentInputs.count + homeAttachmentReservation + inputs.count <= PromptAttachment.countLimit else { error = "The attachment limit is 10 files."; return }
        guard homeAttachmentResidentBytes + (pendingHomeAttachmentInputs + inputs).reduce(0, { $0 + $1.residentBytes }) < SessionStorage.imageInputLimit else { error = "Queued image data limit is 32 MB."; return }
        pendingHomeAttachmentInputs += inputs
        guard !pendingHomeAttachmentInputs.isEmpty, homeAttachmentTask == nil else { return }
        homeAttachingFiles = true
        homeAttachmentTask = Task {
            defer {
                homeAttachingFiles = false; homeAttachmentTask = nil; pendingHomeAttachmentInputs = []
                homeAttachmentReservation = 0; homeAttachmentResidentBytes = 0
            }
            while !pendingHomeAttachmentInputs.isEmpty, !Task.isCancelled, canImportHomeAttachments {
                let input = pendingHomeAttachmentInputs.removeFirst()
                homeAttachmentReservation = 1; homeAttachmentResidentBytes = input.residentBytes
                do {
                    let attachment = try await input.snapshot(using: storage)
                    try await publishHomeAttachment(attachment)
                } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
                homeAttachmentReservation = 0; homeAttachmentResidentBytes = 0
            }
        }
    }
    func attachHomeContext(_ candidate: ContextCandidate, replacing query: PromptQuery? = nil) async -> Bool {
        guard canImportHomeAttachments, !homeAttachingFiles, homeAttachmentTask == nil, let workspace = homeWorkspace else { return false }
        guard (newSessionDraft.attachments?.count ?? 0) < PromptAttachment.countLimit else { error = "The attachment limit is 10 files."; return false }
        let original = newSessionDraft.text
        var accepted = false
        homeAttachingFiles = true; homeAttachmentReservation = 1
        let operation = Task {
            defer {
                homeAttachingFiles = false; homeAttachmentTask = nil; homeAttachmentReservation = 0
                if Task.isCancelled { pendingHomeAttachmentInputs = [] }
                else if !pendingHomeAttachmentInputs.isEmpty { attachHomeInputs([]) }
            }
            do {
                let attachment = try await storage.importWorkspaceContext(candidate, workspace: workspace)
                try await publishHomeAttachment(attachment)
                if let query, newSessionDraft.text == original { newSessionDraft.text = query.removing(from: original) }
                accepted = true
                await saveNewSessionDraft()
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        }
        homeAttachmentTask = operation
        await withTaskCancellationHandler { await operation.value } onCancel: { operation.cancel() }
        return accepted
    }
    private func publishHomeAttachment(_ attachment: Attachment) async throws {
        do {
            try Task.checkCancellation()
            guard canImportHomeAttachments else { throw CancellationError() }
            if let context = attachment.context {
                guard let workspace = homeWorkspace, workspace.roots.contains(context.root),
                      try await workspace.scoped(context.path).path == (context.resolvedPath ?? context.path) else { throw ACPError.workspace("Project context changed while loading. Select it again.") }
            }
            try Task.checkCancellation()
            guard canImportHomeAttachments else { throw CancellationError() }
            guard (newSessionDraft.attachments ?? []).reduce(attachment.promptBytes, { $0 + $1.promptBytes }) < PromptAttachment.promptLimit else { throw ACPError.workspace("Prompt attachment limit is 6 MB / 10 files.") }
        } catch { try? await storage.discardAttachment(attachment); throw error }
        if newSessionDraft.attachments == nil { newSessionDraft.attachments = [] }
        newSessionDraft.attachments?.append(attachment)
        homeAttachmentReservation = 0
        await saveNewSessionDraft()
    }
    func cancelHomeAttachmentImports() { homeAttachmentTask?.cancel(); pendingHomeAttachmentInputs = [] }
    func removeHomeAttachment(_ attachment: Attachment) {
        guard canImportHomeAttachments else { return }
        newSessionDraft.attachments?.removeAll { $0.id == attachment.id }
        if newSessionDraft.attachments?.isEmpty == true { newSessionDraft.attachments = nil }
        Task { await saveNewSessionDraft() }
    }
}
