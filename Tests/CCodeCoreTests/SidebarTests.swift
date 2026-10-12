import XCTest
import CCodeCore

final class SidebarTests: XCTestCase {
    func testProjectCollapsePinAndOrderKeepSearchAndNavigationReachable() throws {
        let a = SessionInfo(projectPath: "/one/shared", title: "Alpha")
        let b = SessionInfo(projectPath: "/two/shared", title: "Beta")
        let c = SessionInfo(projectPath: "/other", title: "Gamma")
        var preferences = SidebarPreferences()
        preferences.projectOrder = [b.projectPath, a.projectPath, b.projectPath, "/missing"]
        preferences.pinnedProjects = [c.projectPath]
        preferences.collapsedProjects = [a.projectPath, b.projectPath]
        let decoded = try JSONDecoder().decode(SidebarPreferences.self, from: JSONEncoder().encode(preferences))
        let snapshot = SidebarSnapshot(sessions: [a, b, c], preferences: decoded)
        XCTAssertEqual(snapshot.projects, [c.projectPath, b.projectPath, a.projectPath])
        XCTAssertEqual(snapshot.rows.map(\.id), ["project:/other", "session:" + c.id.uuidString, "project:/two/shared", "project:/one/shared"])
        XCTAssertEqual(Set(snapshot.sessionOrder.map(\.id)), Set([a.id, b.id, c.id]))
        XCTAssertEqual(SidebarSnapshot(sessions: [a, b, c], search: "Alpha", preferences: decoded).rows.last?.id, "session:" + a.id.uuidString)
        XCTAssertEqual(SidebarSnapshot(sessions: [a, b, c], projectScope: b.projectPath).visible.map(\.id), [b.id])
    }
    func testManagedWorktreeGroupsWithSourceAndOldSessionsRemainReadable() throws {
        let primary = SessionInfo(projectPath: "/projects/app", title: "Main")
        var worktree = SessionInfo(projectPath: "/data/worktrees/session-1", title: "Isolated")
        worktree.worktreeSourcePath = primary.projectPath
        let restored = try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(worktree))
        let snapshot = SidebarSnapshot(sessions: [primary, restored])
        XCTAssertEqual(snapshot.projects, [primary.projectPath])
        XCTAssertEqual(restored.projectName, "app")
        XCTAssertEqual(restored.projectPath, "/data/worktrees/session-1")
        let legacy = try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(primary))
        XCTAssertNil(legacy.worktreeSourcePath)
        XCTAssertEqual(legacy.projectGroupingPath, primary.projectPath)
    }
    func testSnapshotKeepsRowsStableAndSearchPinArchiveOrderConsistent() {
        var a = SessionInfo(projectPath: "/alpha/shared", title: "First")
        var b = SessionInfo(projectPath: "/beta/shared", title: "Second")
        var c = SessionInfo(projectPath: "/gamma", title: "Hidden")
        a.updatedAt = Date(timeIntervalSince1970: 1); b.updatedAt = Date(timeIntervalSince1970: 2)
        c.archived = true; b.pinned = true
        let snapshot = SidebarSnapshot(sessions: [c, a, b])
        XCTAssertEqual(snapshot.sessionOrder.map(\.id), [b.id, a.id])
        XCTAssertEqual(snapshot.rows.map(\.id), ["pinned", "session:" + b.id.uuidString, "project:/alpha/shared", "session:" + a.id.uuidString])
        a.title = "Renamed"
        XCTAssertEqual(SidebarSnapshot(sessions: [c, a, b]).rows.map(\.id), snapshot.rows.map(\.id))
        XCTAssertEqual(SidebarSnapshot(sessions: [c, a, b], search: "renamed").visible.map(\.id), [a.id])
        XCTAssertEqual(SidebarSnapshot(sessions: [c, a, b], archived: true).sessionOrder.map(\.id), [c.id])
    }
}
