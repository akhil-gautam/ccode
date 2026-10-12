import SwiftUI
import CCodeCore

struct ConversationVersionsView: View {
    @Bindable var store: AppStore
    let selected: SessionInfo
    private var versions: [SessionInfo] { ConversationBranch.related(to: selected.id, in: store.sessions) }
    var body: some View {
        if versions.count > 1 || selected.origin != nil {
            Menu {
                if let origin = selected.origin {
                    if let source = versions.first(where: { $0.id == origin.sourceSessionID }) {
                        Text("\(origin.kind.displayTitle) from \(source.title)")
                    } else { Text("Source conversation unavailable") }
                    Divider()
                }
                ForEach(versions) { version in
                    Button {
                        Task { await store.select(version.id) }
                    } label: {
                        HStack {
                            Text(version.title + (version.archived ? " (Archived)" : ""))
                            if version.id == selected.id { Image(systemName: "checkmark") }
                        }
                    }.disabled(version.archived || version.id == selected.id)
                }
            } label: { Label("Versions", systemImage: "arrow.triangle.branch") }
            .menuStyle(.borderlessButton).fixedSize(horizontal: true, vertical: false)
            .help("Browse the original conversation, edits, retries and forks")
            .accessibilityLabel("Conversation versions")
        }
    }
}
