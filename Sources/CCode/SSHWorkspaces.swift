import Foundation
import CCodeCore

extension AppStore {
    @discardableResult
    func createSSHWorkspace(host: SSHConfiguration, path: String, executable: String, arguments: [String] = [], additionalDirectories: [String] = []) async throws -> UUID {
        guard canRunScheduledWork else { throw ACPError.workspace("The app is shutting down.") }
        guard !executable.isEmpty, !executable.hasPrefix("-"), !executable.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }) else { throw ACPError.workspace("Enter the remote ACP executable and valid arguments.") }
        try await SSHTransport(configuration: host, executable: sshExecutable).verifyIdentity()
        let frozen = try await SSHTransport(configuration: host, executable: sshExecutable).resolvedConfiguration()
        let environment = ExecutionEnvironment.ssh(frozen)
        let workspace = try Workspace(root: path, additionalDirectories: additionalDirectories, environment: environment, sshExecutable: sshExecutable)
        // Validate every remote directory before publication. No local file existence check.
        var directories: [String] = []
        for directory in workspace.roots { directories.append(try await workspace.remoteWorkspace(for: directory).resolve(directory, directory: true)) }
        try Task.checkCancellation()
        guard canRunScheduledWork else { throw CancellationError() }
        var info = SessionInfo(projectPath: directories[0], title: "New session")
        info.executionEnvironment = environment; info.agentExecutable = executable; info.agentArguments = arguments
        info.additionalDirectories = Array(directories.dropFirst())
        let transcript = SessionTranscript()
        let chat = try ChatSession(id: info.id, path: info.projectPath, transcript: transcript, additionalDirectories: info.additionalDirectories ?? [], environment: environment, sshExecutable: sshExecutable)
        try await storage.save(transcript, id: info.id)
        do {
            try Task.checkCancellation()
            guard canRunScheduledWork else { throw CancellationError() }
            var next = sessions; next.insert(info, at: 0)
            try await storage.saveIndex(next)
            sessions = next
            await select(info.id)
            guard selected?.id == chat.id else { throw ACPError.workspace("The SSH session was saved but could not be opened.") }
            await refreshWorkspace(selected!)
            return info.id
        } catch {
            // Keep already-published records recoverable; remove only an unpublished transcript.
            if !sessions.contains(where: { $0.id == info.id }) { try? await storage.discardUnpublished(info.id) }
            throw error
        }
    }
}
