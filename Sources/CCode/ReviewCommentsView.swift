import SwiftUI
import CCodeCore

struct ReviewSelection: Sendable {
    let root: String
    let path: String
    let diff: String
    let baseRevision: String?
    let stagedOnly: Bool
    let line: DiffLine?
    var source: String { line?.source(stagedOnly: stagedOnly) ?? (stagedOnly ? "staged index" : "working file") }
    var location: String { path + ((line?.newLine ?? line?.oldLine).map { ":\($0)" } ?? " (whole file)") }
}

/// The batch remains visible even if a refresh removes its file from Changes.
/// Feedback is explicitly submitted, never sent by selecting another file.
struct ReviewCommentsView: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    var selection: ReviewSelection? = nil
    @State private var failure: String?
    @State private var editingID: UUID?
    @State private var editedText = ""
    @State private var saving = false
    @State private var rebindID: UUID?
    @State private var confirmedSelection: ReviewSelection?
    private var canSubmit: Bool { editingID == nil && !chat.busy && !chat.hasLiveAgentWork && chat.pendingPrompts.isEmpty && chat.pendingSettings.isEmpty && !store.checkpointRestorationBlocks(chat) && store.canDeliver(chat) }
    var body: some View {
        if !chat.reviewComments.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                HStack {
                    Text("\(chat.reviewComments.count) pending \(chat.reviewComments.count == 1 ? "comment" : "comments")").font(.caption).monospacedDigit()
                    Spacer()
                    Button(chat.submittingReview ? "Checking changes…" : "Submit comments") { submit() }
                        .keyboardShortcut(.return, modifiers: .command).disabled(!canSubmit)
                        .help("Submit all review comments (⌘Enter)")
                }.padding(12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.reviewComments) { comment in
                            commentRow(comment)
                        }
                    }.padding(.horizontal, 12).padding(.bottom, 12)
                }.frame(maxHeight: 180)
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(.horizontal, 12).padding(.bottom, 12) }
            }
            .confirmationDialog("Update comment context?", isPresented: Binding(get: { rebindID != nil }, set: { if !$0 { rebindID = nil; confirmedSelection = nil } }), titleVisibility: .visible) {
                if let id = rebindID, let context = confirmedSelection {
                    Button(context.line == nil ? "Use displayed file" : "Use selected line") { rebind(id, context: context) }
                }
                Button("Cancel", role: .cancel) { rebindID = nil; confirmedSelection = nil }
            } message: {
                if let context = confirmedSelection {
                    Text("Keep the comment text and replace its captured context with \(context.location) from the \(context.source). Feedback will not be sent.")
                }
            }
        }
    }
    private func commentRow(_ comment: ReviewComment) -> some View {
        let location = comment.path + (comment.lineNumber.map { ":\($0)" } ?? "")
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(location).font(.caption.monospaced()).lineLimit(1).help(comment.path)
                Spacer(minLength: 8)
                if editingID == nil {
                    Button("Edit") { editingID = comment.id; editedText = comment.text; failure = nil }
                        .font(.caption).disabled(chat.busy || !store.canDeliver(chat))
                        .accessibilityLabel("Edit comment on \(comment.path)")
                }
                Button { store.removeReviewComment(chat, id: comment.id); if editingID == comment.id { editingID = nil; editedText = "" } } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    .help("Remove comment on \(comment.path)").accessibilityLabel("Remove comment on \(comment.path)").disabled(chat.submittingReview)
            }
            HStack {
                Text(URL(fileURLWithPath: comment.root).lastPathComponent + " · " + comment.source).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Update context…") { rebindID = comment.id; confirmedSelection = selection; failure = nil }
                    .font(.caption).disabled(selection?.path != comment.path || selection?.root != comment.root || !canSubmit)
                    .help("Display this file's current diff, optionally select a line, then update the comment's context")
                    .accessibilityLabel("Update comment context on \(comment.path)")
            }
            if let line = comment.selectedText { Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
            if editingID == comment.id { editor(comment.id) }
            else { Text(comment.text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Palette.muted, in: RoundedRectangle(cornerRadius: 8))
    }
    private func editor(_ id: UUID) -> some View {
        VStack(spacing: 6) {
            TextEditor(text: $editedText).font(.system(size: 12)).frame(minHeight: 60, maxHeight: 100)
                .padding(4).overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.border))
                .accessibilityLabel("Review comment text").disabled(saving)
            HStack {
                Button("Cancel") { editingID = nil; editedText = ""; failure = nil }.disabled(saving)
                Spacer()
                Button(saving ? "Saving…" : "Save comment") { save(id) }
                    .disabled(saving || chat.busy || editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.font(.caption)
        }
    }
    private func submit() {
        guard canSubmit else { return }
        failure = nil
        Task { do { _ = try await store.submitReviewComments(chat) } catch { failure = error.localizedDescription } }
    }
    private func save(_ id: UUID) {
        guard !saving else { return }
        let text = editedText
        saving = true; failure = nil
        Task {
            defer { saving = false }
            do {
                try await store.editReviewComment(chat, id: id, text: text)
                if editingID == id, editedText == text { editingID = nil; editedText = "" }
            } catch { failure = error.localizedDescription }
        }
    }
    private func rebind(_ id: UUID, context: ReviewSelection) {
        failure = nil; rebindID = nil; confirmedSelection = nil
        Task {
            do { try await store.rebindReviewComment(chat, id: id, path: context.path, diff: context.diff, baseRevision: context.baseRevision, stagedOnly: context.stagedOnly, line: context.line, directory: context.root) }
            catch { failure = error.localizedDescription }
        }
    }
}
