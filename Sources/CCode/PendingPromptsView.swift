import SwiftUI
import CCodeCore

struct PendingPromptsView: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    @State private var editingID: UUID?
    @State private var editedText = ""
    @State private var editError: String?
    private var messages: [PendingPrompt] { chat.pendingPrompts.filter { $0.id != chat.promptDeliveryID } }
    var body: some View {
        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(chat.deliveryPaused ? "Pending messages · Paused" : "Pending messages").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    if chat.deliveryPaused {
                        Button("Resume queue") { store.resumeQueuedPrompts(chat) }
                            .disabled(!messages.contains { $0.state == .queued } || messages.contains { $0.state == .uncertain || $0.state == .failed })
                    } else {
                        Button("Pause queue") { store.pauseDelivery(chat) }
                    }
                }.font(.caption).buttonStyle(.plain)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top, spacing: 8) {
                                    if message.state == .submitting { ProgressView().controlSize(.mini) }
                                    else { Image(systemName: message.state == .uncertain || message.state == .failed ? "exclamationmark.circle" : "text.bubble") .foregroundStyle(.secondary) }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(message.text.isEmpty ? "Attached context" : message.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(status(message)).font(.caption2).foregroundStyle(.secondary)
                                        if !message.attachments.isEmpty { Text("\(message.attachments.count) attached \(message.attachments.count == 1 ? "file" : "files")").font(.caption2).foregroundStyle(.secondary) }
                                    }
                                    if message.state != .submitting {
                                        Menu {
                                            if message.state == .queued, message.reviewContexts == nil, chat.transcript.codeReview?.id != message.id {
                                                Button("Edit message") { editingID = message.id; editedText = message.text; editError = nil }
                                            }
                                            Button("Restore to draft") { do { try store.restorePendingPrompt(chat, id: message.id) } catch { chat.lastError = error.localizedDescription } }
                                            Button("Remove from queue") { store.removeQueuedPrompt(chat, id: message.id) }
                                        } label: { Image(systemName: "ellipsis") }
                                            .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Actions for pending message")
                                    }
                                }
                                if let error = message.error { Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                            }.font(.system(size: 12)).padding(9).background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(height: min(174, CGFloat(messages.count) * 72))
            }.padding(10).background(Palette.muted, in: RoundedRectangle(cornerRadius: 10))
                .popover(isPresented: Binding(get: { editingID != nil }, set: { if !$0 { editingID = nil } })) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Edit queued message").font(.headline)
                        TextEditor(text: $editedText).frame(height: 110)
                        if let editError { Text(editError).font(.caption).foregroundStyle(.orange) }
                        HStack {
                            Button("Cancel") { editingID = nil }.keyboardShortcut(.cancelAction)
                            Spacer()
                            Button("Save") {
                                guard let id = editingID else { return }
                                do { try store.editQueuedPrompt(chat, id: id, text: editedText); editingID = nil }
                                catch { editError = error.localizedDescription }
                            }.keyboardShortcut(.defaultAction)
                        }
                    }.padding(16).frame(width: 320)
                }
        }
    }
    private func status(_ prompt: PendingPrompt) -> String {
        switch prompt.state {
        case .queued: prompt.policy == .steer ? "Will reach the active turn when available" : "Queued for the next turn"
        case .submitting: "Sending…"
        case .uncertain: "Delivery unknown · Check history before resending"
        case .failed: "Not sent"
        case .acknowledged: "Delivered"
        case .cancelled: "Cancelled"
        }
    }
}
