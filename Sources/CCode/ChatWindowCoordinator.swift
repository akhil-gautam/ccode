import AppKit
import SwiftUI
import CCodeCore

/// Owns exactly one native window per detached placement. It never owns a second agent session.
@MainActor final class ChatWindowCoordinator: NSObject, NSWindowDelegate {
    private weak var store: AppStore?
    var openMainWindow: (() -> Void)?
    private var windows: [UUID: NSWindow] = [:]
    private var synchronization: Task<Void, Never>?
    private var mainFocusObserver: NSObjectProtocol?
    private var lastFocusedPane: UUID?
    private var stopped = false
    init(store: AppStore) {
        self.store = store; super.init()
        mainFocusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = NSApp.keyWindow, window.identifier?.rawValue == "main", let store = self.store else { return }
                if !store.paneLayout.panes.contains(where: { $0.id == store.paneLayout.focusedPaneID }), let pane = store.paneLayout.panes.first {
                    store.focusChatPane(pane.id)
                }
                store.acknowledgeVisibleCompletions()
            }
        }
    }
    func isSessionPresented(_ id: UUID) -> Bool {
        guard let store, let pane = store.paneLayout.allPanes.first(where: { $0.sessionID == id }) else { return false }
        let window = windows[pane.id] ?? NSApp.windows.first { $0.identifier?.rawValue == "main" }
        return window?.isVisible == true && window?.isMiniaturized == false && window?.occlusionState.contains(.visible) == true
    }
    func showFocusedWindow() { lastFocusedPane = nil; synchronize() }
    func window(for pane: UUID) -> NSWindow? { windows[pane] }
    func scheduleSynchronize() {
        guard !stopped else { return }
        synchronization?.cancel()
        synchronization = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.synchronize()
        }
    }
    func releaseWindow(for pane: UUID) {
        guard let window = windows.removeValue(forKey: pane) else { return }
        if lastFocusedPane == pane { lastFocusedPane = nil }
        window.delegate = nil
        window.contentView = nil
        window.close()
    }
    func synchronize() {
        guard !stopped, let store else { return }
        let layout = store.paneLayout
        let live = Set(layout.detachedPanes.map(\.id) + layout.detachedWorkspacePanes.map(\.id))
        for id in Set(windows.keys).subtracting(live) { releaseWindow(for: id) }
        for pane in layout.detachedPanes {
            guard let id = pane.sessionID, let info = store.sessions.first(where: { $0.id == id }) else { continue }
            if let window = windows[pane.id] { window.title = info.title; continue }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = info.title
            window.identifier = NSUserInterfaceItemIdentifier("ccode.chat.\(pane.id)")
            window.contentMinSize = NSSize(width: 600, height: 500)
            window.delegate = self
            windows[pane.id] = window
            if let saved = layout.windowFrames[pane.id], saved.isUsable { window.setFrame(Self.restoredFrame(saved), display: false) }
            else { window.center() }
            window.contentView = NSHostingView(rootView: ChatWindowContentView(store: store, paneID: pane.id))
            if pane.id == layout.focusedPaneID { lastFocusedPane = nil }
            window.orderFront(nil)
        }
        for pane in layout.detachedWorkspacePanes {
            guard let info=store.sessions.first(where: { $0.id == pane.sessionID }) else { continue }
            let title="\(pane.kind == "diff" ? "Changes" : pane.kind.capitalized) — \(info.title)"
            if let window=windows[pane.id] { window.title=title;continue }
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:860,height:700),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.title=title;window.identifier=NSUserInterfaceItemIdentifier("ccode.workspace.\(pane.id)")
            window.contentMinSize=NSSize(width:600,height:500);window.delegate=self;windows[pane.id]=window
            if let saved=layout.windowFrames[pane.id], saved.isUsable { window.setFrame(Self.restoredFrame(saved),display:false) } else { window.center() }
            window.contentView=NSHostingView(rootView:WorkspaceWindowContentView(store:store,paneID:pane.id))
            window.orderFront(nil)
        }
        if lastFocusedPane != layout.focusedPaneID {
            lastFocusedPane = layout.focusedPaneID
            if let window = windows[layout.focusedPaneID] { window.makeKeyAndOrderFront(nil) }
            else if let main = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) { main.makeKeyAndOrderFront(nil) }
            else { openMainWindow?() }
        }
    }
    private static func restoredFrame(_ saved: PaneWindowFrame) -> NSRect {
        let frame = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main else { return frame }
        let visible = screen.visibleFrame
        let width = min(frame.width, visible.width), height = min(frame.height, visible.height)
        return NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - width), y: min(max(frame.minY, visible.minY), visible.maxY - height), width: width, height: height)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let pane = windows.first(where: { $0.value === sender })?.key, let store else { return true }
        Task { @MainActor [weak self] in
            if store.paneLayout.detachedWorkspacePanes.contains(where: { $0.id == pane }) { await store.closeWorkspacePane(pane) }
            else { await store.closeChatPane(pane) }
            self?.synchronize()
        }
        return false // Commit the placement change before releasing its mounted views.
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let pane = windows.first(where: { $0.value === window })?.key else { return }
        store?.focusChatPane(pane); store?.acknowledgeVisibleCompletions()
    }
    func windowDidMove(_ notification: Notification) { saveFrame(notification) }
    func windowDidResize(_ notification: Notification) { saveFrame(notification) }
    private func saveFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let pane = windows.first(where: { $0.value === window })?.key else { return }
        let frame = window.frame
        store?.saveChatWindowFrame(PaneWindowFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height), for: pane)
    }
    func stop() {
        stopped = true; synchronization?.cancel(); synchronization = nil
        if let mainFocusObserver { NotificationCenter.default.removeObserver(mainFocusObserver) }
        mainFocusObserver = nil
        for pane in Array(windows.keys) { releaseWindow(for: pane) }
    }
}

struct WorkspaceWindowContentView: View {
    @Bindable var store: AppStore
    let paneID: UUID
    var body: some View {
        Group {
            if let pane=store.paneLayout.detachedWorkspacePanes.first(where: { $0.id == paneID }), let chat=store.chat(pane.sessionID) {
                WorkspacePane(chat:chat,store:store,kind:pane.kind,detachedPaneID:paneID)
                    .background(ChatPaneFocusBoundary(requestID:store.chatPaneFocusRequest?.paneID == paneID ? store.chatPaneFocusRequest?.id : nil) { store.focusChatPane(paneID) })
            }
        }.font(.system(size:14)).tint(Color.primary).background(Palette.surface)
            .preferredColorScheme(store.settings.appearance == "light" ? .light : store.settings.appearance == "dark" ? .dark : nil)
            .modifier(WorkflowPresentation(store:store,detachedPaneID:paneID))
    }
}

struct ChatWindowContentView: View {
    @Bindable var store: AppStore
    let paneID: UUID
    @AppStorage("codeWorkspace") private var codeWorkspace = true
    var body: some View {
        Group {
            if let pane = store.paneLayout.detachedPanes.first(where: { $0.id == paneID }) {
                ChatPaneView(store: store, pane: pane, codeWorkspace: $codeWorkspace)
                    .background(ChatPaneFocusBoundary(requestID: store.chatPaneFocusRequest?.paneID == paneID ? store.chatPaneFocusRequest?.id : nil) { store.focusChatPane(paneID) })
            }
        }.font(.system(size: 14)).tint(Color.primary).background(Palette.surface)
            .preferredColorScheme(store.settings.appearance == "light" ? .light : store.settings.appearance == "dark" ? .dark : nil)
            .modifier(WorkflowPresentation(store: store, detachedPaneID: paneID))
    }
}
