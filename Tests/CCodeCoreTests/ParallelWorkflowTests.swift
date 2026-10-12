import Foundation
import XCTest
import SwiftUI
import AppKit
@testable import CCodeCore
@testable import CCode

final class ParallelWorkflowTests: XCTestCase {
    func testPopOutDockAndRestorePreserveUniquePlacement() throws {
        let a = UUID(), b = UUID(), c = UUID()
        var layout = PaneLayout()
        layout.show(a)
        let left = layout.focusedPaneID
        try layout.showBeside(b)
        let right = layout.focusedPaneID
        try layout.detach(left)
        XCTAssertEqual(layout.panes.map(\.sessionID), [b])
        XCTAssertEqual(layout.detachedPanes.map(\.sessionID), [a])
        XCTAssertEqual(layout.detachedPanes.first?.id, left)
        XCTAssertEqual(layout.visibleSessionIDs, [a, b])
        layout.show(a)
        XCTAssertEqual(layout.focusedPaneID, left)
        XCTAssertEqual(layout.panes.map(\.sessionID), [b], "Selection must focus the existing window")
        try layout.showBeside(c)
        XCTAssertThrowsError(try layout.dock(left), "A full main window must not evict another chat")
        XCTAssertEqual(layout.detachedPanes.map(\.sessionID), [a])
        layout.close(right)
        try layout.dock(left)
        XCTAssertTrue(layout.detachedPanes.isEmpty)
        XCTAssertEqual(Set(layout.panes.compactMap(\.sessionID)), [a, c])
        try layout.detach(left)
        layout.setWindowFrame(PaneWindowFrame(x: 30, y: 40, width: 980, height: 760), for: left)
        let restored = try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(restored.detachedPanes.first?.id, left)
        XCTAssertEqual(restored.windowFrames[left]?.width, 980)
        XCTAssertEqual(restored.focusedSessionID, a)
        var reconciled = restored
        reconciled.reconcile(available: [c])
        XCTAssertTrue(reconciled.detachedPanes.isEmpty)
        XCTAssertTrue(reconciled.windowFrames.isEmpty)
        XCTAssertEqual(reconciled.visibleSessionIDs, [c])
    }
    func testDetachedLayoutRejectsDuplicateAndUnusableWindowOwnership() throws {
        let a = UUID(), first = UUID(), second = UUID()
        let legacy: [String: Any] = ["version": 1, "arrangement": "horizontal", "focusedPaneID": first.uuidString,
            "panes": [["id": first.uuidString, "sessionID": a.uuidString]]]
        let decoded = try JSONDecoder().decode(PaneLayout.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(decoded.detachedPanes.isEmpty)
        var duplicate = legacy
        duplicate["version"] = 2
        duplicate["detachedPanes"] = [["id": second.uuidString, "sessionID": a.uuidString]]
        XCTAssertThrowsError(try JSONDecoder().decode(PaneLayout.self, from: JSONSerialization.data(withJSONObject: duplicate)))
        duplicate["detachedPanes"] = [["id": second.uuidString]]
        XCTAssertThrowsError(try JSONDecoder().decode(PaneLayout.self, from: JSONSerialization.data(withJSONObject: duplicate)))
    }
    @MainActor func testMovingWindowsRetainsDraftEditorTerminalAndAgentOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-detach-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), history = root.appendingPathComponent("empty")
        let storage = SessionStorage(directory: data, claudeDirectory: history)
        let a = SessionInfo(projectPath: root.path, title: "Detached"), b = SessionInfo(projectPath: root.path, title: "Main")
        try await storage.saveIndex([a, b])
        let store = AppStore(directory: data, claudeDirectory: history)
        await store.restore(); await store.select(a.id)
        let chat = try XCTUnwrap(store.selected)
        let pane = store.paneLayout.focusedPaneID
        chat.draft = "Never submit this draft"
        store.setPane("files", for: chat)
        chat.fileDrafts["README.md"] = EditorDraft(original: "original", text: "unsaved")
        try store.popOutChatPane(pane)
        await store.select(b.id)
        XCTAssertTrue(store.chat(a.id) === chat)
        XCTAssertTrue(store.isChatVisible(a.id))
        XCTAssertEqual(chat.draft, "Never submit this draft")
        XCTAssertEqual(chat.fileDrafts["README.md"]?.text, "unsaved")
        store.focusChatPane(pane)
        store.openSessionSearch()
        XCTAssertEqual(store.searchPaneID, pane)
        store.focusNextChatPane()
        XCTAssertEqual(store.searchPaneID, pane, "Search remains attached to the window that opened it")
        store.closeSessionSearch()
        store.focusChatPane(pane)
        XCTAssertTrue(store.selected === chat)
        XCTAssertEqual(store.pane, "files")
        try store.dockChatPane(pane)
        XCTAssertTrue(store.chat(a.id) === chat)
        try store.popOutChatPane(pane)
        await store.shutdown()
        let restored = AppStore(directory: data, claudeDirectory: history)
        await restored.restore()
        XCTAssertEqual(restored.paneLayout.detachedPanes.first?.sessionID, a.id)
        XCTAssertEqual(restored.chat(a.id)?.draft, "Never submit this draft")
        XCTAssertEqual(restored.chat(a.id)?.fileDrafts["README.md"]?.text, "unsaved")
        XCTAssertNil(restored.chat(a.id)?.connection, "Window restoration must not launch or replay agent work")
        await restored.closeChatPane(pane)
        XCTAssertTrue(restored.paneLayout.detachedPanes.isEmpty)
        XCTAssertNil(restored.chat(a.id))
        await restored.shutdown()
    }
    @MainActor func testNativeWindowMovesKeepChatAndReleaseOldViewAfterDock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-window-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), history = root.appendingPathComponent("empty")
        let storage = SessionStorage(directory: data, claudeDirectory: history)
        let info = SessionInfo(projectPath: root.path, title: "Window proof")
        try await storage.saveIndex([info])
        let store = AppStore(directory: data, claudeDirectory: history)
        await store.restore()
        let pane = store.paneLayout.focusedPaneID
        let chat = try XCTUnwrap(store.selected)
        let windows = ChatWindowCoordinator(store: store)
        defer { windows.stop() }
        try store.popOutChatPane(pane)
        windows.synchronize()
        let window = try XCTUnwrap(windows.window(for: pane))
        XCTAssertEqual(window.title, "Window proof")
        XCTAssertNotNil(window.contentView)
        windows.synchronize()
        XCTAssertTrue(windows.window(for: pane) === window, "Layout updates must not duplicate native handles")
        XCTAssertTrue(store.selected === chat)
        try store.dockChatPane(pane)
        windows.synchronize()
        XCTAssertNil(windows.window(for: pane))
        XCTAssertNil(window.contentView, "The previous window must release its mounted native views")
        XCTAssertTrue(store.selected === chat)
        try store.popOutChatPane(pane)
        windows.synchronize()
        let reopened = try XCTUnwrap(windows.window(for: pane))
        reopened.performClose(nil)
        try await wait { store.paneLayout.detachedPanes.isEmpty }
        windows.synchronize()
        XCTAssertNil(windows.window(for: pane))
        XCTAssertNil(reopened.contentView)
        await store.shutdown()
    }
    @MainActor func testDockReopensMissingMainWindowAndRenamingUpdatesDetachedTitle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-window-focus-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = SessionInfo(projectPath: root.path, title: "Before rename")
        let storage = SessionStorage(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("empty"))
        try await storage.saveIndex([info])
        let store = AppStore(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("empty"))
        await store.restore()
        let pane = store.paneLayout.focusedPaneID
        let windows = ChatWindowCoordinator(store: store)
        store.chatWindows = windows
        var openedMain = 0
        windows.openMainWindow = { openedMain += 1 }
        defer { windows.stop() }
        try store.popOutChatPane(pane); windows.synchronize()
        let window = try XCTUnwrap(windows.window(for: pane))
        store.rename(info.id, title: "After rename")
        try await wait { window.title == "After rename" }
        XCTAssertEqual(openedMain, 0)
        try store.dockChatPane(pane); windows.synchronize()
        XCTAssertEqual(openedMain, 1, "Docking must reopen the main window when it was closed")
        XCTAssertNil(windows.window(for: pane))
        XCTAssertNil(window.contentView)
        await store.shutdown()
    }

    @MainActor func testSearchFitsSmallDetachedWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-search-window-\(UUID())")
        let store = AppStore(directory: root, claudeDirectory: root.appendingPathComponent("empty"))
        defer { try? FileManager.default.removeItem(at: root) }
        let host = NSHostingView(rootView: SessionSearchView(store: store, width: 568, resultsHeight: 220))
        host.frame = NSRect(x: 0, y: 0, width: 568, height: 460)
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 570)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 462)
        await store.shutdown()
    }
    @MainActor func testTwoLiveACPChatsRouteDecisionsAndFileChangesIndependently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-parallel-live-\(UUID())")
        let projectA = root.appendingPathComponent("one"), projectB = root.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)
        let history = root.appendingPathComponent("empty"), data = root.appendingPathComponent("data")
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "parallel_work", withExtension: "py", subdirectory: "Fixtures"))
        var a = SessionInfo(projectPath: projectA.path, title: "One"), b = SessionInfo(projectPath: projectB.path, title: "Two")
        a.agentExecutable = "/usr/bin/python3"; a.agentArguments = [fixture.path, "one"]
        b.agentExecutable = "/usr/bin/python3"; b.agentArguments = [fixture.path, "two"]
        let storage = SessionStorage(directory: data, claudeDirectory: history)
        try await storage.saveIndex([a, b])
        let store = AppStore(directory: data, claudeDirectory: history)
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.restore(); await store.select(a.id)
        let first = try XCTUnwrap(store.selected)
        try await store.connect(first)
        try await store.showSessionBeside(b.id)
        let second = try XCTUnwrap(store.selected)
        try await store.connect(second)
        let peerA = try XCTUnwrap(first.connection), peerB = try XCTUnwrap(second.connection)
        XCTAssertFalse(peerA === peerB)
        let identityA = try await peerA.request("fixture/identity", params: [:])
        let identityB = try await peerB.request("fixture/identity", params: [:])
        XCTAssertNotEqual(identityA["pid"], identityB["pid"])
        XCTAssertEqual(identityA["cwd"].string, projectA.resolvingSymlinksInPath().path)
        XCTAssertEqual(identityB["cwd"].string, projectB.resolvingSymlinksInPath().path)
        store.send(first, text: "one-value"); store.send(second, text: "two-value")
        try await wait { first.approvals.count == 1 && second.approvals.count == 1 }
        XCTAssertEqual(store.attentionSessions.count, 2)
        let approvalA = try XCTUnwrap(first.approvals.first), approvalB = try XCTUnwrap(second.approvals.first)
        store.resolveApproval(first, id: approvalB.id, option: "allow")
        XCTAssertEqual(first.approvals.count, 1, "A foreign decision receipt cannot authorize another root")
        store.resolveApproval(second, id: approvalB.id, option: "allow")
        try await wait { !second.busy }
        XCTAssertEqual(try String(contentsOf: projectB.appendingPathComponent("two.txt"), encoding: .utf8), "two-value")
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectA.appendingPathComponent("one.txt").path))
        XCTAssertEqual(first.approvals.count, 1, "The other chat remains pending after background completion")
        let firstPane = try XCTUnwrap(store.paneLayout.panes.first { $0.sessionID == first.id }?.id)
        try store.popOutChatPane(firstPane)
        XCTAssertTrue(store.selected === first)
        XCTAssertTrue(first.connection === peerA)
        let identityAfterMove = try await peerA.request("fixture/identity", params: [:])
        XCTAssertEqual(identityAfterMove["pid"], identityA["pid"])
        try store.dockChatPane(firstPane)
        XCTAssertTrue(store.selected === first)
        XCTAssertTrue(first.connection === peerA); XCTAssertTrue(second.connection === peerB)
        store.resolveApproval(first, id: approvalA.id, option: "allow")
        try await wait { !first.busy }
        XCTAssertEqual(try String(contentsOf: projectA.appendingPathComponent("one.txt"), encoding: .utf8), "one-value")
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectA.appendingPathComponent("two.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectB.appendingPathComponent("one.txt").path))
        XCTAssertTrue(first.transcript.items.contains { $0.text == "Finished one" })
        XCTAssertFalse(first.transcript.items.contains { $0.text == "Finished two" })
        XCTAssertTrue(second.transcript.items.contains { $0.text == "Finished two" })
        XCTAssertFalse(second.transcript.items.contains { $0.text == "Finished one" })
        await store.shutdown()
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
        if !condition() { throw ACPError.workspace("Parallel fixture did not finish its expected state.") }
    }
    @MainActor func testTwoNativeChatViewsFitCompactAndWideWindows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-pane-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), history = root.appendingPathComponent("empty")
        let storage = SessionStorage(directory: data, claudeDirectory: history)
        let a = SessionInfo(projectPath: root.path, title: "First chat"), b = SessionInfo(projectPath: root.path, title: "Second chat")
        try await storage.saveIndex([a, b])
        let store = AppStore(directory: data, claudeDirectory: history)
        await store.restore(); await store.select(a.id); try await store.showSessionBeside(b.id)
        for width in [CGFloat(860), 1320] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let host = NSHostingView(rootView: ContentView(store: store).frame(width: width, height: 900))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 900)
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 2)
            }
        }
        await store.shutdown()
    }
    @MainActor func testNativeFocusBoundaryRoutesOnlyItsOwnResponder() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.contentView = content
        defer { window.contentView = nil }
        let left = ChatPaneFocusView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        let right = ChatPaneFocusView(frame: NSRect(x: 400, y: 0, width: 400, height: 500))
        let editor = NSTextView(frame: NSRect(x: 450, y: 50, width: 250, height: 100))
        content.addSubview(left); content.addSubview(right); content.addSubview(editor)
        XCTAssertFalse(left.ownsResponder(editor))
        XCTAssertTrue(right.ownsResponder(editor))
        XCTAssertFalse(right.ownsResponder(content), "A window-wide responder cannot pick a pane by its center")
        let promptA = InputTextView(frame: NSRect(x: 50, y: 20, width: 250, height: 60))
        let promptB = InputTextView(frame: NSRect(x: 450, y: 20, width: 250, height: 60))
        promptA.identifier = NSUserInterfaceItemIdentifier("ccode.mainPrompt")
        promptB.identifier = NSUserInterfaceItemIdentifier("ccode.mainPrompt")
        content.addSubview(promptA); content.addSubview(promptB)
        XCTAssertTrue(right.focusPrompt())
        XCTAssertTrue(window.firstResponder === promptB)
        XCTAssertTrue(left.focusPrompt())
        XCTAssertTrue(window.firstResponder === promptA)
    }
    func testLayoutKeepsEachChatInOnePaneAndRestoresFocusAndArrangement() throws {
        let a = UUID(), b = UUID(), c = UUID()
        var layout = PaneLayout()
        layout.show(a)
        let left = layout.focusedPaneID
        try layout.showBeside(b)
        let right = layout.focusedPaneID
        XCTAssertNotEqual(left, right)
        XCTAssertEqual(layout.panes.map(\.sessionID), [a, b])
        layout.show(a)
        XCTAssertEqual(layout.focusedPaneID, left)
        XCTAssertEqual(layout.panes.count, 2, "An already visible chat is focused, never duplicated")
        XCTAssertThrowsError(try layout.showBeside(c), "A full layout must not silently evict a visible chat")
        layout.arrangement = .vertical
        let restored = try JSONDecoder().decode(PaneLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(restored, layout)
        layout.reconcile(available: [b])
        XCTAssertEqual(layout.panes.map(\.sessionID), [b])
        XCTAssertEqual(layout.focusedPaneID, right)
        layout.close(right)
        XCTAssertEqual(layout.panes.count, 1)
        XCTAssertNil(layout.focusedSessionID)
    }
    func testCorruptLayoutCannotDuplicateNativeChatHandles() throws {
        let session = UUID(), pane = UUID()
        let object: [String: Any] = ["version": 1, "arrangement": "horizontal", "focusedPaneID": pane.uuidString,
            "panes": [["id": pane.uuidString, "sessionID": session.uuidString], ["id": UUID().uuidString, "sessionID": session.uuidString]]]
        XCTAssertThrowsError(try JSONDecoder().decode(PaneLayout.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    @MainActor func testTwoVisibleIdleChatsStayResidentAndRestoreWithoutAgentLaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-layout-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data"), history = root.appendingPathComponent("empty")
        let storage = SessionStorage(directory: data, claudeDirectory: history)
        let a = SessionInfo(projectPath: root.path, title: "First"), b = SessionInfo(projectPath: root.path, title: "Second")
        try await storage.saveIndex([a, b])
        let store = AppStore(directory: data, claudeDirectory: history)
        await store.restore(); await store.select(a.id)
        let first = try XCTUnwrap(store.selected)
        first.draft = "First unsent draft"
        store.pane = "terminal"
        try await store.showSessionBeside(b.id)
        let second = try XCTUnwrap(store.selected)
        second.draft = "Second unsent draft"
        store.pane = "files"
        XCTAssertTrue(store.chat(a.id) === first, "Visibility must protect idle chat ownership from eviction")
        XCTAssertNil(first.connection); XCTAssertNil(second.connection)
        store.focusChatPane(try XCTUnwrap(store.paneLayout.panes.first?.id))
        XCTAssertTrue(store.selected === first)
        XCTAssertEqual(store.pane, "terminal")
        store.arrangeChatPanes(.vertical)
        await store.shutdown()
        let restored = AppStore(directory: data, claudeDirectory: history)
        await restored.restore()
        XCTAssertEqual(restored.paneLayout.arrangement, .vertical)
        XCTAssertEqual(Set(restored.paneLayout.panes.compactMap(\.sessionID)), [a.id, b.id])
        XCTAssertEqual(restored.selectedID, a.id)
        XCTAssertEqual(restored.chat(a.id)?.draft, "First unsent draft")
        XCTAssertEqual(restored.chat(b.id)?.draft, "Second unsent draft")
        XCTAssertNil(restored.chat(a.id)?.connection); XCTAssertNil(restored.chat(b.id)?.connection)
        await restored.closeChatPane(try XCTUnwrap(restored.paneLayout.panes.first { $0.sessionID == b.id }?.id))
        XCTAssertNil(restored.chat(b.id), "Closing an idle pane permits cleanup after saving its draft")
        XCTAssertEqual(restored.paneLayout.panes.count, 1)
        await restored.shutdown()
    }
    @MainActor func testFocusedPaneDoesNotFollowSelectionIntoAnotherChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-parallel-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data")
        let storage = SessionStorage(directory: data, claudeDirectory: root.appendingPathComponent("empty"))
        let first = SessionInfo(projectPath: root.path, title: "First")
        let second = SessionInfo(projectPath: root.path, title: "Second")
        try await storage.saveIndex([first, second])
        let store = AppStore(directory: data, claudeDirectory: root.appendingPathComponent("empty"))
        await store.restore()
        await store.select(first.id)
        let a = try XCTUnwrap(store.selected)
        a.state = .running // Keep the first owned chat resident while selecting the second.
        a.draft = "First draft"
        store.pane = "terminal"
        await store.select(second.id)
        let b = try XCTUnwrap(store.selected)
        b.state = .running
        b.draft = "Second draft"
        XCTAssertNil(store.pane, "A chat must not inherit another chat's auxiliary view")
        store.pane = "files"
        store.setPane(nil, for: a)
        XCTAssertEqual(store.pane, "files", "Closing an unfocused chat's view cannot close the focused chat's view")
        store.setPane("terminal", for: a)
        store.togglePane("diff", for: a)
        XCTAssertEqual(store.pane, "files")
        XCTAssertEqual(store.pane(for: a), "diff")
        store.togglePane("diff", for: a)
        XCTAssertNil(store.pane(for: a))
        store.setPane("terminal", for: a)
        await store.select(first.id)
        XCTAssertTrue(store.selected === a)
        XCTAssertEqual(store.pane, "terminal")
        XCTAssertEqual(a.draft, "First draft")
        await store.select(second.id)
        XCTAssertTrue(store.selected === b)
        XCTAssertEqual(store.pane, "files")
        XCTAssertEqual(b.draft, "Second draft")
        store.setPane("unrecognized", for: b)
        XCTAssertEqual(store.pane, "files", "Unknown views cannot corrupt the saved view selection")
        let unrelated = try ChatSession(id: b.id, path: root.path, transcript: SessionTranscript())
        store.setPane("browser", for: unrelated)
        XCTAssertNil(unrelated.transcript.workspacePane, "Matching UUID alone does not own a loaded chat's view")
        XCTAssertEqual(store.pane, "files")
        a.state = .idle; b.state = .idle
        await store.shutdown()
        let restoredA = try await storage.load(first.id)
        let restoredB = try await storage.load(second.id)
        XCTAssertEqual(restoredA.workspacePane, "terminal")
        XCTAssertEqual(restoredB.workspacePane, "files")
    }
    func testOldTranscriptsWithoutPaneSelectionStillDecode() throws {
        let bytes = try JSONEncoder().encode(SessionTranscript())
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        legacy.removeValue(forKey: "workspacePane")
        let restored = try JSONDecoder().decode(SessionTranscript.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.workspacePane)
    }
}
