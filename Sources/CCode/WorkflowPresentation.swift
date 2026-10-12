import SwiftUI

struct WorkflowPresentation: ViewModifier {
    @Bindable var store: AppStore
    let detachedPaneID: UUID?
    private func owns(_ chatID: UUID?, key: String = "") -> Bool {
        guard let owner=store.workflowOwner(for:key,sessionID:chatID) else { return false }
        if let detachedPaneID { return owner == detachedPaneID }
        return store.paneLayout.panes.contains { $0.id == owner }
    }
    private var focused: Bool { owns(store.selectedID,key:"settings") }
    private func scoped<T>(_ binding: Binding<T?>, key: String, chat: @escaping (T) -> UUID?) -> Binding<T?> {
        Binding(get: { binding.wrappedValue.flatMap { owns(chat($0),key:key) ? $0 : nil } }, set: { value in
            if value != nil || binding.wrappedValue.map({ owns(chat($0),key:key) }) == true { binding.wrappedValue=value }
        })
    }
    private var ownsSearch: Bool {
        if let detachedPaneID { return store.searchPaneID == detachedPaneID }
        return store.paneLayout.panes.contains { $0.id == store.searchPaneID }
    }
    func body(content: Content) -> some View {
        content
            .disabled(store.showSessionSearch)
            .accessibilityHidden(store.showSessionSearch)
            .overlay {
                if store.showSessionSearch && ownsSearch {
                    GeometryReader { geometry in
                        ZStack(alignment: .top) {
                            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { store.closeSessionSearch() }
                            SessionSearchView(store: store, width: min(620, max(280, geometry.size.width - 32)), resultsHeight: min(330, max(120, geometry.size.height - 225)))
                                .disabled(false).padding(.top, min(72, max(16, (geometry.size.height - 600) / 2)))
                        }
                    }
                }
            }
            .sheet(isPresented: Binding(get: { store.showSettings && focused }, set: { if focused { store.showSettings = $0 } })) { SettingsView(store: store) }
            .sheet(item: scoped($store.checkpointPreviewRequest, key:"checkpoint", chat: { $0.chat.id })) { FileCheckpointPreviewView(store: store, request: $0) }
            .sheet(item: scoped($store.fileRestorationHistoryRequest, key:"restorationHistory", chat: { $0.chat.id })) { FileRestorationHistoryView(store: store, request: $0) }
            .sheet(item: scoped($store.discardPreviewRequest, key:"discard", chat: { $0.chat.id })) { DiscardPreviewView(store: store, request: $0) }
            .sheet(item: scoped($store.pullRequestLogsRequest, key:"prLogs", chat: { $0.chatID ?? store.selectedID })) { PullRequestLogsView(store: store, request: $0) }
            .sheet(item: scoped($store.pullRequestMergeRequest, key:"prMerge", chat: { $0.chat.id })) { PullRequestMergeView(store: store, request: $0) }
            .sheet(item: scoped($store.pullRequestDraftRequest, key:"prDraft", chat: { $0.chat.id })) { PullRequestDraftView(store: store, request: $0) }
            .sheet(item: scoped($store.discardHistoryRequest, key:"discardHistory", chat: { $0.chat.id })) { DiscardHistoryView(store: store, request: $0) }
            .alert("ccode", isPresented: Binding(get: { store.error != nil && owns(store.selectedID,key:"error") }, set: { if !$0 && owns(store.selectedID,key:"error") { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
}
