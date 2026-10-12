import Foundation

public struct SSHConfiguration: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let host: String
    public let port: Int?
    public let identityFile: String?
    public let resolvedOptionsDigest: String?

    public init(id: UUID = UUID(), name: String, host: String, port: Int? = nil, identityFile: String? = nil, resolvedOptionsDigest: String? = nil) throws {
        guard resolvedOptionsDigest.map({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) ?? true else { throw ACPError.workspace("Invalid saved SSH endpoint identity.") }
        let parts = host.split(separator: "@", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:@[]%")
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512,
              host.utf8.count <= 512, (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") }),
              host.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              port.map({ (1...65535).contains($0) }) ?? true,
              identityFile.map({ $0.hasPrefix("/") && !$0.contains("\0") && !$0.contains("\n") && $0.utf8.count <= 4096 }) ?? true else {
            throw ACPError.workspace("Enter an SSH host alias or user@host, a valid port and an absolute key path.")
        }
        self.id = id; self.name = name; self.host = host; self.port = port; self.identityFile = identityFile; self.resolvedOptionsDigest = resolvedOptionsDigest
    }
    private enum CodingKeys: String, CodingKey { case id, name, host, port, identityFile, resolvedOptionsDigest }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), name: c.decode(String.self, forKey: .name), host: c.decode(String.self, forKey: .host), port: c.decodeIfPresent(Int.self, forKey: .port), identityFile: c.decodeIfPresent(String.self, forKey: .identityFile), resolvedOptionsDigest: c.decodeIfPresent(String.self, forKey: .resolvedOptionsDigest))
    }
}

public enum ExecutionEnvironment: Codable, Sendable, Equatable {
    case local
    case ssh(SSHConfiguration)
    public var isLocal: Bool { if case .local = self { true } else { false } }
    public var identity: String { switch self { case .local: "local"; case .ssh(let host): "ssh:\(host.id.uuidString):\(host.host):\(host.port.map(String.init) ?? "config"):\(host.identityFile ?? "config")" } }
    // Remote agents use their own filesystem/tools. Local callbacks and private
    // helpers must be negotiated only after a remote implementation is routed.
    public var clientCapabilities: JSONValue {
        var value: JSONValue = ["elicitation": ["form": [:], "url": [:]], "session": ["configOptions": ["boolean": [:]]]]
        if isLocal { value["fs"] = ["readTextFile": true, "writeTextFile": true]; value["terminal"] = true }
        return value
    }
}

public struct WorkspaceLocation: Codable, Sendable, Equatable {
    public let environment: ExecutionEnvironment
    public let path: String
    public init(environment: ExecutionEnvironment = .local, path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else { throw ACPError.workspace("Workspace paths must be absolute and contain no NUL bytes.") }
        self.environment = environment; self.path = path
    }
    private enum CodingKeys: String, CodingKey { case environment, path }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(environment: c.decode(ExecutionEnvironment.self, forKey: .environment), path: c.decode(String.self, forKey: .path))
    }
    public var identity: String { environment.identity + ":" + path }
    public func localURL() throws -> URL {
        guard environment.isLocal else { throw ACPError.workspace("This path belongs to an SSH host and cannot be opened as a local file.") }
        return URL(fileURLWithPath: path)
    }
}

public struct SSHConnectionPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { host.id }
    public let host: SSHConfiguration
    public let projectPath: String
    public let executable: String
    public let arguments: [String]
    public init(host: SSHConfiguration, projectPath: String, executable: String, arguments: [String] = []) throws {
        _ = try WorkspaceLocation(environment: .ssh(host), path: projectPath)
        guard !executable.isEmpty, !executable.hasPrefix("-"), !executable.contains("\0"), executable.utf8.count <= 4096, arguments.count <= 128, arguments.allSatisfy({ !$0.contains("\0") }), arguments.reduce(0, { $0 + $1.utf8.count }) <= 64 * 1024 else { throw ACPError.workspace("Enter a remote ACP executable and valid arguments.") }
        self.host = host; self.projectPath = projectPath; self.executable = executable; self.arguments = arguments
    }
    private enum CodingKeys: String, CodingKey { case host, projectPath, executable, arguments }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: c.decode(SSHConfiguration.self, forKey: .host), projectPath: c.decode(String.self, forKey: .projectPath), executable: c.decode(String.self, forKey: .executable), arguments: c.decode([String].self, forKey: .arguments))
    }
}
