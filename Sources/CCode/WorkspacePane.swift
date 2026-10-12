import SwiftUI
import AppKit
import WebKit
import CCodeCore

struct WorkspacePane: View {
    @Bindable var chat: ChatSession
    @Bindable var store: AppStore
    let kind: String
    var detachedPaneID: UUID? = nil
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .medium)).fixedSize()
                    Spacer()
                    if kind != "tasks" { Button { Task { await store.refreshWorkspace(chat) } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh workspace") }
                    Button {
                        do { if let detachedPaneID { try store.dockWorkspacePane(detachedPaneID) } else { try store.popOutWorkspacePane(chat,kind:kind) } }
                        catch { store.error=error.localizedDescription }
                    } label: { Image(systemName:detachedPaneID == nil ? "arrow.up.right.square" : "rectangle.inset.filled") }.help(detachedPaneID == nil ? "Pop out pane" : "Dock pane")
                    Button { if let detachedPaneID { Task { await store.closeWorkspacePane(detachedPaneID) } } else { store.setPane(nil, for: chat) } } label: { Image(systemName: "xmark") }.help("Close pane")
                }.buttonStyle(.plain)
                if ["diff", "files", "terminal"].contains(kind) {
                    HStack {
                        WorkspaceFolderMenu(chat: chat, store: store)
                        Spacer(minLength: 8)
                        if !chat.repository.branch.isEmpty { WorkspaceBranchMenu(chat: chat, store: store) }
                    }
                }
            }.padding(15)
            Divider()
            switch kind {
            case "diff": ChangesPane(chat: chat, store: store)
            case "files": FilesPane(chat: chat, store: store)
            case "terminal": TerminalPane(chat: chat, store: store)
            case "browser": BrowserPane(chat: chat, store: store)
            case "computer": ComputerPane(chat:chat,store:store)
            case "simulator": SimulatorPane(chat:chat,store:store)
            case "plan": plan
            case "artifacts": ArtifactsPane(chat: chat)
            case "tasks": TasksPane(chat: chat, store: store)
            default: EmptyView()
            }
        }.background(Palette.sidebar)
    }
    private var title: String { ["diff": "Changes", "files": "Files", "terminal": "Terminal", "browser": "Browser", "plan": "Plan", "artifacts": "Artifacts", "tasks": "Tasks", "computer": "Computer", "simulator": "iOS Simulator"][kind] ?? "Workspace" }
    private var plan: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if chat.transcript.plan.isEmpty { Text("Plans shared by your agent appear here.").foregroundStyle(.secondary).padding(.top, 20) }
                ForEach(Array(chat.transcript.plan.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: entry["status"].string == "completed" ? "checkmark.circle.fill" : entry["status"].string == "in_progress" ? "circle.dotted" : "circle").foregroundStyle(entry["status"].string == "completed" ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 5) { Text(entry["content"].string).textSelection(.enabled); Text(entry["priority"].string.capitalized).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ChangesPane: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    @State private var selectedPath: String?
    @State private var diff = ""
    @State private var loading = false
    @State private var failure: String?
    @State private var comment = ""
    @State private var commentLine: DiffLine?
    @State private var changingIndex = false
    @State private var commitMessage = ""
    @State private var loadRevision = 0
    @State private var stagedOnly = false
    @State private var diffBaseRevision: String?
    @State private var capturingComment = false
    @State private var reviewFailure: String?
    @State private var focusedFindingID: UUID?
    @State private var previewingDiscard = false
    private var canRequestReview: Bool { !chat.busy && !chat.hasLiveAgentWork && chat.pendingPrompts.isEmpty && chat.pendingSettings.isEmpty && !store.checkpointRestorationBlocks(chat) && store.canDeliver(chat) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(chat.repository.files.count) changed \(chat.repository.files.count == 1 ? "file" : "files")").foregroundStyle(.secondary)
                Spacer()
                if let stats = chat.changeStatistics, !stats.isEmpty { ChangeStatisticsLabel(values: Array(stats.values)) }
                if chat.transcript.discards?.isEmpty == false {
                    Button { store.discardHistoryRequest = DiscardHistoryRequest(chat: chat) } label: { Image(systemName: "clock.arrow.circlepath") }.help("Discard history and recovery copies")
                }
                Menu {
                    Button("Discard all working changes…") { previewDiscard(chat.repository.files.filter(\.unstaged).map(\.path), scope: .working) }
                        .disabled(!chat.repository.files.contains(where: \.unstaged))
                    Button("Discard all changes…") { previewDiscard(chat.repository.files.map(\.path), scope: .all) }
                } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(previewingDiscard || changingIndex || !store.canDiscardChanges(chat) || chat.repository.files.isEmpty).help("Preview discard for all changed files")
                Button(chat.transcript.codeReview == nil ? "Review code" : "Re-review") { requestReview() }.disabled(!canRequestReview || changingIndex || chat.repository.files.isEmpty)
            }.font(.caption).padding(12)
            PullRequestBar(chat: chat, store: store)
            if let review = chat.transcript.codeReview {
                CodeReviewStatusView(review: review, canFix: canRequestReview && !changingIndex, select: { finding in
                    Task { do { if chat.workspaceDirectory != finding.context.root { try await store.selectWorkspaceFolder(chat, path: finding.context.root) }; selectedPath = finding.path; stagedOnly = false; focusedFindingID = finding.id } catch { reviewFailure = error.localizedDescription } }
                }, fixAll: { fixReview() })
            }
            if chat.repository.files.isEmpty { Text("No changes to review").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ScrollView(.horizontal) { HStack { ForEach(chat.repository.files) { file in Button { selectedPath = file.path } label: { HStack { Text(file.status).foregroundStyle(file.status == "??" ? Color.green : Color.orange); Text(file.path).lineLimit(1); if let stats = chat.changeStatistics?[file.path] { ChangeStatisticsLabel(values: [stats]) } }.font(.system(size: 11, design: .monospaced)).padding(8).background(selectedPath == file.path ? Palette.selected : Palette.muted, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain) } }.padding(.horizontal, 12) }.frame(height: 46)
                Divider()
                if let file = chat.repository.files.first(where: { $0.path == selectedPath }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(file.staged ? (file.unstaged ? "Staged and working changes" : "Staged changes") : "Working changes").foregroundStyle(.secondary)
                        HStack {
                        if file.unstaged { Button("Stage file") { mutate { root in try await store.stageWorkspaceFile(chat, path: file.path, directory: root) } } }
                        if file.staged { Button("Unstage file") { mutate { root in try await store.unstageWorkspaceFile(chat, path: file.path, originalPath: file.originalPath, directory: root) } } }
                        Menu("Discard…") {
                            if file.unstaged { Button("Working changes…") { previewDiscard([file.path], scope: .working) } }
                            Button("All changes to this file…") { previewDiscard([file.path], scope: .all) }
                        }.disabled(previewingDiscard || loading || !store.canDiscardChanges(chat)).help("Preview before discarding changes; original contents are retained in recovery")
                        Spacer(minLength: 0)
                        }.fixedSize(horizontal: false, vertical: true)
                    }.font(.caption).padding(12).disabled(changingIndex || chat.busy)
                    if file.staged { Picker("Diff source", selection: $stagedOnly) { Text("All changes").tag(false); Text("Staged").tag(true) }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.bottom, 10) }
                }
                if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let failure { Text(failure).foregroundStyle(.secondary).textSelection(.enabled).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { DiffText(text: diff, onComment: { commentLine = $0 }, onFileComment: { commentLine = nil }, findings: displayedFindings, canFix: canRequestReview && !changingIndex, onFix: { fixReview([$0]) }, focusedFindingID: focusedFindingID) }
                if let line = commentLine {
                    HStack {
                        Text("Line \(line.newLine ?? line.oldLine ?? 0) · \(line.source(stagedOnly: stagedOnly))").font(.caption.monospaced())
                        Spacer()
                        Button("Attach line") { attach(line) }.font(.caption).disabled(chat.attachingFiles || loading)
                        Button { commentLine = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Clear line selection")
                    }.padding(.horizontal, 12).padding(.top, 10)
                }
                HStack {
                    TextField(commentLine == nil ? "Feedback on this file" : "Feedback on this line", text: $comment).textFieldStyle(.roundedBorder).onSubmit { addComment() }
                    Button(capturingComment ? "Adding…" : "Add comment") { addComment() }
                        .disabled(capturingComment || loading || chat.submittingReview || selectedPath == nil || diff.isEmpty || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(12)
                Divider()
                HStack {
                    TextField("Commit message", text: $commitMessage).textFieldStyle(.roundedBorder).disabled(changingIndex)
                    Button("Commit staged (\(chat.repository.files.filter(\.staged).count))") {
                        let message = commitMessage
                        mutate { root in try await store.commitWorkspaceChanges(chat, message: message, directory: root); commitMessage = "" }
                    }.disabled(changingIndex || chat.busy || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.repository.files.contains(where: \.staged))
                }.padding(12)
            }
            if let error = chat.changeStatisticsError { Text("Counts unavailable: " + error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(12) }
            if let reviewFailure { Text(reviewFailure).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(12) }
            ReviewCommentsView(chat: chat, store: store, selection: reviewSelection)
        }.task(id: "\(selectedPath ?? "")-\(stagedOnly)-\(chat.workspaceRevision)") { await load() }
        .onChange(of: chat.repository.files) { _, files in if !files.contains(where: { $0.path == selectedPath }) { selectedPath = files.first?.path }; if !files.contains(where: { $0.path == selectedPath && $0.staged }) { stagedOnly = false } }
        .onAppear { selectedPath = chat.repository.files.first?.path }
        .onChange(of: chat.workspaceDirectory) { _, _ in selectedPath = nil; diff = ""; diffBaseRevision = nil; commentLine = nil; stagedOnly = false; focusedFindingID = nil }
        .onChange(of: selectedPath) { _, _ in commentLine = nil; stagedOnly = false }
        .onChange(of: stagedOnly) { _, _ in commentLine = nil }
        .onChange(of: diff) { _, _ in commentLine = nil }
    }
    private var reviewSelection: ReviewSelection? {
        guard !loading, failure == nil, let path = selectedPath, !diff.isEmpty else { return nil }
        return ReviewSelection(root: chat.workspaceDirectory, path: path, diff: diff, baseRevision: diffBaseRevision, stagedOnly: stagedOnly, line: commentLine)
    }
    private var displayedFindings: [ReviewFinding] {
        guard !loading, failure == nil, let path = selectedPath, let review = chat.transcript.codeReview, review.status == .complete else { return [] }
        return review.findings.filter { $0.context.matchesDisplayed(root: chat.workspaceDirectory, path: path, diff: diff, baseRevision: diffBaseRevision, stagedOnly: stagedOnly) }
    }
    private func requestReview() {
        reviewFailure = nil
        Task { do { _ = try await store.requestCodeReview(chat) } catch { reviewFailure = error.localizedDescription } }
    }
    private func previewDiscard(_ paths: [String], scope: DiscardScope) {
        guard !previewingDiscard else { return }
        previewingDiscard = true; reviewFailure = nil
        Task {
            defer { previewingDiscard = false }
            do {
                let preview = try await store.previewDiscardChanges(chat, paths: paths, scope: scope)
                guard store.isChatVisible(chat.id) else { return }
                store.discardPreviewRequest = DiscardPreviewRequest(chat: chat, preview: preview)
            } catch { reviewFailure = error.localizedDescription }
        }
    }
    private func fixReview(_ ids: Set<UUID>? = nil) {
        reviewFailure = nil
        Task { do { _ = try await store.fixCodeReview(chat, findingIDs: ids) } catch { reviewFailure = error.localizedDescription } }
    }
    private func addComment() {
        guard !capturingComment, !loading, !chat.submittingReview, let path = selectedPath else { return }
        let text = comment, capturedDiff = diff, line = commentLine, staged = stagedOnly, base = diffBaseRevision, directory = chat.workspaceDirectory
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        capturingComment = true; reviewFailure = nil
        Task {
            defer { capturingComment = false }
            do {
                try await store.addReviewComment(chat, path: path, diff: capturedDiff, baseRevision: base, stagedOnly: staged, line: line, text: text, directory: directory)
                if comment == text { comment = "" }
                if commentLine?.id == line?.id, commentLine?.text == line?.text { commentLine = nil }
            } catch { reviewFailure = error.localizedDescription }
        }
    }
    private func load() async {
        loadRevision += 1; let revision = loadRevision
        guard let path = selectedPath else { diff = ""; return }
        loading = true; failure = nil
        let source = stagedOnly, directory = chat.workspaceDirectory
        do {
            let before = try? await chat.workspace.repository.run(["rev-parse", "--verify", "HEAD"], at: directory).trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await chat.workspace.repository.diff(at: directory, path: path, stagedOnly: source)
            let after = try? await chat.workspace.repository.run(["rev-parse", "--verify", "HEAD"], at: directory).trimmingCharacters(in: .whitespacesAndNewlines)
            guard before == after else { throw ACPError.workspace("The repository changed while loading the diff. Refresh it before selecting a line.") }
            guard !Task.isCancelled, selectedPath == path, stagedOnly == source, loadRevision == revision, chat.workspaceDirectory == directory else { return }
            diff = result; diffBaseRevision = before
        }
        catch { if !Task.isCancelled, loadRevision == revision { failure = error.localizedDescription } }
        guard loadRevision == revision else { return }
        loading = false
    }
    private func attach(_ line: DiffLine) {
        guard let path = selectedPath else { return }
        let capturedDiff = diff, staged = stagedOnly, revision = diffBaseRevision, directory = chat.workspaceDirectory
        Task {
            do {
                let snapshot = try await chat.workspace.selectedDiffContext(path: URL(fileURLWithPath: directory).appendingPathComponent(path).path, diff: capturedDiff, line: line, stagedOnly: staged, baseRevision: revision)
                _ = await store.attachSelectedContext(snapshot, to: chat)
            } catch { failure = error.localizedDescription }
        }
    }
    private func mutate(_ operation: @escaping (String) async throws -> Void) {
        guard !changingIndex, !chat.busy else { return }
        let directory = chat.workspaceDirectory
        changingIndex = true; failure = nil
        Task {
            do { try await operation(directory); await load() }
            catch { failure = error.localizedDescription }
            changingIndex = false
        }
    }
}

struct DiffText: View {
    let text: String
    var onComment: ((DiffLine) -> Void)?
    var onFileComment: (() -> Void)?
    var findings: [ReviewFinding] = []
    var canFix = false
    var onFix: ((UUID) -> Void)?
    var focusedFindingID: UUID?
    @State private var lines: [DiffLine] = []
    @State private var parsedRevision = UUID()
    var body: some View {
        GeometryReader { geometry in
          ScrollViewReader { proxy in
          ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(findings.filter { $0.startLine == nil }) { finding in
                    ReviewFindingCard(finding: finding, canFix: canFix && onFix != nil, fix: { onFix?(finding.id) }, respond: { onFileComment?() }).id(finding.id)
                }
                ForEach(lines) { line in
                    HStack(alignment: .top, spacing: 12) {
                        Button { onComment?(line) } label: {
                            HStack(spacing: 8) { Text(line.oldLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing); Text(line.newLine.map(String.init) ?? "").frame(width: 40, alignment: .trailing) }.foregroundStyle(.tertiary)
                        }.buttonStyle(.plain).disabled(onComment == nil || (line.oldLine == nil && line.newLine == nil)).help("Add feedback on this line")
                        Text(line.text.isEmpty ? " " : line.text).foregroundStyle(line.added ? Color.green : line.removed ? Color.red : line.text.hasPrefix("@@") ? Color.secondary : Color.primary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 3).padding(.horizontal, 10).background(line.added ? Color.green.opacity(0.055) : line.removed ? Color.red.opacity(0.055) : .clear).id(line.id)
                    ForEach(findings.filter { $0.startLine != nil && ($0.context.side == .old ? line.oldLine : line.newLine) == $0.startLine }) { finding in
                        ReviewFindingCard(finding: finding, canFix: canFix && onFix != nil, fix: { onFix?(finding.id) }, respond: { onComment?(line) })
                    }
                }
            }.font(.system(size: 11, design: .monospaced)).padding(.vertical, 8).frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
          }
          .onChange(of: focusedFindingID) { _, _ in focus(proxy) }
          .onChange(of: parsedRevision) { _, _ in focus(proxy) }
          }
        }
        .task(id: text) { let value = text; let parsed = await Task.detached(priority: .utility) { Repository.diffLines(value) }.value; if !Task.isCancelled { lines = parsed; parsedRevision = UUID() } }
    }
    private func focus(_ proxy: ScrollViewProxy) {
        guard let finding = findings.first(where: { $0.id == focusedFindingID }) else { return }
        guard let start = finding.startLine else { proxy.scrollTo(finding.id, anchor: .top); return }
        guard let line = lines.first(where: { (finding.context.side == .old ? $0.oldLine : $0.newLine) == start }) else { return }
        proxy.scrollTo(line.id, anchor: .top)
    }
}

private struct FilesPane: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    private var path: String? { chat.selectedEditorFile }
    @State private var query = ""
    @State private var failure: String?
    @State private var confirmReload = false
    private var selection: NSRange { chat.editorSelection }
    private var draft: Binding<String> {
        Binding(get: { path.flatMap { chat.fileDrafts[$0]?.text } ?? "" }, set: { if let path { chat.fileDrafts[path]?.text = $0 } })
    }
    private var dirty: Bool { guard let path, let draft = chat.fileDrafts[path] else { return false }; return draft.text != draft.original }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "magnifyingglass"); TextField("Find a file", text: $query).textFieldStyle(.plain) }.padding(12).foregroundStyle(.secondary)
            if let folder = chat.editorFolder {
                HStack {
                    Text(folder).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).help(folder)
                    Spacer()
                    Button("All files") { Task { do { try await store.selectWorkspaceFolder(chat, path: chat.workspaceDirectory) } catch { failure = error.localizedDescription } } }
                }.padding(.horizontal, 12).padding(.bottom, 8)
            }
            ScrollView(.horizontal) {
                HStack { ForEach(chat.files.filter { let full = chat.workspace.filePath($0), folder = chat.editorFolder ?? chat.workspaceDirectory; return full.hasPrefix(folder == "/" ? "/" : folder + "/") }.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.prefix(100), id: \.self) { file in
                    WorkspaceReferenceButton(reference: chat.workspace.filePath(file), chat: chat, store: store) {
                        Text(file).lineLimit(1).font(.caption.monospaced()).padding(8).background(path == file ? Palette.selected : Palette.muted, in: RoundedRectangle(cornerRadius: 6))
                    }
                } }.padding(.horizontal, 12)
            }.frame(height: 44)
            Divider()
            if let path {
                HStack { WorkspaceReferenceButton(reference: chat.workspace.filePath(path), chat: chat, store: store) { Text(path).font(.caption.monospaced()).lineLimit(1).help(path) }; if dirty { Text("Edited").font(.caption).foregroundStyle(.orange) }; Spacer(); Button("Reload") { if dirty { confirmReload = true } else { Task { await load(force: true) } } }.disabled(store.checkpointRestorationBlocks(chat)); Button("Save") { Task { await save(path) } }.disabled(!dirty || store.checkpointRestorationBlocks(chat) || chat.workspaceWrites > 0) }.padding(12)
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(12) }
                if chat.fileDrafts[path] != nil {
                    SelectionTextEditor(text: draft, selection: $chat.editorSelection).id(path)
                    HStack {
                        Text(selection.length > 0 ? "\(selection.length) characters selected" : "Select code to attach as context").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Attach selection") { attachSelection(path) }.font(.caption).disabled(selection.length == 0 || chat.attachingFiles)
                    }.padding(12)
                }
                else { Spacer() }
            } else { Text("Select a file to edit").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: "\(path ?? "")-\(chat.workspaceRevision)") { await load() }
        .onChange(of: chat.workspaceDirectory) { _, _ in failure = nil }
        .onDisappear { Task { await store.save(chat) } }
        .confirmationDialog("Discard unsaved edits and reload this file?", isPresented: $confirmReload) { Button("Discard and reload", role: .destructive) { Task { await load(force: true) } } }
    }
    private func attachSelection(_ path: String) {
        guard let text = chat.fileDrafts[path]?.text, selection.length > 0 else { return }
        let range = selection
        Task {
            do {
                let snapshot = try await chat.workspace.selectedFileContext(path: chat.workspace.filePath(path), text: text, range: range)
                _ = await store.attachSelectedContext(snapshot, to: chat)
            } catch { failure = error.localizedDescription }
        }
    }
    private func load(force: Bool = false) async {
        guard let selected = path, force || chat.fileDrafts[selected].map({ $0.text == $0.original }) ?? true else { return }
        failure = nil
        do { _ = try await store.loadWorkspaceFile(chat, path: chat.workspace.filePath(selected), force: force) }
        catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
    private func save(_ selected: String) async {
        do { try await store.saveWorkspaceFile(chat, key: selected); failure = nil }
        catch { failure = error.localizedDescription }
    }

}
