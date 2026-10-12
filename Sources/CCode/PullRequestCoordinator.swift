import Foundation
import CCodeCore

extension AppStore {
    func pullRequestService(for chat: ChatSession) -> PullRequestService { chat.workspace.environment.isLocal ? pullRequests : chat.remotePullRequests }
    func preparePullRequest(_ chat: ChatSession, remote: String? = nil, base: String? = nil, title: String, body: String) async throws -> PullRequestPreview {
        let root = try declaredWorkspaceDirectory(chat, path: chat.workspaceDirectory), service = pullRequestService(for: chat)
        var result: PullRequestPreview?
        try await performPullRequestAction(chat) {
            result = try await service.preview(at: root, remote: remote, base: base, title: title, body: body)
        }
        return result!
    }
    func createPullRequest(_ chat: ChatSession, preview: PullRequestPreview, push: Bool) async throws {
        guard preview.repository.directory == chat.workspaceDirectory else { throw ACPError.workspace("Displayed repository changed. Prepare a fresh PR preview.") }
        _ = try declaredWorkspaceDirectory(chat, path: preview.repository.directory)
        let service = pullRequestService(for: chat)
        try await performPullRequestAction(chat, mutation: PullRequestOperation(repository: preview.repository, kind: .create)) {
            chat.transcript.pullRequest = try await service.create(preview, push: push)
        }
    }
    func publishPullRequest(_ chat: ChatSession, preview: PullRequestPreview) async throws {
        guard preview.repository.directory == chat.workspaceDirectory else { throw ACPError.workspace("Displayed repository changed. Prepare a fresh PR preview.") }
        _ = try declaredWorkspaceDirectory(chat, path: preview.repository.directory)
        let service = pullRequestService(for: chat)
        try await performPullRequestAction(chat, mutation: PullRequestOperation(repository: preview.repository, kind: .publish)) {
            chat.transcript.pullRequest = try await service.publish(preview)
            chat.transcript.pullRequestAutoFix = nil
        }
    }
    func linkPullRequest(_ chat: ChatSession, preview: PullRequestPreview) async throws {
        guard let pr = preview.existing, preview.repository.directory == chat.workspaceDirectory else { throw ACPError.workspace("Prepare a current preview with an existing PR first.") }
        let service = pullRequestService(for: chat)
        try await performPullRequestAction(chat) {
            let current = try await service.status(pr)
            guard current.headSHA == preview.repository.headSHA else { throw ACPError.workspace("PR branch changed. Refresh the preview.") }
            chat.transcript.pullRequest = current
            try await self.persistDelivery(chat)
        }
    }
    func refreshPullRequest(_ chat: ChatSession) async throws {
        guard canDeliver(chat), let pr = chat.transcript.pullRequest else { throw ACPError.workspace("Open a pull request first.") }
        _ = try declaredWorkspaceDirectory(chat, path: pr.repository.directory)
        let generation = chat.connectionGeneration
        let fresh = try await pullRequestService(for: chat).status(pr)
        try Task.checkCancellation()
        guard canDeliver(chat), chat.connectionGeneration == generation, chat.transcript.pullRequest?.number == pr.number,
              chat.transcript.pullRequest?.repository == pr.repository else { throw CancellationError() }
        chat.transcript.pullRequest = fresh; chat.pullRequestError = nil
        try await self.persistDelivery(chat)
    }
    func mergePullRequest(_ chat: ChatSession, method: PullRequestMergeMethod, auto: Bool, expected: PullRequest? = nil) async throws {
        guard let pr = chat.transcript.pullRequest, pr.repository.directory == chat.workspaceDirectory else { throw ACPError.workspace("Select the PR repository and refresh it before merging.") }
        if let expected {
            guard expected.repository == pr.repository, expected.number == pr.number, expected.headSHA == pr.headSHA, expected.baseSHA == pr.baseSHA else { throw ACPError.workspace("PR changed after opening the merge dialog. Review it again.") }
        }
        let service = pullRequestService(for: chat)
        try await performPullRequestAction(chat, mutation: PullRequestOperation(repository: pr.repository, kind: .merge)) {
            chat.transcript.pullRequest = try await service.merge(pr, method: method, auto: auto)
        }
        if auto, chat.transcript.pullRequest?.state == .open { try startPullRequestMonitoring(chat) }
    }
    func disablePullRequestAutoMerge(_ chat: ChatSession) async throws {
        guard let pr = chat.transcript.pullRequest else { throw ACPError.workspace("Open a current PR first.") }
        _ = try declaredWorkspaceDirectory(chat, path: pr.repository.directory)
        let service = pullRequestService(for: chat)
        try await performPullRequestAction(chat, mutation: PullRequestOperation(repository: pr.repository, kind: .disableAutoMerge)) {
            chat.transcript.pullRequest = try await service.disableAutoMerge(pr)
        }
    }
    func fixPullRequestCI(_ chat: ChatSession, autoPolicy: PullRequestAutoFix? = nil) async throws -> UUID {
        guard let pr = chat.transcript.pullRequest else { throw ACPError.workspace("Open a pull request before fixing CI.") }
        _ = try declaredWorkspaceDirectory(chat, path: pr.repository.directory)
        let service = pullRequestService(for: chat)
        var id: UUID?
        try await performPullRequestAction(chat) {
            try await service.validate(pr.repository, requireHead: true)
            let fresh = try await service.status(pr)
            guard fresh.headSHA == pr.repository.headSHA else { throw ACPError.workspace("CI belongs to a different commit. Check out the PR head before requesting fixes.") }
            let logs = try await service.failureLogs(fresh)
            try Task.checkCancellation()
            guard self.canDeliver(chat), !chat.hasLiveAgentWork, chat.pendingPrompts.isEmpty else { throw CancellationError() }
            let context = PullRequestFixContext(pullRequest: fresh, logs: logs), owner = try self.promptOwner(chat)
            var prompt = try PendingPrompt(text: context.prompt(), attachments: [], policy: .nextTurn, executable: owner.0, arguments: owner.1, remoteID: chat.transcript.remoteID)
            prompt.pullRequestContext = context
            let paused = chat.deliveryPaused, oldPolicy = chat.transcript.pullRequestAutoFix
            if let autoPolicy {
                guard chat.transcript.pullRequestAutoFix == autoPolicy, autoPolicy.enabled,
                      autoPolicy.submittedPromptID == nil, autoPolicy.pullRequest.number == fresh.number,
                      autoPolicy.pullRequest.repository == fresh.repository, autoPolicy.pullRequest.headSHA == fresh.headSHA else { throw ACPError.workspace("The automatic CI fix authorization changed.") }
                chat.transcript.pullRequestAutoFix?.submittedPromptID = prompt.id
                chat.transcript.pullRequestAutoFix?.enabled = false
            }
            chat.pendingPrompts.append(prompt); chat.deliveryPaused = false
            do { try await self.persistDelivery(chat) }
            catch { chat.pendingPrompts.removeAll { $0.id == prompt.id }; chat.deliveryPaused = paused; chat.transcript.pullRequestAutoFix = oldPolicy; throw error }
            id = prompt.id
        }
        return id!
    }
    func validatePullRequestFixPrompt(_ chat: ChatSession, id: UUID, text: String) async throws {
        guard let context = chat.pendingPrompts.first(where: { $0.id == id })?.pullRequestContext else { return }
        guard text == context.prompt() else { throw ACPError.workspace("CI fix request changed. Remove it and request a fresh fix.") }
        let pr = context.pullRequest
        _ = try declaredWorkspaceDirectory(chat, path: pr.repository.directory)
        try await pullRequestService(for: chat).validate(pr.repository, requireHead: true)
        let current = try await pullRequestService(for: chat).status(pr)
        guard current.state == .open, current.headSHA == pr.headSHA, current.checks.contains(where: { $0.bucket == .fail || $0.bucket == .cancel }) else { throw ACPError.workspace("CI head, failures or PR state changed. Refresh before requesting a fix.") }
    }
    func setPullRequestAutoFix(_ chat: ChatSession, enabled: Bool) async throws {
        guard canDeliver(chat), let pr = chat.transcript.pullRequest, pr.state == .open else { throw ACPError.workspace("Open a current PR before enabling CI auto-fix.") }
        let prior = chat.transcript.pullRequestAutoFix
        if enabled {
            guard canMutateWorkspace(chat) else { throw ACPError.workspace("Finish current work before authorizing a CI fix.") }
            try await pullRequestService(for: chat).validate(pr.repository, requireHead: true)
            let current = try await pullRequestService(for: chat).status(pr)
            guard current.headSHA == pr.repository.headSHA, current.state == .open else { throw ACPError.workspace("PR head changed. Refresh and review it first.") }
            guard canMutateWorkspace(chat), chat.transcript.pullRequest == pr else { throw CancellationError() }
            chat.transcript.pullRequestAutoFix = PullRequestAutoFix(pullRequest: current, enabled: true)
        } else { chat.transcript.pullRequestAutoFix?.enabled = false }
        do { try await persistDelivery(chat) } catch { chat.transcript.pullRequestAutoFix = prior; throw error }
    }
    func startPullRequestMonitoring(_ chat: ChatSession, interval: Duration = .seconds(30), maximumPolls: Int = 120) throws {
        guard canDeliver(chat), chat.transcript.pullRequest?.state == .open, chat.pullRequestMonitor == nil,
              interval > .zero, maximumPolls > 0, maximumPolls <= 120 else { throw ACPError.workspace("Open a current PR before monitoring its checks.") }
        let id = UUID(), generation = chat.connectionGeneration
        chat.pullRequestMonitorID = id; chat.pullRequestError = nil
        chat.pullRequestMonitor = Task { @MainActor [weak self, weak chat] in
            guard let self, let chat else { return }
            defer { if chat.pullRequestMonitorID == id { chat.pullRequestMonitor = nil; chat.pullRequestMonitorID = nil } }
            do {
                for index in 0..<maximumPolls {
                    guard chat.pullRequestMonitorID == id, chat.connectionGeneration == generation, canDeliver(chat) else { throw CancellationError() }
                    try await refreshPullRequest(chat)
                    if chat.transcript.pullRequest?.state != .open { return }
                    if let policy = chat.transcript.pullRequestAutoFix, policy.enabled, policy.submittedPromptID == nil,
                       let pr = chat.transcript.pullRequest, pr.number == policy.pullRequest.number,
                       pr.repository == policy.pullRequest.repository, pr.headSHA == policy.pullRequest.headSHA,
                       pr.checks.contains(where: { $0.bucket == .fail || $0.bucket == .cancel }), canMutateWorkspace(chat), pullRequestDraftRequest == nil, pullRequestMergeRequest == nil, pullRequestLogsRequest == nil {
                        _ = try await fixPullRequestCI(chat, autoPolicy: policy)
                    }
                    if index + 1 < maximumPolls { try await Task.sleep(for: interval) }
                }
            } catch is CancellationError {} catch { if chat.pullRequestMonitorID == id { chat.pullRequestError = error.localizedDescription } }
        }
    }
    func stopPullRequestMonitoring(_ chat: ChatSession) async {
        let task = chat.pullRequestMonitor; task?.cancel(); await task?.value
        chat.pullRequestMonitor = nil; chat.pullRequestMonitorID = nil
    }

    private func performPullRequestAction(_ chat: ChatSession, mutation: PullRequestOperation? = nil, operation: @escaping @MainActor () async throws -> Void) async throws {
        try Task.checkCancellation()
        guard canMutateWorkspace(chat) else { throw ACPError.workspace("Finish agent work, pending messages and repository operations before changing PR state.") }
        let owners = checkpointRestoreChats(chat), previous = chat.transcript.pullRequestOperation
        for owner in owners { owner.workspaceWrites += 1 }
        let task = Task { @MainActor in
            var issued = false
            defer {
                for owner in owners { owner.workspaceWrites -= 1; owner.workspaceActionTask = nil }
                for owner in checkpointRestoreChats(chat) { driveDelivery(owner) }
            }
            do {
                if let mutation {
                    chat.transcript.pullRequestOperation = mutation
                    do { try await self.persistDelivery(chat) }
                    catch { chat.transcript.pullRequestOperation = previous; throw error }
                }
                try Task.checkCancellation()
                if mutation != nil { issued = true }
                try await operation()
                if let mutation, chat.transcript.pullRequestOperation?.id == mutation.id {
                    chat.transcript.pullRequestOperation?.state = .completed
                    try await self.persistDelivery(chat)
                }
                chat.pullRequestError = nil
            } catch {
                if issued, let mutation, chat.transcript.pullRequestOperation?.id == mutation.id {
                    chat.transcript.pullRequestOperation?.state = .uncertain
                    chat.transcript.pullRequestOperation?.details = "GitHub operation did not settle locally. Inspect GitHub and refresh before repeating: " + error.localizedDescription
                    try? await self.persistDelivery(chat)
                }
                chat.pullRequestError = error.localizedDescription
                throw error
            }
        }
        for owner in owners { owner.workspaceActionTask = task }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
