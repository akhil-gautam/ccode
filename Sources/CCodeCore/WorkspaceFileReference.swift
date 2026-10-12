import Foundation

public struct WorkspaceFileReference: Equatable, Sendable {
    public let root: String
    public let path: String
    public let isDirectory: Bool
    public let line: Int?
    public let column: Int?
    public let endLine: Int?
    public var candidate: ContextCandidate { ContextCandidate(root: root, path: path, kind: isDirectory ? .folder : .file) }
    public func selection(in text: String) throws -> NSRange {
        guard !isDirectory else { throw ACPError.workspace("Select a text file to open in the editor.") }
        guard let line else { return NSRange(location: 0, length: 0) }
        let source = text as NSString
        func bounds(_ requested: Int) throws -> (Int, Int) {
            guard requested > 0 else { throw ACPError.workspace("File line must be positive.") }
            var position = 0
            for number in 1...requested {
                var start = 0, end = 0, contentsEnd = 0
                source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
                if number == requested { return (start, contentsEnd) }
                guard end > position, end < source.length || contentsEnd < end else { throw ACPError.workspace("This line does not exist in the current editor contents.") }
                position = end
            }
            throw ACPError.workspace("Invalid file line.")
        }
        let (start, finish) = try bounds(line)
        if let column {
            guard column > 0, column - 1 <= finish - start else { throw ACPError.workspace("This column does not exist in the current editor contents.") }
            let range = NSRange(location: start + column - 1, length: 0)
            if range.location > 0, range.location < source.length,
               (0xD800...0xDBFF).contains(source.character(at: range.location - 1)),
               (0xDC00...0xDFFF).contains(source.character(at: range.location)) { throw ACPError.workspace("File column splits a text character.") }
            return range
        }
        let end = try endLine.map { try bounds($0).1 } ?? finish
        guard end >= start else { throw ACPError.workspace("File line range is reversed.") }
        return NSRange(location: start, length: end - start)
    }
}

extension Workspace {
    public func fileReference(_ raw: String, line: Int? = nil) async throws -> WorkspaceFileReference {
        guard !raw.isEmpty, raw.utf8.count <= 8192, !raw.contains("\0"), line == nil || line! > 0 else { throw ACPError.workspace("Invalid file reference.") }
        if !environment.isLocal { return try await remoteFileReference(raw, line: line) }
        var path = raw, fragment: String?
        if raw.lowercased().hasPrefix("file:") {
            guard let url = URLComponents(string: raw), url.scheme?.lowercased() == "file", url.user == nil, url.password == nil,
                  url.port == nil, url.query == nil, ["", "localhost"].contains(url.host?.lowercased() ?? ""), url.path.hasPrefix("/") else { throw ACPError.workspace("Only local file links are supported.") }
            path = url.path; fragment = url.fragment
        } else if !raw.hasPrefix("/"), raw.contains("://") { throw ACPError.workspace("This is not a workspace file link.") }
        var locationLine = line, column: Int?, endLine: Int?
        // Existing literal Unix filenames take precedence over trailing location syntax.
        if fragment == nil, !FileManager.default.fileExists(atPath: filePath(path)) {
            if let hash = path.lastIndex(of: "#") { fragment = String(path[path.index(after: hash)...]); path = String(path[..<hash]) }
            else if let match = Self.locationMatch(#"^(.*?):([0-9]+)(?::([0-9]+))?$"#, in: path) {
                path = match[0]; locationLine = try Self.positiveLocation(match[1]); column = match.count > 2 && !match[2].isEmpty ? try Self.positiveLocation(match[2]) : nil
            }
        }
        if let fragment {
            guard let match = Self.locationMatch(#"^L([0-9]+)(?:C([0-9]+)|-L([0-9]+))?$"#, in: fragment) else { throw ACPError.workspace("Unsupported file location. Use #L2, #L2C3 or #L2-L4.") }
            locationLine = try Self.positiveLocation(match[0])
            if match.count > 1, !match[1].isEmpty { column = try Self.positiveLocation(match[1]) }
            if match.count > 2, !match[2].isEmpty { endLine = try Self.positiveLocation(match[2]) }
        }
        if let line { locationLine = line }
        guard !path.isEmpty, !path.contains("\0") else { throw ACPError.workspace("Invalid local file path.") }
        guard endLine == nil || endLine! >= (locationLine ?? 1) else { throw ACPError.workspace("File line range is reversed.") }
        let url = try await scoped(filePath(path)), values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        guard values.isDirectory == true || values.isRegularFile == true else { throw ACPError.workspace("Select an existing regular file or folder.") }
        guard let owner = roots.filter({ url.path == $0 || url.path.hasPrefix($0 == "/" ? "/" : $0 + "/") }).max(by: { $0.count < $1.count }) else { throw ACPError.workspace("File is outside the session workspace.") }
        guard values.isDirectory != true || locationLine == nil else { throw ACPError.workspace("A folder cannot have a file line location.") }
        return WorkspaceFileReference(root: owner, path: url.path, isDirectory: values.isDirectory == true, line: locationLine, column: column, endLine: endLine)
    }

    private func remoteFileReference(_ raw: String, line: Int?) async throws -> WorkspaceFileReference {
        guard !raw.contains("://"), !raw.lowercased().hasPrefix("file:") else { throw ACPError.workspace("Use a remote workspace path, not a local file URL.") }
        var path = raw, locationLine = line, column: Int?, endLine: Int?
        // Resolve a literal filename first; suffix syntax is used only if absent.
        if (try? await remoteWorkspace(for: filePath(raw)).metadata(filePath(raw))) == nil {
            if let hash = path.lastIndex(of: "#") {
                let fragment = String(path[path.index(after: hash)...]); path = String(path[..<hash])
                guard let match = Self.locationMatch(#"^L([0-9]+)(?:C([0-9]+)|-L([0-9]+))?$"#, in: fragment) else { throw ACPError.workspace("Unsupported file location.") }
                locationLine = try Self.positiveLocation(match[0])
                if !match[1].isEmpty { column = try Self.positiveLocation(match[1]) }
                if !match[2].isEmpty { endLine = try Self.positiveLocation(match[2]) }
            } else if let match = Self.locationMatch(#"^(.*?):([0-9]+)(?::([0-9]+))?$"#, in: path) {
                path = match[0]; locationLine = try Self.positiveLocation(match[1]); column = match[2].isEmpty ? nil : try Self.positiveLocation(match[2])
            }
        }
        if let line { locationLine = line }
        let remote = try remoteWorkspace(for: filePath(path)), metadata = try await remote.metadata(filePath(path))
        guard !metadata.isDirectory || locationLine == nil, endLine == nil || endLine! >= (locationLine ?? 1) else { throw ACPError.workspace("Invalid file line range.") }
        return WorkspaceFileReference(root: remote.root, path: metadata.path, isDirectory: metadata.isDirectory, line: locationLine, column: column, endLine: endLine)
    }

    private nonisolated static func positiveLocation(_ value: String) throws -> Int {
        guard let number = Int(value), number > 0, number <= 10 * 1024 * 1024 else { throw ACPError.workspace("Invalid file line or column.") }
        return number
    }
    private nonisolated static func locationMatch(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern), let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).map { index in Range(match.range(at: index), in: value).map { String(value[$0]) } ?? "" }
    }
}
