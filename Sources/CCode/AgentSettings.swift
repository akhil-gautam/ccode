import Foundation
import CCodeCore

struct AgentSettings: Codable, Equatable {
    var executable: String
    var arguments: [String]
    var appearance = "system"
    var defaultWorktree = false
    var sessionNotifications: Bool?
    var sshConnections: [SSHConnectionPreset]?

    static var environment: [String: String] {
        var values = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [home + "/.local/bin", home + "/.vite-plus/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        values["PATH"] = (extra + [values["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return values
    }
    static func locate(_ name: String) -> String? {
        environment["PATH"]!.split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func usesClaudeHistory(executable: String, arguments: [String]) -> Bool {
        let launcher = URL(fileURLWithPath: executable).lastPathComponent
        return launcher == "claude-agent-acp" || (["node", "nodejs"].contains(launcher) && arguments.first?.hasSuffix("/claude-agent-acp/dist/index.js") == true)
    }
    static func browserServerParameters(handshake: JSONValue, endpoint: BrowserToolEndpoint) throws -> JSONValue {
        guard handshake["agentCapabilities"]["mcpCapabilities"]["http"].bool else {
            throw ACPError.workspace("This agent does not support HTTP MCP browser tools. Disconnect browser tools to use it.")
        }
        return ["type": "http", "name": "ccode-browser", "url": .string(endpoint.url.absoluteString), "headers": [["name": "Authorization", "value": .string("Bearer " + endpoint.token)]]]
    }
    var configurationRuntime: (node: String, entry: String, helper: String)? {
        let explicitNode = ["node", "nodejs"].contains(URL(fileURLWithPath: executable).lastPathComponent)
        guard let candidate = explicitNode ? arguments.first : executable, candidate.hasPrefix("/") else { return nil }
        let entry = URL(fileURLWithPath: candidate).resolvingSymlinksInPath()
        guard entry.lastPathComponent == "index.js", entry.deletingLastPathComponent().lastPathComponent == "dist",
              let data = try? Data(contentsOf: entry.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("package.json")),
              let package = try? JSONDecoder().decode(JSONValue.self, from: data), package["name"] == "@agentclientprotocol/claude-agent-acp", package["version"] == "0.84.0",
              let node = explicitNode ? executable : Self.locate("node") else { return nil }
        let root = Bundle.main.object(forInfoDictionaryKey: "CCodeDevelopmentRoot") as? String ?? FileManager.default.currentDirectoryPath
        let helper = Bundle.main.url(forResource: "claude-configuration", withExtension: "mjs")?.path ?? root + "/scripts/claude-configuration.mjs"
        guard FileManager.default.fileExists(atPath: helper) else { return nil }
        return (node, entry.path, helper)
    }
    static func nativeSubagentLaunch(executable: String, arguments: [String], bridge: String? = nil, node: String? = nil) -> (executable: String, arguments: [String]) {
        let fallback = (executable: executable, arguments: arguments)
        let explicitNode = ["node", "nodejs"].contains(URL(fileURLWithPath: executable).lastPathComponent)
        let entryPath: String
        let adapterArguments: [String]
        if explicitNode {
            guard let first = arguments.first, first.hasPrefix("/") else { return fallback }
            entryPath = first; adapterArguments = Array(arguments.dropFirst())
        } else { entryPath = executable; adapterArguments = arguments }
        let entry = URL(fileURLWithPath: entryPath).resolvingSymlinksInPath()
        guard entry.lastPathComponent == "index.js", entry.deletingLastPathComponent().lastPathComponent == "dist",
              let data = try? Data(contentsOf: entry.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("package.json")),
              let package = try? JSONDecoder().decode(JSONValue.self, from: data),
              package["name"] == "@agentclientprotocol/claude-agent-acp", package["version"] == "0.84.0" else { return fallback }
        let developmentRoot = Bundle.main.object(forInfoDictionaryKey: "CCodeDevelopmentRoot") as? String ?? FileManager.default.currentDirectoryPath
        let resource = Bundle.main.url(forResource: "claude-acp-native-subagents", withExtension: "mjs")?.path
        let bridgePath = bridge ?? resource ?? developmentRoot + "/scripts/claude-acp-native-subagents.mjs"
        guard FileManager.default.fileExists(atPath: bridgePath), let nodePath = explicitNode ? executable : (node ?? locate("node")) else { return fallback }
        // argv preserves paths and user arguments literally; NODE_OPTIONS would
        // leak the preload into unrelated node-based MCP/agent child processes.
        return (nodePath, [bridgePath, entry.path] + adapterArguments)
    }
    static var defaults: AgentSettings {
        let root = Bundle.main.object(forInfoDictionaryKey: "CCodeDevelopmentRoot") as? String ?? FileManager.default.currentDirectoryPath
        let local = root + "/.build/agent/node_modules/.bin/claude-agent-acp"
        return AgentSettings(executable: locate("claude-agent-acp") ?? (FileManager.default.isExecutableFile(atPath: local) ? local : ""), arguments: [])
    }
    static func load() -> AgentSettings {
        guard let bytes = UserDefaults.standard.data(forKey: "agentSettings"), let value = try? JSONDecoder().decode(Self.self, from: bytes) else { return defaults }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "agentSettings") } }
}
