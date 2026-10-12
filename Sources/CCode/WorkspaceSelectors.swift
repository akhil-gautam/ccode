import SwiftUI
import CCodeCore

struct WorkspaceFolderMenu: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    var body: some View {
        Menu {
            ForEach(chat.workspace.roots, id: \.self) { directory in
                Button {
                    Task { do { try await store.selectWorkspaceFolder(chat, path: directory) } catch { store.error = error.localizedDescription } }
                } label: {
                    if chat.workspaceDirectory == directory { Label(directory, systemImage: "checkmark") }
                    else { Text(directory) }
                }
            }
        } label: {
            Text(URL(fileURLWithPath: chat.workspaceDirectory).lastPathComponent).lineLimit(1).truncationMode(.middle)
        }.menuStyle(.borderlessButton).font(.system(size: 12)).frame(maxWidth: 150)
            .help(chat.workspaceDirectory).accessibilityLabel("Workspace folder")
            .disabled(chat.selectingWorkspaceFolder || chat.submittingReview || store.checkpointRestorationBlocks(chat) || store.discardPreviewRequest != nil || store.workspaceBranchEditing)
    }
}

struct WorkspaceBranchMenu: View {
    @Bindable var chat: ChatSession
    @Bindable var store: AppStore
    @State private var branches: [String] = []
    @State private var branchName = ""
    @State private var creating = false
    @State private var failure: String?
    @FocusState private var nameFocused: Bool
    var body: some View {
        Menu {
            ForEach(branches, id: \.self) { branch in
                Button(branch) { switchBranch(branch) }
            }
            Divider()
            Button("New branch…") { branchName = ""; failure = nil; store.workspaceBranchEditing = true }
        } label: {
            Label(chat.repository.branch, systemImage: "arrow.triangle.branch").lineLimit(1).truncationMode(.middle)
        }.menuStyle(.borderlessButton).font(.system(size: 11, design: .monospaced)).frame(maxWidth: 150)
            .help("Switch or create a branch in " + chat.workspaceDirectory).accessibilityLabel("Workspace branch")
            .disabled(!store.canMutateWorkspace(chat))
            .task(id: chat.workspaceRevision) {
                let directory = chat.workspaceDirectory
                do {
                    let values = try await chat.workspace.repository.branches(at: directory)
                    guard !Task.isCancelled, chat.workspaceDirectory == directory else { return }
                    branches = values
                } catch { if !Task.isCancelled { branches = [] } }
            }
            .popover(isPresented: Binding(get: { store.workspaceBranchEditing }, set: { if !creating { store.workspaceBranchEditing = $0 } })) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("New branch").font(.headline)
                    Text(URL(fileURLWithPath: chat.workspaceDirectory).lastPathComponent + " · From " + chat.repository.branch).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    TextField("Branch name", text: $branchName).textFieldStyle(.roundedBorder).focused($nameFocused).accessibilityLabel("Workspace branch name").onSubmit(create).disabled(creating)
                    if let failure { Text(failure).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    HStack {
                        Button(creating ? "Stop" : "Cancel") { if creating { store.stop(chat) } else { store.workspaceBranchEditing = false } }.keyboardShortcut(.cancelAction)
                        Spacer()
                        if creating { ProgressView().controlSize(.small) }
                        Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(creating || branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(16).frame(width: 300).task { nameFocused = true }
            }
            .onDisappear { store.workspaceBranchEditing = false }
    }
    private func switchBranch(_ branch: String) {
        let directory = chat.workspaceDirectory
        Task { do { try await store.switchWorkspaceBranch(chat, branch: branch, directory: directory) } catch { store.error = error.localizedDescription } }
    }
    private func create() {
        guard !creating else { return }
        let directory = chat.workspaceDirectory, name = branchName
        creating = true; failure = nil
        Task {
            defer { creating = false }
            do { try await store.createWorkspaceBranch(chat, name: name, directory: directory); store.workspaceBranchEditing = false }
            catch { failure = error.localizedDescription }
        }
    }
}
