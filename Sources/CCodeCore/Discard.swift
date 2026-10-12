import Foundation
import CryptoKit
import Darwin

public enum DiscardScope: String, Codable, Sendable { case working, all }
public struct DiscardPreview: Sendable, Identifiable {
    public let id: UUID
    public let root: String
    public let paths: [String]
    public let selectedPaths: [String]
    public let scope: DiscardScope
    public let diff: String
    public var recoveryDirectory: String {
        URL(fileURLWithPath: indexPath).deletingLastPathComponent().appendingPathComponent("ccode-discard-" + id.uuidString).path
    }
    fileprivate let gitRoot: String
    fileprivate let prefix: String
    fileprivate let head: String?
    fileprivate let indexPath: String
    fileprivate let indexStamp: DiscardStamp
    fileprivate let files: [String: DiscardStamp]
}
public struct DiscardResult: Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case preparing, completed, partial, conflict, rejected, uncertain }
    public let id: UUID
    public let root: String
    public var paths: [String]
    public let scope: DiscardScope
    public var status: Status
    public var recoveryDirectory: String
    public var details: String?
    public var startedAt: Date?
    public init(preparing preview: DiscardPreview) {
        self.init(id: preview.id, root: preview.root, paths: preview.paths, scope: preview.scope, status: .preparing, recoveryDirectory: preview.recoveryDirectory, details: nil)
    }
    fileprivate init(id: UUID, root: String, paths: [String], scope: DiscardScope, status: Status, recoveryDirectory: String, details: String?) {
        self.id = id; self.root = root; self.paths = paths; self.scope = scope; self.status = status
        self.recoveryDirectory = recoveryDirectory; self.details = details; startedAt = Date()
    }
}

fileprivate struct DiscardStamp: Sendable, Equatable {
    let hash: String?
    let mode: mode_t
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    var exists: Bool { hash != nil }
    static let absent = Self(hash: nil, mode: 0, device: 0, inode: 0, size: 0, modifiedSeconds: 0, modifiedNanos: 0)
    static func read(_ path: String) throws -> Self {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return .absent }
            throw ACPError.workspace("Cannot inspect discard source: \(path)")
        }
        let kind = info.st_mode & S_IFMT
        var digest = SHA256()
        if kind == S_IFLNK {
            digest.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: path).utf8))
        } else if kind == S_IFREG {
            let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw ACPError.workspace("File changed while checking discard: \(path)") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev else { throw ACPError.workspace("File changed while checking discard: \(path)") }
            while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty { try Task.checkCancellation(); digest.update(data: data) }
            var after = stat()
            guard fstat(descriptor, &after) == 0, after.st_size == info.st_size, after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
                throw ACPError.workspace("File changed while checking discard: \(path)")
            }
        } else { throw ACPError.workspace("Discard supports individual files; directories and submodules need their own repository.") }
        return Self(hash: digest.finalize().map { String(format: "%02x", $0) }.joined(), mode: info.st_mode, device: info.st_dev, inode: info.st_ino, size: info.st_size, modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanos: info.st_mtimespec.tv_nsec)
    }
}

extension Repository {
    public static func discardRecoveryDirectory(_ result: DiscardResult, at directory: String) async throws -> URL {
        let root = try Workspace(root: directory).root
        guard result.root == root else { throw ACPError.workspace("Recovery belongs to a different workspace.") }
        let index = URL(fileURLWithPath: try await discardIndexPath(at: root))
        let expected = index.deletingLastPathComponent().appendingPathComponent("ccode-discard-" + result.id.uuidString, isDirectory: true)
        guard result.recoveryDirectory == expected.path else { throw ACPError.workspace("Recovery directory does not match this repository and operation.") }
        var folderInfo = stat()
        guard lstat(expected.path, &folderInfo) == 0, folderInfo.st_mode & S_IFMT == S_IFDIR,
              try canonicalURL(expected.path).path == expected.path else { throw ACPError.workspace("Recovery copies are missing or the directory was replaced.") }
        let file = expected.appendingPathComponent("manifest.json"), stamp = try DiscardStamp.read(file.path)
        guard stamp.mode & S_IFMT == S_IFREG, stamp.size <= 256 * 1024 else { throw ACPError.workspace("Recovery manifest is unavailable.") }
        let manifest = try JSONDecoder().decode(DiscardResult.self, from: Data(contentsOf: file))
        guard manifest.id == result.id, manifest.root == result.root, manifest.paths == result.paths,
              manifest.scope == result.scope, manifest.recoveryDirectory == result.recoveryDirectory else {
            throw ACPError.workspace("Recovery manifest does not match the recorded discard.")
        }
        return expected
    }
    public static func previewDiscard(at directory: String, paths selected: [String], scope: DiscardScope) async throws -> DiscardPreview {
        try Task.checkCancellation()
        let workspace = try Workspace(root: directory)
        guard !selected.isEmpty, selected.count <= 64, Set(selected).count == selected.count else { throw ACPError.workspace("Select between 1 and 64 changed files.") }
        let status = try await status(at: workspace.root)
        var paths = selected
        for path in selected {
            try discardPath(path)
            guard let file = status.files.first(where: { $0.path == path }), scope == .all || file.unstaged else { throw ACPError.workspace("No selected changes to discard: \(path)") }
            guard !file.status.contains("U"), !["AA", "DD"].contains(file.status) else { throw ACPError.workspace("Resolve merge conflicts before discarding this file.") }
            if scope == .all, let original = file.originalPath, !paths.contains(original) { try discardPath(original); paths.append(original) }
        }
        guard paths.count <= 64 else { throw ACPError.workspace("Select fewer files; renamed files include both paths.") }
        let gitRoot = try canonicalURL(try await run(["rev-parse", "--show-toplevel"], at: workspace.root).trimmingCharacters(in: .newlines)).path
        let prefix = try await run(["rev-parse", "--show-prefix"], at: workspace.root).trimmingCharacters(in: .newlines)
        let indexPath = try await discardIndexPath(at: workspace.root)
        let head = try? await run(["rev-parse", "--verify", "HEAD"], at: workspace.root).trimmingCharacters(in: .newlines)
        let indexStamp = try DiscardStamp.read(indexPath)
        var files: [String: DiscardStamp] = [:], diff = ""
        for path in paths {
            _ = try await workspace.scoped(workspace.filePath(path))
            files[path] = try DiscardStamp.read(workspace.filePath(path))
        }
        var base: [String] = []
        if scope == .all {
            if let head { base = [head] }
            else { base = [try await run(["hash-object", "-t", "tree", "/dev/null"], at: workspace.root).trimmingCharacters(in: .newlines)] }
        }
        diff = try await run(["diff", "--no-ext-diff", "--no-textconv", "--relative", "--full-index"] + base + ["--"] + paths, at: workspace.root)
        for path in paths where status.files.contains(where: { $0.path == path && $0.status == "??" }) {
            diff += try await run(["diff", "--no-ext-diff", "--no-textconv", "--full-index", "--no-index", "--", "/dev/null", workspace.filePath(path)], at: workspace.root, acceptDiff: true)
            guard diff.utf8.count <= 4 * 1024 * 1024 else { throw ACPError.workspace("Discard preview exceeds 4 MB. Select fewer files.") }
        }
        guard !diff.isEmpty else { throw ACPError.workspace("No content or metadata changes to discard.") }
        let preview = DiscardPreview(id: UUID(), root: workspace.root, paths: paths, selectedPaths: selected, scope: scope, diff: diff, gitRoot: gitRoot, prefix: prefix, head: head, indexPath: indexPath, indexStamp: indexStamp, files: files)
        try await validateDiscard(preview, at: directory)
        return preview
    }

    public static func discard(_ preview: DiscardPreview, at directory: String) async throws -> DiscardResult {
        try Task.checkCancellation()
        try await validateDiscard(preview, at: directory)
        let manager = FileManager.default
        let recovery = URL(fileURLWithPath: preview.indexPath).deletingLastPathComponent().appendingPathComponent("ccode-discard-" + preview.id.uuidString, isDirectory: true)
        guard !manager.fileExists(atPath: recovery.path) else { throw ACPError.workspace("This discard already has recovery data. Refresh its preview.") }
        try manager.createDirectory(at: recovery, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var touched = false, applied = 0
        let working = recovery.appendingPathComponent("working"), staged = recovery.appendingPathComponent("staged"), target = recovery.appendingPathComponent("target")
        let beforeIndex = recovery.appendingPathComponent("index.before"), nextIndex = recovery.appendingPathComponent("index.target")
        var lockDescriptor: Int32 = -1, ownsLock = false
        let lockPath = preview.indexPath + ".lock"
        defer {
            if lockDescriptor >= 0 { close(lockDescriptor) }
            if ownsLock { unlink(lockPath) }
        }
        do {
            for folder in [working, staged, target] { try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            let originalEnvironment: [String: String]
            if preview.indexStamp.exists {
                try manager.copyItem(atPath: preview.indexPath, toPath: beforeIndex.path)
                guard try DiscardStamp.read(beforeIndex.path).hash == preview.indexStamp.hash else { throw ACPError.workspace("Git index changed since the preview.") }
                try manager.copyItem(at: beforeIndex, to: nextIndex)
                originalEnvironment = ["GIT_INDEX_FILE": beforeIndex.path]
            } else {
                _ = try await run(["read-tree", "--empty"], at: preview.gitRoot, environment: ["GIT_INDEX_FILE": beforeIndex.path])
                try manager.copyItem(at: beforeIndex, to: nextIndex)
                originalEnvironment = ["GIT_INDEX_FILE": beforeIndex.path]
            }
            let repositoryPaths = preview.paths.map { preview.prefix + $0 }
            let stagedPaths = try await indexPaths(repositoryPaths, at: preview.gitRoot, environment: originalEnvironment)
            if !stagedPaths.isEmpty { _ = try await run(["checkout-index", "--prefix=" + staged.path + "/", "--"] + stagedPaths, at: preview.gitRoot, environment: originalEnvironment) }
            let environment = ["GIT_INDEX_FILE": nextIndex.path]
            if preview.scope == .all {
                if let head = preview.head {
                    let headPaths = try await run(["ls-tree", "-r", "--name-only", "-z", head, "--"] + repositoryPaths, at: preview.gitRoot).split(separator: "\0").map(String.init)
                    let known = repositoryPaths.filter { stagedPaths.contains($0) || headPaths.contains($0) }
                    if !known.isEmpty { _ = try await run(["restore", "--source=" + head, "--staged", "--"] + known, at: preview.gitRoot, environment: environment) }
                } else if !stagedPaths.isEmpty {
                    _ = try await run(["rm", "--cached", "-f", "--ignore-unmatch", "--"] + stagedPaths, at: preview.gitRoot, environment: environment)
                }
            }
            let targetPaths = try await indexPaths(repositoryPaths, at: preview.gitRoot, environment: environment)
            if !targetPaths.isEmpty { _ = try await run(["checkout-index", "--prefix=" + target.path + "/", "--"] + targetPaths, at: preview.gitRoot, environment: environment) }
            let workspace = try Workspace(root: preview.root)
            var targetStamps: [String: DiscardStamp] = [:]
            var recoveryInfo = stat(); guard lstat(recovery.path, &recoveryInfo) == 0 else { throw ACPError.workspace("Recovery directory became unavailable.") }
            for path in preview.paths {
                let source = workspace.filePath(path), output = target.appendingPathComponent(preview.prefix + path).path
                let device = try discardParentDevice(source)
                guard device == recoveryInfo.st_dev else { throw ACPError.workspace("Recovery and selected files must be on the same volume. No files were discarded.") }
                let stamp = try DiscardStamp.read(output); targetStamps[path] = stamp
                if stamp.mode & S_IFMT == S_IFLNK {
                    let destination = try manager.destinationOfSymbolicLink(atPath: output)
                    let candidate = destination.hasPrefix("/") ? destination : URL(fileURLWithPath: source).deletingLastPathComponent().appendingPathComponent(destination).path
                    _ = try await workspace.scoped(candidate)
                }
            }
            try Task.checkCancellation()
            lockDescriptor = open(lockPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard lockDescriptor >= 0 else { throw ACPError.workspace("Git is busy. Finish its current operation and refresh the discard preview.") }
            ownsLock = true
            try await validateDiscard(preview, at: directory)
            try discardManifest(preview, recovery: recovery, status: .partial, details: "Discard started. Inspect working and staged recovery copies if interrupted.")
            for path in preview.paths {
                try Task.checkCancellation()
                let source = workspace.filePath(path), backup = working.appendingPathComponent(preview.prefix + path)
                _ = try await workspace.scoped(source)
                guard try DiscardStamp.read(source) == preview.files[path] else { throw ACPError.workspace("File changed since the discard preview: \(path)") }
                if preview.files[path]?.exists == true {
                    try manager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try exclusiveMove(source, backup.path); touched = true
                    if try DiscardStamp.read(backup.path) != preview.files[path] {
                        try? exclusiveMove(backup.path, source)
                        throw ACPError.workspace("File changed while discarding: \(path). Recovery retained.")
                    }
                }
                if targetStamps[path]?.exists == true {
                    let parent = URL(fileURLWithPath: source).deletingLastPathComponent()
                    _ = try await workspace.scoped(parent.path)
                    if !manager.fileExists(atPath: parent.path) { try manager.createDirectory(at: parent, withIntermediateDirectories: true); touched = true }
                    _ = try await workspace.scoped(source)
                    try exclusiveMove(target.appendingPathComponent(preview.prefix + path).path, source)
                    touched = true
                    guard try DiscardStamp.read(source).hash == targetStamps[path]?.hash else { throw ACPError.workspace("File changed while restoring: \(path). Recovery retained.") }
                }
                applied += 1
            }
            try await validateDiscardGit(preview)
            if preview.scope == .all {
                let input = try FileHandle(forReadingFrom: nextIndex); defer { try? input.close() }
                let output = FileHandle(fileDescriptor: lockDescriptor, closeOnDealloc: false)
                while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
                try output.synchronize()
                try await validateDiscardGit(preview)
                guard rename(lockPath, preview.indexPath) == 0 else { throw ACPError.workspace("Cannot publish the restored Git index. Recovery retained.") }
                ownsLock = false
            }
            let result = DiscardResult(id: preview.id, root: preview.root, paths: preview.paths, scope: preview.scope, status: .completed, recoveryDirectory: recovery.path, details: nil)
            try discardManifest(preview, recovery: recovery, status: .completed, details: nil)
            return result
        } catch {
            if !touched {
                try? manager.removeItem(at: recovery)
                throw error
            }
            let status: DiscardResult.Status = applied > 0 ? .partial : .conflict
            let details = "Discard did not finish: " + error.localizedDescription + " Original working files and staged contents are retained in recovery. Inspect them before continuing."
            try? discardManifest(preview, recovery: recovery, status: status, details: details)
            return DiscardResult(id: preview.id, root: preview.root, paths: preview.paths, scope: preview.scope, status: status, recoveryDirectory: recovery.path, details: details)
        }
    }

    private static func indexPaths(_ paths: [String], at root: String, environment: [String: String]) async throws -> [String] {
        try await run(["ls-files", "-z", "--"] + paths, at: root, environment: environment).split(separator: "\0").map(String.init)
    }
    private static func validateDiscard(_ preview: DiscardPreview, at directory: String) async throws {
        try Task.checkCancellation()
        let workspace = try Workspace(root: directory)
        guard workspace.root == preview.root else { throw ACPError.workspace("Discard preview belongs to a different repository.") }
        try await validateDiscardGit(preview)
        for path in preview.paths {
            try discardPath(path)
            _ = try await workspace.scoped(workspace.filePath(path))
            guard try DiscardStamp.read(workspace.filePath(path)) == preview.files[path] else { throw ACPError.workspace("File changed since the discard preview: \(path). Refresh it before discarding.") }
        }
    }
    private static func validateDiscardGit(_ preview: DiscardPreview) async throws {
        try Task.checkCancellation()
        let head = try? await run(["rev-parse", "--verify", "HEAD"], at: preview.root).trimmingCharacters(in: .newlines)
        let index = try await discardIndexPath(at: preview.root)
        guard index == preview.indexPath, head == preview.head, try DiscardStamp.read(index) == preview.indexStamp else { throw ACPError.workspace("Git state changed since the discard preview. Refresh before discarding.") }
    }
    private static func discardPath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096,
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else { throw ACPError.workspace("Select a relative file inside this workspace.") }
    }
    private static func discardIndexPath(at root: String) async throws -> String {
        let reported = try await run(["rev-parse", "--path-format=absolute", "--git-path", "index"], at: root).trimmingCharacters(in: .newlines)
        // --git-path resolves a leaf symlink; inspect the repository's index
        // entry itself before trusting the resolved path.
        let gitDirectory = try await run(["rev-parse", "--absolute-git-dir"], at: root).trimmingCharacters(in: .newlines)
        let entry = URL(fileURLWithPath: gitDirectory).appendingPathComponent("index").path
        var info = stat()
        if lstat(entry, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw ACPError.workspace("Git index must be a regular file, without a symbolic link.") }
        } else if errno != ENOENT { throw ACPError.workspace("Git index is unavailable.") }
        let canonical = try canonicalURL(entry).path
        guard try canonicalURL(reported).path == canonical else { throw ACPError.workspace("Discard requires this repository’s own Git index.") }
        return canonical
    }
    private static func discardParentDevice(_ source: String) throws -> dev_t {
        var parent = URL(fileURLWithPath: source).deletingLastPathComponent()
        while true {
            var info = stat()
            if stat(parent.path, &info) == 0 { return info.st_dev }
            guard errno == ENOENT, parent.path != "/" else { throw ACPError.workspace("Selected file's parent is unavailable.") }
            parent.deleteLastPathComponent()
        }
    }
    private static func exclusiveMove(_ source: String, _ target: String) throws {
        guard renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 else { throw ACPError.workspace("File changed or could not be moved: \(target). Existing files were preserved.") }
    }
    private static func discardManifest(_ preview: DiscardPreview, recovery: URL, status: DiscardResult.Status, details: String?) throws {
        let result = DiscardResult(id: preview.id, root: preview.root, paths: preview.paths, scope: preview.scope, status: status, recoveryDirectory: recovery.path, details: details)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: recovery.appendingPathComponent("manifest.json"), options: .atomic)
        try Data(preview.diff.utf8).write(to: recovery.appendingPathComponent("preview.diff"), options: .atomic)
    }
}
