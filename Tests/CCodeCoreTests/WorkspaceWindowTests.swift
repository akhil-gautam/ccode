import XCTest
import AppKit
import CCodeCore
@testable import CCode

final class WorkspaceWindowTests: XCTestCase {
    func testWorkspaceWindowsHaveUniqueOwnershipAndRestoreWithoutMovingChat() throws {
        var layout=PaneLayout();let session=UUID();layout.show(session)
        let chatPane=layout.focusedPaneID
        let terminal=try layout.detachWorkspace(sessionID:session,kind:"terminal")
        XCTAssertEqual(layout.panes.first?.id,chatPane)
        XCTAssertEqual(layout.panes.first?.sessionID,session)
        XCTAssertEqual(try layout.detachWorkspace(sessionID:session,kind:"terminal"),terminal)
        XCTAssertEqual(layout.detachedWorkspacePanes.count,1)
        XCTAssertThrowsError(try layout.detachWorkspace(sessionID:session,kind:"unknown"))
        layout.setWindowFrame(PaneWindowFrame(x:10,y:20,width:800,height:700),for:terminal)
        let restored=try JSONDecoder().decode(PaneLayout.self,from:JSONEncoder().encode(layout))
        XCTAssertEqual(restored,layout)
        layout.show(UUID());XCTAssertTrue(layout.visibleSessionIDs.contains(session))
        layout.focus(terminal);XCTAssertEqual(layout.focusedSessionID,session)
        layout.reconcile(available:[]);XCTAssertTrue(layout.detachedWorkspacePanes.isEmpty)
        XCTAssertTrue(layout.windowFrames.isEmpty)
    }
    @MainActor func testPopOutDockAndClosePreserveOwnerDraftAndMainChatPlacement() async throws {
        let(root,store,chat)=try await fixture()
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        chat.draft="Unsent main question";chat.fileDrafts["README.md"]=EditorDraft(original:"old",text:"unsaved")
        store.setPane("files",for:chat)
        let main=store.paneLayout.panes
        let auxiliary=try store.popOutWorkspacePane(chat,kind:"files")
        XCTAssertEqual(store.paneLayout.panes,main)
        XCTAssertNil(store.pane(for:chat))
        XCTAssertTrue(store.selected===chat)
        XCTAssertEqual(chat.draft,"Unsent main question")
        store.setPane("terminal",for:chat)
        XCTAssertEqual(store.pane(for:chat),"terminal")
        try store.dockWorkspacePane(auxiliary)
        XCTAssertEqual(store.pane(for:chat),"files")
        XCTAssertEqual(chat.fileDrafts["README.md"]?.text,"unsaved")
        let reopened=try store.popOutWorkspacePane(chat,kind:"files")
        await store.closeWorkspacePane(reopened)
        XCTAssertNil(store.pane(for:chat))
        XCTAssertEqual(store.paneLayout.panes,main)
        XCTAssertEqual(chat.draft,"Unsent main question")
        XCTAssertTrue(store.chat(chat.id)===chat)
    }
    @MainActor func testNativeAuxiliaryWindowReleasesMountedViewBeforeDockAndUsesStableRequestOwner() async throws {
        let(root,store,chat)=try await fixture()
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        let windows=ChatWindowCoordinator(store:store);store.chatWindows=windows
        defer { windows.stop() }
        store.setPane("tasks",for:chat)
        let pane=try store.popOutWorkspacePane(chat,kind:"tasks")
        windows.synchronize()
        let window=try XCTUnwrap(windows.window(for:pane))
        XCTAssertNotNil(window.contentView)
        windows.synchronize();XCTAssertTrue(windows.window(for:pane)===window)
        store.discardHistoryRequest=DiscardHistoryRequest(chat:chat)
        XCTAssertEqual(store.workflowOwner(for:"discardHistory",sessionID:chat.id),pane)
        store.focusChatPane(try XCTUnwrap(store.paneLayout.panes.first?.id))
        XCTAssertEqual(store.workflowOwner(for:"discardHistory",sessionID:chat.id),pane,"Focus changes cannot move a pending sheet to another window")
        try store.dockWorkspacePane(pane)
        XCTAssertNil(window.contentView);XCTAssertNil(windows.window(for:pane))
        XCTAssertEqual(store.pane(for:chat),"tasks")
        XCTAssertEqual(store.workflowOwner(for:"discardHistory",sessionID:chat.id),store.paneLayout.panes.first?.id)
    }
    @MainActor func testHiddenAuxiliaryOwnerRestoresWithoutStartingAgentAndArchiveClosesItsWindow() async throws {
        let(root,store,chat)=try await fixture()
        defer { try? FileManager.default.removeItem(at:root) }
        chat.draft="Preserved owner";store.setPane("plan",for:chat)
        let auxiliary=try store.popOutWorkspacePane(chat,kind:"plan")
        await store.create(path:root.path,worktree:false)
        let other=try XCTUnwrap(store.selectedID)
        XCTAssertNotEqual(other,chat.id);XCTAssertTrue(store.isChatVisible(chat.id))
        await store.shutdown()
        let restored=AppStore(directory:root.appendingPathComponent("data"),claudeDirectory:root.appendingPathComponent("empty"))
        addTeardownBlock { await restored.shutdown() }
        await restored.restore()
        XCTAssertEqual(restored.paneLayout.detachedWorkspacePanes.first?.id,auxiliary)
        XCTAssertEqual(restored.chat(chat.id)?.draft,"Preserved owner")
        XCTAssertNil(restored.chat(chat.id)?.connection)
        XCTAssertEqual(restored.paneLayout.panes.first?.sessionID,other)
        await restored.archive(chat.id)
        XCTAssertTrue(restored.paneLayout.detachedWorkspacePanes.isEmpty)
        XCTAssertEqual(restored.selectedID,other)
    }
    @MainActor private func fixture() async throws -> (URL,AppStore,ChatSession) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("ccode-workspace-window-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let storage=SessionStorage(directory:root.appendingPathComponent("data"),claudeDirectory:root.appendingPathComponent("empty"))
        try await storage.saveIndex([SessionInfo(projectPath:root.path,title:"Window owner")])
        let store=AppStore(directory:root.appendingPathComponent("data"),claudeDirectory:root.appendingPathComponent("empty"))
        await store.restore();return(root,store,try XCTUnwrap(store.selected))
    }
    @MainActor func testSettingsCanOpenFromHomeAndStayWithTheWindowThatOpenedThem() async throws {
        let(root,store,chat)=try await fixture()
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        let pane=try store.popOutWorkspacePane(chat,kind:"plan")
        store.showSettings=true
        store.focusChatPane(try XCTUnwrap(store.paneLayout.panes.first?.id))
        XCTAssertEqual(store.workflowOwner(for:"settings",sessionID:store.selectedID),pane)
        store.showSettings=false
        await store.openHome()
        XCTAssertNil(store.selectedID)
        store.showSettings=true
        XCTAssertEqual(store.workflowOwner(for:"settings",sessionID:nil),store.paneLayout.focusedPaneID)
    }

    @MainActor func testLiveTerminalAndAgentApprovalSurviveWorkspaceMoves() async throws {
        let(root,store,chat)=try await fixture()
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        store.settings.executable="/usr/bin/python3"
        store.settings.arguments=[try XCTUnwrap(Bundle.module.url(forResource:"parallel_work",withExtension:"py",subdirectory:"Fixtures")).path,"auxiliary"]
        store.send(chat,text:"Await user approval")
        try await wait { chat.approvals.count == 1 }
        let peer=try XCTUnwrap(chat.connection),approval=try XCTUnwrap(chat.approvals.first?.id)
        let agent=try await peer.request("fixture/identity",params:[:])
        let tab=try store.openWorkspaceTerminal(chat)
        try await wait { tab.ready }
        func capture(_ name: String) { tab.send(source:tab.view,data:Array("printf '%s' $$ > \(name)\n".utf8)[...]) }
        capture("before.pid");try await wait { FileManager.default.fileExists(atPath:root.appendingPathComponent("before.pid").path) }
        store.setPane("terminal",for:chat)
        let pane=try store.popOutWorkspacePane(chat,kind:"terminal")
        capture("after.pid");try await wait { FileManager.default.fileExists(atPath:root.appendingPathComponent("after.pid").path) }
        try store.dockWorkspacePane(pane)
        capture("docked.pid");try await wait { FileManager.default.fileExists(atPath:root.appendingPathComponent("docked.pid").path) }
        let pid=try String(contentsOf:root.appendingPathComponent("before.pid"),encoding:.utf8)
        XCTAssertFalse(pid.isEmpty)
        XCTAssertEqual(pid,try String(contentsOf:root.appendingPathComponent("after.pid"),encoding:.utf8))
        XCTAssertEqual(pid,try String(contentsOf:root.appendingPathComponent("docked.pid"),encoding:.utf8))
        XCTAssertTrue(chat.terminalTabs.first===tab);XCTAssertEqual(chat.terminalTabs.count,1)
        XCTAssertTrue(chat.connection===peer);XCTAssertEqual(chat.approvals.first?.id,approval)
        let after=try await peer.request("fixture/identity",params:[:]);XCTAssertEqual(agent["pid"],after["pid"])
        store.resolveApproval(chat,id:approval,option:nil);try await wait { !chat.busy }
    }
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return };try await Task.sleep(for:.milliseconds(10)) }
        XCTFail("Owned window/terminal transition timed out");throw ACPError.workspace("Fixture timed out")
    }
}
