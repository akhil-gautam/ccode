import XCTest
import SwiftUI
import AppKit
import CCodeCore
@testable import CCode

final class PullRequestLayoutTests: XCTestCase, @unchecked Sendable {
    // Catches long GitHub errors pushing every file/diff action out of the workspace pane.
    @MainActor func testPRHeaderBoundsLongErrorsInCompactAndWideLightAndDarkPanes() async throws {
        let f = try await PullRequestTests.Fixture.make()
        let store = AppStore(directory: f.dir.appendingPathComponent("data"), claudeDirectory: f.dir.appendingPathComponent("no-claude"))
        store.settings.executable = "/usr/bin/false"; store.settings.arguments = []; store.pullRequests = f.service
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: f.dir) }
        await store.create(path: f.root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected), preview = try await f.preview()
        chat.transcript.pullRequest = try await f.service.create(preview, push: false)
        chat.pullRequestError = String(repeating: "GitHub could not complete this request. Refresh the PR before retrying. ", count: 45)
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(300), 600] {
                let host = NSHostingView(rootView: PullRequestBar(chat: chat, store: store).font(.system(size: 14)).environment(\.colorScheme, scheme).frame(width: width))
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 1)
                XCTAssertGreaterThan(host.fittingSize.height, 60)
                XCTAssertLessThan(host.fittingSize.height, 360, "Error details need a bounded scroll area so workspace actions remain reachable")
            }
        }
    }
}
