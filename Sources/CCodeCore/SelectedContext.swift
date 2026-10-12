import Foundation
import CryptoKit

public struct SelectedContext: Sendable {
    public let context: PromptContext
    public let text: String
}

extension Workspace {
    public func selectedFileContext(path: String, text: String, range: NSRange) async throws -> SelectedContext {
        let url = try await scoped(path)
        guard text.utf8.count <= 10 * 1024 * 1024, range.length > 0, let selection = Range(range, in: text) else { throw ACPError.workspace("Select a valid code range before attaching it.") }
        let body = String(text[selection])
        let start = text[..<selection.lowerBound].filter { $0 == "\n" }.count + 1
        let end = start + body.dropLast().filter { $0 == "\n" }.count
        let root = roots.filter { url.path.hasPrefix($0 == "/" ? "/" : $0 + "/") }.max { $0.count < $1.count } ?? self.root
        return SelectedContext(context: PromptContext(root: root, path: url.path, kind: .selection, startLine: start, endLine: end, source: "editor buffer", revision: "sha256:" + contextHash(text)), text: body)
    }
    public func selectedDiffContext(path: String, diff: String, line: DiffLine, stagedOnly: Bool, baseRevision: String?) async throws -> SelectedContext {
        let url = try await scoped(path)
        // URL.standardizedFileURL rewrites /private/var to /var on macOS.
        // Normalize dot components without changing the selected link's identity.
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        let lexical = "/" + components.joined(separator: "/")
        guard diff.utf8.count <= 4 * 1024 * 1024, line.oldLine != nil || line.newLine != nil,
              let current = Repository.diffLines(diff).first(where: { $0.id == line.id }),
              current.text == line.text, current.oldLine == line.oldLine, current.newLine == line.newLine else { throw ACPError.workspace("The selected diff changed. Select the line again.") }
        guard let root = roots.filter({ lexical.hasPrefix($0 == "/" ? "/" : $0 + "/") }).max(by: { $0.count < $1.count }) else { throw ACPError.workspace("Select a diff from this workspace.") }
        let number = line.newLine ?? line.oldLine
        return SelectedContext(context: PromptContext(root: root, path: lexical, kind: .diff, startLine: number, endLine: number, source: line.source(stagedOnly: stagedOnly), revision: "HEAD:" + (baseRevision ?? "unborn") + "; diff-sha256:" + contextHash(diff), resolvedPath: url.path == lexical ? nil : url.path), text: line.text)
    }
}

private func contextHash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
