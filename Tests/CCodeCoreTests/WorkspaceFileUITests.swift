import XCTest
import SwiftUI
import AppKit
import Observation
@testable import CCode

@MainActor @Observable private final class EditorFixture {
    var text = "first\nsecond\nthird\n"
    var selection = NSRange(location: 6, length: 6)
}

private struct EditorFixtureView: View {
    @Bindable var state: EditorFixture
    var body: some View { SelectionTextEditor(text: $state.text, selection: $state.selection) }
}

final class WorkspaceFileUITests: XCTestCase {
    // Catches line-link selections being ignored on creation/update or reset when SwiftUI republishes the same text.
    @MainActor func testNativeEditorAppliesRequestedSelectionAndKeepsUserSelection() async throws {
        let state = EditorFixture(), host = NSHostingView(rootView: EditorFixtureView(state: EditorFixture()))
        host.rootView = EditorFixtureView(state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; defer { window.contentView = nil }
        await settle(host)
        let editor = try XCTUnwrap(findEditor(host))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 6))
        state.selection = NSRange(location: 13, length: 5)
        await settle(host)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 13, length: 5))
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        await settle(host)
        XCTAssertEqual(state.selection, NSRange(location: 1, length: 2))
        state.text += "fourth\n"; await settle(host)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: 2))
        state.selection = NSRange(location: 999, length: 10); await settle(host)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 26, length: 0))
    }

    // Catches AppStore file-link state never reaching the visible native workspace editor.
    @MainActor func testFileLinkOpensEditorAndSelectedLineWithoutReplacingDirtyText() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-file-ui-\(UUID())")
        let project = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "first\nsecond\n".write(to: project.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let store = AppStore(directory: base.appendingPathComponent("data"), claudeDirectory: base.appendingPathComponent("empty"))
        store.settings.executable = "/usr/bin/false"; store.settings.arguments = []
        await store.create(path: project.path, worktree: false)
        let chat = try XCTUnwrap(store.selected)
        let host = NSHostingView(rootView: WorkspacePane(chat: chat, store: store, kind: "files"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: base) }
        await settle(host)
        chat.fileDrafts["a.txt"] = FileDraft(original: "first\nsecond\n", text: "edited\nsecond\n")
        try await store.openWorkspaceReference(chat, reference: "a.txt#L2")
        await settle(host)
        let editor = try XCTUnwrap(findEditor(host))
        XCTAssertEqual(editor.string, "edited\nsecond\n")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 7, length: 6))
        XCTAssertEqual(chat.fileDrafts["a.txt"]?.text, "edited\nsecond\n")
    }

    @MainActor private func settle(_ host: NSView) async {
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
    }
    @MainActor private func findEditor(_ view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap { self.findEditor($0) }.first
    }
}
