import Foundation
import Darwin

public struct TranscriptExportResult: Sendable {
    public let document: URL
    public let assetsDirectory: URL?
}

extension SessionStorage {
    /// Export the captured conversation and its typed snapshots. Imported resource
    /// references and ephemeral task-output paths never authorize additional reads.
    public func exportTranscript(_ transcript: SessionTranscript, title: String, to destination: URL) throws -> TranscriptExportResult {
        guard destination.isFileURL else { throw ACPError.workspace("Export to a local Markdown file.") }
        let children = try TranscriptExport.children(transcript)
        let sections = [transcript] + children.map(\.transcript)
        var attachments: [UUID: PromptAttachment] = [:]
        for section in sections {
            for item in section.items {
                for attachment in item.promptAttachments ?? [] {
                    if let previous = attachments[attachment.id], previous != attachment { throw ACPError.workspace("Conflicting attachment snapshots in this conversation.") }
                    attachments[attachment.id] = attachment
                }
            }
        }
        let parent = destination.deletingLastPathComponent(), token = UUID().uuidString
        let assets = attachments.isEmpty ? nil : parent.appendingPathComponent(destination.deletingPathExtension().lastPathComponent + ".assets-" + token)
        let temporary = parent.appendingPathComponent(".ccode-export-" + token)
        var published = false, ownsAssets = false, ownsTemporary = false
        defer {
            if ownsTemporary { try? FileManager.default.removeItem(at: temporary) }
            if !published, ownsAssets, let assets { try? FileManager.default.removeItem(at: assets) }
        }
        var links: [UUID: String] = [:]
        if let assets {
            guard mkdir(assets.path, 0o700) == 0 else { throw ACPError.workspace("Could not create the export's attachment folder.") }
            ownsAssets = true
            for attachment in attachments.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                try Task.checkCancellation()
                let source = attachmentURL(attachment)
                let folder = try source.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey])
                var before = stat(), after = stat()
                guard folder.isSymbolicLink != true, lstat(source.path, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ACPError.workspace("A saved attachment snapshot is missing or linked.") }
                let bytes = try attachmentBytes(at: source)
                guard bytes.count == attachment.byteCount, lstat(source.path, &after) == 0,
                      before.st_ino == after.st_ino, before.st_dev == after.st_dev, after.st_mode & S_IFMT == S_IFREG else { throw ACPError.workspace("A saved attachment changed while exporting.") }
                let target = assets.appendingPathComponent(source.lastPathComponent)
                try bytes.write(to: target, options: .atomic)
                let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?()[]"))
                links[attachment.id] = (assets.lastPathComponent + "/" + target.lastPathComponent).addingPercentEncoding(withAllowedCharacters: allowed)
            }
        }
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ACPError.workspace("Could not create the export file.") }
        ownsTemporary = true
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        try TranscriptExport.write(transcript, children: children, title: title, links: links) { text in
            try Task.checkCancellation(); try file.write(contentsOf: Data(text.utf8))
        }
        try file.synchronize(); try file.close(); try Task.checkCancellation()
        guard rename(temporary.path, destination.path) == 0 else { throw ACPError.workspace("Could not save the exported conversation: \(String(cString: strerror(errno)))") }
        published = true
        return TranscriptExportResult(document: destination, assetsDirectory: assets)
    }
}

private enum TranscriptExport {
    static func children(_ transcript: SessionTranscript) throws -> [SubagentSession] {
        var result: [SubagentSession] = [], ids = Set<String>()
        func collect(_ children: [SubagentSession], depth: Int) throws {
            guard depth <= 16 else { throw ACPError.workspace("Subagent history is too deeply nested to export.") }
            for child in children {
                guard result.count < 256, !child.id.isEmpty, child.id != transcript.remoteID,
                      ids.insert(child.id).inserted else { throw ACPError.workspace("Ambiguous subagent identity in this conversation.") }
                result.append(child)
                if let nested = child.transcript.subagents, !nested.isEmpty { try collect(nested, depth: depth + 1) }
            }
        }
        try collect(transcript.subagents ?? [], depth: 1)
        let parents = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.parentID) })
        for child in result {
            var parent = child.parentID, lineage = Set([child.id])
            while parent != transcript.remoteID {
                guard lineage.count <= 16, lineage.insert(parent).inserted, let next = parents[parent] else { throw ACPError.workspace("Incomplete or cyclic subagent history in this conversation.") }
                parent = next
            }
        }
        return result
    }
    static func write(_ transcript: SessionTranscript, children: [SubagentSession], title: String, links: [UUID: String], emit: (String) throws -> Void) throws {
        try emit("# " + label(title) + "\n\n")
        if let id = transcript.remoteID { try emit("Session: \(label(id))\n\n") }
        let anchors = Dictionary(uniqueKeysWithValues: children.enumerated().map { ($0.element.id, "subagent-\($0.offset + 1)") })
        func section(_ section: SessionTranscript, heading: String) throws {
            for item in section.items {
                switch item.kind {
                case "subagent":
                    let id = item.tool["subagentSessionId"].string
                    guard let anchor = anchors[id], let child = children.first(where: { $0.id == id }) else { throw ACPError.workspace("A subagent reference has no captured transcript.") }
                    try emit("[Subagent: \(label(child.name))](#\(anchor))\n\n")
                case "async_task":
                    try emit("\(heading) Background task\n\n" + fence(item.tool.pretty, language: "json"))
                case "tool":
                    try emit("\(heading) Tool: \(label(item.tool["title"].optionalString ?? "Tool call"))\n\n" + fence(item.tool.pretty, language: "json"))
                default:
                    let name = item.kind == "assistant" ? "Claude" : item.kind == "thought" ? "Thinking" : item.kind.capitalized
                    try emit("\(heading) \(label(name))\n\n")
                    if !item.text.isEmpty { try emit(item.text + "\n\n") }
                    if item.tool != JSONValue.object([:]) { try emit(fence(item.tool.pretty, language: "json")) }
                }
                if let delivery = item.deliveryState { try emit("Delivery: \(delivery.rawValue)\n\n") }
                for attachment in item.promptAttachments ?? [] {
                    guard let link = links[attachment.id] else { throw ACPError.workspace("Attachment snapshot was not exported.") }
                    try emit((attachment.mimeType.hasPrefix("image/") ? "!" : "") + "[\(label(attachment.url.lastPathComponent))](\(link))\n\n")
                    if let context = attachment.context { try emit(fence(try json(context), language: "json")) }
                }
                // Retain imported/context blocks as captured data, never follow them.
                if !item.blocks.isEmpty { try emit(fence(JSONValue.array(item.blocks).pretty, language: "json")) }
            }
            if !section.plan.isEmpty { try emit("\(heading) Plan\n\n" + fence(JSONValue.array(section.plan).pretty, language: "json")) }
            if section.usage != JSONValue.object([:]) { try emit("\(heading) Usage\n\n" + fence(section.usage.pretty, language: "json")) }
            for task in section.asyncTasks ?? [] { try emit("\(heading) Background task: \(label(task.name))\n\n" + fence(try json(task), language: "json")) }
        }
        try section(transcript, heading: "##")
        if !(transcript.asyncTasks ?? []).isEmpty { try emit("Background task entries contain recorded metadata; external output files are not copied.\n\n") }
        for child in children {
            try emit("<a id=\"\(anchors[child.id]!)\"></a>\n\n## Subagent: \(label(child.name))\n\n")
            try emit("State: \(label(child.state))\n\n")
            try emit("Session: \(label(child.id))\n\n")
            if let parent = anchors[child.parentID] { try emit("[Parent subagent](#\(parent))\n\n") }
            if !child.task.isEmpty { try emit(child.task + "\n\n") }
            if let prompt = child.prompt { try emit("### Delegation prompt\n\n" + prompt + "\n\n") }
            try section(child.transcript, heading: "###")
        }
    }
    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    private static func label(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    private static func fence(_ text: String, language: String) -> String {
        let lines: [Substring] = text.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = lines.map { $0.prefix(while: { $0 == "`" }).count }.max() ?? 0
        let delimiter = String(repeating: "`", count: max(3, longest + 1))
        return delimiter + language + "\n" + text + "\n" + delimiter + "\n\n"
    }
}
