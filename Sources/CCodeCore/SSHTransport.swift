import Foundation
import CryptoKit

public struct SSHLaunch: Sendable {
    public let executable: String
    public let arguments: [String]
    public let directory: String
}

public struct SSHTransportError: Error, LocalizedError, Sendable {
    public enum Kind: Sendable { case connection, timeout, outputLimit, uncertainMutation, operation }
    public let kind: Kind
    public let detail: String
    public var errorDescription: String? {
        if kind == .uncertainMutation { return "The SSH connection ended before this change was confirmed. It may have completed remotely. Inspect the remote files before retrying. \(detail)" }
        return detail
    }
}

public struct SSHTransport: Sendable {
    public let configuration: SSHConfiguration
    public let executable: String
    public init(configuration: SSHConfiguration, executable: String = "/usr/bin/ssh") throws {
        guard executable.hasPrefix("/"), !executable.contains("\0") else { throw ACPError.workspace("SSH executable must be an absolute path.") }
        self.configuration = configuration; self.executable = executable
    }

    public func launch(executable remoteExecutable: String, arguments: [String] = [], directory: String) throws -> SSHLaunch {
        _ = try WorkspaceLocation(environment: .ssh(configuration), path: directory)
        guard !remoteExecutable.isEmpty, !remoteExecutable.hasPrefix("-"), !remoteExecutable.contains("\0"),
              arguments.allSatisfy({ !$0.contains("\0") }),
              remoteExecutable.utf8.count + arguments.reduce(0, { $0 + $1.utf8.count }) < 128 * 1024 else { throw ACPError.workspace("Invalid or oversized remote command arguments.") }
        var options = ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "CheckHostIP=no", "-o", "UpdateHostKeys=no", "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "PermitLocalCommand=no", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2"]
        if let port = configuration.port { options += ["-p", String(port)] }
        if let identity = configuration.identityFile { options += ["-i", identity] }
        // OpenSSH joins trailing arguments as shell source. Send a single,
        // quoted command; never interpolate a path as unquoted shell syntax.
        let command = "cd " + quote(directory) + " && exec " + ([remoteExecutable] + arguments).map(quote).joined(separator: " ")
        return SSHLaunch(executable: executable, arguments: options + ["--", configuration.host, command], directory: "/")
    }

    public func resolvedConfiguration() async throws -> SSHConfiguration {
        let options = try launch(executable: "true", directory: "/").arguments.dropLast(3)
        let terminals = TerminalService()
        do {
            let id = try await terminals.create(command: executable, arguments: ["-G"] + options + ["--", configuration.host], directory: "/", byteLimit: 256 * 1024, captureStandardErrorSeparately: true)
            let exit = try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask { try await terminals.wait(id) }
                group.addTask { try await Task.sleep(for: .seconds(15)); throw SSHTransportError(kind: .timeout, detail: "SSH configuration lookup timed out.") }
                defer { group.cancelAll() }; return try await group.next()!
            }
            let response = try await terminals.output(id); await terminals.close()
            guard exit["exitCode"].exactInteger == 0, !response["truncated"].bool else { throw ACPError.workspace("Could not resolve this SSH host configuration.") }
            let lines = response["output"].string.split(separator: "\n").map(String.init)
            guard ["hostname ", "user ", "port "].allSatisfy({ key in lines.contains { $0.hasPrefix(key) } }) else { throw ACPError.workspace("SSH configuration is incomplete.") }
            let digest = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
            return try SSHConfiguration(id: configuration.id, name: configuration.name, host: configuration.host, port: configuration.port, identityFile: configuration.identityFile, resolvedOptionsDigest: digest)
        } catch { await terminals.close(); throw error }
    }
    public func verifyIdentity() async throws {
        guard let expected = configuration.resolvedOptionsDigest else { return }
        guard try await resolvedConfiguration().resolvedOptionsDigest == expected else { throw ACPError.workspace("The SSH host configuration changed. Create a new connection after reviewing its destination; this workspace was preserved.") }
    }

    public func run(executable remoteExecutable: String, arguments: [String] = [], directory: String, input: Data? = nil, timeout: Duration = .seconds(60), byteLimit: Int = 4 * 1024 * 1024, mutation: Bool = false, acceptDiff: Bool = false) async throws -> String {
        try Task.checkCancellation()
        try await verifyIdentity()
        let launch = try launch(executable: remoteExecutable, arguments: arguments, directory: directory)
        let terminals = TerminalService()
        do {
            let id = try await terminals.create(command: launch.executable, arguments: launch.arguments, directory: launch.directory, byteLimit: byteLimit, captureStandardErrorSeparately: true, input: input)
            let status = try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask { try await terminals.wait(id) }
                group.addTask { try await Task.sleep(for: timeout); throw SSHTransportError(kind: .timeout, detail: "SSH operation timed out.") }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            let result = try await terminals.output(id)
            await terminals.close()
            guard !result["truncated"].bool else { throw SSHTransportError(kind: .outputLimit, detail: "Remote output exceeds its configured limit.") }
            guard status["signal"].isNull, (status["exitCode"].int == 0 || (acceptDiff && status["exitCode"].int == 1)), result["inputError"].isNull else {
                let diagnostic = String(result["standardError"].string.suffix(2048)).trimmingCharacters(in: .whitespacesAndNewlines)
                let kind: SSHTransportError.Kind = status["signal"].isNull && status["exitCode"].int != 255 ? .operation : .connection
                throw SSHTransportError(kind: kind, detail: diagnostic.isEmpty ? "Remote command ended without a successful result. Check the host key, SSH authentication and remote executable." : diagnostic)
            }
            return result["output"].string
        } catch {
            await terminals.close()
            if mutation { throw SSHTransportError(kind: .uncertainMutation, detail: error.localizedDescription) }
            throw error
        }
    }
    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}

extension ACPConnection {
    public func start(environment: ExecutionEnvironment, executable: String, arguments: [String], directory: String, localEnvironment: [String: String]? = nil, sshExecutable: String = "/usr/bin/ssh") async throws {
        switch environment {
        case .local: try start(executable: executable, arguments: arguments, directory: directory, environment: localEnvironment)
        case .ssh(let host):
            let transport = try SSHTransport(configuration: host, executable: sshExecutable)
            try await transport.verifyIdentity()
            let launch = try transport.launch(executable: executable, arguments: arguments, directory: directory)
            // Credentials and helper paths from localEnvironment stay local.
            try start(executable: launch.executable, arguments: launch.arguments, directory: launch.directory)
        }
    }
}
