import SwiftUI
import CCodeCore

struct LaunchChoiceRecoveryView: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    private struct Choice: Identifiable {
        let key: String
        let legacy: Bool
        let name: String
        let value: String
        let available: Bool
        var id: String { (legacy ? "legacy:" : "config:") + key }
    }
    private var choices: [Choice] {
        guard let configuration = chat.transcript.pendingConfiguration else { return [] }
        let modern = configuration.values.keys.sorted().map { key in
            let value = configuration.values[key]!
            let option = chat.transcript.configOptions.first { $0["id"].string == key }
            let options = option?["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array } ?? []
            let selected = options.first { $0["value"] == value }
            let boolean = option?["type"] == "boolean"
            let display = selected?["name"].optionalString ?? value.optionalString ?? (value == true ? "On" : value == false ? "Off" : value.pretty)
            return Choice(key: key, legacy: false, name: option?["name"].optionalString ?? (key == "fast" ? "Fast mode" : key), value: display,
                          available: option != nil && (boolean || selected != nil || option?["currentValue"] == value))
        }
        let legacy = (configuration.legacyValues ?? [:]).keys.sorted().map { key in
            let value = configuration.legacyValues![key]!, model = key == "modelId"
            let state = model ? chat.transcript.models : chat.transcript.modes
            let selected = state[model ? "availableModels" : "availableModes"].array.first { $0[model ? "modelId" : "id"].string == value }
            return Choice(key: key, legacy: true, name: model ? "Model" : "Mode", value: selected?["name"].optionalString ?? value, available: selected != nil)
        }
        return modern + legacy
    }
    var body: some View {
        if chat.transcript.pendingConfiguration != nil {
            DisclosureGroup("Review launch choices") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(choices) { choice in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(choice.name): \(choice.value)").fixedSize(horizontal: false, vertical: true)
                                if !choice.available { Text("Not offered by the current agent").foregroundStyle(.orange) }
                            }
                            Spacer(minLength: 8)
                            Button("Remove") { store.removeLaunchChoice(chat, key: choice.key, legacy: choice.legacy) }
                                .disabled(chat.busy || !store.canDeliver(chat)).accessibilityLabel("Remove \(choice.name) launch choice")
                        }
                    }
                    Text("Removing a choice keeps the others and your draft. Reconnect when ready; your task is not sent automatically.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Continue with current agent settings") { store.continueWithCurrentConfiguration(chat) }.disabled(chat.busy)
                        .help("Discard all saved launch choices without sending your draft")
                }.padding(.top, 8)
            }.font(.caption).padding(12).background(Palette.muted, in: RoundedRectangle(cornerRadius: 9))
        }
    }
}
