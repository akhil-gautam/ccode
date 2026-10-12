import Foundation

// A task-local binding keeps recursive Git reads on the captured workspace.
// Callers hold this facade rather than passing a remote path to local Git.
public struct WorkspaceRepository: Sendable {
    public let workspace: Workspace
    public func run(_ arguments: [String], at directory: String, acceptDiff: Bool = false) async throws -> String {
        try await Repository.$boundWorkspace.withValue(workspace) { try await Repository.run(arguments, at: directory, acceptDiff: acceptDiff) }
    }
    public func status(at directory: String) async throws -> RepositoryStatus {
        try await Repository.$boundWorkspace.withValue(workspace) { try await Repository.status(at: directory) }
    }
    public func diff(at directory: String, path: String? = nil, stagedOnly: Bool = false) async throws -> String {
        try await Repository.$boundWorkspace.withValue(workspace) { try await Repository.diff(at: directory, path: path, stagedOnly: stagedOnly) }
    }
    public func branches(at directory: String) async throws -> [String] {
        try await Repository.$boundWorkspace.withValue(workspace) { try await Repository.branches(at: directory) }
    }
    public func stage(at directory: String, path: String) async throws {
        try await Repository.$boundWorkspace.withValue(workspace) { try await Repository.stage(at: directory, path: path) }
    }
    public func unstage(at directory: String, path: String, originalPath: String? = nil) async throws {
        try await Repository.$boundWorkspace.withValue(workspace) { try await Repository.unstage(at: directory, path: path, originalPath: originalPath) }
    }
    public func createBranch(at directory: String, name: String, from branch: String? = nil) async throws {
        try await Repository.$boundWorkspace.withValue(workspace) { try await Repository.createBranch(at: directory, name: name, from: branch) }
    }
    public func switchBranch(at directory: String, branch: String) async throws {
        try await Repository.$boundWorkspace.withValue(workspace) { try await Repository.switchBranch(at: directory, branch: branch) }
    }
    public func commit(at directory: String, message: String) async throws {
        try await Repository.$boundWorkspace.withValue(workspace) { try await Repository.commit(at: directory, message: message) }
    }
    public func changeStatistics(at directory: String, stagedOnly: Bool = false) async throws -> [String: FileChangeStatistics] {
        try await Repository.$boundWorkspace.withValue(workspace) { try await Repository.changeStatistics(at: directory, stagedOnly: stagedOnly) }
    }
}
