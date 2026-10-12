import Foundation
import CCodeCore

extension AppStore {
    func loadWorkspaceFile(_ chat: ChatSession, path: String, force: Bool = false) async throws -> String {
        guard canDeliver(chat), !checkpointRestorationBlocks(chat) else { throw ACPError.workspace("Wait for current workspace operations before opening a file.") }
        let directory = try declaredWorkspaceDirectory(chat, path: chat.workspaceDirectory)
        let folder = try Workspace(root: directory, environment: chat.workspace.environment, sshExecutable: chat.workspace.sshExecutable)
        let file = try await folder.scoped(folder.filePath(path))
        let key = editorFileKey(chat, path: file.path)
        if force || chat.fileDrafts[key].map({ $0.text == $0.original }) ?? true {
            let text = try await folder.read(file.path)
            try Task.checkCancellation()
            guard canDeliver(chat), chat.workspaceDirectory == directory, !checkpointRestorationBlocks(chat) else { throw CancellationError() }
            // Only explicit Reload may replace an editor draft which appeared during the read.
            if force || chat.fileDrafts[key].map({ $0.text == $0.original }) ?? true { chat.fileDrafts[key] = FileDraft(original: text, text: text) }
        }
        return key
    }
    func saveWorkspaceFile(_ chat: ChatSession, key: String) async throws {
        guard let draft = chat.fileDrafts[key] else { throw ACPError.workspace("Select an editor draft before saving.") }
        let path = chat.workspace.filePath(key)
        try await performWorkspaceAction(chat) { _ in
            try await chat.workspace.write(path, content: draft.text, expecting: draft.original)
        }
        chat.fileDrafts[key]?.original = draft.text
        try await persistDelivery(chat)
    }
    func unstageWorkspaceFile(_ chat: ChatSession, path: String, originalPath: String? = nil, directory: String? = nil) async throws {
        try await performWorkspaceAction(chat, directory: directory) { root in try await chat.workspace.repository.unstage(at: root, path: path, originalPath: originalPath) }
    }
    func createWorkspaceBranch(_ chat: ChatSession, name: String, directory: String? = nil) async throws {
        try await performWorkspaceAction(chat, directory: directory) { root in try await chat.workspace.repository.createBranch(at: root, name: name) }
    }
    func switchWorkspaceBranch(_ chat: ChatSession, branch: String, directory: String? = nil) async throws {
        guard checkpointRestoreChats(chat).allSatisfy({ !$0.fileDrafts.values.contains { $0.text != $0.original } }) else {
            throw ACPError.workspace("Save or explicitly reload unsaved editor drafts before changing branches.")
        }
        try await performWorkspaceAction(chat, directory: directory) { root in try await chat.workspace.repository.switchBranch(at: root, branch: branch) }
    }
    func openWorkspaceTerminal(_ chat: ChatSession) throws -> TerminalTab {
        guard canDeliver(chat), !checkpointRestorationBlocks(chat), !chat.selectingWorkspaceFolder, chat.terminalTabs.count < 8 else { throw ACPError.workspace("Terminal is unavailable during this workspace operation, or eight tabs are already open.") }
        let directory = try declaredWorkspaceDirectory(chat, path: chat.workspaceDirectory)
        let tab = TerminalTab(directory: directory, environment: chat.workspace.environment, sshExecutable: chat.workspace.sshExecutable, localEnvironment: terminalEnvironment)
        chat.terminalTabs.append(tab); chat.activeTerminalID = tab.id
        return tab
    }
    func editorFileKey(_ chat: ChatSession, path: String) -> String {
        let primary = chat.workspace.root
        return path.hasPrefix(primary == "/" ? "/" : primary + "/") ? String(path.dropFirst(primary.count + (primary == "/" ? 0 : 1))) : path
    }
    func selectWorkspaceFolder(_ chat: ChatSession, path: String) async throws {
        guard canDeliver(chat), !chat.selectingWorkspaceFolder, !chat.submittingReview, !checkpointRestorationBlocks(chat) else {
            throw ACPError.workspace("Wait for the current workspace operation before selecting another folder.")
        }
        let directory = try declaredWorkspaceDirectory(chat, path: path)
        try Task.checkCancellation()
        let prior = chat.transcript.workspaceDirectory
        let priorFile = chat.selectedEditorFile, priorFolder = chat.editorFolder, priorSelection = chat.editorSelection
        chat.selectingWorkspaceFolder = true
        defer { chat.selectingWorkspaceFolder = false; driveDelivery(chat) }
        chat.transcript.workspaceDirectory = directory == chat.workspace.root ? nil : directory
        chat.selectedEditorFile = nil; chat.editorFolder = nil; chat.editorSelection = NSRange(location: 0, length: 0)
        do { try await persistDelivery(chat) }
        catch { chat.transcript.workspaceDirectory = prior; chat.selectedEditorFile = priorFile; chat.editorFolder = priorFolder; chat.editorSelection = priorSelection; throw error }
        chat.repository = RepositoryStatus(); chat.changeStatistics = nil; chat.changeStatisticsError = nil; chat.workspaceRevision = UUID()
        await refreshWorkspace(chat)
    }
    func stageWorkspaceFile(_ chat: ChatSession, path: String, directory: String? = nil) async throws {
        try await performWorkspaceAction(chat, directory: directory) { root in try await chat.workspace.repository.stage(at: root, path: path) }
    }
    func commitWorkspaceChanges(_ chat: ChatSession, message: String, directory: String? = nil) async throws {
        try await performWorkspaceAction(chat, directory: directory) { root in try await chat.workspace.repository.commit(at: root, message: message) }
    }
    func declaredWorkspaceDirectory(_ chat: ChatSession, path: String) throws -> String {
        let directory = chat.workspace.environment.isLocal ? try Workspace(root: path).root : Workspace.lexicalPath(path)
        guard chat.workspace.roots.contains(directory) else { throw ACPError.workspace("Folder does not belong to this session's workspace.") }
        return directory
    }
    private func performWorkspaceAction(_ chat: ChatSession, directory requestedDirectory: String? = nil, operation: @escaping @Sendable (String) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard canMutateWorkspace(chat) else { throw ACPError.workspace("Finish agent work, queued messages, settings and terminals before changing this repository.") }
        let directory = try declaredWorkspaceDirectory(chat, path: requestedDirectory ?? chat.workspaceDirectory)
        guard directory == chat.workspaceDirectory else { throw ACPError.workspace("The displayed folder changed. Review the selected repository before trying again.") }
        let owners = checkpointRestoreChats(chat)
        for owner in owners { owner.workspaceWrites += 1 }
        let task = Task { @MainActor in
            defer {
                for owner in owners { owner.workspaceWrites -= 1; owner.workspaceActionTask = nil }
                for owner in checkpointRestoreChats(chat) { driveDelivery(owner) }
            }
            do {
                try await operation(directory)
                for owner in owners { await refreshWorkspace(owner) }
            } catch {
                for owner in owners { await refreshWorkspace(owner) }
                throw error
            }
        }
        for owner in owners { owner.workspaceActionTask = task }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
