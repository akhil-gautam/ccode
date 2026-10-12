import Foundation
import CCodeCore

extension AppStore {
    func supportsSteering(_ chat: ChatSession) -> Bool {
        supportsMessageFork(chat) && chat.handshake["_meta"]["steering"]["supported"].bool && !chat.steeringUnavailable
    }
    func promptOwner(_ chat: ChatSession) throws -> (String, [String]) {
        guard let info = sessions.first(where: { $0.id == chat.id && !$0.archived }) else { throw ACPError.workspace("Session is no longer available.") }
        return (info.agentExecutable ?? settings.executable, info.agentArguments ?? settings.arguments)
    }
    func enqueuePrompt(_ chat: ChatSession, text: String, policy: DeliveryPolicy) {
        do {
            guard chat.pendingPrompts.count < 16 else { throw ACPError.workspace("The message queue is full. Remove or finish a pending message first.") }
            let (executable, arguments) = try promptOwner(chat)
            let actualPolicy: DeliveryPolicy = supportsSteering(chat) && policy == .steer ? .steer : .nextTurn
            let prompt = try PendingPrompt(text: text, attachments: chat.attachments, policy: actualPolicy, executable: executable, arguments: arguments, remoteID: chat.transcript.remoteID)
            chat.pendingPrompts.append(prompt)
            consumeDraft(chat, text: text, attachments: prompt.attachments)
            if chat.state == .stopping { chat.deliveryPaused = true }
            Task {
                do { try await persistDelivery(chat); driveDelivery(chat) }
                catch { failQueuedPrompt(chat, id: prompt.id, error: error) }
            }
        } catch { chat.lastError = error.localizedDescription }
    }
    func consumeDraft(_ chat: ChatSession, text: String, attachments: [Attachment]) {
        if chat.draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { chat.draft = "" }
        let ids = Set(attachments.map(\.id))
        chat.attachments.removeAll { ids.contains($0.id) }
    }
    func promptBlocks(_ chat: ChatSession, text: String, attachments: [Attachment]) async throws -> [JSONValue] {
        try PendingPrompt.validate(text: text, attachments: attachments)
        var blocks: [JSONValue] = text.isEmpty ? [] : [["type": "text", "text": .string(text)]]
        for attachment in attachments {
            let content = try await storage.attachmentPrompt(attachment, capabilities: chat.handshake["agentCapabilities"]["promptCapabilities"])
            blocks += content
            guard try JSONEncoder().encode(blocks).count < PromptAttachment.promptLimit else { throw ACPError.workspace("Prompt exceeds the 6 MB limit.") }
        }
        guard try JSONEncoder().encode(blocks).count < PromptAttachment.promptLimit else { throw ACPError.workspace("Prompt exceeds the 6 MB limit.") }
        return blocks
    }
    func persistDelivery(_ chat: ChatSession) async throws {
        chat.transcript.draftText = chat.draft.isEmpty ? nil : chat.draft
        chat.transcript.draftAttachments = chat.attachments.isEmpty ? nil : chat.attachments
        chat.transcript.editorDrafts = chat.fileDrafts.filter { $0.value.text != $0.value.original }
        try await storage.save(chat.transcript, id: chat.id)
    }
    func validatePromptOwner(_ chat: ChatSession, id: UUID) throws {
        guard let prompt = chat.pendingPrompts.first(where: { $0.id == id && $0.state == .queued }) else { throw CancellationError() }
        if let peer=prompt.peerMessage {
            guard peer.id == prompt.id,peer.recipientID == chat.id,prompt.text == peer.wireText,prompt.attachments.isEmpty,prompt.policy == .nextTurn else { throw ACPError.workspace("Agent message provenance no longer matches its queued receipt.") }
        }
        let (executable, arguments) = try promptOwner(chat)
        guard prompt.executable == executable, prompt.arguments == arguments,
              prompt.remoteID == nil || prompt.remoteID == chat.transcript.remoteID else { throw ACPError.workspace("This message belongs to a different agent or session. Restore it to the draft to review before sending.") }
    }
    @discardableResult func registerSubmission(_ chat: ChatSession, text: String, attachments: [Attachment], id queuedID: UUID?, policy: DeliveryPolicy, startedSession: Bool?) throws -> UUID {
        let id: UUID
        if let queuedID {
            try validatePromptOwner(chat, id: queuedID)
            id = queuedID
        } else {
            let (executable, arguments) = try promptOwner(chat)
            let prompt = try PendingPrompt(text: text, attachments: attachments, policy: policy, executable: executable, arguments: arguments, remoteID: chat.transcript.remoteID)
            chat.pendingPrompts.append(prompt); id = prompt.id
        }
        if let index = chat.pendingPrompts.firstIndex(where: { $0.id == id }) {
            chat.pendingPrompts[index].remoteID = chat.transcript.remoteID
            chat.pendingPrompts[index].state = .submitting
        }
        chat.transcript.appendUser(text, blocks: attachments.map { ["type": "resource_link", "uri": .string(storage.attachmentURL($0).absoluteString), "name": .string($0.url.lastPathComponent), "mimeType": .string($0.mimeType), "_meta": ["ccode": ["snapshot": true]]] }, attachments: attachments, startedSession: startedSession, id: id, deliveryState: .submitting)
        if let origin=chat.pendingPrompts.first(where:{ $0.id == id })?.peerMessage,let row=chat.transcript.items.firstIndex(where:{ $0.id == id }) {
            chat.transcript.items[row].peerMessage=origin
        }
        return id
    }
    func settleDelivery(_ chat: ChatSession, id: UUID, state: DeliveryState, error: String? = nil) {
        guard let index = chat.pendingPrompts.firstIndex(where: { $0.id == id }) else { return }
        if state == .acknowledged || state == .cancelled { chat.pendingPrompts.remove(at: index) }
        else { chat.pendingPrompts[index].state = state; chat.pendingPrompts[index].error = error }
        if let row = chat.transcript.items.firstIndex(where: { $0.id == id }) { chat.transcript.items[row].deliveryState = state }
    }
    func failQueuedPrompt(_ chat: ChatSession, id: UUID, error: any Error) {
        settleDelivery(chat, id: id, state: .failed, error: error.localizedDescription)
        chat.deliveryPaused = true
        chat.lastError = error.localizedDescription
        Task { try? await persistDelivery(chat) }
    }
    func pauseDelivery(_ chat: ChatSession) {
        if !chat.pendingPrompts.isEmpty { chat.deliveryPaused = true }
        for prompt in chat.pendingPrompts where prompt.state == .submitting && prompt.id != chat.promptDeliveryID {
            settleDelivery(chat, id: prompt.id, state: .uncertain, error: "Stopped before delivery was acknowledged. Check the agent history before sending again.")
        }
        chat.deliveryTask?.cancel()
        Task { try? await persistDelivery(chat) }
    }
    func interruptDelivery(_ chat: ChatSession) {
        if !chat.pendingPrompts.isEmpty { chat.deliveryPaused = true }
        for prompt in chat.pendingPrompts where prompt.state == .submitting {
            settleDelivery(chat, id: prompt.id, state: .uncertain, error: "Delivery was interrupted. Check the agent history before sending again.")
        }
        chat.deliveryTask?.cancel()
    }
    func editQueuedPrompt(_ chat: ChatSession, id: UUID, text: String) throws {
        guard chat.transcript.codeReview?.id != id, chat.pendingPrompts.first(where: { $0.id == id })?.reviewContexts == nil, chat.pendingPrompts.first(where:{ $0.id == id })?.peerMessage == nil else {
            throw ACPError.workspace("Restore review feedback to the draft, or request a fresh review, before editing its captured context.")
        }
        guard let index = chat.pendingPrompts.firstIndex(where: { $0.id == id && $0.state == .queued }) else { throw ACPError.workspace("Only an unsent queued message can be edited.") }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try PendingPrompt.validate(text: value, attachments: chat.pendingPrompts[index].attachments)
        chat.pendingPrompts[index].text = value
        Task { try? await persistDelivery(chat) }
    }
    func removeQueuedPrompt(_ chat: ChatSession, id: UUID) {
        guard chat.pendingPrompts.contains(where: { $0.id == id && $0.state != .submitting }) else { return }
        chat.pendingPrompts.removeAll { $0.id == id }
        if chat.transcript.codeReview?.id == id {
            chat.transcript.codeReview?.status = .interrupted
            chat.transcript.codeReview?.findings = []
            chat.transcript.codeReview?.details = "Review request removed."
        }
        Task { try? await persistDelivery(chat) }
    }
    func restorePendingPrompt(_ chat: ChatSession, id: UUID) throws {
        guard chat.draft.isEmpty, chat.attachments.isEmpty else { throw ACPError.workspace("Save or clear the current draft before restoring this message.") }
        guard let prompt = chat.pendingPrompts.first(where: { $0.id == id && $0.state != .submitting }) else { throw ACPError.workspace("The message is still being submitted.") }
        guard prompt.peerMessage == nil else { throw ACPError.workspace("Agent messages keep their sender provenance. Remove the queued entry and deliver it again from the inbox; it cannot become a human draft.") }
        chat.draft = prompt.text; chat.attachments = prompt.attachments
        removeQueuedPrompt(chat, id: id)
    }
    func resumeQueuedPrompts(_ chat: ChatSession) {
        guard canDeliver(chat), chat.pendingPrompts.contains(where: { $0.state == .queued }),
              !chat.pendingPrompts.contains(where: { $0.state == .uncertain || $0.state == .failed }) else { return }
        chat.deliveryPaused = false
        Task { do { try await persistDelivery(chat); driveDelivery(chat) } catch { chat.lastError = error.localizedDescription; chat.deliveryPaused = true } }
    }
    func driveDelivery(_ chat: ChatSession) {
        guard canDeliver(chat), pullRequestDraftRequest == nil, pullRequestMergeRequest == nil, pullRequestLogsRequest == nil, !chat.revisingPlan, !chat.attachingFiles, !checkpointRestorationBlocks(chat) else { return }
        if !chat.busy, chat.promptTask == nil, !chat.pendingSettings.isEmpty { driveSettings(chat); return }
        guard !chat.deliveryPaused, chat.deliveryTask == nil,
              let prompt = chat.pendingPrompts.first(where: { $0.state == .queued }) else { return }
        if chat.state == .running {
            guard prompt.policy == .steer, supportsSteering(chat) else { return }
            let operation = UUID(), generation = chat.connectionGeneration
            chat.deliveryOperation = operation; chat.deliveringPrompt = true
            chat.deliveryTask = Task { [weak self] in
                guard let self else { return }
                var submitted = false
                defer {
                    if chat.deliveryOperation == operation {
                        chat.deliveryTask = nil; chat.deliveryOperation = nil; chat.deliveringPrompt = false
                        driveDelivery(chat)
                    }
                }
                do {
                    try validatePromptOwner(chat, id: prompt.id)
                    try await validateReviewFeedbackPrompt(chat, id: prompt.id, text: prompt.text)
                    let blocks = try await promptBlocks(chat, text: prompt.text, attachments: prompt.attachments)
                    try Task.checkCancellation()
                    guard !chat.deliveryPaused, chat.connectionGeneration == generation, let peer = chat.connection, let remoteID = chat.transcript.remoteID else { throw CancellationError() }
                    guard chat.pendingPrompts.first(where: { $0.id == prompt.id })?.text == prompt.text else { return }
                    try registerSubmission(chat, text: prompt.text, attachments: prompt.attachments, id: prompt.id, policy: .steer, startedSession: nil)
                    try await persistDelivery(chat)
                    try Task.checkCancellation()
                    submitted = true
                    let result = try await peer.request("_session/steering", params: ["sessionId": .string(remoteID), "prompt": .array(blocks), "_meta": ["steering": ["idleBehavior": "promptRequired"]]], timeout: .seconds(30))
                    guard chat.connectionGeneration == generation, !chat.deliveryPaused, !Task.isCancelled else { throw CancellationError() }
                    switch result["outcome"].string {
                    case "injected": settleDelivery(chat, id: prompt.id, state: .acknowledged)
                    case "promptRequired": returnToQueue(chat, id: prompt.id)
                    default: throw ACPError.protocolViolation("Unknown steering acknowledgement. Check the agent history before sending again.")
                    }
                    try await persistDelivery(chat)
                } catch {
                    guard chat.deliveryOperation == operation else { return }
                    if (error as? ACPError)?.rpcCode == -32601, chat.connectionGeneration == generation, !chat.deliveryPaused {
                        chat.steeringUnavailable = true; returnToQueue(chat, id: prompt.id)
                    } else if submitted {
                        settleDelivery(chat, id: prompt.id, state: .uncertain, error: error.localizedDescription); chat.deliveryPaused = true
                        if !(error is CancellationError) { recordFailure(chat, error: error, deliveryID: prompt.id) }
                    } else if error is CancellationError {
                        returnToQueue(chat, id: prompt.id)
                    } else { failQueuedPrompt(chat, id: prompt.id, error: error) }
                    try? await persistDelivery(chat)
                }
            }
        } else if !chat.busy, chat.promptTask == nil {
            startPrompt(chat, text: prompt.text, attachments: prompt.attachments, queuedID: prompt.id)
        }
    }
    func returnToQueue(_ chat: ChatSession, id: UUID) {
        guard let index = chat.pendingPrompts.firstIndex(where: { $0.id == id }) else { return }
        chat.pendingPrompts[index].state = .queued; chat.pendingPrompts[index].policy = .nextTurn
        chat.transcript.items.removeAll { $0.id == id }
    }
}
