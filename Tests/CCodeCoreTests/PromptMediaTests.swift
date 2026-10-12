import XCTest
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import Observation
import CCodeCore
@testable import CCode

final class PromptMediaTests: XCTestCase, @unchecked Sendable {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aCJkAAAAASUVORK5CYII=")!
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testImageSnapshotKeepsPNGAndBoundsTIFFConversion() async throws {
        let storage = SessionStorage(directory: try temporary())
        let attachment = try await storage.importImage(png)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertEqual(try Data(contentsOf: storage.attachmentURL(attachment)), png)
        let blocks = try await storage.attachmentPrompt(attachment, capabilities: ["image": true])
        XCTAssertEqual(Data(base64Encoded: blocks[0]["data"].string), png)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2200, pixelsHigh: 1100, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(try XCTUnwrap(bitmap.bitmapData), 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let tiff = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))
        XCTAssertGreaterThan(tiff.count, 5 * 1024 * 1024, "A normal uncompressed screenshot exceeds the file import limit")
        let converted = try await storage.importImage(tiff)
        XCTAssertEqual(converted.mimeType, "image/png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(storage.attachmentURL(converted) as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1600)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 800)
        for bytes in [Data("not an image".utf8), Data(count: 32 * 1024 * 1024)] {
            do { _ = try await storage.importImage(bytes); XCTFail("Invalid/oversized clipboard data must reject") } catch {}
        }
    }
    @MainActor func testPrivatePasteboardUsesImagesOrFilesWithoutChangingText() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem(); item.setData(png, forType: .png); item.setString("Image fallback", forType: .string)
        board.writeObjects([item])
        var text = "Keep my draft", inputs: [AttachmentInput] = [], errors: [String] = []
        let host = NSHostingView(rootView: PromptEditor(text: Binding(get: { text }, set: { text = $0 }), placeholder: "Prompt", send: {}, cancel: {},
            attachmentInput: { inputs += $0 }, attachmentError: { errors.append($0) }))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 80); host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> InputTextView? { if let input = view as? InputTextView { return input }; return view.subviews.compactMap(find).first }
        let input = try XCTUnwrap(find(host))
        XCTAssertTrue(input.acceptAttachmentPasteboard(board))
        XCTAssertEqual(inputs.count, 1); XCTAssertEqual(inputs[0].residentBytes, png.count)
        XCTAssertEqual(text, "Keep my draft"); XCTAssertTrue(errors.isEmpty)
        board.clearContents(); board.setString("Ordinary text", forType: .string)
        XCTAssertFalse(input.acceptAttachmentPasteboard(board), "Text-only paste must retain NSTextView's normal paste behavior")
        let url = try temporary().appendingPathComponent("Chosen.txt"); try "file".write(to: url, atomically: true, encoding: .utf8)
        board.clearContents(); board.writeObjects([url as NSURL])
        XCTAssertEqual(try PromptPasteboard.inputs(from: board).count, 1)
        board.clearContents(); board.setData(Data(count: 32 * 1024 * 1024), forType: .png)
        XCTAssertTrue(input.acceptAttachmentPasteboard(board)); XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(errors.count, 1); XCTAssertEqual(text, "Keep my draft")
    }
    @MainActor func testEditorWithoutAttachmentHandlerDoesNotSwallowImagePaste() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setData(png, forType: .png)
        let host = NSHostingView(rootView: PromptEditor(text: .constant("Unchanged"), placeholder: "Prompt", send: {}, cancel: {}))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 80); host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> InputTextView? { if let input = view as? InputTextView { return input }; return view.subviews.compactMap(find).first }
        XCTAssertFalse(try XCTUnwrap(find(host)).acceptAttachmentPasteboard(board))
    }
    @MainActor func testDroppedImageAndFileAreSerializedAndPersistAsSnapshots() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected); chat.draft = "Unsent media"
        let file = root.appendingPathComponent("Context.txt"); try "disk snapshot".write(to: file, atomically: true, encoding: .utf8)
        let image = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        let source = NSItemProvider(object: file as NSURL)
        XCTAssertTrue(store.attachProviders([image, source], to: chat))
        let operation = try XCTUnwrap(chat.attachmentTask)
        store.attachInputs([.image(png)], to: chat)
        await operation.value
        XCTAssertEqual(chat.attachments.map(\.mimeType), ["image/png", "text/plain", "image/png"], store.error ?? "")
        XCTAssertEqual(chat.draft, "Unsent media"); XCTAssertFalse(chat.attachingFiles)
        try FileManager.default.removeItem(at: file)
        await store.shutdown()
        let restored = AppStore(directory: root.appendingPathComponent("data"))
        await restored.restore(); await restored.select(chat.id)
        let loaded = try XCTUnwrap(restored.selected)
        XCTAssertEqual(loaded.attachments, chat.attachments)
        XCTAssertEqual(loaded.draft, "Unsent media")
        for attachment in loaded.attachments { XCTAssertTrue(FileManager.default.fileExists(atPath: restored.attachmentURL(attachment).path)) }
        await restored.shutdown()
    }
    @MainActor func testImageQueueBudgetAndCancelDoNotLoseDraftOrHangOnProvider() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected); chat.draft = "Retained"
        let waiting = NSItemProvider()
        waiting.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { _ in Progress(totalUnitCount: 1) }
        XCTAssertTrue(store.attachProviders([waiting], to: chat))
        let operation = try XCTUnwrap(chat.attachmentTask)
        for _ in 0..<15 { await Task.yield() }
        store.attachInputs([.image(Data(count: 17 * 1024 * 1024)), .image(Data(count: 17 * 1024 * 1024))], to: chat)
        XCTAssertNotNil(store.error, "Queued image bytes need a bound before decode/import")
        var completed = false
        let waiter = Task { await operation.value; completed = true }
        store.cancelAttachmentImports(chat)
        for _ in 0..<100 where !completed { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(completed, "An item provider that never calls back cannot hang cancellation")
        waiter.cancel()
        XCTAssertTrue(chat.attachments.isEmpty); XCTAssertFalse(chat.attachingFiles)
        XCTAssertEqual(chat.draft, "Retained")
        await store.shutdown()
    }
    @MainActor private func finish(_ chat: ChatSession, store: AppStore) async throws {
        for _ in 0..<700 {
            if let approval = chat.approvals.first { store.resolveApproval(chat, id: approval.id, option: "allow") }
            if !chat.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Agent did not finish: \(chat.lastError ?? chat.state.rawValue)")
    }
    @MainActor func testHomeContextAndImageSurviveRestartAndReachFirstPrompt() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data"), audit = root.appendingPathComponent("audit.jsonl")
        let store = AppStore(directory: data)
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--attachments", "--audit-path=" + audit.path]
        await store.restore()
        store.newSessionDraft = NewSessionDraft(projectPath: root.path, text: "Read @Report")
        let file = root.appendingPathComponent("Report 界.txt"); try "Home immutable context".write(to: file, atomically: true, encoding: .utf8)
        let workspace = try Workspace(root: root.path)
        let candidates = try await workspace.contextCandidates(matching: "Report")
        let candidate = try XCTUnwrap(candidates.first { $0.kind == .file })
        let query = try XCTUnwrap(PromptCompletion.query(in: store.newSessionDraft.text, selection: NSRange(location: 12, length: 0)))
        let accepted = await store.attachHomeContext(candidate, replacing: query)
        XCTAssertTrue(accepted, store.error ?? "")
        store.attachHomeInputs([.image(png)])
        await store.homeAttachmentTask?.value
        XCTAssertEqual(store.newSessionDraft.attachments?.count, 2)
        XCTAssertEqual(store.newSessionDraft.text, "Read ")
        let attachments = try XCTUnwrap(store.newSessionDraft.attachments)
        try FileManager.default.removeItem(at: file)
        await store.shutdown()
        let restored = AppStore(directory: data); restored.settings = store.settings
        await restored.restore()
        XCTAssertEqual(restored.newSessionDraft.attachments, attachments)
        await restored.startFromHome()
        let chat = try XCTUnwrap(restored.selected)
        try await finish(chat, store: restored)
        XCTAssertEqual(chat.state, .ready, chat.lastError ?? "")
        XCTAssertEqual(chat.transcript.items.filter { $0.kind == "user" }.count, 1)
        XCTAssertEqual(chat.transcript.items.first?.promptAttachments, attachments)
        XCTAssertTrue(restored.newSessionDraft.text.isEmpty); XCTAssertNil(restored.newSessionDraft.attachments)
        let calls = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        let prompt = try XCTUnwrap(calls.last { $0["method"].string == "session/prompt" })["params"]["prompt"].array
        XCTAssertTrue(prompt.contains { $0["type"].string == "text" && $0["text"].string.contains("Home immutable context") })
        XCTAssertEqual(prompt.filter { $0["type"].string == "image" }.count, 1)
        await restored.shutdown()
    }
    @MainActor func testAttachmentOnlyHomeLaunchAndRejectedConfigurationKeepSnapshots() async throws {
        let root = try temporary()
        for rejected in [false, true] {
            let data = root.appendingPathComponent(rejected ? "rejected" : "accepted")
            let store = AppStore(directory: data)
            store.settings.executable = "/usr/bin/python3"
            store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--attachments", "--config"] + (rejected ? ["--reject-config"] : [])
            await store.restore()
            store.newSessionDraft = NewSessionDraft(projectPath: root.path)
            store.newSessionDraft.configuration = SessionConfiguration(executable: store.settings.executable, arguments: store.settings.arguments, values: ["mode": "plan"])
            store.attachHomeInputs([.image(png)]); await store.homeAttachmentTask?.value
            let attachments = try XCTUnwrap(store.newSessionDraft.attachments)
            await store.startFromHome()
            let chat = try XCTUnwrap(store.selected)
            try await finish(chat, store: store)
            if rejected {
                XCTAssertEqual(chat.state, .failed)
                XCTAssertEqual(chat.attachments, attachments); XCTAssertTrue(chat.transcript.items.isEmpty)
                await store.shutdown()
                let restored = AppStore(directory: data); restored.settings = store.settings
                await restored.restore()
                XCTAssertEqual(restored.selected?.attachments, attachments)
                await restored.shutdown()
            } else {
                XCTAssertEqual(chat.state, .ready, chat.lastError ?? "")
                XCTAssertEqual(chat.transcript.items.first?.promptAttachments, attachments)
                XCTAssertTrue(chat.attachments.isEmpty); await store.shutdown()
            }
        }
    }
    @MainActor func testHomeImageLoadingBlocksSendAndCancelsWithoutLosingDraft() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data"))
        await store.restore(); store.newSessionDraft = NewSessionDraft(projectPath: root.path, text: "Unsent")
        let waiting = NSItemProvider()
        waiting.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { _ in Progress(totalUnitCount: 1) }
        XCTAssertTrue(store.attachHomeProviders([waiting]))
        let operation = try XCTUnwrap(store.homeAttachmentTask)
        await store.startFromHome()
        XCTAssertNil(store.selected); XCTAssertTrue(store.sessions.isEmpty)
        store.cancelHomeAttachmentImports(); await operation.value
        XCTAssertFalse(store.homeAttachingFiles); XCTAssertNil(store.newSessionDraft.attachments)
        XCTAssertEqual(store.newSessionDraft.text, "Unsent")
        await store.shutdown()
    }
    @MainActor func testPublishedImportsDoNotDoubleCountTheirReservedSlot() async throws {
        let root = try temporary()
        for home in [false, true] {
            let store = AppStore(directory: root.appendingPathComponent(home ? "home" : "chat"))
            let queued = expectation(description: "Queue tenth image during publication")
            let input = AttachmentInput.image(png)
            if home {
                await store.restore()
                withObservationTracking { _ = store.newSessionDraft.attachments } onChange: {
                    Task { @MainActor in store.attachHomeInputs([input]); queued.fulfill() }
                }
                store.attachHomeInputs(Array(repeating: input, count: 9))
                let operation = try XCTUnwrap(store.homeAttachmentTask)
                await fulfillment(of: [queued], timeout: 5)
                await operation.value
                XCTAssertEqual(store.newSessionDraft.attachments?.count, 10, store.error ?? "")
            } else {
                await store.create(path: root.path, worktree: false)
                let chat = try XCTUnwrap(store.selected)
                withObservationTracking { _ = chat.attachments } onChange: {
                    Task { @MainActor in store.attachInputs([input], to: chat); queued.fulfill() }
                }
                store.attachInputs(Array(repeating: input, count: 9), to: chat)
                let operation = try XCTUnwrap(chat.attachmentTask)
                await fulfillment(of: [queued], timeout: 5)
                await operation.value
                XCTAssertEqual(chat.attachments.count, 10, store.error ?? "")
            }
            XCTAssertNil(store.error)
            await store.shutdown()
        }
    }
    @MainActor func testStopDuringHomeLaunchRetainsReservedAttachmentInBothDrafts() async throws {
        let root = try temporary(), data = root.appendingPathComponent("data"), store = AppStore(directory: data)
        _ = try await Repository.run(["init", "-b", "main"], at: root.path)
        try "tracked".write(to: root.appendingPathComponent("tracked"), atomically: true, encoding: .utf8)
        _ = try await Repository.run(["add", "tracked"], at: root.path)
        let hook = root.appendingPathComponent("slow-monitor")
        try "#!/bin/sh\nsleep 1\nprintf 'token\\0'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        _ = try await Repository.run(["config", "core.fsmonitor", hook.path], at: root.path)
        await store.restore(); store.newSessionDraft = NewSessionDraft(projectPath: root.path, text: "Cancelled launch")
        store.attachHomeInputs([.image(png)]); await store.homeAttachmentTask?.value
        let snapshots = try XCTUnwrap(store.newSessionDraft.attachments)
        let launch = Task { await store.startFromHome() }
        for _ in 0..<100 where store.selected == nil { try await Task.sleep(for: .milliseconds(10)) }
        let chat = try XCTUnwrap(store.selected)
        XCTAssertTrue(chat.launching); XCTAssertEqual(chat.attachments, snapshots)
        store.stop(chat); await launch.value
        XCTAssertEqual(chat.attachments, snapshots); XCTAssertTrue(chat.transcript.items.isEmpty)
        XCTAssertEqual(store.newSessionDraft.attachments, snapshots); XCTAssertEqual(store.newSessionDraft.text, "Cancelled launch")
        await store.shutdown()
        let restored = AppStore(directory: data); await restored.restore()
        XCTAssertEqual(restored.newSessionDraft.attachments, snapshots)
        XCTAssertEqual(restored.selected?.attachments, snapshots)
        await restored.shutdown()
    }
}
