import SwiftUI
import CCodeCore

struct FailureCard: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    @State private var showingDetails = false
    private var failure: AgentFailure { chat.failure ?? AgentFailure(error: ACPError.workspace(chat.lastError ?? ""), providerMetadata: false) }
    private var pending: PendingPrompt? { failure.deliveryID.flatMap { id in chat.pendingPrompts.first { $0.id == id } } }
    var body: some View {
        if chat.lastError != nil {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(failure.title).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                    Button { chat.lastError = nil } label: { Image(systemName: "xmark") }.help("Dismiss error").accessibilityLabel("Dismiss error")
                }
                Text(failure.guidance).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if pending?.state == .uncertain {
                    Text("Some actions may already have completed. Check the conversation and changes before resending.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { actions }
                    VStack(alignment: .leading, spacing: 10) { actions }
                }.font(.caption)
                if showingDetails {
                    ScrollView { Text(failure.details).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                }
            }.buttonStyle(.plain).padding(12).background(Palette.muted, in: RoundedRectangle(cornerRadius: 9))
        }
    }
    @ViewBuilder private var actions: some View {
        Button(showingDetails ? "Hide details" : "Show details") { showingDetails.toggle() }
        if failure.kind == .authentication {
            ForEach(chat.handshake["authMethods"].array.filter { $0["type"].isNull || $0["type"].string == "agent" }, id: \.["id"]) { method in
                Button(method["name"].string) { Task { await store.recoverConnection(chat, authentication: method["id"].string) } }.disabled(chat.busy || !store.canDeliver(chat))
            }
        }
        if chat.state == .failed || chat.connection == nil {
            Button("Reconnect") { Task { await store.recoverConnection(chat) } }.disabled(chat.busy || !store.canDeliver(chat)).help("Reconnect without submitting a prompt")
        }
        if let pending, pending.state != .submitting {
            Button("Review request in draft") {
                do { try store.restorePendingPrompt(chat, id: pending.id) }
                catch { chat.lastError = error.localizedDescription }
            }.disabled(!chat.draft.isEmpty || !chat.attachments.isEmpty || chat.busy)
                .help("Restore the original prompt and attachments for review. This does not send it.")
        }
        if failure.kind == .context || failure.kind == .budget {
            Button("New session") { Task { await store.openHome(path: chat.workspace.root) } }.disabled(chat.busy)
        }
    }
}
