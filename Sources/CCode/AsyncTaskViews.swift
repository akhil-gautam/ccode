import SwiftUI
import CCodeCore

struct AsyncTaskEntry: View {
    let task: AgentAsyncTask
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: task.state == .failed ? "exclamationmark.triangle" : "terminal")
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    if let summary = task.summary, !summary.isEmpty { Text(summary).font(.caption).lineLimit(2) }
                }
                Spacer(minLength: 4)
                Text(task.state.displayTitle).font(.caption)
                Image(systemName: "chevron.right").font(.system(size: 10))
            }.foregroundStyle(task.state == .failed ? Color.orange : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Open \(task.name) output")
    }
}

struct AsyncTaskDetail: View {
    let task: AgentAsyncTask
    let chat: ChatSession
    let store: AppStore
    @State private var output: AsyncTaskOutput?
    @State private var outputError: String?
    @State private var endingAt: UInt64?
    @State private var refresh = 0
    private struct OutputWindow: Hashable {
        let task: AsyncTaskIdentity
        let endingAt: UInt64?
        let path: String?
        let generation: UUID
        let refresh: Int
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Button { chat.selectedAsyncTaskID = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).help("All tasks")
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name).font(.system(size: 13, weight: .medium)).lineLimit(3)
                    Text(task.state.displayTitle).font(.caption).foregroundStyle(task.state == .failed ? Color.orange : Color.secondary)
                    if let owner = chat.transcript.subagent(task.id.owner) {
                        Button("Subagent: \(owner.name)") { store.openSubagent(chat, id: owner.id) }.buttonStyle(.plain).font(.caption)
                    }
                }
                Spacer(minLength: 0)
                Button { endingAt = nil; refresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh task output").accessibilityLabel("Refresh task output")
                if store.canStopAsyncTask(chat, id: task.id) || chat.stoppingAsyncTasks.contains(task.id) {
                    Button(chat.stoppingAsyncTasks.contains(task.id) ? "Stopping…" : "Stop") {
                        Task { await store.stopAsyncTask(chat, id: task.id) }
                    }.disabled(chat.stoppingAsyncTasks.contains(task.id)).frame(minHeight: 40)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !task.description.isEmpty { Text(task.description).font(.caption).foregroundStyle(.secondary) }
                    if let summary = task.summary { Text(summary).font(.system(size: 13)).textSelection(.enabled) }
                    if let name = task.lastToolName { Text("Last tool: \(name)").font(.caption).foregroundStyle(.secondary) }
                    if let error = chat.asyncTaskErrors[task.id] { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    if let output {
                        if output.truncated {
                            Text("Bytes \(output.offset)–\(output.offset + UInt64(output.byteCount)) of \(output.fileSize)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            HStack {
                                Button("Older") { endingAt = output.offset }.disabled(output.offset == 0)
                                Button("Newer") {
                                    let next = output.offset + UInt64(output.byteCount) + 64 * 1024
                                    endingAt = next >= output.fileSize ? nil : next
                                }.disabled(output.offset + UInt64(output.byteCount) >= output.fileSize)
                                if endingAt != nil { Button("Latest") { endingAt = nil } }
                            }.controlSize(.small)
                        }
                        ToolLog(text: output.text, command: false)
                    } else if outputError == nil { Text(task.isRunning ? "Waiting for task output…" : "No output file was provided.").font(.caption).foregroundStyle(.secondary) }
                    if let outputError { Text(outputError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(14).onChange(of: task.outputFilePath) { endingAt = nil }
        .task(id: OutputWindow(task: task.id, endingAt: endingAt, path: task.outputFilePath, generation: chat.connectionGeneration, refresh: refresh)) {
            output = nil; outputError = nil
            repeat {
                do {
                    let next = try await store.readAsyncOutput(chat, id: task.id, endingAt: endingAt)
                    guard !Task.isCancelled else { return }
                    output = next; outputError = nil
                } catch is CancellationError { return }
                catch { if !Task.isCancelled { output = nil; outputError = error.localizedDescription } }
                guard !Task.isCancelled, endingAt == nil, chat.asyncTaskOwners.contains(task.id), chat.transcript.asyncTask(task.id)?.isRunning == true else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            } while !Task.isCancelled
        }
    }
}
