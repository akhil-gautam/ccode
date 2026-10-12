import Foundation
import SwiftUI
import AppKit
import CCodeCore

extension AppStore {
    func openWorkspaceReference(_ chat: ChatSession, reference: String, line: Int? = nil) async throws {
        guard canDeliver(chat), !chat.selectingWorkspaceFolder, chat.workspaceActionTask == nil, !chat.submittingReview, !checkpointRestorationBlocks(chat), !workspaceBranchEditing else {
            throw ACPError.workspace("Wait for the current workspace operation before opening a file.")
        }
        try Task.checkCancellation()
        chat.selectingWorkspaceFolder = true
        let task = Task { @MainActor in
            defer { chat.selectingWorkspaceFolder = false; chat.workspaceActionTask = nil; driveDelivery(chat) }
            let file = try await chat.workspace.fileReference(reference, line: line)
            let key = editorFileKey(chat, path: file.path)
            let dirty = chat.fileDrafts[key].map { $0.text != $0.original } ?? false
            let diskText = file.isDirectory || dirty ? nil : try await chat.workspace.read(file.path)
            try Task.checkCancellation()
            guard canDeliver(chat), !checkpointRestorationBlocks(chat), try await chat.workspace.fileReference(file.path).path == file.path else { throw CancellationError() }
            @MainActor func currentText() -> String {
                if let draft = chat.fileDrafts[key], draft.text != draft.original { return draft.text }
                return diskText ?? chat.fileDrafts[key]?.text ?? ""
            }
            let range = file.isDirectory ? NSRange(location: 0, length: 0) : try file.selection(in: currentText())
            var saved = chat.transcript
            saved.workspaceDirectory = file.root == chat.workspace.root ? nil : file.root
            saved.selectedEditorFile = file.isDirectory ? nil : key
            saved.editorFolder = file.isDirectory ? file.path : nil
            saved.draftText = chat.draft.isEmpty ? nil : chat.draft
            saved.draftAttachments = chat.attachments.isEmpty ? nil : chat.attachments
            saved.editorDrafts = chat.fileDrafts.filter { $0.value.text != $0.value.original }
            try await storage.save(saved, id: chat.id)
            do {
                try Task.checkCancellation()
                guard canDeliver(chat), !checkpointRestorationBlocks(chat), try await chat.workspace.fileReference(file.path).path == file.path else { throw CancellationError() }
                // Selection is calculated from the current draft, including edits made during storage I/O.
                let latestRange = file.isDirectory ? range : try file.selection(in: currentText())
                if let diskText, chat.fileDrafts[key].map({ $0.text == $0.original }) ?? true { chat.fileDrafts[key] = FileDraft(original: diskText, text: diskText) }
                chat.transcript.workspaceDirectory = saved.workspaceDirectory
                chat.selectedEditorFile = saved.selectedEditorFile; chat.editorFolder = saved.editorFolder; chat.editorSelection = latestRange
                setPane("files", for: chat)
                chat.repository = RepositoryStatus(); chat.changeStatistics = nil; chat.changeStatisticsError = nil; chat.workspaceRevision = UUID()
            } catch {
                // A canceled or re-bound navigation must not restore as a successful selection on restart.
                try? await persistDelivery(chat)
                throw error
            }
            await refreshWorkspace(chat)
        }
        chat.workspaceActionTask = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    func openWorkspaceTerminal(_ chat: ChatSession, directory: String) async throws -> TerminalTab {
        guard canDeliver(chat), !checkpointRestorationBlocks(chat), !chat.selectingWorkspaceFolder, chat.terminalTabs.count < 8 else { throw ACPError.workspace("Terminal is unavailable during this workspace operation, or eight tabs are already open.") }
        let folder = try await chat.workspace.fileReference(directory)
        guard folder.isDirectory else { throw ACPError.workspace("Select an existing workspace folder for the terminal.") }
        try Task.checkCancellation()
        guard canDeliver(chat), !checkpointRestorationBlocks(chat), !chat.selectingWorkspaceFolder, chat.terminalTabs.count < 8 else { throw CancellationError() }
        let tab = TerminalTab(directory: folder.path, environment: chat.workspace.environment, sshExecutable: chat.workspace.sshExecutable, localEnvironment: terminalEnvironment)
        chat.terminalTabs.append(tab); chat.activeTerminalID = tab.id
        return tab
    }
}

struct WorkspaceReferenceButton<Label: View>: View {
    let reference: String
    var line: Int? = nil
    let chat: ChatSession
    let store: AppStore
    @ViewBuilder let label: () -> Label
    var body: some View {
        Button { run { try await store.openWorkspaceReference(chat, reference: reference, line: line) } } label: { label() }
            .buttonStyle(.plain).help("Open in workspace")
            .disabled(chat.selectingWorkspaceFolder || store.checkpointRestorationBlocks(chat))
            .contextMenu {
                Button("Open in workspace") { run { try await store.openWorkspaceReference(chat, reference: reference, line: line) } }
                Button("Attach as context") { fileAction(.attach) }
                Button("Open terminal here") { fileAction(.terminal) }
                Divider()
                Button("Reveal in Finder") { fileAction(.finder) }.disabled(!chat.workspace.environment.isLocal)
                Button("Open in default app") { fileAction(.external) }.disabled(!chat.workspace.environment.isLocal)
                Button("Copy path") { fileAction(.copy) }
            }
    }
    private enum FileAction { case attach, terminal, finder, external, copy }
    private func fileAction(_ action: FileAction) {
        run {
            guard store.canDeliver(chat), !store.checkpointRestorationBlocks(chat) else { throw ACPError.workspace("Wait for the current workspace operation.") }
            let file = try await chat.workspace.fileReference(reference, line: line)
            try Task.checkCancellation()
            guard store.canDeliver(chat), !store.checkpointRestorationBlocks(chat) else { throw CancellationError() }
            switch action {
            case .attach:
                if await store.attachContext(file.candidate, to: chat) == false, store.error == nil { throw ACPError.workspace("Finish loading current attachments before attaching this context.") }
            case .terminal:
                let folder = file.isDirectory ? file.path : URL(fileURLWithPath: file.path).deletingLastPathComponent().path
                _ = try await store.openWorkspaceTerminal(chat, directory: folder)
                store.setPane("terminal", for: chat)
            case .finder:
                guard chat.workspace.environment.isLocal else { throw ACPError.workspace("Remote paths cannot be opened in Finder.") }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            case .external:
                guard chat.workspace.environment.isLocal else { throw ACPError.workspace("Open remote artifacts in the artifact preview.") }
                if !NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) { throw ACPError.workspace("No application could open this file.") }
            case .copy: NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { do { try await operation() } catch { if !(error is CancellationError) { store.error = error.localizedDescription } } }
    }
}

struct WorkspaceLinkHandling: ViewModifier {
    let chat: ChatSession
    let store: AppStore
    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { return .systemAction }
            let reference: String
            if url.scheme == nil {
                reference = url.path + (url.fragment.map { "#" + $0 } ?? "")
            } else { reference = url.absoluteString }
            Task {
                do { try await store.openWorkspaceReference(chat, reference: reference) }
                catch { if !(error is CancellationError) { store.error = error.localizedDescription } }
            }
            return .handled
        })
    }
}
