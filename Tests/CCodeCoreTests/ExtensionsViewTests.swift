import XCTest
import SwiftUI
import AppKit
import CCodeCore
@testable import CCode

final class ExtensionsViewTests: XCTestCase {
    @MainActor func testSwitchingScopeKeepsDraftAndConflictKeepsUnsavedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-extension-editor-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let configuration = try AgentConfiguration(project: root.appendingPathComponent("project").path, configurationDirectory: root.appendingPathComponent("config").path)
        let model = ExtensionsModel(configuration: configuration)
        try await model.select(scope: .project, kind: .settings)
        model.text = #"{"env":{"CCODE_LITERAL":"local draft"}}"#
        try await model.select(scope: .user, kind: .settings)
        model.text = #"{"spinnerTipsEnabled":false}"#
        try await model.select(scope: .project, kind: .settings)
        XCTAssertTrue(model.text.contains("local draft"))
        let path = try XCTUnwrap(model.document?.path)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"external":true}"#.utf8).write(to: URL(fileURLWithPath: path))
        do { try await model.save(); XCTFail("UI overwrote external configuration") } catch {}
        XCTAssertTrue(model.text.contains("local draft"))
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("external"))
        try await model.select(scope: .user, kind: .settings)
        try await model.save()
        XCTAssertFalse(model.dirty)
        XCTAssertTrue(try String(contentsOfFile: model.document!.path, encoding: .utf8).contains("spinnerTipsEnabled"))
    }
    @MainActor func testEditorRendersAtNarrowAndWideSizesAndManagedScopeIsReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-extension-layout-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = ExtensionsModel(configuration: try AgentConfiguration(project: root.path, configurationDirectory: root.appendingPathComponent("config").path))
        try await model.select(scope: .managed, kind: .settings)
        XCTAssertFalse(model.document?.editable ?? true)
        for width: CGFloat in [640, 900] {
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: ConfigurationEditor(model: model).frame(width: width, height: 470).environment(\.colorScheme, scheme))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 470)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
                XCTAssertLessThanOrEqual(host.fittingSize.height, 471)
            }
        }
    }
    @MainActor func testNativeManagerReadsActualPeerStatusWithoutPersistingRuntimeData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-native-live-config-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("empty-history"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "live_configuration", withExtension: "py", subdirectory: "Fixtures")!.path]
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected); try await store.connect(chat)
        let model = ExtensionsModel(configuration: try AgentConfiguration(project: root.path, configurationDirectory: root.appendingPathComponent("config").path))
        model.invokeLive(store: store, chat: chat, operation: .status)
        let until = ContinuousClock.now + .seconds(5)
        while model.operating, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.liveServers.first?.name, "fixture")
        XCTAssertEqual(model.liveServers.first?.status, .connected)
        XCTAssertNil(model.failure)
        XCTAssertFalse(chat.transcript.items.contains { $0.text.contains("read_fixture") })
        XCTAssertFalse(chat.transcript.items.contains { $0.text.contains("76659112") })
    }
    @MainActor func testNativeSignInTracksProviderCompletionAndCancelsWithoutPersistingURL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-mcp-auth-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: root.appendingPathComponent("data"), claudeDirectory: root.appendingPathComponent("empty-history"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "live_configuration", withExtension: "py", subdirectory: "Fixtures")!.path]
        addTeardownBlock { await store.shutdown(); try? FileManager.default.removeItem(at: root) }
        await store.create(path: root.path, worktree: false)
        let chat = try XCTUnwrap(store.selected); try await store.connect(chat)
        let peer = try XCTUnwrap(chat.connection)
        _ = try await peer.request("fixture/auth-required", params: [:])
        let model = ExtensionsModel(configuration: try AgentConfiguration(project: root.path, configurationDirectory: root.appendingPathComponent("config").path))
        model.authenticate(store: store, chat: chat, name: "fixture")
        var until = ContinuousClock.now + .seconds(5)
        while model.authentication == nil, model.operating, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.authentication?.url?.host, "issuer.example"); XCTAssertTrue(model.operating)
        _ = try await peer.request("fixture/auth-complete", params: [:])
        until = ContinuousClock.now + .seconds(5)
        while model.operating, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.authentication); XCTAssertNil(model.failure)
        XCTAssertEqual(model.liveServers.first?.status, .connected)
        XCTAssertEqual(model.notice, "Signed in to fixture.")
        _ = try await peer.request("fixture/auth-required", params: [:])
        model.authenticate(store: store, chat: chat, name: "fixture")
        until = ContinuousClock.now + .seconds(5)
        while model.authentication == nil, model.operating, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        model.cancel()
        until = ContinuousClock.now + .seconds(5)
        while model.operating, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.authentication)
        let state = try await peer.request("fixture/state", params: [:])
        XCTAssertTrue(state["flow"].isNull)
        XCTAssertFalse(chat.transcript.items.contains { $0.text.contains("issuer.example") || $0.text.contains("private-fixture") })
    }

    @MainActor func testNativePluginInstallerWaitsForReviewAndUsesTheExactAcceptedReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-native-plugin-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("cli.py"), marker = root.appendingPathComponent("accepted.json")
        try """
        import json,sys,pathlib
        args=sys.argv[1:];plugin=args[args.index('install')+1];scope=args[args.index('--scope')+1]
        value=dict(command='install',plugin=plugin,scope=scope)
        if '--accept-command' in args:
            pathlib.Path(\(String(reflecting: marker.path))).write_text(json.dumps(args))
            print(json.dumps(dict(**value,outcome='ok')),flush=True)
        else:
            print(json.dumps(dict(**value,outcome='failed',shownCommand=dict(kind='command_source',pluginId=plugin,command='fixture-tool render-plugin',sha256='a'*64,mode='copy'))),flush=True)
        print('private diagnostic must not appear',file=sys.stderr,flush=True)
        sys.exit(0 if '--accept-command' in args else 1)
        """.write(to: script, atomically: true, encoding: .utf8)
        let agent = AgentSettings(executable: "/usr/bin/python3", arguments: [script.path])
        let model = ExtensionsModel(configuration: try AgentConfiguration(project: root.path, configurationDirectory: root.appendingPathComponent("config").path))
        model.invoke(agent: agent, operation: .installPlugin(name: "fixture@owned", scope: .project))
        var until = ContinuousClock.now + .seconds(5)
        while model.operating, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        let review = try XCTUnwrap(model.pluginReview)
        XCTAssertEqual(review.command, "fixture-tool render-plugin"); XCTAssertEqual(review.scope, .project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path)); XCTAssertFalse(model.cliOutput.contains("private diagnostic"))
        for width: CGFloat in [440, 640] {
            for scheme in [ColorScheme.light, .dark] {
                let host = NSHostingView(rootView: PluginInstallReviewView(review: review, changing: false, accept: {}, cancel: {}).frame(width: width).environment(\.colorScheme, scheme))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 300); host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, width, accuracy: 1); XCTAssertLessThanOrEqual(host.fittingSize.height, 360)
            }
        }
        model.acceptPluginReview(agent: agent)
        until = ContinuousClock.now + .seconds(5)
        while model.operating, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.failure); XCTAssertNil(model.pluginReview)
        let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: marker))
        XCTAssertTrue(arguments.contains("--accept-command")); XCTAssertTrue(arguments.contains(String(repeating: "a", count: 64))); XCTAssertFalse(arguments.contains("--yes"))
        XCTAssertFalse(model.cliOutput.contains("private diagnostic"))
        model.invoke(agent: agent, operation: .installPlugin(name: "fixture@owned", scope: .project))
        until = ContinuousClock.now + .seconds(5)
        while model.operating, ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.pluginReview)
        model.cancel(); XCTAssertNil(model.pluginReview)
    }

}
