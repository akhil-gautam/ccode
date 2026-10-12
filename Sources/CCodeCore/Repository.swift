import Foundation

public struct ChangedFile: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let indexStatus: String
    public let worktreeStatus: String
    public let originalPath: String?
    public var status: String { (indexStatus + worktreeStatus).trimmingCharacters(in: .whitespaces) }
    public var staged: Bool { indexStatus != " " && indexStatus != "?" }
    public var unstaged: Bool { worktreeStatus != " " }
}
public struct RepositoryStatus: Sendable {
    public var branch: String
    public var files: [ChangedFile]
    public init(branch: String = "", files: [ChangedFile] = []) { self.branch = branch; self.files = files }
}

public struct DiffLine: Identifiable, Sendable {
    public let id: Int
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?
    public var added: Bool { newLine != nil && oldLine == nil }
    public var removed: Bool { oldLine != nil && newLine == nil }
    public func source(stagedOnly: Bool) -> String { newLine == nil ? "original HEAD" : stagedOnly ? "staged index" : "working file" }
}

public enum Repository {
    @TaskLocal public static var boundWorkspace: Workspace?
    public static func workspace(at directory: String) throws -> Workspace {
        if let boundWorkspace {
            guard boundWorkspace.environment.isLocal || (try? boundWorkspace.remoteWorkspace(for: directory)) != nil else { throw ACPError.workspace("Repository is outside the SSH workspace.") }
            return try Workspace(root: directory, environment: boundWorkspace.environment, sshExecutable: boundWorkspace.sshExecutable)
        }
        return try Workspace(root: directory)
    }
    public static func diffLines(_ text: String) -> [DiffLine] {
        var old = 0, new = 0, inHunk = false
        return text.components(separatedBy: "\n").enumerated().map { index, line in
            var oldLine: Int?, newLine: Int?
            if line.hasPrefix("diff --git ") { inHunk = false }
            if line.hasPrefix("@@ ") {
                let ranges = line.split(separator: " ")
                if ranges.count >= 4, ranges[1].hasPrefix("-"), ranges[2].hasPrefix("+"),
                   let aText = ranges[1].dropFirst().split(separator: ",").first,
                   let bText = ranges[2].dropFirst().split(separator: ",").first,
                   let a = Int(aText), let b = Int(bText), a >= 0, b >= 0 {
                    old = a; new = b; inHunk = true
                } else { inHunk = false }
            } else if inHunk {
                if line.hasPrefix("-") { oldLine = old; old += 1 }
                else if line.hasPrefix("+") { newLine = new; new += 1 }
                else if line.hasPrefix(" ") { oldLine = old; newLine = new; old += 1; new += 1 }
            }
            return DiffLine(id: index, text: line, oldLine: oldLine, newLine: newLine)
        }
    }
    public static func run(_ arguments: [String], at directory: String, acceptDiff: Bool = false, environment: [String: String] = [:]) async throws -> String {
        if let workspace = boundWorkspace, !workspace.environment.isLocal {
            guard environment.isEmpty else { throw ACPError.workspace("Local Git environment cannot be forwarded to SSH.") }
            let remote = try workspace.remoteWorkspace(for: directory)
            let mutating = ["add", "reset", "rm", "commit", "branch", "switch", "checkout", "restore", "worktree", "update-index"].contains(arguments.first ?? "") && !(arguments.first == "branch" && arguments.contains("--show-current"))
            return try await remote.git(arguments, directory: directory, mutation: mutating, acceptDiff: acceptDiff)
        }
        let terminals = TerminalService()
        do {
            // git diff refreshes cached stat entries independently of optional locks.
            // Read-only refreshes must not invalidate a revision-bound preview.
            let id = try await terminals.create(command: "/usr/bin/git", arguments: ["--literal-pathspecs", "--no-optional-locks", "-c", "diff.autoRefreshIndex=false"] + arguments, directory: directory, environment: environment, byteLimit: 4 * 1024 * 1024)
            let status = try await terminals.wait(id)
            let result = try await terminals.output(id)
            await terminals.close()
            guard status["signal"].isNull, status["exitCode"].int == 0 || (acceptDiff && status["exitCode"].int == 1) else { throw ACPError.workspace(result["output"].string.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard !result["truncated"].bool else { throw ACPError.workspace("Git output exceeds 4 MB. Select a smaller diff.") }
            return result["output"].string
        } catch { await terminals.close(); throw error }
    }

    public static func status(at directory: String) async throws -> RepositoryStatus {
        async let branch = run(["symbolic-ref", "--short", "HEAD"], at: directory)
        async let prefixValue = run(["rev-parse", "--show-prefix"], at: directory)
        let raw = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], at: directory)
        let prefixOutput = try await prefixValue
        let prefix = prefixOutput.hasSuffix("\n") ? String(prefixOutput.dropLast()) : prefixOutput
        let entries = raw.split(separator: "\0", omittingEmptySubsequences: true)
        var files: [ChangedFile] = [], index = 0
        while index < entries.count {
            let row = String(entries[index]); index += 1
            guard row.count >= 4 else { continue }
            let flag = String(row.prefix(2)), path = String(row.dropFirst(3))
            let renamed = flag.contains("R") || flag.contains("C")
            let original = renamed && index < entries.count ? String(entries[index]) : nil
            if renamed { index += 1 }
            guard path.hasPrefix(prefix), path != prefix else { continue }
            let originalPath = original.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : String(repeating: "../", count: prefix.split(separator: "/").count) + $0 }
            files.append(ChangedFile(path: String(path.dropFirst(prefix.count)), indexStatus: String(flag.prefix(1)), worktreeStatus: String(flag.suffix(1)), originalPath: originalPath))
        }
        let name = (try? await branch)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Detached HEAD"
        return RepositoryStatus(branch: name, files: files)
    }

    public static func diff(at directory: String, path: String? = nil, stagedOnly: Bool = false) async throws -> String {
        let hasHead = (try? await run(["rev-parse", "--verify", "HEAD"], at: directory)) != nil
        let suffix = ["--"] + (path.map { [$0] } ?? ["."])
        if let path {
            let workspace = try workspace(at: directory)
            let file = try await workspace.scoped(URL(fileURLWithPath: directory).appendingPathComponent(path).path)
            let tracked = try await run(["ls-files"] + (hasHead ? ["--with-tree=HEAD"] : []) + ["--", path], at: directory)
            if tracked.isEmpty, !stagedOnly {
                return try await run(["diff", "--no-ext-diff", "--no-textconv", "--no-index", "--", "/dev/null", file.path], at: directory, acceptDiff: true)
            }
        }
        let flags = ["diff", "--no-ext-diff", "--no-textconv", "--relative"]
        if stagedOnly { return try await run(flags + ["--cached"] + suffix, at: directory) }
        if hasHead {
            return try await run(flags + ["HEAD"] + suffix, at: directory)
        }
        // An unborn branch has an empty original tree. Concatenating index and
        // working diffs repeats staged content and gives conflicting line bases.
        // hash-object without -w is read-only and respects the repository's hash
        // format; Git recognizes the empty tree without writing a commit/object.
        let emptyTree = try await run(["hash-object", "-t", "tree", "/dev/null"], at: directory).trimmingCharacters(in: .newlines)
        return try await run(flags + [emptyTree] + suffix, at: directory)
    }

    public static func branches(at directory: String) async throws -> [String] {
        let output = try await run(["for-each-ref", "--format=%(refname:short)%09%(symref)", "refs/heads", "refs/remotes"], at: directory)
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            return parts.count == 2 && parts[1].isEmpty ? String(parts[0]) : nil
        }
    }
    private static func branchReference(_ branch: String, at directory: String) async throws -> String {
        guard try await branches(at: directory).contains(branch) else { throw ACPError.workspace("The selected branch is no longer available. Choose an existing branch.") }
        return try await run(["rev-parse", "--symbolic-full-name", "--verify", "--end-of-options", branch], at: directory).trimmingCharacters(in: .newlines)
    }
    public static func createBranch(at directory: String, name: String, from branch: String? = nil) async throws {
        try Task.checkCancellation()
        guard !name.isEmpty, !name.hasPrefix("-"), name == name.trimmingCharacters(in: .whitespacesAndNewlines) else { throw ACPError.workspace("Enter a valid Git branch name.") }
        _ = try await run(["check-ref-format", "refs/heads/" + name], at: directory)
        let ref: String
        if let branch { ref = try await branchReference(branch, at: directory) }
        else { ref = try await run(["rev-parse", "--verify", "HEAD^{commit}"], at: directory).trimmingCharacters(in: .newlines) }
        _ = try await run(["branch", "--", name, ref], at: directory)
    }
    public static func switchBranch(at directory: String, branch: String) async throws {
        let ref = try await branchReference(branch, at: directory)
        if (try? await run(["symbolic-ref", "HEAD"], at: directory).trimmingCharacters(in: .newlines)) == ref { return }
        if ref.hasPrefix("refs/heads/") {
            _ = try await run(["switch", "--no-guess", "--", String(ref.dropFirst("refs/heads/".count))], at: directory)
        } else if ref.hasPrefix("refs/remotes/") {
            let local = ref.dropFirst("refs/remotes/".count).split(separator: "/").dropFirst().joined(separator: "/")
            _ = try await run(["switch", "--track", "-c", local, "--", ref], at: directory)
        } else { throw ACPError.workspace("Choose a local or remote branch.") }
    }
    public static func createWorktree(at directory: String, name: String, branch: String? = nil, storageDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ccode/worktrees", isDirectory: true)) async throws -> String {
        guard !name.isEmpty, name.count <= 64, name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }), !name.hasPrefix("-") else { throw ACPError.workspace("Worktree name must contain only letters, numbers and hyphens.") }
        let ref: String
        if let branch { ref = try await branchReference(branch, at: directory) } else { ref = "HEAD" }
        let repo = try await run(["rev-parse", "--show-toplevel"], at: directory).trimmingCharacters(in: .whitespacesAndNewlines)
        let source = try Workspace(root: repo).root
        let base = try canonicalURL(storageDirectory.path)
        guard base.path != source, !base.path.hasPrefix(source == "/" ? "/" : source + "/") else { throw ACPError.workspace("Worktree storage must be outside the project repository.") }
        let path = base.appendingPathComponent(name).path
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let workspace = try Workspace(root: base.path)
        _ = try await workspace.scoped(path)
        guard !FileManager.default.fileExists(atPath: path) else { throw ACPError.workspace("Worktree destination already exists.") }
        do {
            _ = try await run(["worktree", "add", "-b", "ccode/\(name)", "--", path, ref], at: repo)
            return path
        } catch {
            let cleanupError = await Task.detached { () -> String? in
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                do { try await removeWorktree(at: repo, path: path, expectedBranch: "ccode/" + name); return nil }
                catch { return error.localizedDescription }
            }.value
            if let cleanupError { throw ACPError.workspace("Worktree preserved at \(path): \(cleanupError)") }
            throw error
        }
    }
    public static func removeWorktree(at directory: String, path: String, expectedBranch: String) async throws {
        let branch = try await run(["symbolic-ref", "--short", "HEAD"], at: path).trimmingCharacters(in: .newlines)
        guard branch == expectedBranch else { throw ACPError.workspace("The worktree branch changed; its files were preserved.") }
        // ponytail: retain branch refs; prune unchanged owned refs if cancelled launches accumulate.
        _ = try await run(["worktree", "remove", "--", path], at: directory)
    }

    public static func stage(at directory: String, path: String) async throws {
        try await validatePaths([path], at: directory)
        _ = try await run(["add", "--", path], at: directory)
    }
    public static func unstage(at directory: String, path: String, originalPath: String? = nil) async throws {
        let paths = [path] + (originalPath.map { [$0] } ?? [])
        try await validatePaths(paths, at: directory)
        if (try? await run(["rev-parse", "--verify", "HEAD"], at: directory)) != nil {
            _ = try await run(["reset", "--quiet", "HEAD", "--"] + paths, at: directory)
        } else {
            _ = try await run(["rm", "--cached", "-f", "--ignore-unmatch", "--"] + paths, at: directory)
        }
    }
    public static func commit(at directory: String, message: String) async throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ACPError.workspace("Enter a commit message.") }
        // ponytail: commit the whole index from its root; subset commits need a temporary index.
        let prefix = try await run(["rev-parse", "--show-prefix"], at: directory)
        guard prefix.trimmingCharacters(in: .newlines).isEmpty else { throw ACPError.workspace("Open the repository root to review and commit all staged files.") }
        _ = try await run(["commit", "-m", message], at: directory)
    }
    private static func validatePaths(_ paths: [String], at directory: String) async throws {
        let workspace = try workspace(at: directory)
        for path in paths {
            guard !path.isEmpty, !path.hasPrefix("/") else { throw ACPError.workspace("Select a relative repository file path.") }
            _ = try await workspace.scoped(URL(fileURLWithPath: directory).appendingPathComponent(path).path)
        }
    }
}
