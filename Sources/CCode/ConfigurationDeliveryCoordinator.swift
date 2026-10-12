import Foundation
import CCodeCore

extension AppStore {
    func canChooseSettings(_ chat: ChatSession) -> Bool {
        canDeliver(chat) && (chat.state == .running || !chat.preparingPrompt) && ![.connecting, .stopping].contains(chat.state)
    }
    private func settingLabels(_ chat: ChatSession, key: String, value: JSONValue, legacy: Bool) throws -> (String, String, Bool) {
        if legacy {
            guard chat.transcript.configOptions.isEmpty, ["modelId", "modeId"].contains(key) else { throw ACPError.workspace("This agent now uses configuration options. Choose from its current controls.") }
            let model = key == "modelId", state = model ? chat.transcript.models : chat.transcript.modes
            guard let option = state[model ? "availableModels" : "availableModes"].array.first(where: { $0[model ? "modelId" : "id"] == value }) else { throw ACPError.workspace("This agent no longer offers the selected \(model ? "model" : "mode").") }
            return (model ? "Model" : "Mode", option["name"].string, model)
        }
        guard let option = chat.transcript.configOptions.first(where: { $0["id"].string == key }) else { throw ACPError.workspace("This agent no longer offers the selected configuration: \(key).") }
        let name = option["name"].string
        if option["type"] == "boolean", case .bool(let enabled) = value { return (name, enabled ? "On" : "Off", false) }
        let choices = option["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }
        guard option["type"] == "select", value.optionalString != nil,
              let choice = choices.first(where: { $0["value"] == value }) else { throw ACPError.workspace("This agent no longer offers the selected \(name) value.") }
        return (name, choice["name"].string, option["category"] == "model")
    }
    func requestSetting(_ chat: ChatSession, key: String, value: JSONValue, legacy: Bool) async {
        guard canChooseSettings(chat) else { return }
        let wasBusy = chat.busy
        var requestedID: UUID?
        chat.persistingSettings += 1
        do {
            let (name, label, model) = try settingLabels(chat, key: key, value: value, legacy: legacy)
            let (executable, arguments) = try promptOwner(chat)
            let setting = PendingSetting(key: key, value: value, legacy: legacy, name: name, valueName: label, model: model, executable: executable, arguments: arguments, remoteID: chat.transcript.remoteID)
            requestedID = setting.id
            if let index = chat.pendingSettings.firstIndex(where: { $0.key == key && $0.legacy == legacy && $0.state != .applying }) { chat.pendingSettings[index] = setting }
            else {
                guard chat.pendingSettings.count < 16 else { throw ACPError.workspace("Too many pending settings. Remove a pending change first.") }
                chat.pendingSettings.append(setting)
            }
            try await persistDelivery(chat)
        } catch {
            if let requestedID, let index = chat.pendingSettings.firstIndex(where: { $0.id == requestedID }) {
                chat.pendingSettings[index].state = .failed; chat.pendingSettings[index].error = error.localizedDescription
                chat.settingsPaused = true; chat.deliveryPaused = true
            }
            chat.lastError = error.localizedDescription
        }
        chat.persistingSettings -= 1
        driveDelivery(chat)
        if !wasBusy { await chat.settingsTask?.value }
    }
    func pauseSettings(_ chat: ChatSession, preservingReview review: UUID? = nil) {
        if review == nil || chat.settingsReview != review { chat.settingsReview = nil }
        guard !chat.pendingSettings.isEmpty else { return }
        chat.settingsPaused = true
        for index in chat.pendingSettings.indices where chat.pendingSettings[index].state == .applying {
            chat.pendingSettings[index].state = .uncertain
            chat.pendingSettings[index].error = "Setting was interrupted. Review the current value before applying again."
        }
        chat.settingsTask?.cancel()
    }
    func removePendingSetting(_ chat: ChatSession, id: UUID) {
        guard chat.pendingSettings.contains(where: { $0.id == id && $0.state != .applying }), !chat.configuring, chat.settingsTask == nil else { return }
        chat.pendingSettings.removeAll { $0.id == id }
        if chat.pendingSettings.isEmpty { chat.settingsPaused = false }
        Task { do { try await persistDelivery(chat); driveDelivery(chat) } catch { chat.lastError = error.localizedDescription; chat.deliveryPaused = true } }
    }
    func applyPendingSettings(_ chat: ChatSession) async {
        guard canChooseSettings(chat), !chat.busy, !chat.pendingSettings.isEmpty else { return }
        if chat.connection != nil, chat.pendingSettings.contains(where: { $0.state == .uncertain && appliedSettingValue(chat, $0) != $0.value }) {
            // A timed-out/cancelled setter could still finish on its old peer.
            // Stop that peer before reconciling/retrying on a fresh connection.
            let review = UUID(); chat.settingsReview = review; chat.configuring = true
            await disconnect(chat, preservingSettings: review)
            chat.configuring = false
            guard chat.settingsReview == review, canDeliver(chat) else { chat.settingsReview = nil; return }
            chat.settingsReview = nil
        }
        chat.settingsPaused = false
        for index in chat.pendingSettings.indices { chat.pendingSettings[index].state = .queued; chat.pendingSettings[index].error = nil }
        chat.persistingSettings += 1
        do { try await persistDelivery(chat) }
        catch { chat.settingsPaused = true; chat.lastError = error.localizedDescription }
        chat.persistingSettings -= 1
        driveDelivery(chat)
        await chat.settingsTask?.value
    }
    private func appliedSettingValue(_ chat: ChatSession, _ setting: PendingSetting) -> JSONValue {
        if setting.legacy { return setting.key == "modelId" ? chat.transcript.models["currentModelId"] : chat.transcript.modes["currentModeId"] }
        return chat.transcript.configOptions.first { $0["id"].string == setting.key }?["currentValue"] ?? .null
    }
    private func validateSettingOwner(_ chat: ChatSession, _ setting: PendingSetting) throws {
        let (executable, arguments) = try promptOwner(chat)
        guard setting.executable == executable, setting.arguments == arguments,
              setting.remoteID == nil || setting.remoteID == chat.transcript.remoteID else { throw ACPError.workspace("This setting belongs to a different agent or session. Remove it and choose again for the current agent.") }
        guard chat.pendingSettings.contains(where: { $0.id == setting.id && $0.state == .queued }) else { throw CancellationError() }
    }
    func driveSettings(_ chat: ChatSession) {
        guard canDeliver(chat), !chat.busy, chat.promptTask == nil, chat.settingsTask == nil, !chat.settingsPaused,
              !chat.pendingSettings.isEmpty else { return }
        let operation = UUID()
        chat.settingsOperation = operation; chat.configuring = true
        chat.settingsTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if chat.settingsOperation == operation {
                    chat.settingsTask = nil; chat.settingsOperation = nil; chat.configuring = false
                    driveDelivery(chat)
                }
            }
            while !chat.pendingSettings.isEmpty, !chat.settingsPaused {
                let setting = chat.pendingSettings.first(where: { $0.model }) ?? chat.pendingSettings[0]
                var submitted = false
                do {
                    try Task.checkCancellation()
                    try validateSettingOwner(chat, setting)
                    try await connect(chat)
                    try Task.checkCancellation()
                    try validateSettingOwner(chat, setting)
                    _ = try settingLabels(chat, key: setting.key, value: setting.value, legacy: setting.legacy)
                    guard !chat.settingsPaused, let index = chat.pendingSettings.firstIndex(where: { $0.id == setting.id }) else { throw CancellationError() }
                    chat.pendingSettings[index].state = .applying
                    try await persistDelivery(chat)
                    try Task.checkCancellation()
                    guard !chat.settingsPaused else { throw CancellationError() }
                    submitted = true
                    if setting.legacy { try await applyLegacy(chat, key: setting.key, id: setting.value.string) }
                    else { try await applyConfiguration(chat, id: setting.key, value: setting.value) }
                    chat.pendingSettings.removeAll { $0.id == setting.id }
                    try await persistDelivery(chat)
                    chat.lastError = nil
                } catch {
                    var state: SettingState = submitted ? .uncertain : .failed
                    if (error as? ACPError)?.rpcCode != nil { state = .failed }
                    if error is CancellationError { state = submitted ? .uncertain : .queued }
                    if let index = chat.pendingSettings.firstIndex(where: { $0.id == setting.id }) {
                        if chat.pendingSettings[index].state != .uncertain { chat.pendingSettings[index].state = state }
                        chat.pendingSettings[index].error = error is CancellationError ? "Setting was interrupted. Review the current value before applying again." : error.localizedDescription
                    } else if !(error is CancellationError) {
                        var retained = setting; retained.state = state; retained.error = error.localizedDescription
                        chat.pendingSettings.append(retained)
                    }
                    chat.settingsPaused = true; chat.deliveryPaused = true
                    if !(error is CancellationError) { recordFailure(chat, error: error) }
                    try? await persistDelivery(chat)
                    return
                }
            }
        }
    }
}
