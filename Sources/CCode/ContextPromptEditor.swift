import SwiftUI
import CCodeCore

struct PromptSelectionRequest {
    let id = UUID()
    let caret: Int
}

struct ContextPromptEditor: View {
    @Binding var text: String
    let workspace: Workspace?
    let commands: [JSONValue]
    let attach: (ContextCandidate, PromptQuery) async -> Bool
    let send: () -> Void
    let cancel: () -> Void
    var contextRequest: UUID?
    var attachmentInput: (([AttachmentInput]) -> Void)?
    var attachmentError: ((String) -> Void)?
    var placeholder = "Type / for commands"
    var focusOnMount = false
    @State private var query: PromptQuery?
    @State private var context: [ContextCandidate] = []
    @State private var selected = 0
    @State private var loading = false
    @State private var importing = false
    @State private var failure: String?
    @State private var dismissed: PromptQuery?
    @State private var selectionRequest: PromptSelectionRequest?
    @State private var selection: NSRange?
    private var commandMatches: [JSONValue] { query?.kind == .command ? PromptCompletion.commands(matching: query?.filter ?? "", catalog: commands) : [] }
    private var count: Int { query?.kind == .context ? context.count : commandMatches.count }
    private var height: CGFloat { min(150, max(48, CGFloat(text.components(separatedBy: "\n").count) * 20 + 26)) }
    var body: some View {
        PromptEditor(text: $text, placeholder: placeholder, send: send, cancel: cancel, focusOnMount: focusOnMount, isMainPrompt: true,
            selectionChanged: selectionChanged, completionKey: key, selectionRequest: selectionRequest,
            attachmentInput: attachmentInput, attachmentError: attachmentError)
            .frame(height: height)
            .overlay(alignment: .bottomLeading) {
                if query != nil {
                    completionPanel.offset(y: -height - 8)
                }
            }.zIndex(2)
            .task(id: query) {
                let request = query
                context = []; selected = 0; failure = nil
                guard let request, request.kind == .context else { loading = false; return }
                loading = true
                do {
                    try await Task.sleep(for: .milliseconds(120))
                    guard let workspace else { throw ACPError.workspace("Choose a project folder to attach context.") }
                    let matches = try await workspace.contextCandidates(matching: request.filter)
                    guard !Task.isCancelled, query == request else { return }
                    context = matches; loading = false
                } catch {
                    guard !Task.isCancelled, query == request else { return }
                    failure = error.localizedDescription; loading = false
                }
            }
            .onChange(of: text) { _, value in if value.isEmpty { query = nil; dismissed = nil } }
            .onChange(of: contextRequest) { _, _ in
                let caret = min(selection?.location ?? (text as NSString).length, (text as NSString).length)
                let range = NSRange(location: caret, length: 0)
                guard let insertion = Range(range, in: text) else { return }
                let prefix = text[..<insertion.lowerBound]
                let marker = prefix.last?.isWhitespace == false ? " @" : "@"
                text = text.replacingCharacters(in: insertion, with: marker)
                selectionRequest = PromptSelectionRequest(caret: caret + marker.utf16.count)
                dismissed = nil
                selectionChanged(text, NSRange(location: caret + marker.utf16.count, length: 0))
            }
    }
    private var completionPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(query?.kind == .context ? "Project context" : "Slash commands").font(.system(size: 12, weight: .medium))
                Spacer()
                if loading || importing { ProgressView().controlSize(.small) }
                else { Text("↑ ↓  ·  ↵  ·  Esc").font(.caption).foregroundStyle(.secondary) }
            }.padding(10)
            Divider()
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange).padding(12) }
            else if count == 0 { Text(loading ? "Searching…" : "No matches").font(.caption).foregroundStyle(.secondary).padding(12) }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(0..<count, id: \.self) { index in
                                Button { selected = index; choose() } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: query?.kind == .command ? "terminal" : context[index].kind == .folder ? "folder" : "doc")
                                            .foregroundStyle(.secondary).frame(width: 18)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(query?.kind == .command ? "/" + commandMatches[index]["name"].string : context[index].name).lineLimit(1)
                                            Text(query?.kind == .command ? commandMatches[index]["description"].string : context[index].label)
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer(minLength: 0)
                                        if selected == index { Image(systemName: "return").font(.caption).foregroundStyle(.secondary) }
                                    }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 7)
                                        .background(selected == index ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(importing).id(index)
                            }
                        }.padding(4)
                    }.frame(height: min(216, CGFloat(count) * 44 + 8))
                    .onChange(of: selected) { _, value in proxy.scrollTo(value, anchor: .center) }
                }
            }
        }.frame(maxWidth: 480, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1) }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
    private func selectionChanged(_ value: String, _ range: NSRange) {
        selection = range
        var next = PromptCompletion.query(in: value, selection: range)
        if next?.kind == .command, commands.isEmpty { next = nil }
        if next != dismissed { dismissed = nil }
        if next != dismissed, query != next { query = next; selected = 0 }
    }
    private func key(_ code: UInt16) -> Bool {
        guard query != nil else { return false }
        switch code {
        case 53: dismissed = query; query = nil; return true
        case 125: if count > 0 { selected = (selected + 1) % count }; return true
        case 126: if count > 0 { selected = (selected + count - 1) % count }; return true
        case 36, 48: if count > 0 { choose() }; return true
        default: return false
        }
    }
    private func choose() {
        guard let query, selected < count, !importing else { return }
        if query.kind == .command {
            let name = commandMatches[selected]["name"].string
            text = query.applyingCommand(name, to: text)
            selectionRequest = PromptSelectionRequest(caret: min((text as NSString).length, name.utf16.count + 2))
            dismissed = query; self.query = nil
        } else {
            let candidate = context[selected], original = text
            importing = true
            Task {
                let accepted = await attach(candidate, query)
                importing = false
                guard accepted else { return }
                if text == query.removing(from: original) { selectionRequest = PromptSelectionRequest(caret: query.range.location) }
                if self.query == query { dismissed = query; self.query = nil }
            }
        }
    }
}
