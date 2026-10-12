import Foundation
import CCodeCore

extension AppStore {
    private func requireReviewIdle(_ chat: ChatSession) throws {
        guard canDeliver(chat), !chat.busy, !chat.hasLiveAgentWork, !checkpointRestorationBlocks(chat), chat.pendingPrompts.isEmpty, chat.pendingSettings.isEmpty else {
            throw ACPError.workspace("Finish current work and pending messages before requesting a review or fix.")
        }
    }
    private func checkReviewOperation(_ chat: ChatSession, operation: UUID, generation: UUID) throws {
        try Task.checkCancellation()
        guard chat.reviewOperation == operation, chat.connectionGeneration == generation, canDeliver(chat), !chat.hasLiveAgentWork,
              !checkpointRestorationBlocks(chat), chat.pendingPrompts.isEmpty, chat.pendingSettings.isEmpty else { throw CancellationError() }
    }
    @discardableResult func requestCodeReview(_ chat: ChatSession) async throws -> UUID {
        try requireReviewIdle(chat)
        let operation = UUID(), generation = chat.connectionGeneration
        chat.submittingReview = true; chat.reviewOperation = operation
        defer { chat.submittingReview = false; if chat.reviewOperation == operation { chat.reviewOperation = nil }; driveDelivery(chat) }
        let review = try await CodeReview.capture(at: declaredWorkspaceDirectory(chat, path: chat.workspaceDirectory), workspace: chat.workspace)
        try checkReviewOperation(chat, operation: operation, generation: generation)
        let owner = try promptOwner(chat)
        let prompt = try PendingPrompt(id: review.id, text: review.prompt(), attachments: [], policy: .nextTurn, executable: owner.0, arguments: owner.1, remoteID: chat.transcript.remoteID)
        let prior = chat.transcript.codeReview, paused = chat.deliveryPaused
        chat.transcript.codeReview = review; chat.pendingPrompts.append(prompt); chat.deliveryPaused = false
        do { try await persistDelivery(chat) }
        catch {
            chat.pendingPrompts.removeAll { $0.id == prompt.id }
            if chat.transcript.codeReview?.id == review.id { chat.transcript.codeReview = prior }
            if chat.reviewOperation == operation { chat.deliveryPaused = paused }
            throw error
        }
        return review.id
    }
    func validateCodeReviewPrompt(_ chat: ChatSession, id: UUID, text: String) async throws {
        guard let review = chat.transcript.codeReview, review.id == id else { return }
        do {
            guard text == (try review.prompt()) else { throw CodeReviewError.invalidReport("The review request changed. Remove it and request a fresh review.") }
            try await review.validate(at: declaredWorkspaceDirectory(chat, path: review.root), workspace: chat.workspace)
        } catch {
            failCodeReview(chat, id: id, error: error)
            throw error
        }
    }
    func completeCodeReview(_ chat: ChatSession, id: UUID, reason: String) async {
        guard var review = chat.transcript.codeReview, review.id == id, review.status == .running else { return }
        guard reason == "end_turn", chat.state != .stopping else { interruptCodeReview(chat, details: "Review stopped. Request a fresh review when ready."); return }
        let generation = chat.connectionGeneration, operation = chat.promptOperation
        guard let start = chat.transcript.items.firstIndex(where: { $0.id == id && $0.kind == "user" }) else {
            failCodeReview(chat, id: id, error: CodeReviewError.invalidReport("The review response has no matching request.")); return
        }
        let turn = chat.transcript.items.dropFirst(start + 1).prefix(while: { $0.kind != "user" })
        do {
            if let proposals = try CodeReview.parse(turn.filter { $0.kind == "assistant" }.map(\.text), reviewID: id) {
                review.findings = try await review.resolve(proposals, at: declaredWorkspaceDirectory(chat, path: review.root), workspace: chat.workspace)
                review.status = .complete; review.details = nil
            } else {
                review.status = .unstructured; review.details = "The response has no structured findings. Read the review in the conversation."
            }
        } catch {
            review.findings = []
            if case CodeReviewError.stale = error { review.status = .stale }
            else if error is CancellationError { review.status = .interrupted }
            else { review.status = .unstructured }
            review.details = error.localizedDescription
        }
        guard chat.connectionGeneration == generation, chat.promptOperation == operation,
              chat.transcript.codeReview?.id == id, chat.transcript.codeReview?.status == .running, chat.state != .stopping else { return }
        chat.transcript.codeReview = review
    }
    func failCodeReview(_ chat: ChatSession, id: UUID?, error: any Error) {
        guard let id, chat.transcript.codeReview?.id == id, let status = chat.transcript.codeReview?.status,
              status == .queued || status == .running else { return }
        if case CodeReviewError.stale = error { chat.transcript.codeReview?.status = .stale }
        else { chat.transcript.codeReview?.status = error is CancellationError ? .interrupted : .failed }
        chat.transcript.codeReview?.findings = []; chat.transcript.codeReview?.details = error.localizedDescription
    }
    func interruptCodeReview(_ chat: ChatSession, details: String) {
        guard chat.transcript.codeReview?.status == .running else { return }
        chat.transcript.codeReview?.status = .interrupted; chat.transcript.codeReview?.findings = []; chat.transcript.codeReview?.details = details
    }
    @discardableResult func fixCodeReview(_ chat: ChatSession, findingIDs: Set<UUID>? = nil) async throws -> Bool {
        try requireReviewIdle(chat)
        guard let review = chat.transcript.codeReview, review.status == .complete else { throw ACPError.workspace("Complete a fresh review before requesting fixes.") }
        let ids = findingIDs ?? Set(review.findings.map(\.id))
        guard !ids.isEmpty else { return false }
        guard ids.isSubset(of: Set(review.findings.map(\.id))) else { throw ACPError.workspace("Some findings no longer belong to this review. Request a fresh review.") }
        let comments = review.findings.filter { ids.contains($0.id) }.map(\.context)
        let operation = UUID(), generation = chat.connectionGeneration
        chat.submittingReview = true; chat.reviewOperation = operation
        defer { chat.submittingReview = false; if chat.reviewOperation == operation { chat.reviewOperation = nil }; driveDelivery(chat) }
        do {
            try await review.validate(at: declaredWorkspaceDirectory(chat, path: review.root), workspace: chat.workspace)
            for comment in comments { try await comment.validate(at: declaredWorkspaceDirectory(chat, path: comment.root), workspace: chat.workspace) }
        } catch {
            if case CodeReviewError.stale = error, chat.transcript.codeReview?.id == review.id {
                chat.transcript.codeReview?.status = .stale; chat.transcript.codeReview?.details = error.localizedDescription
            }
            throw error
        }
        try checkReviewOperation(chat, operation: operation, generation: generation)
        guard chat.transcript.codeReview?.id == review.id, chat.transcript.codeReview?.status == .complete else { throw CancellationError() }
        let owner = try promptOwner(chat), paused = chat.deliveryPaused
        var prompt = try PendingPrompt(text: ReviewComment.prompt(comments), attachments: [], policy: .nextTurn, executable: owner.0, arguments: owner.1, remoteID: chat.transcript.remoteID)
        prompt.reviewContexts = comments
        chat.pendingPrompts.append(prompt); chat.deliveryPaused = false
        do { try await persistDelivery(chat) }
        catch { chat.pendingPrompts.removeAll { $0.id == prompt.id }; if chat.reviewOperation == operation { chat.deliveryPaused = paused }; throw error }
        return true
    }
}
