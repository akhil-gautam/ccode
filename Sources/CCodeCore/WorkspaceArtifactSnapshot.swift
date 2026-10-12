import Foundation

// Quick Look only accepts local URLs. Remote bytes live in a bounded, owned
// temporary copy, never in a URL pointing at the Mac's matching remote path.
public final class WorkspaceArtifactSnapshot: Sendable {
    public let url: URL
    private let ownedDirectory: URL?
    fileprivate init(url: URL, ownedDirectory: URL? = nil) { self.url = url; self.ownedDirectory = ownedDirectory }
    deinit { if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) } }
}

extension Workspace {
    public func artifactSnapshot(_ path: String) async throws -> WorkspaceArtifactSnapshot {
        let scoped = try await scoped(path)
        guard !environment.isLocal else { return WorkspaceArtifactSnapshot(url: scoped) }
        let bytes = try await remoteWorkspace(for: scoped.path).download(scoped.path)
        try Task.checkCancellation()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-artifact-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let local = folder.appendingPathComponent(scoped.lastPathComponent)
            try bytes.write(to: local, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: local.path)
            try Task.checkCancellation()
            return WorkspaceArtifactSnapshot(url: local, ownedDirectory: folder)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
}
