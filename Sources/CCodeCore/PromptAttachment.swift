import Foundation
import Darwin
import UniformTypeIdentifiers
import ImageIO
import AppKit
import PDFKit

public struct PromptAttachment: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let url: URL
    public let mimeType: String
    public let byteCount: Int
    public let promptBytes: Int
    public var context: PromptContext?
    public static let promptLimit = 6 * 1024 * 1024
    public static let countLimit = 10
}

extension SessionStorage {
    public func importWorkspaceContext(_ candidate: ContextCandidate, workspace: Workspace) async throws -> PromptAttachment {
        guard workspace.roots.contains(candidate.root) else { throw ACPError.workspace("Context belongs to a different workspace.") }
        let url = try await workspace.scoped(candidate.path)
        guard url.path == candidate.path else { throw ACPError.workspace("The selected context path changed. Search again.") }
        let metadata = PromptContext(root: candidate.root, path: url.path, kind: candidate.kind == .folder ? .folder : .file)
        var attachment: PromptAttachment
        if candidate.kind == .folder {
            let text = try await workspace.folderManifest(candidate), bytes = Data(text.utf8)
            let charge = bytes.reduce(1024) { sum, byte in sum + ([8, 9, 10, 12, 13, 34, 47, 92].contains(byte) ? 2 : byte < 32 ? 6 : 1) }
            attachment = PromptAttachment(id: UUID(), url: url, mimeType: "text/plain", byteCount: bytes.count, promptBytes: charge, context: metadata)
            let target = attachmentURL(attachment)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Task.checkCancellation(); try bytes.write(to: target, options: .atomic)
        } else {
            if workspace.environment.isLocal { attachment = try importAttachment(url) }
            else {
                let bytes = try await workspace.remoteWorkspace(for: candidate.path).download(candidate.path)
                let source = URL(string: "ssh://workspace/" + candidate.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!
                attachment = try importAttachmentBytes(bytes, source: source)
            }
            attachment.context = metadata
        }
        do {
            try Task.checkCancellation()
            guard try await workspace.scoped(candidate.path).path == candidate.path else { throw ACPError.workspace("The selected context path changed. Search again.") }
        } catch { try? discardAttachment(attachment); throw error }
        return attachment
    }
    public func importSelectedContext(_ snapshot: SelectedContext) throws -> PromptAttachment {
        let bytes = Data(snapshot.text.utf8)
        guard bytes.count < 5 * 1024 * 1024 else { throw ACPError.workspace("Select less than 5 MB of context.") }
        let charge = bytes.reduce(1024) { sum, byte in sum + ([8, 9, 10, 12, 13, 34, 47, 92].contains(byte) ? 2 : byte < 32 ? 6 : 1) }
        guard charge < PromptAttachment.promptLimit else { throw ACPError.workspace("Prompt attachment limit is 6 MB / 10 files.") }
        let attachment = PromptAttachment(id: UUID(), url: URL(fileURLWithPath: snapshot.context.path), mimeType: "text/plain", byteCount: bytes.count, promptBytes: charge, context: snapshot.context)
        let target = attachmentURL(attachment)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation(); try bytes.write(to: target, options: .atomic)
        return attachment
    }
    public nonisolated func attachmentURL(_ attachment: PromptAttachment) -> URL {
        let suffix = UTType(mimeType: attachment.mimeType)?.preferredFilenameExtension ?? "txt"
        return directory.appendingPathComponent("attachments", isDirectory: true).appendingPathComponent(attachment.id.uuidString).appendingPathExtension(suffix)
    }
    public func importAttachment(_ url: URL) throws -> PromptAttachment {
        try importAttachmentBytes(attachmentBytes(at: url), source: url)
    }
    private func importAttachmentBytes(_ bytes: Data, source url: URL) throws -> PromptAttachment {
        guard bytes.count < 5 * 1024 * 1024 else { throw ACPError.workspace("Attachments must be smaller than 5 MB.") }
        let mime: String, charge: Int
        if bytes.starts(with: Data("%PDF-".utf8)) {
            mime = "application/pdf"; charge = bytes.count
        } else if let source = CGImageSourceCreateWithData(bytes as CFData, nil), let type = CGImageSourceGetType(source), let value = UTType(type as String)?.preferredMIMEType {
            guard ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(value) else { throw ACPError.workspace("Use a PNG, JPEG, GIF or WebP image.") }
            mime = value; charge = ((bytes.count + 2) / 3) * 4 + 1024
        } else if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio), let value = type.preferredMIMEType {
            mime = value; charge = ((bytes.count + 2) / 3) * 4 + 1024
        } else {
            guard let text = String(data: bytes, encoding: .utf8) else { throw ACPError.workspace("This file is not supported. Attach text, images, PDF or audio.") }
            mime = "text/plain"
            // Count JSON escapes before encoding so highly escaped text cannot allocate a huge frame.
            charge = text.utf8.reduce(1024) { sum, byte in sum + ([8, 9, 10, 12, 13, 34, 47, 92].contains(byte) ? 2 : byte < 32 ? 6 : 1) }
        }
        guard charge < PromptAttachment.promptLimit else { throw ACPError.workspace("Prompt attachment limit is 6 MB / 10 files.") }
        let attachment = PromptAttachment(id: UUID(), url: url, mimeType: mime, byteCount: bytes.count, promptBytes: charge)
        let target = attachmentURL(attachment)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try bytes.write(to: target, options: .atomic)
        return attachment
    }
    public func discardAttachment(_ attachment: PromptAttachment) throws {
        let url = attachmentURL(attachment)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func attachmentPrompt(_ attachment: PromptAttachment, capabilities: JSONValue) async throws -> [JSONValue] {
        if attachment.mimeType == "application/pdf" || attachment.mimeType.hasPrefix("image/") {
            guard capabilities["image"].bool else { throw ACPError.workspace("This agent does not support image or PDF attachments.") }
        }
        if attachment.mimeType.hasPrefix("audio/") {
            guard capabilities["audio"].bool else { throw ACPError.workspace("This agent does not support audio attachments. The attachment stays in your draft.") }
        }
        let bytes = try attachmentBytes(at: attachmentURL(attachment))
        guard bytes.count == attachment.byteCount else { throw ACPError.workspace("The saved attachment is damaged. Remove it and attach the file again.") }
        let prepare = Task.detached(priority: .userInitiated) { try makeAttachmentPrompt(attachment, bytes: bytes) }
        return try await withTaskCancellationHandler { try await prepare.value } onCancel: { prepare.cancel() }
    }
}

func attachmentBytes(at url: URL) throws -> Data {
    try Task.checkCancellation()
    guard url.isFileURL else { throw ACPError.workspace("Attach a local file.") }
    let path = try canonicalURL(url.path).path
    let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
    guard descriptor >= 0 else { throw ACPError.workspace("Could not open attachment: \(url.lastPathComponent)") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ACPError.workspace("Attach a regular file.") }
    let limit = 5 * 1024 * 1024
    guard info.st_size < limit else { throw ACPError.workspace("Attachments must be smaller than 5 MB.") }
    var bytes = Data()
    while bytes.count < limit {
        try Task.checkCancellation()
        guard let chunk = try handle.read(upToCount: min(64 * 1024, limit - bytes.count)), !chunk.isEmpty else { return bytes }
        bytes.append(chunk)
    }
    throw ACPError.workspace("Attachments must be smaller than 5 MB.")
}

private func makeAttachmentPrompt(_ attachment: PromptAttachment, bytes: Data) throws -> [JSONValue] {
    try Task.checkCancellation()
    var blocks: [JSONValue] = []
    if attachment.mimeType == "application/pdf" {
        guard let document = PDFDocument(data: bytes), !document.isLocked, document.pageCount > 0 else { throw ACPError.workspace("Open and unlock this PDF before attaching it.") }
        blocks.append(["type": "text", "text": .string("PDF: \(attachment.url.lastPathComponent) (\(document.pageCount) pages). The following images contain every page in order.")])
        var total = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let image: JSONValue = try autoreleasepool {
                guard let page = document.page(at: index)?.pageRef else { throw ACPError.workspace("Could not read PDF page \(index + 1).") }
                let box = page.getBoxRect(.mediaBox)
                guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { throw ACPError.workspace("Invalid PDF page dimensions.") }
                let rotated = page.rotationAngle % 180 != 0
                let scale = 1600 / max(box.width, box.height)
                let width = max(1, Int((rotated ? box.height : box.width) * scale)), height = max(1, Int((rotated ? box.width : box.height) * scale))
                guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ACPError.workspace("Could not render PDF page.") }
                let rect = CGRect(x: 0, y: 0, width: width, height: height)
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
                context.concatenate(page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true)); context.drawPDFPage(page)
                guard let image = context.makeImage(), let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { throw ACPError.workspace("Could not encode PDF page.") }
                return ["type": "image", "mimeType": "image/jpeg", "data": .string(jpeg.base64EncodedString())]
            }
            total += try JSONEncoder().encode(image).count
            guard total < PromptAttachment.promptLimit else { throw ACPError.workspace("Rendered PDF exceeds the 6 MB prompt limit. Attach a smaller document; no pages were submitted.") }
            blocks.append(image)
        }
    } else if attachment.mimeType.hasPrefix("image/") || attachment.mimeType.hasPrefix("audio/") {
        blocks = [["type": .string(attachment.mimeType.hasPrefix("image/") ? "image" : "audio"), "mimeType": .string(attachment.mimeType), "data": .string(bytes.base64EncodedString())]]
    } else {
        guard let text = String(data: bytes, encoding: .utf8) else { throw ACPError.workspace("The saved text attachment is damaged.") }
        blocks = [["type": "text", "text": .string("File: \(attachment.url.lastPathComponent)\n\(text)")]]
    }
    if let context = attachment.context {
        var identity = "Attached \(context.kind.rawValue) context\nWorkspace root: \(context.root)\nPath: \(context.path)\n"
        if let start = context.startLine, let end = context.endLine { identity += "Lines: \(start)–\(end)\n" }
        if let source = context.source { identity += "Source: \(source)\n" }
        if let revision = context.revision { identity += "Revision: \(revision)\n" }
        if let resolved = context.resolvedPath { identity += "Resolved path: \(resolved)\n" }
        if attachment.mimeType == "text/plain" { blocks[0]["text"] = .string(identity + blocks[0]["text"].string) }
        else { blocks.insert(["type": "text", "text": .string(identity)], at: 0) }
    }
    guard try JSONEncoder().encode(blocks).count < PromptAttachment.promptLimit else { throw ACPError.workspace("Prompt attachment limit is 6 MB / 10 files.") }
    return blocks
}
