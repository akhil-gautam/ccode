import SwiftUI
import CCodeCore

@MainActor @Observable final class PullRequestDraftRequest: Identifiable {
    let id = UUID()
    let chat: ChatSession
    let directory: String
    var applying = false
    var preparing = false
    var remote = ""
    var remotes: [String] = []
    var base = ""
    var title = ""
    var body = ""
    var push = true
    var preview: PullRequestPreview?
    var failure: String?
    init(chat: ChatSession) { self.chat = chat; directory = chat.workspaceDirectory }
}

struct PullRequestBar: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    @State private var performing = false
    private var canAct: Bool { !performing && store.canMutateWorkspace(chat) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pr = chat.transcript.pullRequest {
                HStack(alignment: .firstTextBaseline) {
                    Label("PR #\(pr.number)", systemImage: "arrow.triangle.pull")
                    Text(pr.state.rawValue.capitalized).foregroundStyle(pr.state == .merged ? Color.purple : .secondary)
                    Spacer(minLength: 4)
                    if let url = URL(string: pr.url), url.scheme == "https", url.host?.lowercased() == pr.repository.host.lowercased(), url.path.lowercased() == "/\(pr.repository.owner)/\(pr.repository.name)/pull/\(pr.number)".lowercased() {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("Open on GitHub")
                    }
                    Button { run { try await store.refreshPullRequest(chat) } } label: { Image(systemName: "arrow.clockwise") }.disabled(performing).help("Refresh PR and checks")
                }.font(.system(size: 12, weight: .medium))
                Text(pr.title).font(.system(size: 12)).lineLimit(2)
                Text("\(pr.repository.branch) → \(pr.repository.base) · \(pr.headSHA.prefix(7))").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if !pr.checks.isEmpty {
                    DisclosureGroup("\(pr.checks.filter { $0.bucket == .pass }.count)/\(pr.checks.count) checks passed") {
                        ScrollView { VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(pr.checks.enumerated()), id: \.offset) { _, check in
                                HStack(alignment: .firstTextBaseline) {
                                    Image(systemName: check.bucket == .pass ? "checkmark.circle" : check.bucket == .pending ? "clock" : check.bucket == .fail ? "exclamationmark.circle" : "minus.circle")
                                        .foregroundStyle(check.bucket == .pass ? Color.green : check.bucket == .fail ? Color.orange : .secondary)
                                    Text(check.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(check.bucket.rawValue).foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                        }.padding(.top, 6) }.frame(maxHeight: 140)
                    }.font(.caption)
                }
                if pr.state == .open {
                    ViewThatFits(in: .horizontal) {
                        HStack { actions(pr); Spacer(minLength: 0) }
                        VStack(alignment: .leading, spacing: 6) { actions(pr) }
                    }
                    if pr.autoMergeEnabled {
                        Label("Auto-merge enabled · waiting for GitHub", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                        Button("Cancel auto-merge") { run { try await store.disablePullRequestAutoMerge(chat) } }.font(.caption).disabled(!canAct)
                    }
                    if chat.transcript.pullRequestAutoFix?.submittedPromptID != nil {
                        Text("CI fix requested for the authorized commit").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Toggle("Auto-fix this commit once", isOn: Binding(get: { chat.transcript.pullRequestAutoFix?.enabled == true }, set: { enabled in run { try await store.setPullRequestAutoFix(chat, enabled: enabled); if enabled, chat.pullRequestMonitor == nil { try store.startPullRequestMonitoring(chat) } } }))
                            .toggleStyle(.checkbox).font(.caption).disabled(!canAct)
                    }
                }
            } else {
                HStack { Label("Pull request", systemImage: "arrow.triangle.pull").foregroundStyle(.secondary); Spacer(); Button("Create…") { store.pullRequestDraftRequest = PullRequestDraftRequest(chat: chat) }.disabled(!canAct) }.font(.caption)
            }
            if let receipt = chat.transcript.pullRequestOperation, receipt.state == .uncertain { PullRequestFailureText(text: receipt.details ?? "GitHub operation interrupted. Refresh before repeating.") }
            if let error = chat.pullRequestError { PullRequestFailureText(text: error) }
            if performing { ProgressView().controlSize(.small) }
        }.padding(12).background(Palette.muted.opacity(0.35))
    }
    @ViewBuilder private func actions(_ pr: PullRequest) -> some View {
        if pr.checks.contains(where: { $0.bucket == .fail || $0.bucket == .cancel }) {
            Button("Logs") { run { store.pullRequestLogsRequest = PullRequestLogsRequest(text: try await store.pullRequestService(for: chat).failureLogs(pr), chatID: chat.id) } }.disabled(performing)
            Button("Fix with agent") { run { _ = try await store.fixPullRequestCI(chat) } }.disabled(!canAct)
        }
        Button(chat.pullRequestMonitor == nil ? "Watch checks" : "Stop watching") {
            run { if chat.pullRequestMonitor == nil { try store.startPullRequestMonitoring(chat) } else { await store.stopPullRequestMonitoring(chat) } }
        }.disabled(performing)
        Button("Update…") { store.pullRequestDraftRequest = PullRequestDraftRequest(chat: chat) }.disabled(!canAct)
        Button("Merge…") { store.pullRequestMergeRequest = PullRequestMergeRequest(chat: chat, pullRequest: pr) }.disabled(!canAct)
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        performing = true
        Task { defer { performing = false }; do { try await operation() } catch { chat.pullRequestError = error.localizedDescription } }
    }
}

struct PullRequestDraftView: View {
    let store: AppStore
    @Bindable var request: PullRequestDraftRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(request.preview?.existing == nil ? "Create pull request" : "Update pull request").font(.system(size: 19, weight: .semibold)); Spacer(); if request.preparing || request.applying { ProgressView().controlSize(.small) } }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text(request.directory).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                HStack {
                    Picker("Remote", selection: $request.remote) { Text("Choose remote").tag(""); ForEach(request.remotes, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: .infinity)
                    TextField("Base (repository default)", text: $request.base).textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                }
                if let existing = request.preview?.existing { Text(existing.title).font(.system(size: 14, weight: .medium)).lineLimit(2) }
                else { TextField("PR title", text: $request.title).textFieldStyle(.roundedBorder) }
                if let preview = request.preview {
                    HStack { Text("\(preview.repository.branch) → \(preview.repository.base)"); Spacer(); Text(String(preview.repository.headSHA.prefix(7))) }.font(.caption.monospaced())
                    if let existing = preview.existing { Text(existing.headSHA == preview.repository.headSHA ? "PR #\(existing.number) is current." : "Publish the new commit to PR #\(existing.number). Title and description stay as shown on GitHub.").font(.caption) }
                    DisclosureGroup("Description") { ScrollView { ToolLog(text: preview.existing?.body ?? preview.body, command: false) }.frame(maxHeight: 80) }.font(.caption)
                    DiffText(text: preview.diff).frame(minHeight: 160).overlay { RoundedRectangle(cornerRadius: 6).stroke(Palette.border) }
                } else {
                    Text("Description").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $request.body).font(.system(size: 13)).frame(minHeight: 170).padding(6).overlay { RoundedRectangle(cornerRadius: 6).stroke(Palette.border) }
                }
                if request.preview?.existing == nil { Toggle("Push the previewed commit before creating the PR", isOn: $request.push).font(.caption) }
                Text("Only committed code is published. Unsent messages and unsaved editor buffers stay in ccode.").font(.caption).foregroundStyle(.secondary)
                if let failure = request.failure { PullRequestFailureText(text: failure) }
            }.padding(20).disabled(request.preparing || request.applying)
            Divider()
            HStack {
                Button("Cancel") { store.closePullRequestDraft() }.disabled(request.preparing || request.applying)
                if request.preparing || request.applying { Button("Stop") { store.stop(request.chat) } }
                Spacer()
                if let preview = request.preview {
                    Button("Edit details") { request.preview = nil }.disabled(request.applying)
                    Button(preview.existing == nil ? (request.push ? "Push and create PR" : "Create PR") : preview.existing?.headSHA != preview.repository.headSHA ? "Push changes to PR" : "Open existing PR") { submit(preview) }.disabled(request.applying).keyboardShortcut(.defaultAction)
                } else { Button("Preview PR") { prepare() }.disabled(request.remote.isEmpty || request.title.isEmpty || request.preparing).keyboardShortcut(.defaultAction) }
            }.padding(20)
        }.frame(width: 720, height: 650).background(Palette.surface)
        .interactiveDismissDisabled(request.applying || request.preparing)
        .onExitCommand { store.closePullRequestDraft() }
        .onChange(of: request.remote) { request.preview = nil }
        .onChange(of: request.base) { request.preview = nil }
        .onChange(of: request.title) { request.preview = nil }
        .onChange(of: request.body) { request.preview = nil }
        .task {
            do {
                request.remotes = try await store.pullRequestService(for: request.chat).remotes(at: request.directory)
                if request.remotes.count == 1 { request.remote = request.remotes[0] }
                request.title = try await request.chat.workspace.repository.run(["log", "-1", "--format=%s"], at: request.directory).trimmingCharacters(in: .newlines)
            } catch { request.failure = error.localizedDescription }
        }
    }
    private func prepare() {
        request.preparing = true; request.failure = nil
        Task { defer { request.preparing = false }; do { request.preview = try await store.preparePullRequest(request.chat, remote: request.remote, base: request.base.isEmpty ? nil : request.base, title: request.title, body: request.body) } catch { request.failure = error.localizedDescription } }
    }
    private func submit(_ preview: PullRequestPreview) {
        request.applying = true; request.failure = nil
        Task {
            do {
                if let existing = preview.existing, existing.headSHA != preview.repository.headSHA { try await store.publishPullRequest(request.chat, preview: preview) }
                else if preview.existing != nil { try await store.linkPullRequest(request.chat, preview: preview) }
                else { try await store.createPullRequest(request.chat, preview: preview, push: request.push) }
                request.applying = false; store.closePullRequestDraft()
            } catch { request.failure = error.localizedDescription; request.applying = false }
        }
    }
}

struct PullRequestLogsRequest: Identifiable {
    let id = UUID()
    let text: String
    var chatID: UUID? = nil
}
@MainActor @Observable final class PullRequestMergeRequest: Identifiable {
    let id = UUID()
    let chat: ChatSession
    let pullRequest: PullRequest
    var applying = false
    var method: PullRequestMergeMethod = .squash
    var auto = true
    var failure: String?
    init(chat: ChatSession, pullRequest: PullRequest) { self.chat = chat; self.pullRequest = pullRequest }
}

struct PullRequestLogsView: View {
    let store: AppStore
    let request: PullRequestLogsRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Failed CI logs").font(.headline); Spacer(); Button("Done") { store.pullRequestLogsRequest = nil; if let chat = store.selected { store.driveDelivery(chat) } }.keyboardShortcut(.cancelAction) }
            ScrollView { ToolLog(text: request.text, command: false).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(20).frame(width: 680, height: 540).background(Palette.surface)
    }
}
struct PullRequestMergeView: View {
    let store: AppStore
    @Bindable var request: PullRequestMergeRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge pull request").font(.system(size: 19, weight: .semibold))
            Text("\(request.pullRequest.repository.slug) · PR #\(request.pullRequest.number)").textSelection(.enabled)
            Text("\(request.pullRequest.repository.branch) → \(request.pullRequest.repository.base)").font(.caption.monospaced())
            Text("Commit \(request.pullRequest.headSHA)").font(.caption.monospaced()).textSelection(.enabled)
            Picker("Method", selection: $request.method) { ForEach(PullRequestMergeMethod.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.disabled(request.applying)
            Toggle("Merge automatically when GitHub requirements pass", isOn: $request.auto).disabled(request.applying)
            Text("GitHub branch protections and checks apply.").font(.caption).foregroundStyle(.secondary)
            if let failure = request.failure { PullRequestFailureText(text: failure) }
            HStack {
                Button("Cancel") { store.closePullRequestMerge() }.disabled(request.applying)
                if request.applying { Button("Stop") { store.stop(request.chat) }; ProgressView().controlSize(.small) }
                Spacer()
                Button(request.auto ? "Enable auto-merge" : "Merge now") { submit() }.keyboardShortcut(.defaultAction).disabled(request.applying || !store.canMutateWorkspace(request.chat))
            }
        }.padding(24).frame(width: 540).background(Palette.surface)
        .interactiveDismissDisabled(request.applying)
        .onExitCommand { store.closePullRequestMerge() }
    }
    private func submit() {
        request.applying = true; request.failure = nil
        Task {
            do {
                try await store.mergePullRequest(request.chat, method: request.method, auto: request.auto, expected: request.pullRequest)
                request.applying = false; store.closePullRequestMerge()
            } catch { request.failure = error.localizedDescription; request.applying = false }
        }
    }
}

private struct PullRequestFailureText: View {
    let text: String
    var body: some View {
        ScrollView { Text(text).font(.caption).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 76)
    }
}
