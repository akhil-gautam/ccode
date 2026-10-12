import SwiftUI
import AppKit

@main struct CCodeApp: App {
    @State private var store = AppStore()
    @State private var titlebarHeight: CGFloat = 0
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("ccode", id: "main") {
            MainWindowContent(store: store, titlebarHeight: $titlebarHeight)
                .frame(minWidth: 860, minHeight: 600)
                .padding(.top, -titlebarHeight)
                .ignoresSafeArea(.container, edges: .top)
                .preferredColorScheme(store.settings.appearance == "light" ? .light : store.settings.appearance == "dark" ? .dark : nil)
                .task {
                    delegate.store = store
                    delegate.attachWindows(store)
                    delegate.chatWindows?.openMainWindow = { openWindow(id: "main") }
                    if store.loading { await store.restore() }
                    store.startLocalScheduling()
                    delegate.sessionNotifications.attach(store)
                    store.acknowledgeVisibleCompletions()
                    delegate.chatWindows?.synchronize()
                    await store.refreshSessionHistory()
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(30)) } catch { return }
                        if NSApp.isActive { await store.refreshSessionHistory() }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    if !store.loading { store.acknowledgeVisibleCompletions(); Task { await store.refreshSessionHistory() } }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notice in
                    if (notice.object as? NSWindow)?.identifier?.rawValue == "main" { titlebarHeight = 0 }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notice in
                    if let window = notice.object as? NSWindow, window.identifier?.rawValue == "main" {
                        titlebarHeight = window.frame.height - window.contentLayoutRect.height
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New session") { Task { await store.openHome() } }.keyboardShortcut("n")
                Button("Open project…") { store.chooseNewSessionProject() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { store.showSettings = true }.keyboardShortcut(",")
            }
            CommandMenu("Session") {
                Button("Send prompt") {
                    if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.keyCode == 36, let terminal = NSApp.keyWindow?.firstResponder as? NativeTerminalView { terminal.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
                    else if let chat = store.selected { if chat.editingSideQuestion { store.askSideQuestion(chat) } else { store.send(chat) } }
                    else { Task { await store.startFromHome() } }
                }.keyboardShortcut(.return, modifiers: .command).disabled(!store.canSendPromptCommand)
                Button("Stop response") {
                    if store.dictation.state != .idle { store.dictation.cancel() }
                    else if store.showSessionSearch { store.closeSessionSearch() }
                    else if store.discardPreviewRequest != nil { store.closeDiscardPreview() }
                    else if store.discardHistoryRequest != nil { store.discardHistoryRequest = nil }
                    else if store.showNewBranch { store.cancelHomeBranch() }
                    else if store.workspaceBranchEditing { if let task = store.selected?.workspaceActionTask { task.cancel() } else { store.workspaceBranchEditing = false } }
                    else if NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.keyCode == 53, let terminal = NSApp.keyWindow?.firstResponder as? NativeTerminalView { terminal.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
                    else if let chat = store.selected { if chat.editingSideQuestion { store.closeSideQuestion(chat) } else { store.stop(chat) } }
                    else { Task { await store.cancelHomeDiscovery() } }
                }.keyboardShortcut(.escape, modifiers: [])
                Button("Side question") { if let chat=store.selected { store.toggleSideQuestion(chat) } }.keyboardShortcut(";")
                    .disabled(store.selected == nil || store.showSessionSearch)
                Button("Fork session") { if let chat = store.selected { Task { do { try await store.fork(chat) } catch { store.error = error.localizedDescription } } } }.disabled(store.selected.map { !store.canFork($0) } ?? true)
                Button("Export transcript…") { if let chat = store.selected { store.export(chat) } }
                Button("Archive session") { if let id = store.selectedID { Task { await store.archive(id) } } }
            }
            CommandMenu("Go") {
                Button("Back") { Task { await store.goBack() } }.keyboardShortcut("[").disabled(!store.canGoBack)
                Button("Forward") { Task { await store.goForward() } }.keyboardShortcut("]").disabled(!store.canGoForward)
                Divider()
                Button("Previous Session") { Task { await store.previousSession() } }.keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(!store.canGoToPreviousSession)
                Button("Next Session") { Task { await store.nextSession() } }.keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(!store.canGoToNextSession)
                Button("Search…") { if store.showSessionSearch { store.closeSessionSearch() } else { store.openSessionSearch() } }.keyboardShortcut("k")
            }
            CommandGroup(replacing: .sidebar) {
                Button("Toggle sidebar") { store.showSidebar.toggle() }.keyboardShortcut("s", modifiers: [.command, .control])
                Button("Collapse all projects") { store.setAllProjectsCollapsed(true) }
                Button("Expand all projects") { store.setAllProjectsCollapsed(false) }
                ForEach([("Changes", "diff", "d"), ("Browser", "browser", "b"), ("Files", "files", "f"), ("Terminal", "terminal", "t"), ("Plan", "plan", "p"), ("Artifacts", "artifacts", "a")], id: \.1) { item in
                    Button(item.0) { store.pane = store.pane == item.1 ? nil : item.1 }.keyboardShortcut(KeyEquivalent(Character(item.2)), modifiers: [.command, .shift])
                }
                Button("Tasks") { store.pane = store.pane == "tasks" ? nil : "tasks" }
                Button("Close pane") { Task { await store.closeFocusedWorkspacePane() } }.keyboardShortcut("\\")
                Divider()
                Button("Focus next chat pane") { store.focusNextChatPane() }.keyboardShortcut("`", modifiers: [.command, .option])
                    .disabled(store.paneLayout.focusablePaneIDs.count < 2)
                Button("Pop out chat") { do { try store.popOutChatPane(store.paneLayout.focusedPaneID) } catch { store.error = error.localizedDescription } }.disabled(!store.paneLayout.panes.contains { $0.id == store.paneLayout.focusedPaneID && $0.sessionID != nil })
                Button("Dock chat") { do { try store.dockChatPane(store.paneLayout.focusedPaneID) } catch { store.error = error.localizedDescription } }.disabled(!store.paneLayout.canDock(store.paneLayout.focusedPaneID))
                Button("Chats side by side") { store.arrangeChatPanes(.horizontal) }.disabled(store.paneLayout.panes.count < 2)
                Button("Chats stacked") { store.arrangeChatPanes(.vertical) }.disabled(store.paneLayout.panes.count < 2)
            }
        }
    }
}

private struct MainWindowContent: NSViewRepresentable {
    let store: AppStore
    @Binding var titlebarHeight: CGFloat
    func makeNSView(context: Context) -> WindowHostingView {
        let view = WindowHostingView(rootView: ContentView(store: store))
        // HSplitView otherwise reserves the hidden native titlebar above our own header.
        view.safeAreaRegions = []
        view.reportTitlebar = { titlebarHeight = $0 }
        return view
    }
    func updateNSView(_ view: WindowHostingView, context: Context) {
        view.rootView = ContentView(store: store)
    }
}

private final class WindowHostingView: NSHostingView<ContentView> {
    var reportTitlebar: ((CGFloat) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Task { @MainActor [weak self] in
            guard let self, let window else { return }
            reportTitlebar?(window.styleMask.contains(.fullScreen) ? 0 : window.frame.height - window.contentLayoutRect.height)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    let sessionNotifications = SessionNotificationCoordinator()
    private(set) var chatWindows: ChatWindowCoordinator?
    func attachWindows(_ store: AppStore) {
        guard chatWindows == nil else { return }
        let coordinator = ChatWindowCoordinator(store: store)
        chatWindows = coordinator; store.chatWindows = coordinator
    }
    private var quitting = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting, let store else { return .terminateNow }
        quitting = true
        Task { sessionNotifications.stopDelivery(); chatWindows?.stop(); await store.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
