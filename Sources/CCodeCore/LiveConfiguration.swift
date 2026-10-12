import Foundation
public enum LiveConfigurationOperation: Sendable {
    case status, toggle(name: String, enabled: Bool), reconnect(name: String), reloadSkills, reloadPlugins
    case beginAuthentication(name: String), authenticationStatus(name: String, flowID: String), cancelAuthentication(name: String, flowID: String)
    public var name: String {
        switch self {
        case .status: "status"; case .toggle: "toggle"; case .reconnect: "reconnect"; case .reloadSkills: "reloadSkills"; case .reloadPlugins: "reloadPlugins"
        case .beginAuthentication: "beginAuthentication"; case .authenticationStatus: "authenticationStatus"; case .cancelAuthentication: "cancelAuthentication"
        }
    }
    public var mutating: Bool { !["status", "authenticationStatus", "cancelAuthentication"].contains(name) }
    public var serverName: String? {
        switch self { case .toggle(let name, _), .reconnect(let name), .beginAuthentication(let name), .authenticationStatus(let name, _), .cancelAuthentication(let name, _): name; default: nil }
    }
    public var flowID: String? { switch self { case .authenticationStatus(_, let id), .cancelAuthentication(_, let id): id; default: nil } }
    public var authenticating: Bool { ["beginAuthentication", "authenticationStatus", "cancelAuthentication"].contains(name) }
}
public struct MCPAuthentication: Sendable {
    public enum State: String, Sendable { case pending, connected, failed, cancelled }
    public let id: String
    public let name: String
    public let state: State
    public let url: URL?
}
public struct MCPServerConnection: Sendable, Identifiable {
    public enum Status: String, Sendable { case connected, failed, pending, disabled; case needsAuthentication = "needs-auth" }
    public var id: String { name }
    public let name: String
    public let status: Status
    public let source: String?
    public let scope: String?
    public let tools: [String]
}
public struct LiveConfigurationCapability: Sendable {
    public let connectionID: String
    public let supportsAuthentication: Bool
    public init?(_ value: JSONValue) {
        guard value["version"] == 1, value["method"] == "_ccode/configuration", let id = value["connectionId"].optionalString, UUID(uuidString: id) != nil else { return nil }
        connectionID = id
        supportsAuthentication = value["authenticationVersion"] == 1
    }
    public func parameters(sessionID: String, operation: LiveConfigurationOperation) throws -> JSONValue {
        guard UUID(uuidString: sessionID) != nil else { throw ACPError.workspace("Reconnect this session before changing configuration.") }
        var params: JSONValue = ["connectionId": .string(connectionID), "sessionId": .string(sessionID), "operation": .string(operation.name)]
        if operation.authenticating, !supportsAuthentication { throw ACPError.workspace("This agent does not expose MCP sign-in. Reconnect with a compatible adapter.") }
        if let name = operation.serverName {
            guard bounded(name, 256) else { throw ACPError.workspace("Choose a server from the current list.") }
            params["name"] = .string(name)
        }
        if let id = operation.flowID {
            guard UUID(uuidString: id) != nil else { throw ACPError.protocolViolation("Invalid authentication flow.") }
            params["flowId"] = .string(id)
        }
        switch operation {
        case .toggle(let name, let enabled): guard bounded(name, 256) else { throw ACPError.workspace("Choose a server from the current list.") }; params["name"] = .string(name); params["enabled"] = .bool(enabled)
        case .reconnect(let name): guard bounded(name, 256) else { throw ACPError.workspace("Choose a server from the current list.") }; params["name"] = .string(name)
        default: break
        }
        return params
    }
}
public struct LiveConfigurationResult: Sendable {
    public let servers: [MCPServerConnection]
    public let plugins: [String]
    public let errorCount: Int
    public let authentication: MCPAuthentication?
    public init(_ value: JSONValue, capability: LiveConfigurationCapability, sessionID: String, operation: LiveConfigurationOperation) throws {
        guard value["version"] == 1, value["connectionId"] == .string(capability.connectionID), value["sessionId"] == .string(sessionID), value["operation"] == .string(operation.name),
              case .array(let values) = value["servers"], values.count <= 256, try JSONEncoder().encode(value).count <= 512 * 1024 else { throw ACPError.protocolViolation("Invalid live configuration response.") }
        if operation.authenticating {
            let flow = value["authentication"]
            guard capability.supportsAuthentication, let id = flow["id"].optionalString, UUID(uuidString: id) != nil,
                  flow["name"].optionalString == operation.serverName, let name = operation.serverName,
                  let state = MCPAuthentication.State(rawValue: flow["state"].string),
                  operation.flowID == nil || operation.flowID == id,
                  (operation.name == "cancelAuthentication") == (state == .cancelled) else { throw ACPError.protocolViolation("Invalid MCP authentication response.") }
            let url: URL?
            if flow["url"].isNull { url = nil }
            else {
                guard state == .pending, let raw = flow["url"].optionalString, bounded(raw, 16384), let parsed = URL(string: raw),
                      parsed.user == nil, parsed.password == nil, parsed.host != nil,
                      parsed.scheme == "https" || parsed.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(parsed.host ?? "") else { throw ACPError.protocolViolation("Invalid MCP authorization URL.") }
                url = parsed
            }
            authentication = MCPAuthentication(id: id, name: name, state: state, url: url)
        } else {
            guard value["authentication"].isNull else { throw ACPError.protocolViolation("Unexpected authentication data.") }
            authentication = nil
        }
        var names: Set<String> = []
        servers = try values.map { server in
            guard let name = server["name"].optionalString, bounded(name, 256), names.insert(name).inserted, let status = MCPServerConnection.Status(rawValue: server["status"].string) else { throw ACPError.protocolViolation("Invalid MCP server status.") }
            let tools: [String]
            if server["tools"].isNull { tools = [] }
            else { guard case .array(let values) = server["tools"], values.count <= 512, values.allSatisfy({ bounded($0.string, 256) }) else { throw ACPError.protocolViolation("Invalid MCP tool list.") }; tools = values.map(\.string) }
            return MCPServerConnection(name: name, status: status, source: bounded(server["source"].string, 256) ? server["source"].string : nil, scope: bounded(server["scope"].string, 256) ? server["scope"].string : nil, tools: tools)
        }
        if let authentication {
            guard let server = servers.first(where: { $0.name == authentication.name }),
                  authentication.state != .connected || server.status == .connected else { throw ACPError.protocolViolation("MCP sign-in completion does not match the server status.") }
        }
        if value["plugins"].isNull { plugins = [] }
        else { guard case .array(let values) = value["plugins"], values.count <= 512, values.allSatisfy({ bounded($0.string, 256) }) else { throw ACPError.protocolViolation("Invalid plugin list.") }; plugins = values.map(\.string) }
        guard value["errorCount"].isNull || value["errorCount"].exactInteger.map({ $0 >= 0 }) == true else { throw ACPError.protocolViolation("Invalid reload status.") }
        errorCount = value["errorCount"].exactInteger ?? 0
    }
}

private func bounded(_ value: String, _ limit: Int) -> Bool { !value.isEmpty && value.utf8.count <= limit && !value.unicodeScalars.contains(where: { $0.value < 32 }) }
