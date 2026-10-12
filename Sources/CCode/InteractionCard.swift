import SwiftUI
import AppKit
import CCodeCore

struct InteractionCard: View {
    let interaction: PendingInteraction
    let chat: ChatSession
    let store: AppStore
    var body: some View {
        InteractionForm(request: interaction.request, agentName: chat.workOwnerName(interaction.request.sessionID)) { action, content in
            if action == .accept, let url = interaction.request.url {
                guard NSWorkspace.shared.open(url) else { throw ACPError.workspace("Could not open the authorization page in your browser.") }
            }
            try store.resolveInteraction(chat, id: interaction.id, action: action, content: content)
        }.id(interaction.id)
            .onKeyPress(keys: [.escape]) { _ in store.stop(chat); return .handled }
    }
}

struct InteractionForm: View {
    let request: ElicitationRequest
    let agentName: String
    let resolve: (ElicitationAction, JSONValue) throws -> Void
    @State private var values: [String: JSONValue] = [:]
    @State private var numericText: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(request.mode == .form ? "\(agentName) has a question" : "\(agentName) requests a connection", systemImage: request.mode == .form ? "questionmark.bubble" : "link")
                .font(.caption).foregroundStyle(.secondary)
            Text(request.message).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let url = request.url {
                Text(url.host ?? "").fontWeight(.medium)
                Text(url.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(4)
                Text("Continue in your browser, then return here.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(request.fields) { field in fieldView(field) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
                }.frame(height: min(280, CGFloat(request.fields.reduce(0) { $0 + 58 + ($1.kind == .choice || $1.kind == .multiple ? $1.choices.count * 38 : 0) })))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 12) {
                Button("Skip") { submit(.decline) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Cancel") { submit(.cancel) }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button(request.mode == .form ? "Submit answers" : "Open in browser") { submit(.accept) }.buttonStyle(.borderedProminent)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.muted, in: RoundedRectangle(cornerRadius: 12))
            .onAppear {
                values = request.defaultContent.object
                for field in request.fields {
                    if field.kind == .boolean, values[field.id] == nil { values[field.id] = false }
                    if case .number(let number) = values[field.id] { numericText[field.id] = field.kind == .integer ? String(Int(number)) : String(number) }
                }
            }
    }

    @ViewBuilder private func fieldView(_ field: ElicitationField) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) { Text(field.title).font(.system(size: 13, weight: .medium)); if field.required { Text("Required").font(.caption2).foregroundStyle(.secondary) } }
            if !field.description.isEmpty { Text(field.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            switch field.kind {
            case .text:
                TextField(field.title, text: Binding(get: { values[field.id]?.string ?? "" }, set: { values[field.id] = .string($0); error = nil }), axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder).accessibilityLabel(field.title)
            case .number, .integer:
                TextField(field.kind == .integer ? "Whole number" : "Number", text: Binding(get: { numericText[field.id] ?? "" }, set: { numericText[field.id] = $0; error = nil }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel(field.title)
            case .boolean:
                Toggle(field.title, isOn: Binding(get: { values[field.id]?.bool ?? false }, set: { values[field.id] = .bool($0); error = nil }))
            case .choice, .multiple:
                ForEach(field.choices) { choice in
                    let selected = field.kind == .choice ? values[field.id] == choice.value : (values[field.id]?.array.contains(choice.value) ?? false)
                    Button {
                        choose(field, choice: choice.value, selected: selected)
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: field.kind == .multiple ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                                .foregroundStyle(selected ? Palette.accent : Color.secondary).padding(.top, 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.title).font(.system(size: 13))
                                if !choice.description.isEmpty { Text(choice.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            }
                            Spacer(minLength: 0)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).padding(.vertical, 4)
                    }.buttonStyle(.plain).focusable()
                        .onKeyPress(keys: [.space, .return]) { _ in choose(field, choice: choice.value, selected: selected); return .handled }
                        .accessibilityLabel(choice.title).accessibilityValue(selected ? "Selected" : "Not selected")
                }
            }
        }
    }

    private func choose(_ field: ElicitationField, choice: JSONValue, selected: Bool) {
        if field.kind == .choice { values[field.id] = selected && !field.required ? nil : choice }
        else {
            var answers = values[field.id]?.array ?? []
            if selected { answers.removeAll { $0 == choice } } else { answers.append(choice) }
            values[field.id] = .array(answers)
        }
        error = nil
    }

    private func submit(_ action: ElicitationAction) {
        do {
            var content = values
            if action == .accept, request.mode == .form {
                for field in request.fields where field.kind == .number || field.kind == .integer {
                    let text = (numericText[field.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty { content.removeValue(forKey: field.id) }
                    else if let number = Double(text), number.isFinite { content[field.id] = .number(number) }
                    else { throw ACPError.workspace("Enter a valid number for \(field.title).") }
                }
                _ = try request.response(action: action, content: .object(content))
            }
            try resolve(action, .object(content))
        } catch { self.error = error.localizedDescription }
    }
}
