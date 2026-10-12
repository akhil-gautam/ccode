import SwiftUI
import CCodeCore

struct SessionSearchView: View {
    @Bindable var store: AppStore
    var width: CGFloat = 620
    var resultsHeight: CGFloat = 330
    @FocusState private var focused: Bool
    @State private var type = "All"
    @State private var compose = false
    @State private var highlighted: String?
    private enum Entry: Identifiable {
        case session(SessionInfo), project(String)
        var id: String {
            switch self { case .session(let info): "session:" + info.id.uuidString; case .project(let path): "project:" + path }
        }
    }
    private var entries: [Entry] {
        let projects = store.sidebarProjects.filter { (store.searchProject == nil || store.searchProject == $0) && (store.search.isEmpty || URL(fileURLWithPath: $0).lastPathComponent.localizedCaseInsensitiveContains(store.search)) }
        return (type == "Projects" ? [] : store.sessionSearchResults.map(Entry.session)) + (type == "Sessions" || (type == "All" && store.search.isEmpty) ? [] : projects.map(Entry.project))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search").font(.system(size: 18, weight: .medium))
                Spacer()
                Picker("Search or compose", selection: $compose) { Text("Search").tag(false); Text("Compose").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }.padding(18)
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(compose ? "What would you like to work on?" : "Search", text: $store.search).textFieldStyle(.plain).font(.system(size: 16)).focused($focused)
                    .onSubmit { submit() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { store.closeSessionSearch(); return .handled }
                Button { store.closeSessionSearch() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }.help("Close (Esc)").accessibilityLabel("Close search")
            }.padding(.horizontal, 18).padding(.bottom, 16)
            Divider()
            if !compose {
                HStack(spacing: 4) {
                    ForEach(["All", "Sessions", "Projects"], id: \.self) { value in
                        Button { type = value; highlighted = entries.first?.id } label: {
                            Text(value).padding(.horizontal, 12).padding(.vertical, 6).background(type == value ? Palette.muted : .clear, in: Capsule())
                        }.accessibilityAddTraits(type == value ? [.isSelected] : [])
                    }
                    Spacer()
                    if let path = store.searchProject {
                        Button { store.openSessionSearch() } label: { HStack(spacing: 4) { Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1); Image(systemName: "xmark").font(.system(size: 9)) } }
                            .help("Search all projects")
                    }
                }.font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 10)
                ScrollViewReader { proxy in
                    List {
                        if !entries.isEmpty {
                            Text(store.search.isEmpty ? "Recents" : "Results").font(.system(size: 11)).foregroundStyle(.secondary).listRowSeparator(.hidden)
                        }
                        ForEach(entries) { entry in
                            Button { activate(entry) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: symbol(entry)).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(title(entry)).lineLimit(1)
                                        if case .session(let info) = entry { Text(info.projectName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer(minLength: 0)
                                    if highlighted == entry.id { Image(systemName: "return").font(.system(size: 11)).foregroundStyle(.secondary) }
                                }.padding(.horizontal, 10).frame(height: 44).background(highlighted == entry.id ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                            }.listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8)).listRowSeparator(.hidden).listRowBackground(Color.clear)
                                .accessibilityAddTraits(highlighted == entry.id ? [.isSelected] : [])
                        }
                        if entries.isEmpty { Text("No matching sessions or projects").foregroundStyle(.secondary).listRowSeparator(.hidden) }
                        if store.search.isEmpty {
                            Text("Actions").font(.system(size: 11)).foregroundStyle(.secondary).listRowSeparator(.hidden)
                            Button("New session") { store.closeSessionSearch(); Task { await store.openHome() } }.listRowSeparator(.hidden)
                            Button("Open project…") { store.closeSessionSearch(); store.chooseNewSessionProject() }.listRowSeparator(.hidden)
                        }
                    }.listStyle(.plain).scrollContentBackground(.hidden).frame(height: resultsHeight)
                        .onChange(of: highlighted) { _, id in if let id { proxy.scrollTo(id) } }
                }
            } else {
                HStack { Text("Start a new session with this prompt").foregroundStyle(.secondary); Spacer(); Button("Compose") { submit() }.disabled(store.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.padding(18)
            }
            Divider()
            HStack(spacing: 16) {
                Text("↑ ↓ Navigate"); Text("↵ Open"); Spacer(); Text("Esc Close")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 12)
        }.buttonStyle(.plain).background(Palette.surface, in: RoundedRectangle(cornerRadius: 14)).overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border, lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.18), radius: 24, y: 10).frame(width: width).accessibilityElement(children: .contain).accessibilityLabel("Search sessions")
            .task { await Task.yield(); focused = true; highlighted = entries.first?.id }
            .onChange(of: store.search) { _, _ in highlighted = entries.first?.id }
            .onChange(of: store.sessionSearchResults.map(\.id)) { _, _ in if !entries.contains(where: { $0.id == highlighted }) { highlighted = entries.first?.id } }
    }
    private func move(_ offset: Int) {
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex { $0.id == highlighted } ?? 0
        highlighted = entries[max(0, min(entries.count - 1, current + offset))].id
    }
    private func submit() {
        if compose {
            Task { await store.composeFromSessionSearch() }
        } else if let entry = entries.first(where: { $0.id == highlighted }) { activate(entry) }
    }
    private func activate(_ entry: Entry) {
        store.closeSessionSearch()
        switch entry {
        case .session(let info): Task { await store.select(info.id) }
        case .project(let path): Task { await store.openHome(path: path) }
        }
    }
    private func title(_ entry: Entry) -> String { switch entry { case .session(let info): info.title; case .project(let path): URL(fileURLWithPath: path).lastPathComponent } }
    private func symbol(_ entry: Entry) -> String { switch entry { case .session: "chevron.left.forwardslash.chevron.right"; case .project: "folder" } }
}
