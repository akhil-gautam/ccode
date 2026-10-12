import SwiftUI
import AppKit
import CCodeCore

struct TranscriptView: View {
    @Bindable var chat: ChatSession
    let store: AppStore
    @State private var followTail = true
    var body: some View {
        ScrollViewReader { proxy in
            // Native row recycling avoids the selectable-text layout loop in LazyVStack.
            List {
                ForEach(TranscriptGroup.rows(chat.transcript.items, showThoughts: chat.displayMode != "normal")) { row in
                    Group {
                        // Disclosure state changes the row height even when its transcript data is unchanged.
                        if row.items[0].kind == "tool" { ToolCallsView(items: row.items, verbose: chat.displayMode == "verbose", chat: chat, store: store) }
                        else { TranscriptRow(item: row.items[0], streaming: chat.state == .running && row.id == chat.transcript.items.last?.id, chat: chat, store: store) }
                    }
                        .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 8, leading: 28, bottom: 8, trailing: 28))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
                if chat.state == .running {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("\(chat.agentName) is working…").font(.system(size: 13)).foregroundStyle(.secondary) }
                        .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 8, leading: 28, bottom: 16, trailing: 28))
                        .listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
                Color.clear.frame(height: 1).id("bottom").listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .modifier(TranscriptScrollFollowing(followTail: $followTail, scrollToBottom: { proxy.scrollTo("bottom", anchor: .bottom) }))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in if followTail { proxy.scrollTo("bottom", anchor: .bottom) } }
            .task { await Task.yield(); if !Task.isCancelled { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: chat.transcript.items.last) { _, _ in if followTail { proxy.scrollTo("bottom", anchor: .bottom) } }
            .overlay(alignment: .bottomTrailing) { if !followTail { Button { followTail = true; proxy.scrollTo("bottom", anchor: .bottom) } label: { Image(systemName: "arrow.down").padding(9).background(Palette.surface, in: Circle()).shadow(color: .black.opacity(0.1), radius: 4, y: 1) }.buttonStyle(.plain).help("Jump to latest").padding(16) } }
        }.modifier(WorkspaceLinkHandling(chat: chat, store: store))
    }
}

private struct TranscriptScrollFollowing: ViewModifier {
    @Binding var followTail: Bool
    let scrollToBottom: () -> Void
    @State private var userScrolling = false
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollPhaseChange { _, phase, context in
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        userScrolling = true
                        followTail = context.geometry.visibleRect.maxY >= context.geometry.contentSize.height - 48
                    } else if phase == .idle, userScrolling {
                        followTail = context.geometry.visibleRect.maxY >= context.geometry.contentSize.height - 48
                        userScrolling = false
                    }
                }
                .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
                    let bottom = new.visibleRect.maxY >= new.contentSize.height - 48
                    if userScrolling { followTail = bottom }
                    else if !bottom, old.containerSize == new.containerSize, old.contentSize == new.contentSize, new.visibleRect.minY < old.visibleRect.minY { followTail = false }
                    else if followTail, old.contentSize.height != new.contentSize.height { scrollToBottom() }
                }
                .background(ScrollWheelObserver { followTail = false })
        } else { content.background(ScrollWheelObserver { followTail = false }) }
    }
}

private struct ScrollWheelObserver: NSViewRepresentable {
    let scroll: () -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(scroll: scroll) }
    func updateNSView(_ view: ObserverView, context: Context) { view.scroll = scroll }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.removeMonitor() }
    final class ObserverView: NSView {
        var scroll: () -> Void
        private var monitor: Any?
        init(scroll: @escaping () -> Void) {
            self.scroll = scroll; super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window == self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.scroll() }
                return event
            }
        }
        required init?(coder: NSCoder) { nil }
        func removeMonitor() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    let streaming: Bool
    let chat: ChatSession
    let store: AppStore
    var allowRevisions = true
    @State private var expanded = false
    var body: some View {
        Group {
            switch item.kind {
            case "user":
                if let peer=item.peerMessage {
                    DisclosureGroup("Agent message · \(peer.senderTitle)") { Text(peer.body).textSelection(.enabled).padding(.top,8) }.font(.system(size:13)).foregroundStyle(.secondary)
                } else { UserMessageView(text: item.text, blocks: item.blocks) }
            case "thought": DisclosureGroup("Thinking", isExpanded: $expanded) { MarkdownText(text: item.text, streaming: streaming).foregroundStyle(.secondary).padding(.top, 8) }.font(.system(size: 13)).foregroundStyle(.secondary)
            case "notice": Label(item.text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            case "subagent":
                if let child = chat.transcript.subagent(item.tool["subagentSessionId"].string) {
                    SubagentEntry(child: child) { store.openSubagent(chat, id: child.id) }
                }
            case "async_task":
                let id = AsyncTaskIdentity(owner: item.tool["ownerSessionId"].string, task: item.tool["asyncTaskId"].string)
                if let task = chat.transcript.asyncTask(id) {
                    AsyncTaskEntry(task: task) { store.openAsyncTask(chat, id: task.id) }
                }
            case "interaction":
                DisclosureGroup(item.tool["action"].string == "accept" ? "Answered question" : item.tool["action"].string == "decline" ? "Skipped question" : "Cancelled question") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.text).fontWeight(.medium)
                        ForEach(Array(item.tool["answers"].array.enumerated()), id: \.offset) { _, answer in
                            if !answer["answer"].isNull {
                                Text(answer["title"].string + ": " + (answer["answer"].optionalString ?? answer["answer"].pretty))
                            }
                        }
                    }.font(.system(size: 13)).textSelection(.enabled).padding(.top, 8)
                }.font(.system(size: 13)).foregroundStyle(.secondary)
            default: VStack(alignment: .leading, spacing: 10) { MarkdownText(text: item.text, streaming: streaming); ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, block in ContentBlock(block: block, chat: chat, store: store) } }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).contextMenu {
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.kind == "tool" ? item.tool.pretty : item.text, forType: .string) }
            if allowRevisions, item.kind == "assistant" {
                Button("Retry response") { Task { do { try await store.retryResponse(chat, at: item.id) } catch { store.error = error.localizedDescription } } }
                    .disabled(!store.canRevise(chat, at: item.id))
                Button("Fork from here") { Task { do { try await store.fork(chat, at: item.id) } catch { store.error = error.localizedDescription } } }
                    .disabled(!store.canFork(chat, at: item.id))
            } else if allowRevisions, item.kind == "user" {
                Button("Edit message") { Task { do { try await store.editMessage(chat, at: item.id) } catch { store.error = error.localizedDescription } } }
                    .disabled(!store.canRevise(chat, at: item.id))
                if item.fileCheckpoint != nil {
                    Button("Preview file checkpoint") { store.checkpointPreviewRequest = FileCheckpointPreviewRequest(chat: chat, itemID: item.id) }
                        .disabled(!store.canPreviewFileCheckpoint(chat, at: item.id))
                }
            }
        }
    }
}

private struct UserMessageView: View {
    let text: String
    let blocks: [JSONValue]
    @State private var parts: [UserMessagePart] = []
    @State private var expanded: Set<Int> = []
    private var agentMessage: Bool { parts.first?.kind == .agent || parts.first?.kind == .notification }
    var body: some View {
        HStack {
            if !agentMessage { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 12) {
                if parts.isEmpty { Text(text.components(separatedBy: "\n").first ?? "").textSelection(.enabled) }
                ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                    if part.kind == .text { Text(part.text).textSelection(.enabled).lineSpacing(5) }
                    else {
                        Button { toggle(index) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: expanded.contains(index) ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                                Label(part.title, systemImage: part.kind == .paste ? "doc.text" : part.kind == .agent ? "person.2" : "checkmark.circle")
                            }.font(.system(size: 13)).foregroundStyle(.secondary).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if expanded.contains(index) {
                            if part.kind == .notification { Text(part.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                            else { MarkdownText(text: part.text, streaming: false).padding(.top, 8) }
                        }
                    }
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in ContentBlock(block: block) }
            }.padding(14).background(Palette.muted, in: RoundedRectangle(cornerRadius: 11))
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            ForEach(Array(parts.enumerated()).filter { $0.element.kind != .text }, id: \.offset) { index, part in
                Button("\(expanded.contains(index) ? "Collapse" : "Expand") \(part.title)") { toggle(index) }
            }
        }
        .task(id: text) {
            let value = text
            let parsed = await Task.detached(priority: .utility) { UserMessagePart.parse(value) }.value
            if !Task.isCancelled { parts = parsed }
        }
    }
    private func toggle(_ index: Int) { if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) } }
}

struct UserMessagePart: Sendable {
    enum Kind: Sendable, Equatable { case text, paste, agent, notification }
    let kind: Kind
    let text: String
    var title = ""
    static func parse(_ source: String) -> [Self] {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let announced = trimmed.hasPrefix("Another Claude session sent a message:\n")
        let peer = announced ? String(trimmed.dropFirst("Another Claude session sent a message:\n".count)) : trimmed
        for tag in ["agent-message", "teammate-message", "cross-session-message"] {
            if peer.hasPrefix("<\(tag) ") || peer.hasPrefix("<\(tag)>"), let opening = peer.firstIndex(of: ">"), !peer[..<opening].contains("\n"), let closing = peer.range(of: "</\(tag)>", options: .backwards), closing.lowerBound > opening, announced || closing.upperBound == peer.endIndex {
                let body = peer[peer.index(after: opening)..<closing.lowerBound].trimmingCharacters(in: .newlines)
                let framed = body.hasPrefix("[Subagent hand-back]")
                let formatted = body.components(separatedBy: "\n").map { framed && $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n")
                return [Self(kind: .agent, text: formatted + peer[closing.upperBound...], title: "Agent message")]
            }
        }
        if trimmed.hasPrefix("<task-notification>\n"), trimmed.hasSuffix("</task-notification>") {
            let summary = trimmed.range(of: "(?<=<summary>)[\\s\\S]*?(?=</summary>)", options: .regularExpression).map { String(trimmed[$0]) }
            return [Self(kind: .notification, text: source, title: summary ?? "Task notification")]
        }
        let lines = source.components(separatedBy: "\n")
        var parts: [Self] = [], plain: [String] = [], fence: (Character, Int)?, i = 0
        while i < lines.count {
            let line = lines[i]
            let markers = line.drop(while: { $0 == " " }).prefix(while: { $0 == "`" || $0 == "~" })
            if line.prefix(while: { $0 == " " }).count <= 3, let marker = markers.first, markers.count >= 3, markers.allSatisfy({ $0 == marker }) {
                if let active = fence { if marker == active.0, markers.count >= active.1, line.trimmingCharacters(in: .whitespaces) == String(markers) { fence = nil } }
                else { fence = (marker, markers.count) }
            }
            if fence == nil, line.range(of: "^<pasted_content id=\"[0-9a-f]{4}\">$", options: .regularExpression) != nil {
                let id = line.dropFirst(20).prefix(4)
                if let end = lines[(i + 1)...].firstIndex(of: "</pasted_content id=\"\(id)\">") {
                    if !plain.isEmpty { parts.append(Self(kind: .text, text: plain.joined(separator: "\n"))); plain.removeAll(keepingCapacity: true) }
                    parts.append(Self(kind: .paste, text: lines[(i + 1)..<end].joined(separator: "\n"), title: "Pasted text · \(end - i - 1) lines"))
                    i = end + 1; continue
                }
                // An unfinished wrapper stays literal, including everything after it.
                plain.append(contentsOf: lines[i...]); break
            }
            plain.append(line); i += 1
        }
        if !plain.isEmpty { parts.append(Self(kind: .text, text: plain.joined(separator: "\n"))) }
        return parts
    }
}

struct ContentBlock: View {
    let block: JSONValue
    var chat: ChatSession? = nil
    var store: AppStore? = nil
    var body: some View {
        switch block["type"].string {
        case "text": MarkdownText(text: block["text"].string, streaming: false)
        case "image":
            AttachmentImage(source: .base64(block["data"].string)).frame(maxHeight: 400).clipShape(RoundedRectangle(cornerRadius: 8))
        case "resource_link":
            if let url = URL(string: block["uri"].string), ["file", "https", "http"].contains(url.scheme ?? "") {
                if url.isFileURL, let chat, let store {
                    WorkspaceReferenceButton(reference: url.absoluteString, chat: chat, store: store) { Text(block["name"].optionalString ?? url.lastPathComponent).foregroundStyle(.link) }
                } else { Link(block["name"].optionalString ?? url.lastPathComponent, destination: url) }
            }
        case "resource": Text(block["resource"]["text"].string).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        default: Text("Content: \(block["type"].string)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MarkdownText: View {
    let text: String
    let streaming: Bool
    @State private var segments: [MarkdownSegment] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if streaming || segments.isEmpty { Text(text).textSelection(.enabled) }
            else { ForEach(segments) { segment in
                if case .code(let language) = segment.style {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(language.isEmpty ? "Code" : language).font(.caption).foregroundStyle(.secondary); Spacer(); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(segment.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy code") }
                        ScrollView(.horizontal) { Text(segment.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                    }.padding(14).background(Palette.muted, in: RoundedRectangle(cornerRadius: 8)).padding(.leading, CGFloat(segment.indentation) * 28)
                } else { block(segment).padding(.leading, CGFloat(segment.indentation) * 28) }
            } }
        }.font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading)
        .task(id: streaming ? "stream" : text) {
            guard !streaming else { return }
            let value = text
            let parsed = await Task.detached(priority: .utility) { MarkdownSegment.parse(value) }.value
            guard !Task.isCancelled else { return }; segments = parsed
        }
    }
    @ViewBuilder private func block(_ segment: MarkdownSegment) -> some View {
        switch segment.style {
        case .heading(let level): Text(segment.attributed).font(.system(size: level == 1 ? 24 : level == 2 ? 20 : 16, weight: .semibold)).textSelection(.enabled).padding(.top, 6)
        case .list(let marker, let depth): HStack(alignment: .top, spacing: 10) { Text(marker).frame(minWidth: 18, alignment: .trailing); Text(segment.attributed).textSelection(.enabled).lineSpacing(4) }.padding(.leading, CGFloat(depth) * 20)
        case .quote: HStack(spacing: 12) { Rectangle().fill(Palette.border).frame(width: 3); Text(segment.attributed).textSelection(.enabled).foregroundStyle(.secondary).lineSpacing(5) }.fixedSize(horizontal: false, vertical: true)
        case .table:
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(segment.rows.enumerated()), id: \.offset) { row, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                                Text(cell).fontWeight(row == 0 ? .semibold : .regular).textSelection(.enabled).padding(10)
                                    .gridColumnAlignment(segment.alignment(column))
                                    .frame(maxWidth: .infinity, alignment: Alignment(horizontal: segment.alignment(column), vertical: .center))
                                    .background(row == 0 ? Palette.muted : Palette.surface)
                                    .overlay(Rectangle().stroke(Palette.border, lineWidth: 0.5))
                            }
                        }
                    }
                }
            }
        default: Text(segment.attributed).textSelection(.enabled).lineSpacing(5)
        }
    }
}

struct MarkdownSegment: Identifiable, Sendable {
    enum Style: Sendable, Equatable { case paragraph, heading(Int), code(String), list(String, Int), quote, table }
    let id: Int
    var attributed: AttributedString
    var style: Style
    var indentation = 0
    var rows: [[AttributedString]] = []
    var columnAlignments: [String] = []
    var text: String { String(attributed.characters) }
    func alignment(_ column: Int) -> HorizontalAlignment {
        guard column < columnAlignments.count else { return .leading }
        return columnAlignments[column] == "right" ? .trailing : columnAlignments[column] == "center" ? .center : .leading
    }
    static func parse(_ text: String) -> [MarkdownSegment] {
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full)) else {
            return [Self(id: 0, attributed: AttributedString(text), style: .paragraph)]
        }
        var result: [Self] = [], seenItems: Set<Int> = []
        for run in parsed.runs {
            let intents = run.presentationIntent?.components ?? []
            let table = intents.first { if case .table = $0.kind { return true }; return false }
            let id = table?.identity ?? intents.first?.identity ?? 0
            var piece = AttributedString(parsed[run.range]); piece.presentationIntent = nil
            if run.inlinePresentationIntent?.contains(.code) == true {
                piece.foregroundColor = Palette.inlineCode
                piece.backgroundColor = Palette.muted
            }
            if let table {
                if result.last?.id != id {
                    var block = Self(id: id, attributed: AttributedString(), style: .table)
                    if case .table(let columns) = table.kind { block.columnAlignments = columns.map { $0.alignment == .right ? "right" : $0.alignment == .center ? "center" : "left" } }
                    result.append(block)
                }
                var row = 0, column = 0
                for intent in intents {
                    if case .tableRow(let index) = intent.kind { row = index }
                    if case .tableCell(let index) = intent.kind { column = index }
                }
                let index = result.count - 1
                while result[index].rows.count <= row { result[index].rows.append([]) }
                while result[index].rows[row].count <= column { result[index].rows[row].append(AttributedString()) }
                result[index].rows[row][column].append(piece)
            } else if result.last?.id == id { result[result.count - 1].attributed.append(piece) }
            else {
                var style: Style = .paragraph, depth = 0, marker: String?, itemID: Int?, ordinal = 1
                for intent in intents {
                    switch intent.kind {
                    case .header(let level): style = .heading(level)
                    case .codeBlock(let language): style = .code(language ?? "")
                    case .blockQuote: if style == .paragraph { style = .quote }
                    case .listItem(let number): if itemID == nil { itemID = intent.identity; ordinal = number }
                    case .orderedList: if marker == nil { marker = "\(ordinal)." }; depth += 1
                    case .unorderedList: if marker == nil { marker = "•" }; depth += 1
                    default: break
                    }
                }
                if let marker, let itemID, style == .paragraph { style = .list(seenItems.insert(itemID).inserted ? marker : "", max(0, depth - 1)) }
                let indentation: Int
                if case .list = style { indentation = 0 } else { indentation = depth }
                result.append(Self(id: id, attributed: piece, style: style, indentation: indentation))
            }
        }
        return result
    }
}
