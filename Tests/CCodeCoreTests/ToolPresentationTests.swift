import XCTest
import SwiftUI
import AppKit
@testable import CCode
import CCodeCore

final class ToolPresentationTests: XCTestCase {
    func testReadUsesCanonicalResultAndRetainsRequestedRange() {
        let details = ToolDetailPresentation(tool: ["name": "Read", "kind": "read", "rawInput": ["file_path": "/tmp/Space 🐈/file.swift", "offset": 20, "limit": 2],
            "locations": [["path": "/tmp/Space 🐈/file.swift", "line": 20]],
            "rawOutput": "model-facing copy\n<system-reminder>Do not display</system-reminder>",
            "content": [["type": "content", "content": ["type": "text", "text": "```\n20\tlet value = 1\n21\tprint(value)\n```"]]]])
        XCTAssertEqual(details.locations, [.init(path: "/tmp/Space 🐈/file.swift", line: 20)])
        XCTAssertEqual(details.fields, [.init(label: "Start line", value: "20"), .init(label: "Line limit", value: "2")])
        XCTAssertEqual(details.sections, [.text(title: "Output", value: "20\tlet value = 1\n21\tprint(value)", command: false)])
    }
    func testEditPrefersProviderChangeAndDoesNotInventPartialDeletion() {
        let tool: JSONValue = ["name": "Edit", "kind": "edit", "rawInput": ["file_path": "/tmp/file.swift", "old_string": "old", "new_string": "new", "replace_all": true],
            "content": [["type": "diff", "path": "/tmp/file.swift", "oldText": "actual before", "newText": "actual after"]], "rawOutput": "File updated"]
        let details = ToolDetailPresentation(tool: tool)
        XCTAssertEqual(details.sections, [.change(path: "/tmp/file.swift", before: "actual before", after: "actual after"), .text(title: "Output", value: "File updated", command: false)])
        XCTAssertEqual(details.fields, [.init(label: "Replace all", value: "Yes")])
        let partial = ToolDetailPresentation(tool: ["name": "Write", "kind": "edit", "rawInput": ["path": "/tmp/new.swift"], "content": [["type": "diff", "path": "/tmp/new.swift", "oldText": nil]]])
        XCTAssertEqual(partial.sections, [.change(path: "/tmp/new.swift", before: nil, after: nil)])
        let deletion = ToolDetailPresentation(tool: ["name": "Edit", "rawInput": ["file_path": "/tmp/file.swift", "old_string": "old", "new_string": ""]])
        XCTAssertEqual(deletion.sections, [.change(path: "/tmp/file.swift", before: "old", after: "")])
    }
    func testSearchShowsItsScopeOptionsAndResultsWithoutRawJSONDuplication() {
        let details = ToolDetailPresentation(tool: ["name": "Grep", "kind": "search", "rawInput": ["pattern": "TODO|FIXME", "path": "/tmp/project", "glob": "*.swift", "-i": true, "-n": true, "head_limit": 50],
            "rawOutput": [["type": "text", "text": "src/file.swift:8:TODO"]]])
        XCTAssertEqual(details.locations, [.init(path: "/tmp/project", line: nil)])
        XCTAssertEqual(details.fields, [.init(label: "Pattern", value: "TODO|FIXME"), .init(label: "Glob", value: "*.swift"), .init(label: "Result limit", value: "50"), .init(label: "Case insensitive", value: "Yes"), .init(label: "Line numbers", value: "Yes")])
        XCTAssertEqual(details.sections, [.text(title: "Output", value: "src/file.swift:8:TODO", command: false)])
    }
    func testGenericToolsKeepUnknownInputAndMediaAndUnwrapOnlyWholeFences() {
        let media: JSONValue = ["type": "image", "data": "AQID", "mimeType": "image/png"]
        let details = ToolDetailPresentation(tool: ["name": "mcp__custom__inspect", "rawInput": ["custom": "literal"], "content": [["type": "content", "content": media]]])
        XCTAssertEqual(details.sections, [.text(title: "Input", value: "{\n  \"custom\" : \"literal\"\n}", command: false), .content(media)])
        XCTAssertEqual(ToolPresentation.displayText("````\nembedded ``` fence\n````"), "embedded ``` fence")
        XCTAssertEqual(ToolPresentation.displayText("```\nbody\n```\nExplanation"), "```\nbody\n```\nExplanation")
        XCTAssertEqual(ToolPresentation.displayText("ordinary `code`"), "ordinary `code`")
    }
    func testUnknownResultBlocksRemainInspectableAndCommandsRenderOnlyOnce() {
        let unfamiliar: JSONValue = ["type": "custom_result", "message": "Detailed diagnostic", "code": 17]
        let details = ToolDetailPresentation(tool: ["name": "mcp__custom__inspect", "content": [["type": "content", "content": unfamiliar]]])
        XCTAssertEqual(details.sections, [.text(title: "Content", value: unfamiliar.pretty, command: false)])
        let command = ToolDetailPresentation(tool: ["name": "Bash", "rawInput": ["command": "printf 'hello'", "description": "Read greeting"], "rawOutput": "hello",
            "content": [["type": "content", "content": ["type": "text", "text": "```sh\nprintf 'hello'\n```"]]]])
        XCTAssertEqual(command.sections, [.text(title: "Command", value: "printf 'hello'", command: true), .text(title: "Output", value: "hello", command: false)])
    }
    @MainActor func testStructuredDetailsFitCompactAndWideLightAndDark() {
        let details = ToolDetailPresentation(tool: ["name": "Edit", "rawInput": ["file_path": .string("/tmp/" + String(repeating: "long-path/", count: 20))], "content": [["type": "diff", "path": "/tmp/file.swift", "oldText": "before", "newText": "after"]]])
        for width in [CGFloat(300), 640] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let host = NSHostingView(rootView: ToolDetailsContent(details: details).frame(width: width))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 640)
                host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width, width + 2)
                XCTAssertLessThan(host.fittingSize.height, 350, "Long paths must wrap/truncate within the pane without stretching the card")
            }
        }
    }
    func testInterruptedToolGroupsRetainFailuresAndLiveSiblingStatus() {
        var stopped = TranscriptItem(kind: "tool", tool: ["status": "pending"]); stopped.toolInterruption = .stopped
        let completed = TranscriptItem(kind: "tool", tool: ["status": "completed"])
        let failed = TranscriptItem(kind: "tool", tool: ["status": "failed"])
        let running = TranscriptItem(kind: "tool", tool: ["status": "in_progress"])
        XCTAssertEqual(ToolPresentation.activity([stopped]), "Stopped")
        XCTAssertEqual(ToolPresentation.activity([completed, stopped]), "1 stopped")
        XCTAssertEqual(ToolPresentation.activity([failed, stopped, running]), "1 failed, 1 stopped, Running")
        var disconnected = stopped; disconnected.toolInterruption = .disconnected
        XCTAssertEqual(ToolPresentation.activity([disconnected]), "Disconnected")
        var restored = stopped; restored.toolInterruption = .interrupted
        XCTAssertEqual(ToolPresentation.activity([restored]), "Interrupted")
        restored.tool["status"] = "completed"
        XCTAssertEqual(ToolPresentation.activity([restored]), "Completed")
    }
    func testGroupingPreservesOrderAndIdentityAcrossHiddenThoughts() {
        let command = TranscriptItem(kind: "tool", tool: ["title": "Bash", "kind": "execute", "status": "completed"])
        let failed = TranscriptItem(kind: "tool", tool: ["title": "Bash", "kind": "execute", "status": "failed"])
        let thought = TranscriptItem(kind: "thought", text: "thinking")
        let prose = TranscriptItem(kind: "assistant", text: "Next step")
        let question = TranscriptItem(kind: "tool", tool: ["title": "AskUserQuestion", "kind": "other"])
        let items = [command, thought, failed, prose, command, question]
        let rows = TranscriptGroup.rows(items, showThoughts: false)
        XCTAssertEqual(rows.map { $0.items.count }, [2, 1, 1, 1])
        XCTAssertEqual(rows[0].id, command.id)
        XCTAssertEqual(rows[0].items[1].tool["status"].string, "failed")
        XCTAssertEqual(rows.flatMap(\.items), items.filter { $0.kind != "thought" })
        XCTAssertEqual(TranscriptGroup.rows(items, showThoughts: true).count, items.count)
        XCTAssertEqual(TranscriptGroup.rows([command, failed], showThoughts: false).first?.id, command.id)
        let longRun = (0..<1_000).map { _ in TranscriptItem(kind: "tool", tool: command.tool) }
        let bounded = TranscriptGroup.rows(longRun, showThoughts: false)
        XCTAssertTrue(bounded.allSatisfy { $0.items.count <= TranscriptGroup.maximumCommands })
        XCTAssertEqual(bounded.flatMap(\.items), longRun)
        XCTAssertEqual(bounded.map(\.id), stride(from: 0, to: longRun.count, by: TranscriptGroup.maximumCommands).map { longRun[$0].id })
    }

    func testDescriptionsPlainOutputAndBoundedPages() {
        XCTAssertEqual(ToolPresentation.title(["title": "Bash", "rawInput": ["description": "Fetched origin master", "command": "git fetch origin master"]]), "Fetched origin master")
        XCTAssertEqual(ToolPresentation.title(["title": "Bash", "status": "completed", "rawInput": ["description": "Run HRMS sync test suites"]]), "Ran HRMS sync test suites")
        XCTAssertEqual(ToolPresentation.title(["title": "Bash", "status": "in_progress", "rawInput": ["description": "Run HRMS sync test suites"]]), "Run HRMS sync test suites")
        XCTAssertEqual(ToolPresentation.title(["title": "Read", "rawInput": ["file_path": "/tmp/file.swift"]]), "Read /tmp/file.swift")
        XCTAssertEqual(ToolPresentation.title(["title": "Bash", "rawInput": ["command": "git status\necho done"]]), "git status")
        XCTAssertEqual(ToolPresentation.text("a\n\"b\""), "a\n\"b\"")
        XCTAssertEqual(ToolPresentation.text([["type": "text", "text": "first"], ["type": "text", "text": "second"]]), "first\nsecond")
        XCTAssertEqual(ToolPresentation.text(nil), "")
        let large = String(repeating: "👩🏽‍💻abc\n", count: 10_000)
        let count = (large.count + ToolPresentation.pageSize - 1) / ToolPresentation.pageSize
        let pages = (0..<count).map { ToolPresentation.page(large, at: $0) }
        XCTAssertEqual(pages.joined(), large)
        XCTAssertTrue(pages.allSatisfy { $0.count <= ToolPresentation.pageSize })
        XCTAssertEqual(ToolPresentation.page(large, at: count), "")
    }
}
