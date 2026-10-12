import Foundation

public struct FileChangeStatistics: Sendable, Equatable {
    public let additions: Int?
    public let deletions: Int?
    public var isBinary: Bool { additions == nil || deletions == nil }
    public init(additions: Int?, deletions: Int?) { self.additions = additions; self.deletions = deletions }
}

extension Repository {
    public static func changeStatistics(at directory: String, stagedOnly: Bool = false) async throws -> [String: FileChangeStatistics] {
        try Task.checkCancellation()
        let before = try await status(at: directory)
        let files = before.files.filter { !stagedOnly || $0.staged }
        guard files.count <= 4096 else { throw ACPError.workspace("Too many changed files to count. Select a smaller repository.") }
        guard !files.contains(where: { $0.status.contains("U") || ["AA", "DD"].contains($0.status) }) else {
            throw ACPError.workspace("Resolve merge conflicts before counting changes.")
        }
        let head = try? await run(["rev-parse", "--verify", "HEAD"], at: directory).trimmingCharacters(in: .newlines)
        let base: [String]
        if stagedOnly { base = ["--cached"] }
        else if let head { base = [head] }
        else { base = [try await run(["hash-object", "-t", "tree", "/dev/null"], at: directory).trimmingCharacters(in: .newlines)] }
        let flags = ["diff", "--no-ext-diff", "--no-textconv", "--relative", "--numstat", "-z"]
        let raw = try await run(flags + base + ["--", "."], at: directory)
        let tracked = try numstat(raw)
        var results: [String: FileChangeStatistics] = [:]
        let workspace = try workspace(at: directory)
        for file in files {
            try Task.checkCancellation()
            if file.status == "??", !stagedOnly {
                _ = try await workspace.scoped(workspace.filePath(file.path))
                let output = try await run(["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", "--no-index", "--", "/dev/null", workspace.filePath(file.path)], at: directory, acceptDiff: true)
                let values = try numstat(output)
                guard values.count <= 1 else { throw ACPError.workspace("File changed while counting: \(file.path)") }
                results[file.path] = values.values.first ?? FileChangeStatistics(additions: 0, deletions: 0)
            } else {
                var value = tracked[file.path] ?? FileChangeStatistics(additions: 0, deletions: 0)
                // Git can detect an index rename while the combined working
                // diff sees separate deletion/addition after substantial edits.
                if let original = file.originalPath, let old = tracked[original] {
                    if value.isBinary || old.isBinary { value = FileChangeStatistics(additions: nil, deletions: nil) }
                    else { value = FileChangeStatistics(additions: value.additions! + old.additions!, deletions: value.deletions! + old.deletions!) }
                }
                results[file.path] = value
            }
        }
        let after = try await status(at: directory)
        let afterHead = try? await run(["rev-parse", "--verify", "HEAD"], at: directory).trimmingCharacters(in: .newlines)
        guard !Task.isCancelled, before.files == after.files, head == afterHead else {
            throw ACPError.workspace("Repository changed while counting. Refresh changes.")
        }
        return results
    }

    // -z retains literal tabs/newlines in filenames. Rename records contain
    // an empty path followed by original and destination NUL fields.
    private static func numstat(_ text: String) throws -> [String: FileChangeStatistics] {
        guard !text.isEmpty else { return [:] }
        guard text.hasSuffix("\0") else { throw ACPError.workspace("Incomplete Git change counts.") }
        var fields = text.components(separatedBy: "\0"); fields.removeLast()
        var result: [String: FileChangeStatistics] = [:], index = 0
        while index < fields.count {
            let row = fields[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false); index += 1
            guard row.count == 3 else { throw ACPError.workspace("Invalid Git change counts.") }
            let value: FileChangeStatistics
            if row[0] == "-", row[1] == "-" { value = FileChangeStatistics(additions: nil, deletions: nil) }
            else {
                guard let added = Int(row[0]), let removed = Int(row[1]), added >= 0, removed >= 0 else { throw ACPError.workspace("Invalid Git change counts.") }
                value = FileChangeStatistics(additions: added, deletions: removed)
            }
            var path = String(row[2])
            if path.isEmpty {
                guard index + 1 < fields.count, !fields[index].isEmpty else { throw ACPError.workspace("Incomplete Git rename counts.") }
                path = fields[index + 1]; index += 2
            }
            guard !path.isEmpty, result[path] == nil else { throw ACPError.workspace("Ambiguous Git change counts.") }
            result[path] = value
        }
        return result
    }
}
