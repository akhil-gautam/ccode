import Foundation
import CCodeCore

extension AppStore {
    func validateReviewFeedbackPrompt(_ chat: ChatSession, id: UUID, text: String) async throws {
        guard let contexts = chat.pendingPrompts.first(where: { $0.id == id })?.reviewContexts else { return }
        guard !contexts.isEmpty, contexts.count <= 64, text == (try ReviewComment.prompt(contexts)) else {
            throw ACPError.workspace("Review feedback changed. Restore it to the draft and review before sending.")
        }
        do {
            for context in contexts { try Task.checkCancellation(); try await context.validate(at: declaredWorkspaceDirectory(chat, path: context.root), workspace: chat.workspace) }
        } catch is CancellationError { throw CancellationError() }
        catch {
            if chat.transcript.codeReview?.status == .complete,
               chat.transcript.codeReview?.findings.contains(where: { contexts.contains($0.context) }) == true {
                chat.transcript.codeReview?.status = .stale
                chat.transcript.codeReview?.details = error.localizedDescription
            }
            throw error
        }
    }
    func addReviewComment(_ chat: ChatSession, path: String, diff: String, baseRevision: String?, stagedOnly: Bool, line: DiffLine?, text: String, directory: String? = nil) async throws {
        guard canDeliver(chat), !chat.submittingReview, chat.reviewComments.count < 64 else { throw ACPError.workspace("Finish submitting the current review, or remove a comment before adding more.") }
        let root = try declaredWorkspaceDirectory(chat, path: directory ?? chat.workspaceDirectory)
        guard root == chat.workspaceDirectory else { throw ACPError.workspace("The displayed folder changed. Refresh the diff before adding feedback.") }
        let comment = try await ReviewComment.capture(at: root, path: path, diff: diff, baseRevision: baseRevision, stagedOnly: stagedOnly, line: line, text: text, workspace: chat.workspace)
        guard !Task.isCancelled, canDeliver(chat), !chat.submittingReview, chat.reviewComments.count < 64, chat.workspaceDirectory == root else { throw ACPError.workspace("The session changed before feedback was added. Your text was kept.") }
        chat.reviewComments.append(comment)
        do { try await persistDelivery(chat) }
        catch { chat.reviewComments.removeAll { $0.id == comment.id }; throw error }
    }
    func removeReviewComment(_ chat: ChatSession, id: UUID) {
        guard !chat.submittingReview else { return }
        chat.reviewComments.removeAll { $0.id == id }
        Task { await save(chat) }
    }
    /// Editing a note keeps its captured source, including any stale revision.
    /// A failed save keeps the prior durable note; the editor retains new text.
    func editReviewComment(_ chat: ChatSession, id: UUID, text: String) async throws {
        guard canDeliver(chat), !chat.busy, let index = chat.reviewComments.firstIndex(where: { $0.id == id }) else {
            throw ACPError.workspace("The comment is unavailable or current work must finish before editing it. Your text was kept.")
        }
        let original = chat.reviewComments[index]
        let updated = try original.updatingText(text)
        chat.submittingReview = true
        defer { chat.submittingReview = false; driveDelivery(chat) }
        chat.reviewComments[index] = updated
        do { try await persistDelivery(chat) }
        catch {
            if let current = chat.reviewComments.firstIndex(where: { $0.id == id }), chat.reviewComments[current] == updated {
                chat.reviewComments[current] = original
            }
            throw error
        }
    }
    /// Explicitly replace a captured source with the displayed file/line. This
    /// creates a new receipt, retains the note and never submits feedback.
    func rebindReviewComment(_ chat: ChatSession, id: UUID, path: String, diff: String, baseRevision: String?, stagedOnly: Bool, line: DiffLine?, directory: String? = nil) async throws {
        guard canDeliver(chat), !chat.busy, !chat.hasLiveAgentWork, !checkpointRestorationBlocks(chat), chat.pendingPrompts.isEmpty, chat.pendingSettings.isEmpty,
              let original = chat.reviewComments.first(where: { $0.id == id }), original.path == path, original.root == chat.workspaceDirectory, directory == nil || directory == original.root else {
            throw ACPError.workspace("Display this comment's file and finish current work before updating its context. Your feedback was kept.")
        }
        let operation = UUID(), generation = chat.connectionGeneration
        chat.submittingReview = true; chat.reviewOperation = operation
        defer { chat.submittingReview = false; if chat.reviewOperation == operation { chat.reviewOperation = nil }; driveDelivery(chat) }
        let updated = try await ReviewComment.capture(at: original.root, path: path, diff: diff, baseRevision: baseRevision, stagedOnly: stagedOnly, line: line, text: original.text, workspace: chat.workspace)
        try Task.checkCancellation()
        guard chat.reviewOperation == operation, chat.connectionGeneration == generation else { throw CancellationError() }
        guard canDeliver(chat), !chat.hasLiveAgentWork, !checkpointRestorationBlocks(chat), chat.pendingPrompts.isEmpty, chat.pendingSettings.isEmpty,
              let index = chat.reviewComments.firstIndex(where: { $0 == original }) else {
            throw ACPError.workspace("The session changed while checking the selected context. Your feedback was kept.")
        }
        guard updated.root == original.root else { throw ACPError.workspace("The selected context belongs to a different repository. Your feedback was kept.") }
        chat.reviewComments[index] = updated
        do { try await persistDelivery(chat) }
        catch {
            if let current = chat.reviewComments.firstIndex(where: { $0 == updated }) { chat.reviewComments[current] = original }
            throw error
        }
    }
    /// Validate every comment before publishing exactly one durable outbox item.
    /// It never consumes the unrelated composer or its attachment snapshots.
    @discardableResult func submitReviewComments(_ chat: ChatSession) async throws -> Bool {
        guard !chat.reviewComments.isEmpty else { return false }
        guard canDeliver(chat), !chat.busy, !chat.hasLiveAgentWork, !checkpointRestorationBlocks(chat), chat.pendingPrompts.isEmpty, chat.pendingSettings.isEmpty else {
            throw ACPError.workspace("Wait for current work and pending messages to finish before submitting review feedback.")
        }
        let comments = chat.reviewComments
        let operation = UUID(), generation = chat.connectionGeneration
        chat.submittingReview = true; chat.reviewOperation = operation
        defer { chat.submittingReview = false; if chat.reviewOperation == operation { chat.reviewOperation = nil }; driveDelivery(chat) }
        for comment in comments {
            try Task.checkCancellation()
            guard chat.reviewOperation == operation, chat.connectionGeneration == generation else { throw CancellationError() }
            try await comment.validate(at: declaredWorkspaceDirectory(chat, path: comment.root), workspace: chat.workspace)
        }
        try Task.checkCancellation()
        guard chat.reviewOperation == operation, chat.connectionGeneration == generation else { throw CancellationError() }
        guard canDeliver(chat), !chat.hasLiveAgentWork, !checkpointRestorationBlocks(chat), chat.reviewComments == comments, chat.pendingPrompts.isEmpty, chat.pendingSettings.isEmpty else {
            throw ACPError.workspace("The session changed while validating feedback. Your comments were kept.")
        }
        let (executable, arguments) = try promptOwner(chat)
        var prompt = try PendingPrompt(text: ReviewComment.prompt(comments), attachments: [], policy: .nextTurn, executable: executable, arguments: arguments, remoteID: chat.transcript.remoteID)
        prompt.reviewContexts = comments
        let paused = chat.deliveryPaused
        chat.pendingPrompts.append(prompt)
        chat.deliveryPaused = false // Explicit submission cannot resume any older work: the queue was checked empty.
        chat.reviewComments = []
        do { try await persistDelivery(chat) }
        catch {
            chat.pendingPrompts.removeAll { $0.id == prompt.id }
            chat.reviewComments = comments + chat.reviewComments
            if chat.reviewOperation == operation { chat.deliveryPaused = paused }
            throw error
        }
        return true
    }
}
