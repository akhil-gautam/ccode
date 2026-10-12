import XCTest
import Foundation
import CCodeCore

final class PluginInstallReviewTests: XCTestCase {
    func testActualCLIReviewsExactCommandAndRefusesChangedCatalogBeforeRunningIt() async throws {
        let executable = FileManager.default.currentDirectoryPath + "/.build/agent/node_modules/.bin/claude-agent-acp"
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("Pinned Claude CLI fixture unavailable") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-plugin-review-\(UUID())")
        let project = root.appendingPathComponent("project"), configDir = root.appendingPathComponent("config")
        let market = root.appendingPathComponent("marketplace"), plugin = root.appendingPathComponent("fixture-plugin"), marker = root.appendingPathComponent("command-ran")
        for folder in [project, configDir, market.appendingPathComponent(".claude-plugin"), plugin.appendingPathComponent(".claude-plugin")] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let config = try AgentConfiguration(project: project.path, configurationDirectory: configDir.path)
        let foreign = try AgentConfiguration(project: project.path, configurationDirectory: configDir.path)
        let script = root.appendingPathComponent("emit.py")
        // Paths are generated fixture paths, not interpolated user shell input.
        try "import pathlib,sys\npathlib.Path(\(String(reflecting: marker.path))).write_text(sys.argv[1] if len(sys.argv)>1 else 'original')\nprint(\(String(reflecting: plugin.path)))\n".write(to: script, atomically: true, encoding: .utf8)
        let manifestURL = market.appendingPathComponent(".claude-plugin/marketplace.json")
        let command = "/usr/bin/python3 \(script.path)"
        var manifest: JSONValue = ["name": "owned-command-marketplace", "owner": ["name": "Fixture"], "plugins": [["name": "fixture-command", "source": ["source": "command", "command": .string(command), "mode": "copy"]]]]
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        try JSONEncoder().encode(JSONValue.object(["name": "fixture-command", "version": "1.0.0"])).write(to: plugin.appendingPathComponent(".claude-plugin/plugin.json"))
        _ = try await config.invoke(executable: executable, arguments: [], operation: .addMarketplace(source: market.path))
        let name = "fixture-command@owned-command-marketplace"
        let initial = try await config.installPlugin(executable: executable, arguments: [], name: name, scope: .project)
        guard case .review(let review) = initial else { return XCTFail("Command must be reviewed before it runs") }
        XCTAssertEqual(review.command, command); XCTAssertEqual(review.plugin, name); XCTAssertEqual(review.scope, .project)
        XCTAssertEqual(review.sha256.count, 64); XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        do { _ = try await foreign.acceptPluginInstallation(review, executable: executable, arguments: []); XCTFail("Foreign receipt accepted") } catch {}
        do { _ = try await config.acceptPluginInstallation(review, executable: executable, arguments: ["changed-agent"]); XCTFail("Changed launch accepted") } catch {}
        var entry = manifest["plugins"].array[0]; entry["source"]["command"] = .string(command + " changed"); manifest["plugins"] = .array([entry])
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let stale = try await config.acceptPluginInstallation(review, executable: executable, arguments: [])
        guard case .review(let replacement) = stale else { return XCTFail("Changed catalog must require another review") }
        XCTAssertNotEqual(replacement.sha256, review.sha256); XCTAssertEqual(replacement.command, command + " changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let accepted = try await config.acceptPluginInstallation(replacement, executable: executable, arguments: [])
        guard case .installed = accepted else { return XCTFail("Exact reviewed command should install") }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "changed")
        let settings = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: project.appendingPathComponent(".claude/settings.json")))
        XCTAssertEqual(settings["enabledPlugins"][name], true)
        do { _ = try await config.acceptPluginInstallation(replacement, executable: executable, arguments: []); XCTFail("Consumed receipt replayed") } catch {}
    }
    func testJSONResultIsSeparateFromLateStandardError() async throws {
        let terminals = TerminalService()
        let id = try await terminals.create(command: "/usr/bin/python3", arguments: ["-c", "import sys,time;print('{\"outcome\":\"failed\"}',flush=True);time.sleep(0.05);print('late diagnostic',file=sys.stderr,flush=True)"], directory: FileManager.default.temporaryDirectory.path, captureStandardErrorSeparately: true)
        addTeardownBlock { await terminals.close() }
        _ = try await terminals.wait(id)
        let output = try await terminals.output(id)
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(output["output"].string.utf8))
        XCTAssertEqual(result["outcome"], "failed")
        XCTAssertEqual(output["standardError"].string.trimmingCharacters(in: .whitespacesAndNewlines), "late diagnostic")
        XCTAssertEqual(output["exitStatus"]["exitCode"], 0)
    }

}
