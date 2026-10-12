import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CCodeCore

enum Palette {
    static let sidebar = adaptive(0xFBFBF9, 0x20201F)
    static let surface = adaptive(0xFFFFFF, 0x262624)
    static let muted = adaptive(0xF0F0ED, 0x333330)
    static let selected = adaptive(0xEDECE9, 0x3C3C38)
    static let accent = Color(red: 0.77, green: 0.37, blue: 0.25)
    static let inlineCode = adaptive(0x9C2E2E, 0xD79A82)
    static let border = Color.primary.opacity(0.09)
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

struct ContentView: View {
    @Bindable var store: AppStore
    @AppStorage("codeWorkspace") private var codeWorkspace = true
    @State private var fullscreen = false
    var body: some View {
        HSplitView {
            if store.showSidebar { Sidebar(store: store, codeWorkspace: $codeWorkspace, titlebarInset: fullscreen ? 0 : 74).frame(minWidth: 266, idealWidth: 266, maxWidth: 380) }
            GeometryReader { geometry in
                if store.paneLayout.panes.count == 1 {
                    chatPane(store.paneLayout.panes[0])
                } else if store.paneLayout.arrangement == .horizontal, geometry.size.width >= 800 {
                    HSplitView { ForEach(store.paneLayout.panes) { chatPane($0).frame(minWidth: 360) } }
                } else {
                    VSplitView { ForEach(store.paneLayout.panes) { chatPane($0).frame(minHeight: 280) } }
                }
            }.background(Palette.surface)
        }
        .font(.system(size: 14))
        .ignoresSafeArea(.container, edges: .top)
        .tint(Color.primary)
        .onAppear { fullscreen = NSApp.windows.first { $0.identifier?.rawValue == "main" }?.styleMask.contains(.fullScreen) == true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notice in
            if (notice.object as? NSWindow)?.identifier?.rawValue == "main" { fullscreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notice in
            if (notice.object as? NSWindow)?.identifier?.rawValue == "main" { fullscreen = false }
        }
        .onChange(of: store.pane) { _, pane in if pane != nil { codeWorkspace = true } }
        .modifier(WorkflowPresentation(store: store, detachedPaneID: nil))
        .sheet(isPresented: $store.showSSHWorkspaces) { SSHWorkspacesView(store: store) }
        .sheet(isPresented: $store.showSchedules) { SchedulesView(store: store) }
    }
    private func chatPane(_ pane: ChatPane) -> some View {
        ChatPaneView(store: store, pane: pane, codeWorkspace: $codeWorkspace, titlebarInset: !store.showSidebar && !fullscreen && store.paneLayout.panes.first?.id == pane.id ? 74 : 0)
            .background(ChatPaneFocusBoundary(requestID: store.chatPaneFocusRequest?.paneID == pane.id ? store.chatPaneFocusRequest?.id : nil) { store.focusChatPane(pane.id) })
            .overlay(alignment: .top) {
                if store.paneLayout.panes.count > 1, store.paneLayout.focusedPaneID == pane.id {
                    Rectangle().fill(Palette.accent.opacity(0.7)).frame(height: 2).allowsHitTesting(false)
                }
            }.id(pane.id)
    }
}

struct ChatPaneView: View {
    @Bindable var store: AppStore
    let pane: ChatPane
    @Binding var codeWorkspace: Bool
    var titlebarInset: CGFloat = 0
    var body: some View {
        VStack(spacing: 0) {
            if let id = pane.sessionID, let info = store.sessions.first(where: { $0.id == id }) {
                if let chat = store.chat(id) {
                    GeometryReader { geometry in header(chat, info: info, compact: geometry.size.width < 600) }.frame(height: 48)
                    Divider()
                    GeometryReader { geometry in
                        if codeWorkspace, let auxiliary = store.pane(for: chat) {
                            if geometry.size.width >= 750 {
                                HSplitView {
                                    conversation(chat, info: info).frame(minWidth: 360)
                                    WorkspacePane(chat: chat, store: store, kind: auxiliary).id("\(chat.id)-\(auxiliary)").frame(minWidth: 300)
                                }
                            } else {
                                VSplitView {
                                    conversation(chat, info: info).frame(minHeight: 220)
                                    WorkspacePane(chat: chat, store: store, kind: auxiliary).id("\(chat.id)-\(auxiliary)").frame(minHeight: 160)
                                }
                            }
                        } else { conversation(chat, info: info) }
                    }
                } else { sessionSkeleton }
            } else { NewSessionHome(store: store) }
        }.background(Palette.surface)
            .onChange(of: pane.sessionID.flatMap { store.chat($0) }.flatMap { store.pane(for: $0) }) { _, auxiliary in if auxiliary != nil { codeWorkspace = true } }
    }
    private func conversation(_ chat: ChatSession, info: SessionInfo) -> some View {
        VStack(spacing: 0) {
            if chat.transcript.items.isEmpty, store.loadingSessions[pane.id] == chat.id || chat.state == .connecting { sessionSkeleton }
            else if chat.transcript.items.isEmpty { emptyChat(chat, info: info) }
            else { TranscriptView(chat: chat, store: store).id(chat.id) }
            if chat.showSideQuestion { SideQuestionView(chat:chat,store:store) }
            Composer(chat: chat, store: store, info: info)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var sessionSkeleton: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack { Spacer(minLength: 80); RoundedRectangle(cornerRadius: 11).fill(Palette.muted).frame(maxWidth: 360).frame(height: 66) }
            VStack(alignment: .leading, spacing: 12) {
                ForEach([CGFloat(0.92), 0.83, 0.96, 0.62], id: \.self) { width in
                    GeometryReader { geometry in RoundedRectangle(cornerRadius: 4).fill(Palette.muted).frame(width: geometry.size.width * width) }.frame(height: 12)
                }
            }
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading session…").font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }.frame(maxWidth: 780).padding(.horizontal, 28).padding(.vertical, 35).frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore).accessibilityLabel("Loading session")
    }
    private func header(_ chat: ChatSession, info: SessionInfo, compact: Bool) -> some View {
        HStack(spacing: 12) {
            if !store.showSidebar, !store.paneLayout.detachedPanes.contains(where: { $0.id == pane.id }) { Button { store.showSidebar = true } label: { Image(systemName: "sidebar.left") }.help("Show sidebar") }
            Image(systemName: codeWorkspace ? "laptopcomputer" : "bubble.left.and.bubble.right").font(.system(size: 16)).foregroundStyle(.secondary)
            Text(info.title).fontWeight(.medium).lineLimit(1).truncationMode(.tail).layoutPriority(1).help(info.title)
            if !compact {
                Text(info.environment.isLocal ? projectTitle(info) : "SSH · \(projectTitle(info))").lineLimit(1).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.vertical, 4).background(Palette.muted, in: RoundedRectangle(cornerRadius: 7)).help(info.projectPath)
                ConversationVersionsView(store: store, selected: info)
            }
            Spacer()
            Group {
                if chat.busy { ProgressView().controlSize(.small) }
                if codeWorkspace, !compact {
                    ForEach([("Terminal", "terminal", "terminal"), ("Changes", "diff", "square.badge.plus"), ("Browser", "browser", "globe"), ("Files", "files", "folder")], id: \.1) { entry in
                        Button { store.togglePane(entry.1, for: chat) } label: {
                            Image(systemName: entry.2).font(.system(size: 16)).frame(width: 28, height: 28)
                                .background(store.pane(for: chat) == entry.1 ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.help(entry.0).accessibilityLabel(entry.0)
                    }
                }
                Menu { ForEach([("Changes", "diff", "arrow.triangle.branch"), ("Files", "files", "doc"), ("Terminal", "terminal", "terminal"), ("Browser", "browser", "globe"), ("Plan", "plan", "checklist"), ("Artifacts", "artifacts", "square.on.square"), ("Tasks", "tasks", "person.2"), ("Computer", "computer", "desktopcomputer"), ("iOS Simulator", "simulator", "iphone")], id: \.1) { row in
                    Button { store.togglePane(row.1, for: chat) } label: { Label(row.0, systemImage: row.2) }
                }
                    if store.paneLayout.panes.count > 1 {
                        Divider()
                        Button("Chats side by side") { store.arrangeChatPanes(.horizontal) }
                        Button("Chats stacked") { store.arrangeChatPanes(.vertical) }
                    }
                } label: { Image(systemName: "rectangle.split.2x1") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Views")
                Menu {
                    if store.paneLayout.detachedPanes.contains(where: { $0.id == pane.id }) {
                        Button("Dock in main window") { do { try store.dockChatPane(pane.id) } catch { store.error = error.localizedDescription } }.disabled(!store.paneLayout.canDock(pane.id))
                    } else {
                        Button("Pop out chat") { do { try store.popOutChatPane(pane.id) } catch { store.error = error.localizedDescription } }
                    }
                    Button("Fork session") { Task { do { try await store.fork(chat) } catch { store.error = error.localizedDescription } } }.disabled(!store.canFork(chat))
                    Button("Export transcript…") { store.export(chat) }
                    if chat.transcript.fileRestorations?.isEmpty == false {
                        Button("File restorations…") { store.fileRestorationHistoryRequest = FileRestorationHistoryRequest(chat: chat) }
                    }
                    if chat.transcript.discards?.isEmpty == false {
                        Button("Discarded changes…") { store.discardHistoryRequest = DiscardHistoryRequest(chat: chat) }
                    }
                    Button("Show project in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: info.projectPath) }.disabled(!info.environment.isLocal)
                    Button(chat.transcript.sessionToolsEnabled == true ? "Disable app session tools" : "Enable app session tools") {
                        Task { do { try await store.setAppSessionTools(chat,enabled:chat.transcript.sessionToolsEnabled != true) } catch { store.error=error.localizedDescription } }
                    }.disabled(!chat.workspace.environment.isLocal || chat.busy || chat.hasLiveAgentWork || !chat.pendingPrompts.isEmpty || !chat.pendingSettings.isEmpty)
                    Button("Disconnect agent") { Task { await store.disconnect(chat) } }
                    Button("Archive session") { Task { await store.archive(chat.id) } }
                } label: { Image(systemName: "ellipsis").rotationEffect(.degrees(90)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                if store.paneLayout.allPanes.count > 1 {
                    Button { Task { await store.closeChatPane(pane.id) } } label: { Image(systemName: "xmark") }.help("Close chat pane")
                }
            }
        }.buttonStyle(.plain).padding(.leading, 22 + titlebarInset).padding(.trailing, 22).frame(height: 48)
    }
    private func emptyChat(_ chat: ChatSession, info: SessionInfo) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "asterisk").font(.system(size: 40, weight: .medium)).foregroundStyle(Palette.accent)
            Text("Let’s build something").font(.system(size: 29, weight: .medium, design: .serif))
            Text("Working in \(info.projectName)").foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { suggestions(chat) }
                VStack(spacing: 8) { suggestions(chat) }
            }.padding(.top, 8)
            Spacer(); Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func projectTitle(_ info: SessionInfo) -> String {
        let path = info.worktreeSourcePath ?? info.projectPath
        return URL(fileURLWithPath: path.components(separatedBy: "/.claude/worktrees/")[0]).lastPathComponent
    }
    private func suggestions(_ chat: ChatSession) -> some View {
        ForEach(["Explore this project", "Review the changes", "Find and fix a bug"], id: \.self) { text in
            Button(text) { chat.draft = text }.buttonStyle(.plain).padding(12).background(Palette.muted, in: RoundedRectangle(cornerRadius: 9))
        }
    }
}

struct Sidebar: View {
    @Bindable var store: AppStore
    @Binding var codeWorkspace: Bool
    var titlebarInset: CGFloat = 0
    @State private var hoveredNavigation: String?
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var showMore = false
    @State private var showAccount = false
    @State private var hoveredProject: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                toolbarButton(.sidebar, "Hide sidebar") { store.showSidebar = false }
                toolbarButton(.search, "Search sessions (⌘K)") { store.openSessionSearch() }
                toolbarButton(.back, "Back") { Task { await store.goBack() } }.disabled(!store.canGoBack)
                toolbarButton(.forward, "Forward") { Task { await store.goForward() } }.disabled(!store.canGoForward)
                Spacer(minLength: 8)
                HStack(spacing: 0) {
                    workspaceButton(.chat, title: "Chat", code: false)
                    workspaceButton(.code, title: "Code", code: true)
                }.padding(2).background(Palette.muted, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain).accessibilityLabel("Chat or Code")
            }.padding(.leading, 10 + titlebarInset).padding(.trailing, 8).frame(height: 48)
            VStack(spacing: 1) {
                nav("New", .plus, selected: store.selectedID == nil) { Task { await store.openHome() } }
                nav("Artifacts", .artifacts, selected: store.pane == "artifacts" && codeWorkspace) { store.pane = store.pane == "artifacts" ? nil : "artifacts" }
                nav("Customize", .briefcase, selected: store.showSettings) { store.showSettings = true }
                Button { showMore.toggle() } label: {
                    navigationLabel("More", .down).foregroundStyle(.secondary)
                }.popover(isPresented: $showMore, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Search…    ⌘K") { showMore = false; store.openSessionSearch() }
                        Button("Routines…") { showMore = false; store.showSchedules = true }
                        sidebarActions
                    }.buttonStyle(.plain).padding(12)
                }
            }.padding(.top, 6).padding(.horizontal, 8)
            if let error = store.sessionHistoryError {
                Text("Session history: " + error).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(error).padding(.horizontal, 16).padding(.bottom, 8)
            }
            if store.sessionStatusFilter != nil {
                SessionStatusFilters(store: store).padding(.horizontal, 14).padding(.top, 14)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.sidebarSnapshot.rows) { entry in
                        switch entry {
                        case .pinned: Text("Pinned").font(SidebarTypography.font(12)).foregroundStyle(.secondary).padding(.leading, 6).padding(.top, 8).padding(.bottom, 6)
                        case .project(let path): projectHeader(path)
                        case .session(let info): row(info)
                        }
                    }
                    if store.visibleSessions.isEmpty { Text(store.sessionStatusFilter != nil ? "No sessions match this filter" : store.showArchived ? "No archived sessions" : "Open a project to get started").foregroundStyle(.tertiary).padding(12) }
                }.padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 8)
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "asterisk").font(.system(size: 16)).foregroundStyle(Palette.accent).frame(width: 20, height: 20)
                Button { showAccount.toggle() } label: {
                    HStack(spacing: 4) {
                        Text(NSFullUserName().components(separatedBy: " ").first ?? "ccode").font(SidebarTypography.font(14))
                        Text("· Local").font(SidebarTypography.font(12)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.secondary).padding(.leading, 8)
                    }
                }.fixedSize().accessibilityLabel("Account and sidebar options")
                    .popover(isPresented: $showAccount, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 12) {
                            Button("Settings…") { showAccount = false; store.showSettings = true }
                            Divider(); sidebarActions
                        }.buttonStyle(.plain).padding(12)
                    }
                Spacer()
                Button { store.showSettings = true } label: { Image(systemName: "gearshape") }.help("Settings")
            }.padding(.horizontal, 12).frame(height: 44)
        }.font(SidebarTypography.font(14)).buttonStyle(.plain).background(Palette.sidebar)
        .alert("Rename session", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renameID = nil }
            Button("Save") { if let id = renameID { store.rename(id, title: renameText) }; renameID = nil }
        }
    }
    private func glyph(_ kind: NavigationGlyph.Kind) -> some View {
        NavigationGlyph(kind: kind).stroke(style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)).frame(width: 14, height: 14)
    }
    private func toolbarButton(_ kind: NavigationGlyph.Kind, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { glyph(kind).frame(width: 24, height: 28).contentShape(Rectangle()) }
            .foregroundStyle(Palette.adaptive(0x5B5B58, 0xC5C5C0)).help(title).accessibilityLabel(title)
    }
    private func workspaceButton(_ kind: NavigationGlyph.Kind, title: String, code: Bool) -> some View {
        Button { codeWorkspace = code } label: {
            glyph(kind).foregroundStyle(codeWorkspace == code ? Color.primary : Color.secondary)
                .frame(width: 33, height: 24)
                .background(codeWorkspace == code ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay { if codeWorkspace == code { RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.border, lineWidth: 0.5) } }
                .contentShape(Rectangle())
        }.help(title).accessibilityLabel(title).accessibilityAddTraits(codeWorkspace == code ? [.isSelected] : [])
    }
    private func navigationLabel(_ title: String, _ kind: NavigationGlyph.Kind) -> some View {
        HStack(spacing: 7) {
            glyph(kind).rotationEffect(.degrees(title == "More" && !showMore ? -90 : 0)).frame(width: 18, height: 18).background(title == "New" && store.selectedID != nil ? Palette.selected : .clear, in: Circle())
            Text(title).font(SidebarTypography.font(14))
        }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 5).frame(height: 26).contentShape(Rectangle())
    }
    private func nav(_ title: String, _ kind: NavigationGlyph.Kind, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            navigationLabel(title, kind)
                .foregroundStyle(selected ? Color.primary : Palette.adaptive(0x575754, 0xC5C5C0))
                .background(selected || hoveredNavigation == title ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.onHover { hoveredNavigation = $0 ? title : nil }
    }
    private func projectHeader(_ path: String) -> some View {
        let title = URL(fileURLWithPath: path).lastPathComponent
        let collapsed = store.sidebarPreferences.collapsedProjects.contains(path)
        let pinned = store.sidebarPreferences.pinnedProjects.contains(path)
        return HStack(spacing: 0) {
            Button { store.toggleProjectCollapsed(path) } label: {
                HStack(spacing: 5) {
                    Text(title).font(SidebarTypography.font(12)).lineLimit(1)
                    if pinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .medium)).frame(width: 10)
                        .opacity(collapsed || hoveredProject == path ? 1 : 0)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 26).contentShape(Rectangle())
            }.accessibilityLabel(title + " project").accessibilityValue(collapsed ? "Collapsed" : "Expanded").help(path)
                .onDrag { NSItemProvider(object: path as NSString) }
            HStack(spacing: 0) {
                if hoveredProject != path && store.sidebarProjects.first != path { Spacer().frame(width: 48) }
                Button { Task { await store.openHome(path: path) } } label: { glyph(.plus).frame(width: 24, height: 26).contentShape(Rectangle()) }
                    .help("New session in " + title).accessibilityLabel("New session in " + title)
                if hoveredProject == path || store.sidebarProjects.first == path {
                    Button { store.openSessionSearch(project: store.sidebarProjects.first == path ? nil : path) } label: { glyph(.search).frame(width: 24, height: 26).contentShape(Rectangle()) }
                        .help("Search sessions (⌘K)").accessibilityLabel("Search")
                    Menu { projectActions(path); Divider(); sidebarActions } label: { Image(systemName: "slider.vertical.3").font(.system(size: 13, weight: .regular)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24, height: 26).help("Project and sidebar options").accessibilityLabel("Project options for " + title)
                }
            }.frame(width: 72)
        }.foregroundStyle(Palette.adaptive(0x8B8B86, 0x969692)).padding(.horizontal, 6).padding(.top, 8)
            .onHover { hoveredProject = $0 ? path : nil }
            .contextMenu { projectActions(path); Divider(); sidebarActions }
            .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let source = object as? String else { return }
                    Task { @MainActor in
                        store.moveProject(source, before: path)
                    }
                }
                return true
            }
    }
    @ViewBuilder private func projectActions(_ path: String) -> some View {
        Button(store.sidebarPreferences.pinnedProjects.contains(path) ? "Unpin project" : "Pin project") { store.toggleProjectPin(path) }
        Button(store.sidebarPreferences.collapsedProjects.contains(path) ? "Expand project" : "Collapse project") { store.toggleProjectCollapsed(path) }
        Button("Search in project…") { store.openSessionSearch(project: path) }
        Button("Move up") { store.moveProject(path, by: -1) }.disabled(!store.canMoveProject(path, by: -1))
        Button("Move down") { store.moveProject(path, by: 1) }.disabled(!store.canMoveProject(path, by: 1))
    }
    @ViewBuilder private var sidebarActions: some View {
        Menu("Filter sessions") { SessionStatusFilterOptions(store: store) }
        Button("Collapse all projects") { store.setAllProjectsCollapsed(true) }
        Button("Expand all projects") { store.setAllProjectsCollapsed(false) }
        Button(store.showArchived ? "Show active sessions" : "Show archived sessions") { store.showArchived.toggle() }
        Button("Refresh sessions") { Task { await store.refreshSessionHistory() } }.disabled(store.refreshingSessionHistory)
    }
    private func row(_ info: SessionInfo) -> some View {
        Button { Task { await store.select(info.id) } } label: {
            HStack(spacing: 10) {
                Image(systemName: store.sessionActivity(info.id) == .needsAttention ? "exclamationmark.triangle" : store.sessionActivity(info.id) == .completed ? "circle.fill" : store.sessionActivity(info.id) == .working ? "circle.dotted" : info.worktreeSourcePath != nil ? "arrow.triangle.branch" : info.pinned ? "pin" : "circle")
                    .font(.system(size: info.lastError != nil || info.worktreeSourcePath != nil ? 12 : info.pinned ? 9 : 6, weight: .regular)).frame(width: 12)
                    .foregroundStyle(store.sessionActivity(info.id) == .needsAttention ? Palette.adaptive(0xAD2929, 0xE66A61) : store.sessionActivity(info.id) == .completed ? Color.blue : store.sessionActivity(info.id) == .working ? Palette.accent : info.worktreeSourcePath != nil ? Color.purple : Palette.adaptive(0xBDBDB7, 0x969692))
                Text(info.title).font(SidebarTypography.font(14)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.94), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
            }
                .foregroundStyle(store.selectedID == info.id ? Color.primary : Palette.adaptive(0x575754, 0xC5C5C0))
                .padding(.horizontal, 8).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading).modifier(SidebarRowHover(selected: store.selectedID == info.id)).contentShape(Rectangle())
        }.accessibilityAddTraits(store.selectedID == info.id ? [.isSelected] : []).contextMenu {
            if !info.archived {
                Button("Open alongside current chat") {
                    Task { do { try await store.showSessionBeside(info.id) } catch { store.error = error.localizedDescription } }
                }.disabled(store.paneLayout.panes.count == 2 && !store.isChatVisible(info.id))
            }
            Button("Rename…") { renameID = info.id; renameText = info.title }
            Button(info.pinned ? "Unpin" : "Pin") { store.togglePin(info.id) }
            Button(info.archived ? "Restore" : "Archive") { Task { await store.archive(info.id) } }
            Button("Show project in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: info.projectPath) }.disabled(!info.environment.isLocal)
        }.help(info.title + " · " + store.sessionActivity(info.id).title).accessibilityValue(store.sessionActivity(info.id).title)
    }
}

private struct SidebarRowHover: ViewModifier {
    let selected: Bool
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.background(selected || hovered ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6)).onHover { hovered = $0 }
    }
}

// Sidebar outlines share one stroke instead of mixing symbol weights and text glyphs.
private struct NavigationGlyph: Shape {
    enum Kind { case sidebar, back, forward, chat, code, plus, artifacts, briefcase, down, search }
    let kind: Kind
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func line(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            p.move(to: first); for point in points.dropFirst() { p.addLine(to: point) }
        }
        switch kind {
        case .sidebar:
            p.addRoundedRect(in: CGRect(x: 2, y: 2, width: 20, height: 20), cornerSize: CGSize(width: 1, height: 1))
            line([CGPoint(x: 9, y: 2), CGPoint(x: 9, y: 22)])
        case .back, .forward:
            line([CGPoint(x: 20, y: 12), CGPoint(x: 4, y: 12)])
            line([CGPoint(x: 11, y: 5), CGPoint(x: 4, y: 12), CGPoint(x: 11, y: 19)])
            if kind == .forward { p = p.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 24, ty: 0)) }
        case .chat:
            p.move(to: CGPoint(x: 9, y: 2))
            p.addCurve(to: CGPoint(x: 16, y: 9), control1: CGPoint(x: 13, y: 2), control2: CGPoint(x: 16, y: 5))
            p.addCurve(to: CGPoint(x: 9, y: 16), control1: CGPoint(x: 16, y: 13), control2: CGPoint(x: 13, y: 16))
            p.addLine(to: CGPoint(x: 2, y: 16)); p.addLine(to: CGPoint(x: 4, y: 13))
            p.addCurve(to: CGPoint(x: 9, y: 2), control1: CGPoint(x: -1, y: 7), control2: CGPoint(x: 3, y: 2))
            p.closeSubpath()
            p.move(to: CGPoint(x: 19, y: 8))
            p.addCurve(to: CGPoint(x: 20, y: 18), control1: CGPoint(x: 24, y: 10), control2: CGPoint(x: 23, y: 16))
            line([CGPoint(x: 20, y: 18), CGPoint(x: 22, y: 22), CGPoint(x: 16, y: 21)])
            p.addQuadCurve(to: CGPoint(x: 12, y: 19), control: CGPoint(x: 13, y: 21))
        case .code:
            line([CGPoint(x: 7, y: 6), CGPoint(x: 2, y: 12), CGPoint(x: 7, y: 18)])
            line([CGPoint(x: 17, y: 6), CGPoint(x: 22, y: 12), CGPoint(x: 17, y: 18)])
            line([CGPoint(x: 14, y: 3), CGPoint(x: 10, y: 21)])
        case .plus:
            line([CGPoint(x: 12, y: 4), CGPoint(x: 12, y: 20)])
            line([CGPoint(x: 4, y: 12), CGPoint(x: 20, y: 12)])
        case .artifacts:
            p.addEllipse(in: CGRect(x: 2, y: 13, width: 8, height: 8))
            p.addRoundedRect(in: CGRect(x: 14, y: 12, width: 8, height: 10), cornerSize: CGSize(width: 1, height: 1))
            p.move(to: CGPoint(x: 6, y: 14)); p.addLine(to: CGPoint(x: 6, y: 8))
            p.addCurve(to: CGPoint(x: 17, y: 4), control1: CGPoint(x: 6, y: -1), control2: CGPoint(x: 16, y: 0))
            line([CGPoint(x: 17, y: 4), CGPoint(x: 21, y: 9), CGPoint(x: 6, y: 14)])
        case .briefcase:
            p.addRoundedRect(in: CGRect(x: 2, y: 7, width: 20, height: 15), cornerSize: CGSize(width: 2, height: 2))
            p.addRoundedRect(in: CGRect(x: 7, y: 3, width: 10, height: 4), cornerSize: CGSize(width: 1, height: 1))
            line([CGPoint(x: 2, y: 13), CGPoint(x: 22, y: 13)])
        case .search:
            p.addEllipse(in: CGRect(x: 2, y: 2, width: 16, height: 16))
            line([CGPoint(x: 16, y: 16), CGPoint(x: 23, y: 23)])
        case .down:
            line([CGPoint(x: 4, y: 8), CGPoint(x: 12, y: 16), CGPoint(x: 20, y: 8)])
        }
        return p.applying(CGAffineTransform(a: rect.width / 24, b: 0, c: 0, d: rect.height / 24, tx: rect.minX, ty: rect.minY))
    }
}
