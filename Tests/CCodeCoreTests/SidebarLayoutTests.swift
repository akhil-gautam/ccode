import XCTest
import SwiftUI
import AppKit
import CCodeCore
@testable import CCode

final class SidebarLayoutTests: XCTestCase {
    @MainActor func testCollapsedProjectsRemainCompactAndExpansionAddsOnlySessionRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(directory: directory, claudeDirectory: directory.appendingPathComponent("claude"))
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: directory) }
        store.sessions = (0..<10).map { SessionInfo(projectPath: "/projects/project-\($0)", title: "Session \($0)") }
        store.setAllProjectsCollapsed(true)
        let host = NSHostingView(rootView: Sidebar(store: store, codeWorkspace: .constant(true)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
        let scroll = try XCTUnwrap(findScroll(host))
        let collapsed = scroll.documentView!.frame.height
        XCTAssertLessThan(collapsed, 390, "Collapsed projects must not retain the expanded group's extra spacing")
        XCTAssertEqual(store.sidebarSnapshot.rows.count, 10)
        store.toggleProjectCollapsed("/projects/project-0")
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
        XCTAssertEqual(store.sidebarSnapshot.rows.count, 11)
        // LazyVStack estimates offscreen rows; expansion must add a row, not another group gap.
        let expansion = scroll.documentView!.frame.height - collapsed
        XCTAssertGreaterThan(expansion, 10)
        XCTAssertLessThan(expansion, 33)
    }

    func testSidebarFontIsRegisteredFromPackagedResource() {
        XCTAssertEqual(SidebarTypography.nativeFont(14).fontName, "Inter-Regular")
    }

    @MainActor private func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScroll($0) }.first
    }
}
