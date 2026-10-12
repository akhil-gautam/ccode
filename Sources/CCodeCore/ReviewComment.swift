import Foundation
import CryptoKit

public enum ReviewSide: String, Codable, Sendable { case old, new }

/// User feedback bound to the exact repository and displayed diff. This is
/// captured review context, not a file mutation or a reusable agent capability.
public struct ReviewComment: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let root: String
    public let path: String
    public let resolvedPath: String
    public let stagedOnly: Bool
    public let baseRevision: String?
    public let diffSHA256: String
    public let oldLine: Int?
    public let newLine: Int?
    public let selectedText: String?
    public let side: ReviewSide?
    public var text: String
    public var source: String { side == .old || selectedText != nil && newLine == nil ? "original HEAD" : stagedOnly ? "staged index" : "working file" }
    public var lineNumber: Int? { side == .old ? oldLine : newLine ?? oldLine }
    public func matchesDisplayed(root: String, path: String, diff: String, baseRevision: String?, stagedOnly: Bool) -> Bool {
        self.root == root && self.path == path && self.baseRevision == baseRevision && self.stagedOnly == stagedOnly && self.diffSHA256 == Self.hash(diff)
    }

    public func updatingText(_ text: String) throws -> Self {
        var updated = self
        updated.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try updated.checkShape()
        return updated
    }

    public static func capture(at directory: String, path: String, diff: String, baseRevision: String?, stagedOnly: Bool, line: DiffLine?, text: String, side: ReviewSide? = nil, workspace bound: Workspace? = nil) async throws -> Self {
        if let bound { return try await Repository.$boundWorkspace.withValue(bound) { try await capture(at: directory, path: path, diff: diff, baseRevision: baseRevision, stagedOnly: stagedOnly, line: line, text: text, side: side) } }
        let workspace = try Repository.workspace(at: directory)
        try validPath(path)
        let resolved = try await workspace.scoped(workspace.filePath(path))
        guard !diff.isEmpty, diff.utf8.count <= 4 * 1024 * 1024 else { throw ACPError.workspace("Load a changed file before adding feedback.") }
        if let line {
            guard line.oldLine != nil || line.newLine != nil,
                  Repository.diffLines(diff).contains(where: { $0.id == line.id && $0.text == line.text && $0.oldLine == line.oldLine && $0.newLine == line.newLine }) else {
                throw ACPError.workspace("The selected diff line changed. Select it again.")
            }
        }
        let comment = Self(id: UUID(), root: workspace.root, path: path, resolvedPath: resolved.path, stagedOnly: stagedOnly, baseRevision: baseRevision, diffSHA256: hash(diff), oldLine: line?.oldLine, newLine: line?.newLine, selectedText: line?.text, side: side, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        try comment.checkShape()
        try await comment.validate(at: directory)
        return comment
    }
    public func validate(at directory: String, workspace bound: Workspace? = nil) async throws {
        if let bound { try await Repository.$boundWorkspace.withValue(bound) { try await validate(at: directory) }; return }
        try checkShape()
        let workspace = try Repository.workspace(at: directory)
        guard workspace.root == root, try await workspace.scoped(workspace.filePath(path)).path == resolvedPath else {
            throw ACPError.workspace("Feedback belongs to a different repository or file. Review it before sending.")
        }
        let before = await Self.head(root)
        let diff = try await Repository.diff(at: root, path: path, stagedOnly: stagedOnly)
        let after = await Self.head(root)
        guard before == baseRevision, after == baseRevision, Self.hash(diff) == diffSHA256 else {
            throw ACPError.workspace("The diff for \(path) changed. Your feedback was kept; refresh and review it before submitting.")
        }
        if let selectedText {
            guard Repository.diffLines(diff).contains(where: { $0.text == selectedText && $0.oldLine == oldLine && $0.newLine == newLine }) else {
                throw ACPError.workspace("The commented line changed. Your feedback was kept.")
            }
        }
    }
    public static func prompt(_ comments: [Self]) throws -> String {
        guard !comments.isEmpty, comments.count <= 64, Set(comments.map(\.id)).count == comments.count else { throw ACPError.workspace("Submit between 1 and 64 review comments.") }
        for comment in comments { try comment.checkShape() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Source names accompany actual line numbers; a removed line refers to
        // HEAD, never the same line number in the working file.
        var entries: [JSONValue] = []
        for comment in comments {
            let encoded = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(comment))
            var entry = encoded; entry["source"] = .string(comment.source); entries.append(entry)
        }
        let body = JSONValue.array(entries).pretty
        return "Apply the following review feedback as one batch. Each entry names its repository, file, source and captured revision. Confirm the current code before changing it; if the source no longer matches, explain the conflict rather than guessing line locations. Make the requested fixes and run relevant tests.\n\nReview comments (JSON):\n" + body
    }
    private func checkShape() throws {
        try Self.validPath(path)
        guard side == nil || selectedText != nil && (side == .old ? oldLine != nil : newLine != nil) else { throw ACPError.workspace("The selected review side has no line.") }
        guard root.hasPrefix("/"), resolvedPath.hasPrefix(root == "/" ? "/" : root + "/"),
              !root.contains("\0"), !resolvedPath.contains("\0"), root.utf8.count <= 4096, resolvedPath.utf8.count <= 8192,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 8192,
              diffSHA256.count == 64, diffSHA256.allSatisfy({ $0.isHexDigit }),
              baseRevision == nil || baseRevision!.count <= 128,
              oldLine == nil || oldLine! > 0, newLine == nil || newLine! > 0,
              selectedText == nil ? oldLine == nil && newLine == nil : (oldLine != nil || newLine != nil) && selectedText!.utf8.count <= 4 * 1024 * 1024 else {
            throw ACPError.workspace("Invalid or oversized review feedback.")
        }
    }
    private static func validPath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096,
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ACPError.workspace("Select a file within this repository for feedback.")
        }
    }
    private static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func head(_ root: String) async -> String? { try? await Repository.run(["rev-parse", "--verify", "HEAD"], at: root).trimmingCharacters(in: .newlines) }
}
