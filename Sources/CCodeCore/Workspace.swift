import Foundation
import Darwin

public actor Workspace {
    public nonisolated let root: String
    public nonisolated let roots: [String]
    public nonisolated let environment: ExecutionEnvironment
    public nonisolated let sshExecutable: String
    public nonisolated var repository: WorkspaceRepository { WorkspaceRepository(workspace: self) }
    public init(root: String, additionalDirectories: [String] = [], environment: ExecutionEnvironment = .local, sshExecutable: String = "/usr/bin/ssh") throws {
        self.environment = environment; self.sshExecutable = sshExecutable
        if !environment.isLocal {
            var paths: [String] = []
            for path in [root] + additionalDirectories {
                _ = try WorkspaceLocation(environment: environment, path: path)
                let normalized = Self.lexicalPath(path)
                if !paths.contains(normalized) { paths.append(normalized) }
            }
            self.root = paths[0]; roots = paths; return
        }
        var paths: [String] = []
        for path in [root] + additionalDirectories {
            guard path.hasPrefix("/") else { throw ACPError.workspace("Workspace folders must be absolute paths.") }
            let url = try canonicalURL(path)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw ACPError.workspace("Select an existing project folder: \(path)") }
            if !paths.contains(url.path) { paths.append(url.path) }
        }
        self.root = paths[0]; roots = paths
    }
    public nonisolated func filePath(_ file: String) -> String {
        file.hasPrefix("/") ? file : (environment.isLocal ? URL(fileURLWithPath: root).appendingPathComponent(file).path : (root == "/" ? "" : root) + "/" + file)
    }
    public func scoped(_ path: String) async throws -> URL {
        if environment.isLocal { return try scopedLocal(path) }
        let remote = try remoteWorkspace(for: path)
        return URL(fileURLWithPath: try await remote.resolve(path))
    }
    func scopedLocal(_ path: String) throws -> URL {
        guard environment.isLocal else { throw ACPError.workspace("Remote files cannot be opened on this Mac.") }
        guard path.hasPrefix("/") else { throw ACPError.workspace("Workspace paths must be absolute.") }
        let url = try canonicalURL(path)
        guard roots.contains(where: { url.path == $0 || url.path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else { throw ACPError.workspace("Path is outside the selected workspace: \(path)") }
        return url
    }

    public func read(_ path: String, line: Int? = nil, limit: Int? = nil) async throws -> String {
        if !environment.isLocal { return try await remoteWorkspace(for: path).read(path, line: line, limit: limit) }
        let url = try scopedLocal(path)
        guard (line ?? 1) >= 1, (limit ?? 0) >= 0 else { throw ACPError.workspace("Invalid file line range.") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10 * 1024 * 1024 else { throw ACPError.workspace("Text file exceeds the 10 MB editor limit.") }
        let text = try String(contentsOf: url, encoding: .utf8)
        if line == nil && limit == nil { return text }
        let lines = text.components(separatedBy: "\n")
        let start = min((line ?? 1) - 1, lines.count)
        let count = min(limit ?? lines.count, lines.count - start)
        return lines[start..<(start + count)].joined(separator: "\n")
    }

    public func write(_ path: String, content: String, expecting original: String? = nil) async throws {
        if !environment.isLocal { try await remoteWorkspace(for: path).write(path, content: content, expecting: original); return }
        let url = try scopedLocal(path)
        guard content.utf8.count <= 10 * 1024 * 1024 else { throw ACPError.workspace("Text exceeds the 10 MB editor limit.") }
        if let original {
            guard let current = try? String(contentsOf: url, encoding: .utf8), current == original else { throw ACPError.workspace("File changed on disk. Reload it before saving.") }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try scopedLocal(url.path)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    public func files(limit: Int = 3000) async throws -> [String] {
        if !environment.isLocal {
            guard limit > 0 else { return [] }
            var result: [String] = []
            for directory in roots {
                let entries = try await remoteWorkspace(for: directory).files(limit: min(limit, 3000))
                result += entries.map { directory == root ? $0 : (directory == "/" ? "" : directory) + "/" + $0 }
            }
            return Array(Set(result)).sorted().prefix(limit).map { $0 }
        }
        guard limit > 0 else { return [] }
        var paths: [String] = [], seen: Set<String> = []
        let ignored: Set<String> = [".git", ".build", "node_modules", ".swiftpm", "vendor", "dist"]
        let enumerators = roots.compactMap { FileManager.default.enumerator(at: URL(fileURLWithPath: $0), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsPackageDescendants]) }
        // Each pass takes one file per root so a large project cannot hide added folders.
        while paths.count < limit {
            let count = paths.count
            for enumerator in enumerators {
                while let url = enumerator.nextObject() as? URL {
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if ignored.contains(url.lastPathComponent) || values.isSymbolicLink == true {
                        if values.isDirectory == true { enumerator.skipDescendants() }
                        continue
                    }
                    if values.isDirectory != true, seen.insert(url.path).inserted {
                        paths.append(url.path.hasPrefix(root == "/" ? "/" : root + "/") ? String(url.path.dropFirst(root.count + (root == "/" ? 0 : 1))) : url.path)
                        break
                    }
                }
                if paths.count >= limit { break }
            }
            if paths.count == count { break }
        }
        return paths.sorted()
    }

    public nonisolated func remoteWorkspace(for path: String) throws -> RemoteWorkspace {
        guard case .ssh(let host) = environment else { throw ACPError.workspace("Select an SSH workspace.") }
        _ = try WorkspaceLocation(environment: environment, path: path)
        let normalized = Self.lexicalPath(path)
        guard let owner = roots.filter({ normalized == $0 || normalized.hasPrefix($0 == "/" ? "/" : $0 + "/") }).max(by: { $0.count < $1.count }) else { throw ACPError.workspace("Path is outside the remote workspace.") }
        return try RemoteWorkspace(root: owner, transport: SSHTransport(configuration: host, executable: sshExecutable))
    }
    public nonisolated static func lexicalPath(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

}

// realpath keeps /var and /private/var consistent and resolves existing symlink
// ancestors even when the leaf being written does not exist yet.
func canonicalURL(_ path: String) throws -> URL {
    var url = URL(fileURLWithPath: path).standardizedFileURL
    var suffix: [String] = []
    while true {
        var info = stat()
        if lstat(url.path, &info) == 0 { break }
        guard errno == ENOENT, url.path != "/" else { throw ACPError.workspace("Cannot resolve workspace path: \(path)") }
        suffix.append(url.lastPathComponent); url.deleteLastPathComponent()
    }
    guard let resolved = realpath(url.path, nil) else { throw ACPError.workspace("Cannot resolve workspace symlink: \(path)") }
    defer { free(resolved) }
    var result = URL(fileURLWithPath: String(cString: resolved))
    for component in suffix.reversed() { result.appendPathComponent(component) }
    return result
}
