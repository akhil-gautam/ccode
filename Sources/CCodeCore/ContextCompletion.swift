import Foundation

public struct PromptQuery: Equatable, Sendable {
    public enum Kind: Sendable { case context, command }
    public let kind: Kind
    public let filter: String
    public let range: NSRange
    public func removing(from text: String) -> String {
        guard let range = Range(range, in: text) else { return text }
        return text.replacingCharacters(in: range, with: "")
    }
    public func applyingCommand(_ name: String, to text: String) -> String {
        guard kind == .command, let range = Range(range, in: text) else { return text }
        let suffix = text[range.upperBound...]
        return text.replacingCharacters(in: range, with: "/" + name + (suffix.first?.isWhitespace == true ? "" : " "))
    }
}

public enum PromptCompletion {
    public static func query(in text: String, selection: NSRange) -> PromptQuery? {
        let source = text as NSString, caret = selection.location
        guard selection.length == 0, caret >= 0, caret <= source.length else { return nil }
        let prefix = source.substring(to: caret)
        if text.hasPrefix("/") {
            let token = text.prefix { !$0.isWhitespace }
            let length = (String(token) as NSString).length
            if caret >= 1, caret <= length {
                return PromptQuery(kind: .command, filter: String(prefix.dropFirst()), range: NSRange(location: 0, length: length))
            }
        }
        guard let marker = prefix.lastIndex(of: "@"), marker == prefix.startIndex || prefix[prefix.index(before: marker)].isWhitespace else { return nil }
        let filter = String(prefix[prefix.index(after: marker)...])
        guard !filter.contains("\n"), !filter.contains("\r"), filter.utf8.count <= 256 else { return nil }
        let start = (String(prefix[..<marker]) as NSString).length
        return PromptQuery(kind: .context, filter: filter, range: NSRange(location: start, length: caret - start))
    }
    public static func commands(matching filter: String, catalog: [JSONValue]) -> [JSONValue] {
        var seen: Set<String> = []
        return catalog.filter {
            let name = $0["name"].string
            return !name.isEmpty && !name.contains(where: \.isWhitespace) && seen.insert(name).inserted && name.localizedCaseInsensitiveContains(filter)
        }.sorted { $0["name"].string < $1["name"].string }
    }
}

public struct ContextCandidate: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, folder }
    public let root: String
    public let path: String
    public let kind: Kind
    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var relativePath: String { path == root ? "." : String(path.dropFirst(root.count + (root == "/" ? 0 : 1))) }
    public var label: String { URL(fileURLWithPath: root).lastPathComponent + "/" + relativePath + (kind == .folder ? "/" : "") }
}

public struct PromptContext: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, folder, selection, diff }
    public let root: String
    public let path: String
    public let kind: Kind
    public let startLine: Int?
    public let endLine: Int?
    public let source: String?
    public let revision: String?
    public let resolvedPath: String?
    public init(root: String, path: String, kind: Kind, startLine: Int? = nil, endLine: Int? = nil, source: String? = nil, revision: String? = nil, resolvedPath: String? = nil) {
        self.root = root; self.path = path; self.kind = kind; self.startLine = startLine; self.endLine = endLine; self.source = source; self.revision = revision; self.resolvedPath = resolvedPath
    }
}

extension Workspace {
    public func contextCandidates(matching filter: String, limit: Int = 40) async throws -> [ContextCandidate] {
        guard limit > 0 else { return [] }
        let words = filter.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).split(whereSeparator: \.isWhitespace)
        let entries = try await contextEntries()
        return entries.filter { entry in
            let path = entry.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return words.allSatisfy { path.contains($0) }
        }.sorted { left, right in
            let a = left.name.lowercased().hasPrefix(filter.lowercased()), b = right.name.lowercased().hasPrefix(filter.lowercased())
            if a != b { return a }
            if left.kind != right.kind { return left.kind == .folder }
            return left.label == right.label ? left.path < right.path : left.label.localizedStandardCompare(right.label) == .orderedAscending
        }.prefix(min(limit, 100)).map { $0 }
    }

    public func folderManifest(_ candidate: ContextCandidate) async throws -> String {
        let url = try await scoped(candidate.path)
        guard candidate.kind == .folder, roots.contains(candidate.root), url.path == candidate.path else { throw ACPError.workspace("Select a folder from this workspace.") }
        var directory: ObjCBool = false
        guard !environment.isLocal || FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue else { throw ACPError.workspace("The selected folder no longer exists.") }
        if !environment.isLocal { _ = try await remoteWorkspace(for: url.path).resolve(url.path, directory: true) }
        let files = try await contextEntries().filter { $0.kind == .file && ($0.path.hasPrefix(candidate.path == "/" ? "/" : candidate.path + "/")) }.sorted { $0.path < $1.path }
        var text = "Folder manifest: \(candidate.path)\nWorkspace root: \(candidate.root)\nThis is a directory listing, not the files' contents.\n"
        var count = 0
        for entry in files {
            let line = "- " + String(entry.path.dropFirst(candidate.path.count + (candidate.path == "/" ? 0 : 1))) + "\n"
            guard count < 256, text.utf8.count + line.utf8.count < 64000 else { break }
            text += line; count += 1
        }
        if count < files.count { text += "[Manifest truncated: showing \(count) of \(files.count) files. Search or attach individual files for more context.]\n" }
        if files.isEmpty { text += "[No visible files.]\n" }
        return text
    }

    private func contextEntries() async throws -> [ContextCandidate] {
        if !environment.isLocal {
            var result: [ContextCandidate] = [], seen: Set<String> = []
            for root in roots {
                result.append(ContextCandidate(root: root, path: root, kind: .folder)); seen.insert(root)
                for relative in try await remoteWorkspace(for: root).files() {
                    let path = (root == "/" ? "" : root) + "/" + relative
                    if seen.insert(path).inserted { result.append(ContextCandidate(root: root, path: path, kind: .file)) }
                    var components = relative.split(separator: "/"); components.removeLast()
                    while !components.isEmpty {
                        let folder = (root == "/" ? "" : root) + "/" + components.joined(separator: "/")
                        if seen.insert(folder).inserted { result.append(ContextCandidate(root: root, path: folder, kind: .folder)) }
                        components.removeLast()
                    }
                }
            }
            return result
        }
        let ignored: Set<String> = [".git", ".build", "node_modules", ".swiftpm", "vendor", "dist"]
        var entries: [ContextCandidate] = [], seen: Set<String> = []
        func add(_ url: URL, root: String) throws {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, values?.isDirectory == true || values?.isRegularFile == true,
                  let canonical = try? scopedLocal(url.path), canonical.path == url.path,
                  seen.insert(url.path).inserted else { return }
            entries.append(ContextCandidate(root: root, path: url.path, kind: values?.isDirectory == true ? .folder : .file))
            guard entries.count <= 100000 else { throw ACPError.workspace("Context search exceeds 100,000 workspace entries. Choose a smaller workspace.") }
        }
        for root in roots {
            try Task.checkCancellation()
            let base = URL(fileURLWithPath: root)
            try add(base, root: root)
            let isGit = (try? await Repository.run(["rev-parse", "--is-inside-work-tree"], at: root))?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
            if isGit {
                let output = try await Repository.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "."], at: root)
                for relative in output.split(separator: "\0") {
                    guard !relative.split(separator: "/").contains(where: { ignored.contains(String($0)) }) else { continue }
                    var url = base.appendingPathComponent(String(relative))
                    try add(url, root: root)
                    url.deleteLastPathComponent()
                    while url.path != root, url.path.hasPrefix(root == "/" ? "/" : root + "/") {
                        try add(url, root: root); url.deleteLastPathComponent()
                    }
                }
            } else if let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsPackageDescendants]) {
                var visited = 0
                while let url = enumerator.nextObject() as? URL {
                    try Task.checkCancellation(); visited += 1
                    guard visited <= 100000 else { throw ACPError.workspace("Context search exceeds 100,000 workspace entries. Choose a smaller workspace.") }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if ignored.contains(url.lastPathComponent) || values?.isSymbolicLink == true {
                        if values?.isDirectory == true { enumerator.skipDescendants() }
                    } else { try add(url, root: root) }
                }
            }
        }
        return entries
    }
}
