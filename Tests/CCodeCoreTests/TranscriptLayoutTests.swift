import XCTest
import SwiftUI
import AppKit
import CCodeCore
@testable import CCode

final class TranscriptLayoutTests: XCTestCase {
    @MainActor func testComposerControlsDoNotStretchCompactChatVertically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var transcript = SessionTranscript()
        transcript.configOptions = [
            ["id": "mode", "type": "select", "category": "mode", "currentValue": "auto", "options": [["value": "auto", "name": "Ask before making changes"]]],
            ["id": "model", "type": "select", "category": "model", "currentValue": "opus", "options": [["value": "opus", "name": "Claude Opus 5.5"]]],
            ["id": "effort", "type": "select", "category": "thought_level", "currentValue": "high", "options": [["value": "high", "name": "High"]]]
        ]
        let chat = try ChatSession(id: UUID(), path: directory.path, transcript: transcript)
        let store = AppStore(directory: directory.appendingPathComponent("data"), claudeDirectory: directory.appendingPathComponent("claude"))
        let info = SessionInfo(id: chat.id, projectPath: directory.path)
        for width in [CGFloat(360), 780] {
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: Composer(chat: chat, store: store, info: info).frame(width: width).preferredColorScheme(scheme))
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
                XCTAssertLessThan(host.fittingSize.height, 200, "Controls must scroll horizontally without consuming the transcript's height")
            }
        }
    }

    @MainActor func testWorkingStatusStaysInConversationColumn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var transcript = SessionTranscript()
        transcript.items = [TranscriptItem(kind: "assistant", text: "Reading the project")]
        let chat = try ChatSession(id: UUID(), path: directory.path, transcript: transcript)
        chat.state = .running
        let store = AppStore(directory: directory.appendingPathComponent("data"), claudeDirectory: directory.appendingPathComponent("claude"))
        let host = NSHostingView(rootView: TranscriptView(chat: chat, store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
        let table = try XCTUnwrap(findTable(host))
        XCTAssertEqual(table.numberOfRows, 3)
        let message = try XCTUnwrap(accessibleText("Reading the project", in: host))
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        let status = try XCTUnwrap(findProgress(cell))
        XCTAssertGreaterThan(status.accessibilityFrame().minX, 250, "Busy status must not escape to the window edge")
        XCTAssertEqual(status.accessibilityFrame().minX, message.accessibilityFrame().minX, accuracy: 2)
    }

    @MainActor private func accessibleText(_ text: String, in element: Any) -> (any NSAccessibilityProtocol)? {
        guard let accessible = element as? any NSAccessibilityProtocol else { return nil }
        if (accessible.accessibilityValue() as? String)?.contains(text) == true || accessible.accessibilityLabel()?.contains(text) == true { return accessible }
        if let match = (accessible.accessibilityChildren() ?? []).lazy.compactMap({ self.accessibleText(text, in: $0) }).first { return match }
        return (element as? NSView)?.subviews.lazy.compactMap { self.accessibleText(text, in: $0) }.first
    }

    @MainActor private func findProgress(_ view: NSView) -> NSProgressIndicator? {
        if let progress = view as? NSProgressIndicator { return progress }
        return view.subviews.lazy.compactMap { self.findProgress($0) }.first
    }

    @MainActor func testCollapsingToolImmediatelyShrinksNativeListRow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = TranscriptItem(kind: "tool", tool: ["title": "Bash", "kind": "execute", "status": "completed", "rawInput": ["command": "printf output"], "rawOutput": .string(String(repeating: "output\n", count: 80))])
        var transcript = SessionTranscript()
        transcript.items = [tool, TranscriptItem(kind: "assistant", text: "Following message")]
        let chat = try ChatSession(id: UUID(), path: directory.path, transcript: transcript)
        let store = AppStore(directory: directory.appendingPathComponent("data"), claudeDirectory: directory.appendingPathComponent("claude"))
        let host = NSHostingView(rootView: TranscriptView(chat: chat, store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
        let table = try XCTUnwrap(findTable(host))
        XCTAssertEqual(table.numberOfRows, 3)
        let initial = table.rect(ofRow: 0).height
        chat.displayMode = "verbose"
        for _ in 0..<15 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() }
        let expanded = table.rect(ofRow: 0).height
        XCTAssertGreaterThan(expanded, initial + 400)
        // Match a reader who scrolled away from the tail; tail-following would itself trigger a layout pass.
        table.enclosingScrollView?.contentView.scroll(to: .zero)
        table.enclosingScrollView?.reflectScrolledClipView(table.enclosingScrollView!.contentView)
        try await Task.sleep(for: .milliseconds(40))
        chat.displayMode = "normal"
        try await Task.sleep(for: .milliseconds(40))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.rect(ofRow: 0).height, initial, accuracy: 2, "Collapse must invalidate the row height without scrolling")
        XCTAssertEqual(table.rect(ofRow: 1).minY, table.rect(ofRow: 0).maxY + table.intercellSpacing.height, accuracy: 2)
    }

    @MainActor private func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.findTable($0) }.first
    }
}
