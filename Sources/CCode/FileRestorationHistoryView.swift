import SwiftUI
import CCodeCore

struct FileRestorationHistoryRequest: Identifiable {
    let id = UUID()
    let chat: ChatSession
}

struct FileRestorationHistoryView: View {
    let store: AppStore
    let request: FileRestorationHistoryRequest
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("File restorations").font(.system(size: 19, weight: .semibold)).padding(22)
            Divider()
            List((request.chat.transcript.fileRestorations ?? []).reversed()) { result in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(result.status.title).fontWeight(.medium)
                        Spacer()
                        Text(result.startedAt, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                    }
                    if let details = result.details { Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(3).help(details) }
                    if result.recoveryDirectory != nil {
                        Button("Show recovery copies") { Task { await store.showCheckpointRecovery(result) } }.font(.caption)
                    } else if result.status == .uncertain {
                        Text("Recovery manifests are stored in ccode’s checkpoint-recovery folder.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
            }.listStyle(.plain)
            Divider()
            HStack { Button("Recovery folder") { Task { await store.showCheckpointRecoveryFolder() } }; Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(22)
        }.frame(width: 560, height: 400).background(Palette.surface)
            .onExitCommand { dismiss() }
    }
}
