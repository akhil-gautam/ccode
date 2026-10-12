import SwiftUI
import CCodeCore

struct FileCheckpointPreviewView: View {
    let store: AppStore
    let request: FileCheckpointPreviewRequest
    @Environment(\.dismiss) private var dismiss
    @State private var preview: FileCheckpointPreview?
    @State private var failure: String?
    @State private var result: FileCheckpointRestoration?
    @State private var confirmRestore = false
    @State private var inspectionID = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("File checkpoint").font(.system(size: 19, weight: .semibold)).fixedSize(horizontal: true, vertical: false)
                Text("Captured edits since this message").foregroundStyle(.secondary)
            }.padding(22)
            Divider()
            Group {
                if request.chat.restoringFiles {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Restoring captured files…") }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let result {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(result.status.title).fontWeight(.medium)
                            if let details = result.details { Text(details).foregroundStyle(.secondary).textSelection(.enabled) }
                            Text("The conversation and unsent drafts are preserved.").foregroundStyle(.secondary)
                            if result.status == .uncertain || result.status == .partial {
                                Text("Inspect the changed files and recovery copies before restoring again.").foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
                    }
                } else if let failure {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Checkpoint unavailable").fontWeight(.medium)
                        Text(failure).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if let preview {
                    if !preview.canRewind || preview.paths.isEmpty {
                        Text(preview.canRewind ? "No captured file changes" : "This checkpoint is unavailable")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(preview.paths.count) \(preview.paths.count == 1 ? "file" : "files") · +\(preview.insertions) −\(preview.deletions)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.top, 14)
                            List(Array(preview.paths.enumerated()), id: \.offset) { _, path in
                                Text(path).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                                    .truncationMode(.middle).help(path).textSelection(.enabled)
                            }.listStyle(.plain)
                        }
                    }
                } else {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Inspecting captured changes…").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("Checkpoints cover Claude’s file edits. Shell commands, external edits and background work may be outside this snapshot.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let unavailable = preview?.restoreUnavailable { Text(unavailable).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(unavailable) }
                HStack {
                    if let result, result.recoveryDirectory != nil {
                        Button("Recovery copies") { Task { await store.showCheckpointRecovery(result) } }.fixedSize()
                    }
                    Spacer()
                    Button("Refresh") { result = nil; preview = nil; failure = nil; inspectionID = UUID() }
                        .disabled(request.chat.restoringFiles).fixedSize()
                    if let preview, result == nil, preview.restoreParameters != nil {
                        Button("Restore files…") { confirmRestore = true }.disabled(!store.canRestoreFileCheckpoint(request.chat, preview: preview)).fixedSize()
                    }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).disabled(request.chat.restoringFiles).fixedSize()
                }
            }.padding(22)
        }.frame(width: 560, height: 430).background(Palette.surface)
        .task(id: inspectionID) {
            if !store.canPreviewFileCheckpoint(request.chat, at: request.itemID),
               let previous = request.chat.transcript.fileRestorations?.last(where: { $0.reference.promptID == request.itemID }) {
                result = previous; return
            }
            do {
                let result = try await store.previewFileCheckpoint(request.chat, at: request.itemID)
                try Task.checkCancellation(); preview = result
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
        .interactiveDismissDisabled(request.chat.restoringFiles)
        .onExitCommand { if !request.chat.restoringFiles { dismiss() } }
        .alert("Restore captured file edits?", isPresented: $confirmRestore) {
            Button("Cancel", role: .cancel) {}
            Button("Restore files", role: .destructive) {
                guard let preview else { return }
                Task { result = await store.restoreFileCheckpoint(request.chat, preview: preview) }
            }
        } message: {
            Text("This restores captured files to their state before this message. Current contents are saved as recovery copies. Finish external work first; conversation history and unsent drafts stay in place.")
        }
    }
}

extension FileCheckpointRestoration.Status {
    var title: String {
        switch self {
        case .preparing: "Preparing restoration"
        case .completed: "File restoration finished"
        case .partial: "Some files were skipped"
        case .uncertain: "Restoration outcome is uncertain"
        case .rejected: "Files were not restored"
        }
    }
}
