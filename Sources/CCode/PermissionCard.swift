import SwiftUI
import AppKit
import CCodeCore

struct PermissionPresentation {
    struct Diff: Equatable {
        let path: String
        let before: String?
        let after: String
    }
    let tool: JSONValue
    var toolName: String { tool["name"].optionalString ?? tool["_meta"]["claudeCode"]["toolName"].string }
    var canRevise: Bool { toolName == "ExitPlanMode" }
    var plan: String? {
        if let plan = tool["rawInput"]["plan"].optionalString { return plan }
        guard canRevise else { return nil }
        let text = tool["content"].array.filter { $0["type"].string == "content" && $0["content"]["type"].string == "text" }.map { $0["content"]["text"].string }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }
    var command: String? { tool["rawInput"]["command"].optionalString }
    var diffs: [Diff] {
        let values = tool["content"].array.filter { $0["type"].string == "diff" }.map { Diff(path: $0["path"].string, before: $0["oldText"].optionalString, after: $0["newText"].string) }
        if !values.isEmpty { return values }
        let input = tool["rawInput"]
        guard let path = input["file_path"].optionalString else { return [] }
        if let after = input["new_string"].optionalString { return [Diff(path: path, before: input["old_string"].optionalString, after: after)] }
        if let after = input["content"].optionalString { return [Diff(path: path, before: nil, after: after)] }
        return []
    }
    static func revisionOption(_ request: JSONValue) -> String? {
        let options = request["options"].array.filter { $0["kind"].string == "reject_once" && !$0["optionId"].string.isEmpty }
        return options.count == 1 ? options[0]["optionId"].string : nil
    }
    struct PlanSnapshot { let path: String; var text: String }
    static func planSnapshot(items: [TranscriptItem]) -> PlanSnapshot? {
        // Claude's CLI can omit plan text from ExitPlanMode. Reconstruct only
        // completed root writes/edits of its standard plan file in this cycle.
        // No filesystem scan, title guessing or subagent proposal is used.
        let start = items.lastIndex { $0.kind == "tool" && PermissionPresentation(tool: $0.tool).toolName == "EnterPlanMode" && $0.tool["status"] == "completed" && $0.tool["_meta"]["claudeCode"]["parentToolUseId"].isNull }
            ?? items.lastIndex { $0.kind == "user" } ?? -1
        var snapshot: PlanSnapshot?
        for item in items.dropFirst(start + 1) where item.kind == "tool" && item.tool["status"] == "completed" {
            let tool = item.tool, input = tool["rawInput"]
            guard tool["_meta"]["claudeCode"]["parentToolUseId"].isNull,
                  let path = input["file_path"].optionalString, path.contains("/.claude/plans/"), path.hasSuffix(".md") else { continue }
            let name = PermissionPresentation(tool: tool).toolName
            if name == "Write", let text = input["content"].optionalString {
                if let snapshot, snapshot.path != path { return nil }
                snapshot = PlanSnapshot(path: path, text: text)
            } else if name == "Edit" {
                guard var current = snapshot, current.path == path,
                      let old = input["old_string"].optionalString, !old.isEmpty,
                      let new = input["new_string"].optionalString, let range = current.text.range(of: old) else { return nil }
                if input["replace_all"].bool { current.text = current.text.replacingOccurrences(of: old, with: new) }
                else {
                    guard current.text[range.upperBound...].range(of: old) == nil else { return nil }
                    current.text.replaceSubrange(range, with: new)
                }
                snapshot = current
            }
        }
        return snapshot
    }
}

extension AppStore {
    // ExitPlanMode rejection interrupts the provider turn; feedback is a separate
    // durable next turn, never an invented permission response field.
    func revisePlan(_ chat: ChatSession, id: UUID, feedback: String) async {
        guard let index = chat.approvals.firstIndex(where: { $0.id == id }), !chat.revisingPlan,
              chat.approvals[index].request["sessionId"].string == chat.transcript.remoteID,
              supportsMessageFork(chat), PermissionPresentation(tool: chat.approvals[index].toolCall).canRevise,
              let reject = PermissionPresentation.revisionOption(chat.approvals[index].request),
              chat.state == .running, canDeliver(chat) else { return }
        let generation = chat.connectionGeneration
        var queuedID: UUID?
        chat.revisingPlan = true; chat.approvals[index].submittingRevision = true; chat.approvals[index].error = nil
        defer {
            chat.revisingPlan = false
            if let current = chat.approvals.firstIndex(where: { $0.id == id }) { chat.approvals[current].submittingRevision = false }
            driveDelivery(chat)
        }
        do {
            let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ACPError.workspace("Describe what you want changed in the plan.") }
            guard chat.pendingPrompts.count < 16 else { throw ACPError.workspace("The message queue is full. Remove or finish a pending message first.") }
            let (executable, arguments) = try promptOwner(chat)
            let prompt = try PendingPrompt(text: text, attachments: [], policy: .nextTurn, executable: executable, arguments: arguments, remoteID: chat.transcript.remoteID)
            queuedID = prompt.id
            // Revision precedes unrelated queued work, keeping that work intact.
            chat.pendingPrompts.insert(prompt, at: 0)
            try await persistDelivery(chat)
            try Task.checkCancellation()
            guard chat.connectionGeneration == generation, chat.state == .running,
                  let current = chat.approvals.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
            chat.approvals[current].submittingRevision = false
            resolveApproval(chat, id: id, option: reject)
        } catch {
            if let queuedID {
                if error is CancellationError, chat.pendingPrompts.contains(where: { $0.id == queuedID }) {
                    // The decision disappeared while saving (Stop, Cancel or
                    // disconnect). Keep the accepted text, requiring explicit resume.
                    chat.deliveryPaused = true
                } else { chat.pendingPrompts.removeAll { $0.id == queuedID } }
                try? await persistDelivery(chat)
            }
            if let current = chat.approvals.firstIndex(where: { $0.id == id }), !(error is CancellationError) {
                chat.approvals[current].error = error.localizedDescription
            }
        }
    }
}

struct PermissionCard: View {
    let chat: ChatSession
    let store: AppStore
    let approval: Approval
    @State private var editingFeedback = false
    @State private var feedback = ""
    private var preview: PermissionPresentation { .init(tool: approval.toolCall) }
    private var canRevise: Bool { approval.request["sessionId"].string == chat.transcript.remoteID && store.supportsMessageFork(chat) && preview.canRevise && PermissionPresentation.revisionOption(approval.request) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if approval.request["sessionId"].string != chat.transcript.remoteID {
                Label(chat.workOwnerName(approval.request["sessionId"].optionalString), systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
            }
            Label(preview.canRevise ? "Review plan" : "Permission required", systemImage: preview.canRevise ? "list.bullet.clipboard" : "hand.raised")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
            if let error = approval.error { Text(error).font(.caption).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(approval.request["toolCall"]["title"].string).fontWeight(.medium)
                    if let plan = preview.plan { PermissionPlanPreview(text: plan) }
                    else if preview.canRevise { Text("Review Claude’s proposal in the conversation. This request did not include plan text.").font(.caption).foregroundStyle(.secondary) }
                    if let path = approval.toolCall["_meta"]["ccode"]["planSourcePath"].optionalString { Text("Plan file: \(path)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let command = preview.command { ToolLog(text: command, command: true) }
                    ForEach(Array(preview.diffs.enumerated()), id: \.offset) { _, diff in
                        Text(diff.path).font(.caption.monospaced()).textSelection(.enabled)
                        if let before = diff.before { Text("Before").font(.caption).foregroundStyle(.secondary); ToolLog(text: before, command: false) }
                        Text("After").font(.caption).foregroundStyle(.secondary); ToolLog(text: diff.after, command: false)
                    }
                    if !approval.request["toolCall"]["rawInput"].isNull {
                        DisclosureGroup("All action details") { ToolLog(text: approval.request["toolCall"]["rawInput"].pretty, command: false) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(maxHeight: 180)
            // Decisions stay reachable while a long plan, command or diff is
            // being inspected. Scroll many choices separately from the preview.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(approval.request["options"].array, id: \.["optionId"]) { option in
                        Button { store.resolveApproval(chat, id: approval.id, option: option["optionId"].string) } label: {
                            Text(option["name"].string).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                        }.buttonStyle(.bordered).focusable().disabled(approval.submittingRevision)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
            }.frame(maxHeight: 120)
            if editingFeedback {
                PromptEditor(text: $feedback, placeholder: "What should change in this plan?", send: submitFeedback, cancel: { editingFeedback = false }, focusOnMount: true)
                    .frame(height: 64).disabled(approval.submittingRevision)
                Button(chat.deliveryPaused ? "Queue revision · delivery paused" : "Send revision") { submitFeedback() }
                    .buttonStyle(.borderedProminent).disabled(approval.submittingRevision || feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                if canRevise { Button(editingFeedback ? "Hide feedback" : "Revise plan") { editingFeedback.toggle() }.disabled(approval.submittingRevision) }
                if approval.submittingRevision { ProgressView().controlSize(.small); Text("Saving feedback…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { store.resolveApproval(chat, id: approval.id, option: nil) }.buttonStyle(.plain).foregroundStyle(.secondary).focusable()
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.muted, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.accent.opacity(0.3)) }
            .id(approval.id)
    }
    private func submitFeedback() { Task { await store.revisePlan(chat, id: approval.id, feedback: feedback) } }
}

private struct PermissionPlanPreview: View {
    let text: String
    @State private var page = 0
    private var pages: Int { max(1, (text.count + ToolPresentation.pageSize - 1) / ToolPresentation.pageSize) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MarkdownText(text: ToolPresentation.page(text, at: page), streaming: false)
            if pages > 1 {
                HStack {
                    Button("Previous") { page -= 1 }.disabled(page == 0)
                    Text("Page \(page + 1) of \(pages)").font(.caption)
                    Button("Next") { page += 1 }.disabled(page + 1 >= pages)
                    Button("Copy full plan") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                }
            }
        }.onChange(of: text) { _, _ in page = 0 }
    }
}
