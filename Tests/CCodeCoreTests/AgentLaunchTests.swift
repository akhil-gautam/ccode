import XCTest
import CCodeCore
@testable import CCode

final class AgentLaunchTests: XCTestCase {
    func testExplicitNodeEntryUsesSameBridgeAndRetainsExactRuntimeAndArguments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("claude-agent-acp"), entry = package.appendingPathComponent("dist/index.js")
        try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: entry)
        try "{\"name\":\"@agentclientprotocol/claude-agent-acp\",\"version\":\"0.84.0\"}".write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let bridge = root.appendingPathComponent("bridge with spaces.mjs")
        try Data().write(to: bridge)
        let runtime = "/chosen runtime/node", arguments = [entry.path, "--literal", "space and $value"]
        let launch = AgentSettings.nativeSubagentLaunch(executable: runtime, arguments: arguments, bridge: bridge.path, node: "/different/node")
        XCTAssertEqual(launch.executable, runtime, "Do not replace a user's configured Node runtime")
        XCTAssertEqual(launch.arguments, [bridge.path, entry.path, "--literal", "space and $value"])
        for unsupported in [["--inspect", entry.path], ["-e", "literal code"], ["relative/index.js"], []] {
            let fallback = AgentSettings.nativeSubagentLaunch(executable: runtime, arguments: unsupported, bridge: bridge.path, node: "/different/node")
            XCTAssertEqual(fallback.executable, runtime)
            XCTAssertEqual(fallback.arguments, unsupported, "Unsupported Node launch semantics remain unchanged")
        }
        try "{\"name\":\"@agentclientprotocol/claude-agent-acp\",\"version\":\"0.85.0\"}".write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let newer = AgentSettings.nativeSubagentLaunch(executable: runtime, arguments: arguments, bridge: bridge.path, node: "/different/node")
        XCTAssertEqual(newer.executable, runtime); XCTAssertEqual(newer.arguments, arguments)
    }

    func testOnlyPinnedOfficialEntryUsesThePackagedCapabilityBridge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = root.appendingPathComponent("claude-agent-acp"), entry = package.appendingPathComponent("dist/index.js")
        try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: entry)
        let executable = root.appendingPathComponent("claude-agent-acp-bin")
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: entry)
        let bridge = root.appendingPathComponent("bridge with spaces.mjs")
        try Data().write(to: bridge)
        try "{\"name\":\"@agentclientprotocol/claude-agent-acp\",\"version\":\"0.84.0\"}".write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let launch = AgentSettings.nativeSubagentLaunch(executable: executable.path, arguments: ["--literal", "space and $value"], bridge: bridge.path, node: "/usr/bin/node")
        XCTAssertEqual(launch.executable, "/usr/bin/node")
        XCTAssertEqual(launch.arguments, [bridge.path, entry.path, "--literal", "space and $value"])
        try "{\"name\":\"@agentclientprotocol/claude-agent-acp\",\"version\":\"0.85.0\"}".write(to: package.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let newer = AgentSettings.nativeSubagentLaunch(executable: executable.path, arguments: [], bridge: bridge.path, node: "/usr/bin/node")
        XCTAssertEqual(newer.executable, executable.path)
        XCTAssertTrue(newer.arguments.isEmpty)
        let unrelated = AgentSettings.nativeSubagentLaunch(executable: "/usr/bin/python3", arguments: ["fixture.py"], bridge: bridge.path, node: "/usr/bin/node")
        XCTAssertEqual(unrelated.executable, "/usr/bin/python3")
        XCTAssertEqual(unrelated.arguments, ["fixture.py"])
    }
}
