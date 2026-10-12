import XCTest
import Foundation
import CCodeCore

final class ConfigurationManagementTests: XCTestCase {
    private func fixture() throws -> (URL, AgentConfiguration) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-configuration-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try AgentConfiguration(project: root.appendingPathComponent("project").path, configurationDirectory: root.appendingPathComponent("config").path, managedDirectory: root.appendingPathComponent("managed").path))
    }
    func testScopedPatchPreservesUnknownFieldsAndRefusesConcurrentChanges() async throws {
        let (root, config) = try fixture()
        let path = root.appendingPathComponent("config/settings.json")
        try Data(#"{"env":{"EXISTING":"literal $()"},"future":{"nested":[1,2]},"permissions":{"deny":["Read(.env)"]}}"#.utf8).write(to: path)
        let original = try await config.document(scope: .user, kind: .settings)
        let saved = try await config.set(original, path: ["env", "NEW"], value: "literal 'quotes'")
        let independentlyRead = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: path))
        XCTAssertEqual(independentlyRead["future"]["nested"], [1, 2])
        XCTAssertEqual(independentlyRead["env"]["EXISTING"], "literal $()")
        XCTAssertEqual(independentlyRead["env"]["NEW"], "literal 'quotes'")
        XCTAssertEqual(independentlyRead["permissions"]["deny"], ["Read(.env)"])
        let external = Data(#"{"external":"preserve me"}"#.utf8)
        try external.write(to: path, options: .atomic)
        do { _ = try await config.save(saved, text: "{}"); XCTFail("Concurrent file overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: path), external)
        do { _ = try await config.save(original, text: "{}"); XCTFail("Old receipt reused") } catch {}
    }
    func testManagedForeignSymlinkAndInvalidJSONCannotBeMutated() async throws {
        let (root, config) = try fixture(), (_, foreign) = try fixture()
        let managed = try await config.document(scope: .managed, kind: .settings)
        do { _ = try await config.save(managed, text: "{}"); XCTFail("Managed settings editable") } catch {}
        let local = try await config.document(scope: .local, kind: .settings)
        do { _ = try await foreign.save(local, text: "{}"); XCTFail("Foreign receipt accepted") } catch {}
        do { _ = try await config.save(local, text: "[]"); XCTFail("Non-object settings saved") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("project/.claude"), withDestinationURL: root.appendingPathComponent("config"))
        do { _ = try await config.document(scope: .project, kind: .settings); XCTFail("Project configuration escaped through symlink") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("config/settings.json").path))
    }
    func testInstructionsAndHooksAreLiteralAndCancellationDoesNotWrite() async throws {
        let (_, config) = try fixture()
        let instructions = try await config.document(scope: .project, kind: .instructions)
        let text = "# Project\n\nUse literal `$()` and keep two trailing spaces.  \n"
        _ = try await config.save(instructions, text: text)
        XCTAssertEqual(try String(contentsOfFile: instructions.path, encoding: .utf8), text)
        let settings = try await config.document(scope: .local, kind: .settings)
        let task = Task { try Task.checkCancellation(); return try await config.set(settings, path: ["hooks", "PostToolUse"], value: [["matcher": "Edit", "hooks": [["type": "command", "command": "printf literal"]]]]) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled mutation succeeded") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
    }
    func testSkillAndCommandBrowsingDoesNotExecuteContent() async throws {
        let (root, config) = try fixture()
        let skill = root.appendingPathComponent("project/.claude/skills/fixture/SKILL.md")
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nname: fixture\ndescription: A literal test skill\n---\nDo not execute !`touch forbidden`.\n".utf8).write(to: skill)
        let command = root.appendingPathComponent("config/commands/nested/check.md")
        try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\ndescription: Check the fixture\n---\nLiteral $ARGUMENTS".utf8).write(to: command)
        let records = try await config.extensions()
        XCTAssertTrue(records.contains { $0.name == "fixture" && $0.scope == .project && $0.description == "A literal test skill" })
        XCTAssertTrue(records.contains { $0.name == "nested:check" && $0.scope == .user && $0.kind == .command })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("project/forbidden").path))
    }
    func testActualPinnedSDKReportsEffectiveScopeProvenanceAndRedactsSecrets() async throws {
        let (root, config) = try fixture()
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let entry = base.appendingPathComponent(".build/agent/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js")
        guard FileManager.default.fileExists(atPath: entry.path) else { throw XCTSkip("Pinned adapter fixture not installed") }
        let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let node else { throw XCTSkip("Node fixture unavailable") }
        let user = try await config.document(scope: .user, kind: .settings)
        _ = try await config.save(user, text: #"{"env":{"CCODE_SECRET":"do-not-output","CCODE_SCOPE":"user"},"spinnerTipsEnabled":true}"#)
        let project = try await config.document(scope: .project, kind: .settings)
        _ = try await config.save(project, text: #"{"env":{"CCODE_SCOPE":"project"}}"#)
        let local = try await config.document(scope: .local, kind: .settings)
        _ = try await config.save(local, text: #"{"spinnerTipsEnabled":false,"env":{"CCODE_SCOPE":"local"}}"#)
        let snapshot = try await config.resolve(node: node, adapterEntry: entry.path, helper: base.appendingPathComponent("scripts/claude-configuration.mjs").path)
        XCTAssertEqual(snapshot["effective"]["spinnerTipsEnabled"], false)
        XCTAssertEqual(snapshot["provenance"]["spinnerTipsEnabled"]["source"], "local")
        XCTAssertTrue(snapshot["sources"].array.contains { $0["source"] == "project" })
        XCTAssertFalse(snapshot.pretty.contains("do-not-output"))
        XCTAssertTrue(snapshot["effective"]["env"]["CCODE_SECRET"].string.contains("redacted"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("project/forbidden").path))
    }

    func testActualCLIAddsAndRemovesMCPInItsSupportedScopes() async throws {
        let (root, config) = try fixture()
        let executable = FileManager.default.currentDirectoryPath + "/.build/agent/node_modules/.bin/claude-agent-acp"
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("Pinned Claude CLI fixture not installed") }
        let server: JSONValue = ["type": "stdio", "command": "/usr/bin/true", "args": [], "env": ["LITERAL": "quotes ' $()"]]
        _ = try await config.invoke(executable: executable, arguments: [], operation: .addMCP(name: "owned-fixture", configuration: server, scope: .project))
        let bytes = try Data(contentsOf: root.appendingPathComponent("project/.mcp.json"))
        let saved = try JSONDecoder().decode(JSONValue.self, from: bytes)
        XCTAssertEqual(saved["mcpServers"]["owned-fixture"]["env"]["LITERAL"], "quotes ' $()")
        _ = try await config.invoke(executable: executable, arguments: [], operation: .removeMCP(name: "owned-fixture", scope: .project))
        let removed = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("project/.mcp.json")))
        XCTAssertTrue(removed["mcpServers"]["owned-fixture"].isNull)
        do { _ = try await config.invoke(executable: executable, arguments: [], operation: .addMCP(name: "foreign", configuration: server, scope: .managed)); XCTFail("Managed MCP mutated") } catch {}
    }
    func testPatchPreservesUnknownIntegersBeyondDoublePrecision() async throws {
        let (_, config) = try fixture()
        let document = try await config.document(scope: .user, kind: .settings)
        let original = try await config.save(document, text: #"{"futureId":9007199254740993,"env":{"OTHER":"keep"}}"#)
        let saved = try await config.set(original, path: ["spinnerTipsEnabled"], value: false)
        XCTAssertTrue(saved.text.contains("9007199254740993"), "Unknown numeric settings must not be rounded while editing another key")
        XCTAssertTrue(saved.text.contains("keep"))
    }
    func testActualCLIInstallsDisablesEnablesAndUninstallsOwnedLocalPlugin() async throws {
        let (root, config) = try fixture()
        let executable = FileManager.default.currentDirectoryPath + "/.build/agent/node_modules/.bin/claude-agent-acp"
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("Pinned Claude CLI fixture not installed") }
        let marketplace = root.appendingPathComponent("marketplace"), manifest = marketplace.appendingPathComponent(".claude-plugin/marketplace.json")
        let plugin = marketplace.appendingPathComponent("fixture-plugin/.claude-plugin/plugin.json")
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(JSONValue.object(["name": "owned-fixture-marketplace", "owner": ["name": "Fixture"], "plugins": [["name": "fixture-plugin", "source": "./fixture-plugin", "description": "Owned offline test plugin"]]])).write(to: manifest)
        try JSONEncoder().encode(JSONValue.object(["name": "fixture-plugin", "version": "1.0.0", "description": "Owned offline test plugin"])).write(to: plugin)
        _ = try await config.invoke(executable: executable, arguments: [], operation: .addMarketplace(source: marketplace.path))
        let name = "fixture-plugin@owned-fixture-marketplace"
        _ = try await config.invoke(executable: executable, arguments: [], operation: .installPlugin(name: name, scope: .project))
        let listed = try await config.invoke(executable: executable, arguments: [], operation: .plugins)
        XCTAssertTrue(listed.contains(name))
        let settingsURL = root.appendingPathComponent("project/.claude/settings.json")
        _ = try await config.invoke(executable: executable, arguments: [], operation: .enablePlugin(name: name, scope: .project, enabled: false))
        var settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settingsURL))
        XCTAssertEqual(settings["enabledPlugins"][name], false)
        _ = try await config.invoke(executable: executable, arguments: [], operation: .enablePlugin(name: name, scope: .project, enabled: true))
        settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: settingsURL))
        XCTAssertEqual(settings["enabledPlugins"][name], true)
        _ = try await config.invoke(executable: executable, arguments: [], operation: .uninstallPlugin(name: name, scope: .project))
        let final = try await config.invoke(executable: executable, arguments: [], operation: .plugins)
        XCTAssertFalse(final.contains(name))
    }
}
