import Foundation

extension Workspace {
    public func createTerminal(_ terminals: TerminalService, command: String, arguments: [String] = [], directory: String, environment supplied: [String: String] = [:], localEnvironment: [String: String] = [:], byteLimit: Int = 1024 * 1024) async throws -> String {
        let target = try await scoped(directory).path
        if environment.isLocal {
            return try await terminals.create(command: command, arguments: arguments, directory: target, environment: supplied.merging(localEnvironment) { explicit, _ in explicit }, byteLimit: byteLimit)
        }
        let remote = try remoteWorkspace(for: target)
        _ = try await remote.resolve(target, directory: true)
        // Only explicitly supplied ACP environment values cross the SSH boundary.
        guard supplied.keys.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_").contains($0) } && !($0.first?.isNumber ?? true) }) else { throw ACPError.workspace("Invalid remote terminal environment name.") }
        let env = supplied.keys.sorted().map { $0 + "=" + supplied[$0]! }
        try await remote.transport.verifyIdentity()
        let launch = try remote.transport.launch(executable: env.isEmpty ? command : "env", arguments: env.isEmpty ? arguments : env + [command] + arguments, directory: target)
        return try await terminals.create(command: launch.executable, arguments: launch.arguments, directory: launch.directory, byteLimit: byteLimit)
    }
}
