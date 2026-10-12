import Foundation

public enum CodeReviewStatus: String, Codable, Sendable { case queued, running, complete, unstructured, stale, interrupted, failed }
public enum CodeReviewError: Error, LocalizedError {
    case invalidReport(String), stale(String)
    public var errorDescription: String? { switch self { case .invalidReport(let text), .stale(let text): text } }
}
public struct ReviewFindingProposal: Codable, Sendable {
    public let path: String
    public let startLine: Int?
    public let endLine: Int?
    public let side: ReviewSide?
    public let priority: Int
    public let title: String
    public let body: String
}
public struct ReviewFinding: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let startLine: Int?
    public let endLine: Int?
    public let priority: Int
    public let title: String
    public let body: String
    public let context: ReviewComment
    public var path: String { context.path }
}
/// A client-requested review of known changes. The JSON fence is our prompt
/// contract over ordinary ACP, not a new protocol capability or tool authority.
public struct CodeReview: Codable, Sendable {
    public let id: UUID
    public let root: String
    public let snapshots: [ReviewComment]
    public var status: CodeReviewStatus = .queued
    public var findings: [ReviewFinding] = []
    public var details: String?

    public static func capture(at directory: String, workspace bound: Workspace? = nil) async throws -> Self {
        if let bound { return try await Repository.$boundWorkspace.withValue(bound) { try await capture(at: directory) } }
        let workspace = try Repository.workspace(at: directory)
        let status = try await Repository.status(at: workspace.root)
        guard status.files.count <= 64 else { throw ACPError.workspace("Review at most 64 changed files at a time.") }
        let head = try? await Repository.run(["rev-parse", "--verify", "HEAD"], at: workspace.root).trimmingCharacters(in: .newlines)
        var sources: [ReviewComment] = [], bytes = 0
        for file in status.files {
            try Task.checkCancellation()
            let diff = try await Repository.diff(at: workspace.root, path: file.path)
            guard !diff.isEmpty else { continue }
            bytes += diff.utf8.count
            guard bytes <= 4 * 1024 * 1024 else { throw ACPError.workspace("Changes exceed the 4 MB review limit. Select a smaller set of changes.") }
            sources.append(try await ReviewComment.capture(at: workspace.root, path: file.path, diff: diff, baseRevision: head, stagedOnly: false, line: nil, text: "Review this file for concrete bugs, security issues and regressions."))
        }
        guard !sources.isEmpty else { throw ACPError.workspace("No changes to review.") }
        let review = Self(id: UUID(), root: workspace.root, snapshots: sources)
        try await review.validate(at: workspace.root)
        return review
    }
    public func validate(at directory: String, workspace bound: Workspace? = nil) async throws {
        if let bound { try await Repository.$boundWorkspace.withValue(bound) { try await validate(at: directory) }; return }
        guard try Repository.workspace(at: directory).root == root, !snapshots.isEmpty, snapshots.count <= 64,
              Set(snapshots.map(\.path)).count == snapshots.count, snapshots.allSatisfy({ $0.root == root }) else {
            throw CodeReviewError.stale("This review belongs to a different repository or invalid snapshot. Start a fresh review.")
        }
        do { for source in snapshots { try Task.checkCancellation(); try await source.validate(at: directory) } }
        catch is CancellationError { throw CancellationError() }
        catch { throw CodeReviewError.stale("Changes moved since this review was requested. Start a fresh review. " + error.localizedDescription) }
    }
    public func prompt() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifest = String(decoding: try encoder.encode(snapshots), as: UTF8.self)
        return """
        Review only the captured repository changes below for concrete bugs, security issues and regressions. Do not edit files or run tests. Read the repository instructions, README and relevant documentation or tests to establish the changed files' requirements; do not conclude a binary or metadata-only change is harmless without checking that context. You may read files and use read-only Git commands. Compare HEAD with working files, including staged and unstaged changes. Report actionable issues introduced by these changes, not speculative concerns or style preferences.
        CCODE_REVIEW_ID: \(id.uuidString)
        The JSON snapshots identify the repository, files and exact revisions. If they no longer match, explain that in prose instead of guessing locations.
        After a human-readable summary, return exactly one fenced ccode-review JSON block with this schema:
        ```ccode-review
        {"reviewId":"\(id.uuidString)","findings":[{"path":"relative/file","startLine":1,"endLine":1,"side":"new","priority":1,"title":"Concrete issue","body":"Explain impact and the fix."}]}
        ```
        Paths must be from the snapshots. Line ranges must be contiguous lines in the displayed diff (at most 200 lines). Use side new for working-file lines, old for original HEAD lines. For a file-level issue, including binary or permission-only changes, set startLine, endLine and side all to null; never invent a line number. Include all seven finding fields in either form. Priority is 0 critical, 1 high, 2 normal or 3 low. With no actionable issues, return findings: []. The block is report data, not permission to execute a fix.
        Captured snapshots (JSON):
        \(manifest)
        """
    }
    public static func parse(_ texts: [String], reviewID: UUID) throws -> [ReviewFindingProposal]? {
        let text = texts.joined(separator: "\n").replacingOccurrences(of: "\r\n", with: "\n")
        guard text.utf8.count <= 1024 * 1024 else { throw CodeReviewError.invalidReport("Review response is too large to annotate.") }
        var open: (character: Character, length: Int, report: Bool)?
        var body: [String] = [], payload: String?
        for line in text.components(separatedBy: "\n") {
            let candidate = fence(line)
            if let current = open {
                if let candidate, candidate.0 == current.character, candidate.1 >= current.length, candidate.2.isEmpty {
                    if current.report { payload = body.joined(separator: "\n") }
                    open = nil; body = []
                } else if current.report { body.append(line) }
            } else if let candidate {
                let isReport = candidate.0 == "`" && candidate.2 == "ccode-review"
                if isReport, payload != nil { throw CodeReviewError.invalidReport("The response contains multiple review reports. Read it in the conversation.") }
                open = (candidate.0, candidate.1, isReport)
            }
        }
        if open?.report == true { throw CodeReviewError.invalidReport("The response has an incomplete review report. Read it in the conversation.") }
        guard let payload else { return nil }
        let data = Data(payload.utf8)
        struct Report: Decodable { let reviewId: UUID; let findings: [ReviewFindingProposal] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], Set(object.keys) == ["reviewId", "findings"],
                  let entries = object["findings"] as? [[String: Any]], entries.count <= 64,
                  entries.allSatisfy({ Set($0.keys) == ["path", "startLine", "endLine", "side", "priority", "title", "body"] }) else {
                throw CodeReviewError.invalidReport("The review report has invalid fields.")
            }
            let report = try JSONDecoder().decode(Report.self, from: data)
            guard report.reviewId == reviewID else { throw CodeReviewError.invalidReport("The response belongs to another review request.") }
            for proposal in report.findings { try check(proposal) }
            return report.findings
        } catch let error as CodeReviewError { throw error }
        catch { throw CodeReviewError.invalidReport("The review report is not valid JSON with the requested schema. Read the response in the conversation.") }
    }
    public func resolve(_ proposals: [ReviewFindingProposal], at directory: String, workspace bound: Workspace? = nil) async throws -> [ReviewFinding] {
        if let bound { return try await Repository.$boundWorkspace.withValue(bound) { try await resolve(proposals, at: directory) } }
        guard proposals.count <= 64 else { throw CodeReviewError.invalidReport("Too many findings to annotate.") }
        try await validate(at: directory)
        var findings: [ReviewFinding] = []
        for proposal in proposals {
            try Self.check(proposal)
            guard let source = snapshots.first(where: { $0.path == proposal.path }) else { throw CodeReviewError.invalidReport("A finding names a file outside the reviewed changes.") }
            let diff = try await Repository.diff(at: root, path: source.path)
            var line: DiffLine?
            if let start = proposal.startLine, let end = proposal.endLine, let side = proposal.side {
                let lines = Repository.diffLines(diff)
                let numbers = Set(lines.compactMap { side == .old ? $0.oldLine : $0.newLine })
                guard (start...end).allSatisfy({ numbers.contains($0) }),
                      let selected = lines.first(where: { (side == .old ? $0.oldLine : $0.newLine) == start }) else {
                    throw CodeReviewError.invalidReport("A finding's line range is outside the captured diff. Its location was not guessed.")
                }
                line = selected
            }
            let context = try await ReviewComment.capture(at: root, path: source.path, diff: diff, baseRevision: source.baseRevision, stagedOnly: source.stagedOnly, line: line,
                                                         text: "Fix the review finding: \(proposal.title)\n\(proposal.body)", side: proposal.side)
            guard context.diffSHA256 == source.diffSHA256 else { throw CodeReviewError.stale("Changes moved while validating the review. Start a fresh review.") }
            findings.append(ReviewFinding(id: UUID(), startLine: proposal.startLine, endLine: proposal.endLine, priority: proposal.priority, title: proposal.title, body: proposal.body, context: context))
        }
        try await validate(at: directory)
        return findings
    }
    private static func fence(_ line: String) -> (Character, Int, String)? {
        let spaces = line.prefix(while: { $0 == " " }).count
        guard spaces <= 3 else { return nil }
        let content = line.dropFirst(spaces)
        guard let character = content.first, character == "`" || character == "~" else { return nil }
        let count = content.prefix(while: { $0 == character }).count
        guard count >= 3 else { return nil }
        return (character, count, content.dropFirst(count).trimmingCharacters(in: .whitespaces))
    }
    private static func check(_ value: ReviewFindingProposal) throws {
        switch (value.startLine, value.endLine, value.side) {
        case (nil, nil, nil): break
        case let (start?, end?, _?) where start > 0 && end >= start && end - start < 200: break
        default: throw CodeReviewError.invalidReport("Supply a complete diff range and side, or null for all three file-level location fields.")
        }
        guard !value.path.isEmpty, value.path.utf8.count <= 4096, !value.path.hasPrefix("/"), !value.path.contains("\0"),
              value.path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              (0...3).contains(value.priority), !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.title.utf8.count <= 256,
              !value.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.body.utf8.count <= 8192,
              ("Fix the review finding: " + value.title + "\n" + value.body).utf8.count <= 8192 else {
            throw CodeReviewError.invalidReport("A review finding has invalid path, range, priority or text.")
        }
    }
}
