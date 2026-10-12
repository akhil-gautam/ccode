import Foundation
import CryptoKit
import Darwin

public enum ConfigurationScope: String, CaseIterable, Sendable, Identifiable {
    case user, project, local, managed
    public var id: String { rawValue }
    public var title: String { switch self { case .user: "User"; case .project: "Shared project"; case .local: "Project local"; case .managed: "Managed" } }
}
public enum ConfigurationDocumentKind: String, Sendable { case settings, instructions, mcp }
public struct ConfigurationDocument: Sendable, Identifiable {
    public let id: UUID
    public let scope: ConfigurationScope
    public let kind: ConfigurationDocumentKind
    public let path: String
    public let text: String
    public let exists: Bool
    public var editable: Bool { scope != .managed }
}
public struct ConfigurationExtension: Sendable, Identifiable {
    public enum Kind: String, Sendable { case skill, command }
    public var id: String { path }
    public let name: String
    public let description: String
    public let scope: ConfigurationScope
    public let kind: Kind
    public let path: String
}
public struct PluginInstallReview: Sendable, Identifiable {
    public let id: UUID
    public let plugin: String
    public let scope: ConfigurationScope
    public let command: String
    public let sha256: String
    public let kind: String
    public let mode: String?
    public let archiveURL: String?
}
public enum PluginInstallationResult: Sendable { case installed, review(PluginInstallReview) }
public enum ConfigurationOperation: Sendable {
    case addMCP(name: String, configuration: JSONValue, scope: ConfigurationScope)
    case removeMCP(name: String, scope: ConfigurationScope)
    case checkMCP(name: String?)
    case plugins
    case installPlugin(name: String, scope: ConfigurationScope)
    case enablePlugin(name: String, scope: ConfigurationScope, enabled: Bool)
    case uninstallPlugin(name: String, scope: ConfigurationScope)
    case addMarketplace(source: String)
}
public actor AgentConfiguration {
    private let project: String
    private let configurationDirectory: String
    private let managedDirectory: String
    private struct Receipt { let scope: ConfigurationScope; let kind: ConfigurationDocumentKind; let path: String; let digest: String? }
    private var receipts: [UUID: Receipt] = [:]
    private struct PluginReceipt {
        let review: PluginInstallReview
        let executable: String
        let arguments: [String]
        let deadline: ContinuousClock.Instant
    }
    private var pluginReceipts: [UUID: PluginReceipt] = [:]
    public init(project: String, configurationDirectory: String, managedDirectory: String = "/Library/Application Support/ClaudeCode") throws {
        guard [project, configurationDirectory, managedDirectory].allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
              FileManager.default.fileExists(atPath: project) else { throw ACPError.workspace("Choose an existing project and absolute configuration paths.") }
        self.project = try canonicalURL(project).path
        self.configurationDirectory = try canonicalURL(configurationDirectory).path
        self.managedDirectory = try canonicalURL(managedDirectory).path
    }
    public func document(scope: ConfigurationScope, kind: ConfigurationDocumentKind) throws -> ConfigurationDocument {
        try Task.checkCancellation()
        if kind == .mcp, scope == .user || scope == .local { throw ACPError.workspace("User and local MCP servers are managed by Claude's CLI, not a settings file.") }
        let base = scope == .user ? configurationDirectory : scope == .managed ? managedDirectory : project
        let relative: String
        switch kind {
        case .settings: relative = scope == .user ? "settings.json" : scope == .managed ? "managed-settings.json" : ".claude/settings\(scope == .local ? ".local" : "").json"
        case .instructions: relative = scope == .local ? "CLAUDE.local.md" : "CLAUDE.md"
        case .mcp: relative = scope == .managed ? "managed-mcp.json" : ".mcp.json"
        }
        let path = URL(fileURLWithPath: base).appendingPathComponent(relative).path
        try validate(path, base: base)
        let data = try contents(path)
        guard data == nil || String(data: data!, encoding: .utf8) != nil else { throw ACPError.workspace("Configuration must be UTF-8 text.") }
        let id = UUID()
        if receipts.count >= 64 { receipts.removeAll() }
        receipts[id] = Receipt(scope: scope, kind: kind, path: path, digest: data.map(Self.digest))
        return ConfigurationDocument(id: id, scope: scope, kind: kind, path: path, text: data.flatMap { String(data: $0, encoding: .utf8) } ?? (kind == .instructions ? "" : "{}"), exists: data != nil)
    }
    public func save(_ document: ConfigurationDocument, text: String) throws -> ConfigurationDocument {
        try Task.checkCancellation()
        guard let receipt = receipts[document.id], receipt.path == document.path, receipt.scope == document.scope, receipt.kind == document.kind, document.editable else { throw ACPError.workspace("Reopen this editable configuration before saving. Managed configuration is read-only.") }
        let data = Data(text.utf8)
        guard data.count <= 512 * 1024 else { throw ACPError.workspace("Configuration exceeds the 512 KB editor limit.") }
        if document.kind != .instructions {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = value else { throw ACPError.workspace("Settings must contain a valid JSON object.") }
        }
        let base = document.scope == .user ? configurationDirectory : project
        try validate(receipt.path, base: base)
        guard try contents(receipt.path).map(Self.digest) == receipt.digest else { throw ACPError.workspace("Configuration changed outside this editor. Reload it before saving; your draft is preserved.") }
        let url = URL(fileURLWithPath: receipt.path), parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validate(receipt.path, base: base)
        let temporary = parent.appendingPathComponent(".ccode-config-\(UUID()).tmp")
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ACPError.workspace("Cannot create a private configuration draft.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data); try handle.synchronize()
        try Task.checkCancellation()
        try validate(receipt.path, base: base)
        guard try contents(receipt.path).map(Self.digest) == receipt.digest else { throw ACPError.workspace("Configuration changed while saving. Reload it before saving; your draft is preserved.") }
        guard Darwin.rename(temporary.path, receipt.path) == 0 else { throw ACPError.workspace("Cannot replace the configuration file.") }
        receipts.removeValue(forKey: document.id)
        return try self.document(scope: document.scope, kind: document.kind)
    }
    public func set(_ document: ConfigurationDocument, path: [String], value: JSONValue?) throws -> ConfigurationDocument {
        guard document.kind != .instructions, !path.isEmpty, path.count <= 16, path.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else { throw ACPError.workspace("Choose a settings key.") }
        var settings = try JSONSerialization.jsonObject(with: Data(document.text.utf8))
        guard settings is [String: Any] else { throw ACPError.workspace("Settings must contain a JSON object.") }
        let replacement = try value.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0), options: [.fragmentsAllowed]) }
        // Foundation preserves integer JSON numbers. JSONValue uses Double and
        // would round an unrelated future setting above 2^53 during a patch.
        func patch(_ node: inout Any, _ index: Int) throws {
            guard var object = node as? [String: Any] else { throw ACPError.workspace("The existing setting is not an object. Edit it explicitly instead of replacing unknown data.") }
            let key = path[index]
            if index == path.count - 1 { object[key] = replacement }
            else { var child: Any = object[key] ?? [String: Any](); try patch(&child, index + 1); object[key] = child }
            node = object
        }
        try patch(&settings, 0)
        let bytes = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        return try save(document, text: String(decoding: bytes, as: UTF8.self) + "\n")
    }
    public func extensions() throws -> [ConfigurationExtension] {
        try Task.checkCancellation()
        var result: [ConfigurationExtension] = []
        for (scope, base) in [(ConfigurationScope.user, configurationDirectory), (.project, project + "/.claude")] {
            for (kind, relative) in [(ConfigurationExtension.Kind.skill, "skills"), (.command, "commands")] {
                let directory = URL(fileURLWithPath: base).appendingPathComponent(relative)
                try validate(directory.path, base: scope == .project ? project : configurationDirectory)
                guard FileManager.default.fileExists(atPath: directory.path), let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
                var visited = 0
                for case let file as URL in files {
                    try Task.checkCancellation(); visited += 1
                    if visited > 4096 || result.count >= 512 { break }
                    let metadata = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if metadata.isSymbolicLink == true { files.skipDescendants(); continue }
                    guard metadata.isRegularFile == true, kind == .skill ? file.lastPathComponent == "SKILL.md" : file.pathExtension == "md" else { continue }
                    try validate(file.path, base: scope == .project ? project : configurationDirectory)
                    guard let bytes = try contents(file.path), let body = String(data: bytes, encoding: .utf8) else { continue }
                    let front = Self.frontmatter(body)
                    let relativePath = String(file.path.dropFirst(directory.path.count + 1))
                    let name = kind == .skill ? front["name"] ?? file.deletingLastPathComponent().lastPathComponent : String(relativePath.dropLast(3)).replacingOccurrences(of: "/", with: ":")
                    result.append(ConfigurationExtension(name: name, description: front["description"] ?? "", scope: scope, kind: kind, path: file.path))
                }
            }
        }
        return result.sorted { ($0.name, $0.scope.rawValue) < ($1.name, $1.scope.rawValue) }
    }
    public func resolve(node: String, adapterEntry: String, helper: String) async throws -> JSONValue {
        let raw = try await run(command: node, arguments: [helper, adapterEntry, project], environment: ["CLAUDE_CONFIG_DIR": configurationDirectory])
        return try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
    }
    public func installPlugin(executable: String, arguments: [String], name: String, scope: ConfigurationScope) async throws -> PluginInstallationResult {
        try validatePlugin(name, scope: scope)
        return try await runPluginInstallation(executable: executable, arguments: arguments, name: name, scope: scope, acceptedCommand: nil)
    }
    public func acceptPluginInstallation(_ review: PluginInstallReview, executable: String, arguments: [String]) async throws -> PluginInstallationResult {
        try Task.checkCancellation()
        guard let receipt = pluginReceipts[review.id], receipt.executable == executable, receipt.arguments == arguments,
              receipt.deadline > .now else { throw ACPError.workspace("The plugin review expired or the selected agent changed. Review the install again.") }
        // Consume before launching: cancellation/uncertainty never silently
        // replays a command. The CLI itself binds sha256 to plugin/catalog.
        pluginReceipts.removeValue(forKey: review.id)
        return try await runPluginInstallation(executable: executable, arguments: arguments, name: receipt.review.plugin, scope: receipt.review.scope, acceptedCommand: receipt.review.sha256)
    }
    public func discardPluginInstallationReview(_ review: PluginInstallReview) { pluginReceipts.removeValue(forKey: review.id) }
    private func validatePlugin(_ name: String, scope: ConfigurationScope) throws {
        guard scope != .managed, !name.isEmpty, name.utf8.count <= 256, !name.hasPrefix("-"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else { throw ACPError.workspace("Choose an editable scope and a valid plugin name.") }
    }
    private func runPluginInstallation(executable: String, arguments: [String], name: String, scope: ConfigurationScope, acceptedCommand: String?) async throws -> PluginInstallationResult {
        try Task.checkCancellation()
        var command = ["--cli", "plugin", "install", name, "--json", "--scope", scope.rawValue]
        if let acceptedCommand { command += ["--accept-command", acceptedCommand] }
        let result = try await runResult(command: executable, arguments: arguments + command, environment: ["CLAUDE_CONFIG_DIR": configurationDirectory], timeout: .seconds(120))
        try Task.checkCancellation()
        // Parse only the final result line; preceding output may contain
        // untrusted diagnostics, commands or credentials and is discarded.
        guard let line = result.output.split(whereSeparator: \.isNewline).last, line.utf8.count <= 16 * 1024,
              let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), value["command"] == "install",
              value["scope"] == .string(scope.rawValue) else { throw ACPError.workspace("Claude could not confirm this installation. Refresh the installed plugin list before repeating it.") }
        if result.exitCode == 0, value["outcome"] == "ok" { return .installed }
        let shown = value["shownCommand"]
        guard result.exitCode == 1, value["outcome"] == "failed", let plugin = shown["pluginId"].optionalString,
              plugin == name || !name.contains("@") && plugin.split(separator: "@").first.map(String.init) == name,
              let text = shown["command"].optionalString, !text.isEmpty, text.utf8.count <= 500,
              text.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }),
              let sha = shown["sha256"].optionalString, sha.count == 64, sha.allSatisfy({ $0.isHexDigit }),
              let kind = shown["kind"].optionalString, !kind.isEmpty, kind.utf8.count <= 128 else { throw ACPError.workspace("Claude refused this installation. Check the plugin and marketplace configuration.") }
        try validatePlugin(plugin, scope: scope)
        let review = PluginInstallReview(id: UUID(), plugin: plugin, scope: scope, command: text, sha256: sha, kind: kind,
                                        mode: shown["mode"].optionalString.map { String($0.prefix(64)) },
                                        archiveURL: shown["archiveUrl"].optionalString.map { String($0.prefix(4096)) })
        pluginReceipts = pluginReceipts.filter { $0.value.deadline > .now }
        if pluginReceipts.count >= 32 { pluginReceipts.removeAll() }
        pluginReceipts[review.id] = PluginReceipt(review: review, executable: executable, arguments: arguments, deadline: .now + .seconds(600))
        return .review(review)
    }
    public func invoke(executable: String, arguments: [String], operation: ConfigurationOperation) async throws -> String {
        try Task.checkCancellation()
        func scope(_ value: ConfigurationScope) throws -> [String] {
            guard value != .managed else { throw ACPError.workspace("Managed configuration is read-only.") }
            return ["--scope", value.rawValue]
        }
        func name(_ value: String) throws -> String {
            guard !value.isEmpty, value.utf8.count <= 256, !value.hasPrefix("-"), !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }) else { throw ACPError.workspace("Enter a valid extension or server name.") }
            return value
        }
        let command: [String], message: String?
        switch operation {
        case .addMCP(let server, let configuration, let target):
            guard case .object = configuration else { throw ACPError.workspace("MCP configuration must be a JSON object.") }
            command = ["mcp", "add-json", try name(server), configuration.pretty] + (try scope(target)); message = "MCP server added. Reconnect the agent to load it."
        case .removeMCP(let server, let target): command = ["mcp", "remove", try name(server)] + (try scope(target)); message = "MCP server removed. Reconnect the agent to unload it."
        case .checkMCP(let server): command = try server.map { ["mcp", "get", try name($0)] } ?? ["mcp", "list"]; message = nil
        case .plugins: command = ["plugin", "list", "--json"]; message = nil
        case .installPlugin(let plugin, let target):
            let result = try await installPlugin(executable: executable, arguments: arguments, name: plugin, scope: target)
            if case .review(let review) = result { discardPluginInstallationReview(review); throw ACPError.workspace("This plugin requires an install command review. Use the native plugin installer.") }
            return "Plugin installed. Reload extensions in the agent to apply it."
        case .enablePlugin(let plugin, let target, let enabled): command = ["plugin", enabled ? "enable" : "disable", try name(plugin)] + (try scope(target)); message = "Plugin \(enabled ? "enabled" : "disabled"). Reload extensions in the agent to apply it."
        case .uninstallPlugin(let plugin, let target): command = ["plugin", "uninstall", try name(plugin)] + (try scope(target)); message = "Plugin uninstalled. Reload extensions in the agent to apply it."
        case .addMarketplace(let source):
            guard !source.isEmpty, source.utf8.count <= 4096, !source.hasPrefix("-"), !source.contains("\0"), !source.contains("\n") else { throw ACPError.workspace("Enter a marketplace repository, path or URL.") }
            command = ["plugin", "marketplace", "add", source]; message = "Marketplace added."
        }
        let result = try await run(command: executable, arguments: arguments + ["--cli"] + command, environment: ["CLAUDE_CONFIG_DIR": configurationDirectory], timeout: .seconds(120))
        // Mutation output can echo credentials/configuration. Do not retain it.
        return message ?? result
    }
    private func run(command: String, arguments: [String], environment: [String: String] = [:], timeout: Duration = .seconds(20)) async throws -> String {
        let result = try await runResult(command: command, arguments: arguments, environment: environment, timeout: timeout)
        guard result.exitCode == 0 else { throw ACPError.workspace("Claude could not resolve configuration. Check the selected adapter and configuration files.") }
        return result.output
    }
    private func runResult(command: String, arguments: [String], environment: [String: String], timeout: Duration) async throws -> (output: String, exitCode: Int) {
        let terminals = TerminalService()
        do {
            let id = try await terminals.create(command: command, arguments: arguments, directory: project, environment: environment, byteLimit: 1024 * 1024, captureStandardErrorSeparately: true)
            let status = try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask { try await terminals.wait(id) }
                group.addTask { try await Task.sleep(for: timeout); throw ACPError.timeout("configuration operation") }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            let output = try await terminals.output(id)
            await terminals.close()
            guard status["signal"].isNull, let exitCode = status["exitCode"].exactInteger, !output["truncated"].bool else { throw ACPError.workspace("Claude could not confirm this configuration operation. Refresh before repeating it.") }
            return (output["output"].string, exitCode)
        } catch { await terminals.close(); throw error }
    }
    private func contents(_ path: String) throws -> Data? {
        var stat = stat()
        if lstat(path, &stat) != 0 {
            if errno == ENOENT { return nil }
            throw ACPError.workspace("Configuration cannot be read.")
        }
        guard (stat.st_mode & S_IFMT) == S_IFREG, stat.st_size <= 512 * 1024 else { throw ACPError.workspace("Choose a regular configuration file smaller than 512 KB.") }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
    private func validate(_ path: String, base: String) throws {
        let canonical = try canonicalURL(path).path
        guard canonical == base || canonical.hasPrefix(base == "/" ? "/" : base + "/"), canonical == path else { throw ACPError.workspace("Configuration path changed or escapes its selected scope.") }
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func frontmatter(_ body: String) -> [String: String] {
        let lines = body.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var result: [String: String] = [:]
        for line in lines[1..<end] {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]), raw = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if ["name", "description"].contains(key) { result[key] = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
        return result
    }
}
