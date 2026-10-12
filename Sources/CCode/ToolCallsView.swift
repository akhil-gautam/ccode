import SwiftUI
import AppKit
import CCodeCore

struct TranscriptGroup: Identifiable, Equatable {
    var items: [TranscriptItem]
    var id: UUID { items[0].id }
    // ponytail: cap eager card children at 12; separately recycled child rows if larger groups are needed.
    static let maximumCommands = 12
    static func rows(_ items: [TranscriptItem], showThoughts: Bool) -> [Self] {
        var rows: [Self] = []
        for item in items where showThoughts || item.kind != "thought" {
            if item.kind == "tool", item.tool["kind"].string == "execute",
               rows.last?.items.count ?? 0 < maximumCommands,
               rows.last?.items.first?.kind == "tool", rows.last?.items.first?.tool["kind"].string == "execute" {
                rows[rows.count - 1].items.append(item)
            } else { rows.append(Self(items: [item])) }
        }
        return rows
    }
}

enum ToolPresentation {
    static func activity(_ items: [TranscriptItem]) -> String {
        let failures = items.filter { $0.tool["status"].string == "failed" }.count
        let running = items.contains(where: \.isToolRunning)
        let interruptions = items.compactMap { item in
            ["completed", "failed"].contains(item.tool["status"].string) ? nil : item.toolInterruption
        }
        var states: [String] = []
        if failures > 0 { states.append(items.count == 1 ? "Failed" : "\(failures) failed") }
        for reason in [ToolInterruption.stopped, .disconnected, .interrupted] {
            let count = interruptions.filter { $0 == reason }.count
            if count > 0 { states.append(items.count == 1 ? reason.label : "\(count) \(reason.rawValue)") }
        }
        if running { states.append("Running") }
        return states.isEmpty ? "Completed" : states.joined(separator: ", ")
    }
    static func title(_ tool: JSONValue) -> String {
        let input = tool["rawInput"]
        if let description = input["description"].optionalString, !description.isEmpty {
            if tool["status"].string == "completed", let word = description.split(separator: " ").first,
               let past = ["Run": "Ran", "Fetch": "Fetched", "Check": "Checked", "Push": "Pushed", "Commit": "Committed", "Stage": "Staged", "Create": "Created", "Search": "Searched", "List": "Listed", "Map": "Mapped"][String(word)] {
                return past + description.dropFirst(word.count)
            }
            return description
        }
        let title = tool["title"].optionalString ?? "Tool activity"
        if ["Bash", "Read", "Write", "Edit", "Grep", "Glob"].contains(title) {
            if let path = input["file_path"].optionalString { return "\(title) \(path)" }
            if let pattern = input["pattern"].optionalString { return "\(title): \(pattern)" }
            if let command = input["command"].optionalString { return String(command.prefix(100)).components(separatedBy: "\n")[0] }
        }
        return title
    }
    static func text(_ value: JSONValue) -> String {
        if value.isNull { return "" }
        if let string = value.optionalString { return string }
        if case .array(let blocks) = value {
            return blocks.map { $0["type"].string == "text" ? $0["text"].string : text($0) }.joined(separator: "\n")
        }
        return value.pretty
    }
    // ponytail: render at most 16K characters per page; use a virtual text view if continuous huge logs are needed.
    static let pageSize = 16_000
    static func page(_ text: String, at page: Int) -> String {
        let start = text.index(text.startIndex, offsetBy: max(0, page) * pageSize, limitedBy: text.endIndex) ?? text.endIndex
        let end = text.index(start, offsetBy: pageSize, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }
}

struct ToolCallsView: View {
    let items: [TranscriptItem]
    let verbose: Bool
    var chat: ChatSession? = nil
    var store: AppStore? = nil
    @State private var expanded = false
    @State private var opened: Set<UUID> = []
    private var title: String { items.count == 1 ? ToolPresentation.title(items[0].tool) : "\(running ? "Running " : interrupted ? "" : "Ran ")\(items.count) commands" }
    private var failed: Int { items.filter { $0.tool["status"].string == "failed" }.count }
    private var running: Bool { items.contains(where: \.isToolRunning) }
    private var interrupted: Bool { items.contains { $0.toolInterruption != nil && !["completed", "failed"].contains($0.tool["status"].string) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if items.count > 1 || !expanded {
                header(title, open: expanded, failed: failed, running: running, activity: ToolPresentation.activity(items)) { toggle() }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 0) {
                            header(ToolPresentation.title(item.tool), open: opened.contains(item.id), failed: item.tool["status"].string == "failed" ? 1 : 0, running: item.isToolRunning, activity: ToolPresentation.activity([item])) {
                                if items.count == 1 { toggle() }
                                else if opened.contains(item.id) { opened.remove(item.id) } else { opened.insert(item.id) }
                            }.padding(12)
                            if opened.contains(item.id) { ToolCallDetails(tool: item.tool, chat: chat, store: store).padding([.horizontal, .bottom], 12) }
                        }
                        if item.id != items.last?.id { Divider() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border, lineWidth: 1))
            }
        }
        .contextMenu {
            Button(expanded ? "Collapse tool calls" : "Expand tool calls") { toggle() }
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(items.map { $0.tool.pretty }.joined(separator: "\n"), forType: .string) }
        }
        .accessibilityElement(children: expanded ? .contain : .combine)
        .accessibilityLabel("Tool calls")
        .accessibilityValue(Text("\(title), \(ToolPresentation.activity(items))"))
        .accessibilityActions { Button("\(expanded ? "Collapse" : "Expand") \(title)") { toggle() } }
        .onAppear { if verbose { expandAll() } }
        .onChange(of: verbose) { _, value in if value { expandAll() } else { expanded = false; opened.removeAll() } }
        .onChange(of: items.map(\.id)) { _, _ in if verbose { expandAll() } }
    }
    private func toggle() {
        expanded.toggle()
        if expanded, opened.isEmpty { opened.insert(items[0].id) }
        if !expanded { opened.removeAll() }
    }
    private func expandAll() { expanded = true; opened = Set(items.map(\.id)) }
    private func header(_ title: String, open: Bool, failed: Int, running: Bool, activity: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).lineLimit(2).multilineTextAlignment(.leading)
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .medium))
                if failed > 0 { Label(failed > 1 ? "\(failed) failed" : "Failed", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                if !running, failed == 0, activity != "Completed" { Text(activity).font(.caption).foregroundStyle(.secondary) }
                if running { ProgressView().controlSize(.mini).accessibilityLabel("Running") }
                Spacer(minLength: 0)
            }.font(.system(size: 14)).foregroundStyle(.secondary).padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(Text("\(open ? "Collapse" : "Expand") \(title), \(activity)"))
            .help("\(open ? "Collapse" : "Expand") \(title)")
    }
}

private struct ToolCallDetails: View {
    let tool: JSONValue
    let chat: ChatSession?
    let store: AppStore?
    @State private var details: ToolDetailPresentation?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let details { ToolDetailsContent(details: details, chat: chat, store: store) }
            else { ProgressView().controlSize(.small) }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task(id: tool) {
            let value = tool
            let result = await Task.detached(priority: .utility) { ToolDetailPresentation(tool: value) }.value
            if !Task.isCancelled { details = result }
        }
    }
}

struct ToolLog: View {
    let text: String
    let command: Bool
    @State private var page = 0
    private var pages: Int { max(1, (text.count + ToolPresentation.pageSize - 1) / ToolPresentation.pageSize) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                Text(command ? highlighted(ToolPresentation.page(text, at: page)) : AttributedString(ToolPresentation.page(text, at: page)))
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
            }.padding(command ? 8 : 0).background(command ? Palette.muted.opacity(0.45) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            if pages > 1 {
                HStack {
                    Button("Previous") { page -= 1 }.disabled(page == 0)
                    Text("Page \(page + 1) of \(pages)").foregroundStyle(.secondary)
                    Button("Next") { page += 1 }.disabled(page + 1 >= pages)
                    Spacer()
                    Button("Copy full \(command ? "command" : "output")") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                }.font(.caption)
            }
        }.onChange(of: text) { _, _ in page = 0 }
    }
    private func highlighted(_ command: String) -> AttributedString {
        let source = "$ " + command
        var result = AttributedString(source)
        result.foregroundColor = .secondary
        // ponytail: lexical shell coloring, not a shell parser; replace if semantic highlighting is required.
        let pattern = #""[^"\n]*"|'[^'\n]*'|[^\s|;&<>]+|[|;&<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        var executable = true
        for match in regex.matches(in: command, range: NSRange(command.startIndex..., in: command)) {
            guard let range = Range(match.range, in: command) else { continue }
            let token = String(command[range])
            let shifted = NSRange(location: match.range.location + 2, length: match.range.length)
            guard let sourceRange = Range(shifted, in: source), let attributedRange = Range(sourceRange, in: result) else { continue }
            let separator = token.allSatisfy { "|;&<>".contains($0) }
            result[attributedRange].foregroundColor = separator ? .secondary : token.hasPrefix("-") ? Palette.adaptive(0x9B6D20, 0xD5A754) : executable ? Palette.adaptive(0x4674E8, 0x8AA9FF) : Palette.adaptive(0x4C9D4D, 0x8CCB8E)
            executable = separator
        }
        return result
    }
}
