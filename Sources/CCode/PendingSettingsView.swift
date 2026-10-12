import SwiftUI
import CCodeCore

struct PendingSettingsView: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    var body: some View {
        if !chat.pendingSettings.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(chat.settingsPaused ? "Pending settings · Paused" : "Settings for next turn").font(.caption.weight(.medium))
                    Spacer()
                    if chat.settingsPaused { Button("Apply settings") { Task { await store.applyPendingSettings(chat) } }.disabled(chat.busy || !store.canChooseSettings(chat)).font(.caption) }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(chat.pendingSettings) { setting in
                            HStack(alignment: .top, spacing: 8) {
                                if setting.state == .applying { ProgressView().controlSize(.mini) }
                                else { Image(systemName: setting.state == .queued ? "clock" : "exclamationmark.circle").foregroundStyle(.secondary) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(setting.name): \(applied(setting)) → \(setting.valueName)").fixedSize(horizontal: false, vertical: true)
                                    if let error = setting.error { Text(error).font(.caption2).foregroundStyle(.orange).textSelection(.enabled) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Button { store.removePendingSetting(chat, id: setting.id) } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).disabled(setting.state == .applying || chat.configuring || chat.settingsTask != nil)
                                    .accessibilityLabel("Remove pending \(setting.name) change")
                            }.font(.system(size: 12)).padding(.vertical, 2)
                        }
                    }
                }.frame(height: min(126, CGFloat(chat.pendingSettings.count) * 46))
                Text("Queued work waits for these settings. Stopping or restarting keeps them paused.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(10).background(Palette.muted, in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private func applied(_ setting: PendingSetting) -> String {
        if setting.legacy {
            let state = setting.key == "modelId" ? chat.transcript.models : chat.transcript.modes
            let model = setting.key == "modelId", value = state[model ? "currentModelId" : "currentModeId"]
            return state[model ? "availableModels" : "availableModes"].array.first { $0[model ? "modelId" : "id"] == value }?["name"].optionalString ?? value.string
        }
        guard let option = chat.transcript.configOptions.first(where: { $0["id"].string == setting.key }) else { return "Unavailable" }
        if option["type"] == "boolean" { return option["currentValue"].bool ? "On" : "Off" }
        let choices = option["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }
        return choices.first { $0["value"] == option["currentValue"] }?["name"].optionalString ?? option["currentValue"].string
    }
}
