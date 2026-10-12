import SwiftUI
import CCodeCore

@MainActor @Observable final class DiscardPreviewRequest: Identifiable {
    nonisolated let id: UUID
    let chat: ChatSession
    let preview: DiscardPreview
    var applying = false
    var stopping = false
    init(chat: ChatSession, preview: DiscardPreview) { id = preview.id; self.chat = chat; self.preview = preview }
}
struct DiscardHistoryRequest: Identifiable {
    let id = UUID()
    let chat: ChatSession
}
struct DiscardPreviewView: View {
    let store: AppStore
    @Bindable var request: DiscardPreviewRequest
    @State private var preview: DiscardPreview
    @State private var refreshing = false
    @State private var failure: String?
    @State private var result: DiscardResult?
    init(store: AppStore, request: DiscardPreviewRequest) {
        self.store = store; self.request = request; _preview = State(initialValue: request.preview)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(result?.status.title ?? (preview.scope == .working ? "Discard working changes?" : "Discard all selected changes?"))
                    .font(.system(size: 19, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(preview.scope == .working ? "Restore selected files to the staged index. Staged changes stay in place." : "Restore selected files to HEAD, including staged changes.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(22)
            Divider()
            Group {
                if request.applying {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Saving recovery copies and discarding changes…") }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let result {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let details = result.details { Text(details).textSelection(.enabled) }
                            Text(result.status == .completed ? "The selected files were restored. Original working files and staged contents are retained in recovery." : "Inspect the files and recovery copies before continuing. Queued work is paused.")
                            Text("Conversation history, composer text and unsaved editor buffers are preserved.").foregroundStyle(.secondary)
                            Text(result.recoveryDirectory).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) { ForEach(preview.paths, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) } }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.vertical, 12)
                        }.frame(maxHeight: 84)
                        Divider()
                        DiffText(text: preview.diff)
                    }
                }
            }.frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                if result == nil {
                    Text("Files absent from the target are removed into recovery. Finish external work before applying; changed files or Git state require a fresh preview. Unsaved editor buffers stay in place.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if let result, [.completed, .partial, .conflict, .uncertain].contains(result.status) {
                        Button("Recovery copies") { Task { await store.showDiscardRecovery(result, chat: request.chat) } }.fixedSize()
                    }
                    Spacer(minLength: 12)
                    if request.applying {
                        Button(request.stopping ? "Stopping…" : "Stop discarding") { request.stopping = true; store.stop(request.chat) }
                            .disabled(request.stopping).fixedSize()
                    } else if result == nil {
                        Button(refreshing ? "Refreshing…" : "Refresh") { refresh() }.disabled(refreshing || request.applying).fixedSize()
                        Button("Cancel") { store.closeDiscardPreview() }.disabled(request.applying).fixedSize()
                        Button("Discard changes", role: .destructive) { apply() }
                            .disabled(refreshing || request.applying || !store.canDiscardChanges(request.chat)).fixedSize()
                    } else { Button("Done") { store.closeDiscardPreview() }.keyboardShortcut(.defaultAction).fixedSize() }
                }
            }.padding(22)
        }.frame(width: 640, height: 560).background(Palette.surface)
            .interactiveDismissDisabled(request.applying || request.chat.restoringFiles)
            .onExitCommand { store.closeDiscardPreview() }
    }
    private func apply() {
        guard !request.applying, !refreshing else { return }
        request.applying = true; request.stopping = false; failure = nil
        let captured = preview
        Task {
            defer { request.applying = false }
            guard !request.stopping else { return }
            do { result = try await store.discardChanges(request.chat, preview: captured) }
            catch is CancellationError { result = request.chat.transcript.discards?.last { $0.id == captured.id }; failure = result == nil ? "Discard cancelled before changing files." : nil }
            catch { failure = error.localizedDescription }
        }
    }
    private func refresh() {
        guard !request.applying, !refreshing else { return }
        refreshing = true; failure = nil
        Task {
            defer { refreshing = false }
            do { preview = try await store.refreshDiscardPreview(request.chat, preview: request.preview) }
            catch { failure = error.localizedDescription }
        }
    }
}
struct DiscardHistoryView: View {
    let store: AppStore
    let request: DiscardHistoryRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Discarded changes").font(.system(size: 19, weight: .semibold)).padding(22)
            Divider()
            List((request.chat.transcript.discards ?? []).reversed()) { result in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(result.status.title).fontWeight(.medium)
                        Spacer()
                        if let started = result.startedAt { Text(started, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary) }
                    }
                    Text(result.paths.joined(separator: "\n")).font(.caption.monospaced()).lineLimit(4).help(result.paths.joined(separator: "\n"))
                    Text(result.scope == .working ? "Working changes → staged index" : "All selected changes → HEAD").font(.caption).foregroundStyle(.secondary)
                    if let details = result.details { Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(4).help(details) }
                    if [.completed, .partial, .conflict, .uncertain].contains(result.status) {
                        Button("Show recovery copies") { Task { await store.showDiscardRecovery(result, chat: request.chat) } }.font(.caption)
                    }
                }.padding(.vertical, 6)
            }.listStyle(.plain)
            Divider()
            HStack { Spacer(); Button("Done") { store.discardHistoryRequest = nil }.keyboardShortcut(.defaultAction).fixedSize() }.padding(22)
        }.frame(width: 600, height: 430).background(Palette.surface)
            .onExitCommand { store.discardHistoryRequest = nil }
    }
}
extension DiscardResult.Status {
    var title: String {
        switch self {
        case .preparing: "Preparing discard"
        case .completed: "Changes discarded"
        case .partial: "Discard partially finished"
        case .conflict: "Discard encountered a conflict"
        case .rejected: "Changes were not discarded"
        case .uncertain: "Discard outcome is uncertain"
        }
    }
}
