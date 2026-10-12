import SwiftUI
import CCodeCore

extension AppStore {
    func openSubagent(_ chat: ChatSession, id: String) {
        guard isChatVisible(chat.id), canDeliver(chat), chat.transcript.subagent(id) != nil else { return }
        chat.selectedAsyncTaskID = nil; chat.selectedSubagentID = id; setPane("tasks", for: chat)
    }
}

struct SubagentEntry: View {
    let child: SubagentSession
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: child.isRunning ? "person.2" : child.state == "failed" ? "exclamationmark.triangle" : "person.2")
                    .foregroundStyle(child.state == "failed" ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(child.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    if !child.task.isEmpty { Text(child.task).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 4)
                Text(child.state.capitalized).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 10))
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Open \(child.name) transcript")
    }
}

struct TasksPane: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    private var selected: SubagentSession? { chat.selectedSubagentID.flatMap { chat.transcript.subagent($0) } }
    var body: some View {
        VStack(spacing: 0) {
            if let id = chat.selectedAsyncTaskID, let task = chat.transcript.asyncTask(id) {
                AsyncTaskDetail(task: task, chat: chat, store: store).id(id)
            } else if let child = selected {
                HStack(alignment: .top, spacing: 10) {
                    Button { chat.selectedSubagentID = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("All tasks")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(child.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text(child.state.capitalized).font(.caption).foregroundStyle(child.state == "failed" ? Color.orange : Color.secondary)
                        if let parent = chat.transcript.subagent(child.parentID) {
                            Button("Parent: \(parent.name)") { store.openSubagent(chat, id: parent.id) }.font(.caption).buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 0)
                    if store.canStopSubagent(chat, id: child.id) || chat.stoppingSubagents.contains(child.id) {
                        Button(chat.stoppingSubagents.contains(child.id) ? "Stopping…" : "Stop") {
                            Task { await store.stopSubagent(chat, id: child.id) }
                        }.disabled(chat.stoppingSubagents.contains(child.id)).frame(minHeight: 40)
                            .help("Stop this subagent")
                    }
                }.padding(14)
                if let error = chat.subagentStopErrors[child.id] {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 12)
                }
                if !child.task.isEmpty { Text(child.task).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 12) }
                Divider()
                List {
                    ForEach(TranscriptGroup.rows(child.transcript.items, showThoughts: chat.displayMode != "normal")) { row in
                        Group {
                            if row.items[0].kind == "tool" { ToolCallsView(items: row.items, verbose: chat.displayMode == "verbose", chat: chat, store: store) }
                            else { TranscriptRow(item: row.items[0], streaming: child.isRunning && row.id == child.transcript.items.last?.id, chat: chat, store: store, allowRevisions: false) }
                        }.listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                    if child.transcript.items.isEmpty { Text(child.isRunning ? "Waiting for subagent output…" : "No transcript output was provided.").font(.caption).foregroundStyle(.secondary).listRowSeparator(.hidden) }
                }.listStyle(.plain).scrollContentBackground(.hidden).id(child.id)
            } else {
                List {
                    ForEach(chat.transcript.asyncTasks ?? []) { task in
                        AsyncTaskEntry(task: task) { store.openAsyncTask(chat, id: task.id) }
                            .padding(.vertical, 4).listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                    ForEach(chat.transcript.subagents ?? []) { child in
                        SubagentEntry(child: child) { store.openSubagent(chat, id: child.id) }
                            .padding(.vertical, 4).listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                    if (chat.transcript.subagents ?? []).isEmpty, (chat.transcript.asyncTasks ?? []).isEmpty { Text("Subagents and background tasks appear here when the agent starts them.").foregroundStyle(.secondary).font(.caption).listRowSeparator(.hidden) }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.sidebar)
            .modifier(WorkspaceLinkHandling(chat: chat, store: store))
    }
}
