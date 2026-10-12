import Foundation
import XCTest
import AppKit
import SwiftUI
@testable import CCodeCore
@testable import CCode

final class RemoteWorkflowTests: XCTestCase, @unchecked Sendable {
    func testEnvironmentIdentityPersistsAndRefusesLocalURLInterpretation() throws {
        let host = try SSHConfiguration(name: "Build VM", host: "dev@build-box", port: 2202, identityFile: "/tmp/key with spaces")
        let location = try WorkspaceLocation(environment: .ssh(host), path: "/projects/日本語 folder")
        let restored = try JSONDecoder().decode(WorkspaceLocation.self, from: JSONEncoder().encode(location))
        XCTAssertEqual(restored, location)
        XCTAssertThrowsError(try location.localURL())
        XCTAssertNotEqual(location.identity, try WorkspaceLocation(environment: .local, path: location.path).identity)
        var info = SessionInfo(projectPath: location.path)
        info.executionEnvironment = .ssh(host)
        XCTAssertEqual(try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(info)).environment, .ssh(host))
        XCTAssertEqual(try JSONDecoder().decode(SessionInfo.self, from: JSONEncoder().encode(SessionInfo(projectPath: "/tmp"))).environment, .local)
        for invalid in ["", "-oProxyCommand=touch", "host;touch /tmp/no", "host\nnext", "a@b@c"] {
            XCTAssertThrowsError(try SSHConfiguration(name: "x", host: invalid))
        }
        XCTAssertThrowsError(try SSHConfiguration(name: "x", host: "host", port: 0))
        XCTAssertThrowsError(try SSHConfiguration(name: "x", host: "host", identityFile: "relative"))
        XCTAssertThrowsError(try WorkspaceLocation(environment: .ssh(host), path: "~/repo"))
    }

    func testRemoteShellArgumentsAndCWDStayLiteralAndSSHPolicyIsExplicit() async throws {
        let fixture = try temporary(), remote = fixture.appendingPathComponent("remote ' 日本語")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let transport = try boundary(in: fixture)
        let marker = fixture.appendingPathComponent("injected")
        let hostile = "$(touch \(marker.path)); `touch \(marker.path)` ' \" \n"
        let result = try await transport.run(executable: "/usr/bin/python3", arguments: ["-c", "import json,sys,os; print(json.dumps([os.getcwd(),sys.argv[1]],ensure_ascii=False))", hostile], directory: remote.path)
        let values = try JSONDecoder().decode([String].self, from: Data(result.utf8))
        XCTAssertEqual(values, [remote.path, hostile])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let launch = try transport.launch(executable: "claude-agent-acp", arguments: [hostile], directory: "/remote/path")
        XCTAssertEqual(launch.directory, "/")
        for option in ["BatchMode=yes", "StrictHostKeyChecking=yes", "ClearAllForwardings=yes", "ForwardAgent=no", "ControlMaster=no", "ControlPath=none", "PermitLocalCommand=no"] {
            XCTAssertTrue(launch.arguments.contains(option), option)
        }
        XCTAssertEqual(launch.arguments.suffix(2).first, "fixture-host")
    }

    func testScopedRemoteFilesConflictsSymlinksAndBinaryTransfers() async throws {
        let fixture = try temporary(), root = fixture.appendingPathComponent("remote"), outside = fixture.appendingPathComponent("outside")
        for directory in [root, outside] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let remote = try RemoteWorkspace(root: root.path, transport: boundary(in: fixture))
        let file = root.appendingPathComponent("nested/日本語 ' file.txt").path
        try await remote.write(file, content: "first\nsecond\nthird")
        let text = try await remote.read(file, line: 2, limit: 1); XCTAssertEqual(text, "second")
        try await remote.write(file, content: "updated", expecting: "first\nsecond\nthird")
        do { try await remote.write(file, content: "lost", expecting: "first\nsecond\nthird"); XCTFail("Overwrote remote conflict") } catch { }
        let current = try await remote.read(file); XCTAssertEqual(current, "updated")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: outside.path)
        for path in [outside.appendingPathComponent("bad").path, root.path + "-sibling/bad", root.appendingPathComponent("escape/bad").path, root.path + "/../outside/bad"] {
            do { try await remote.write(path, content: "bad"); XCTFail("Remote scope escape") } catch { }
        }
        let binary = Data((0..<100_000).map { UInt8($0 % 256) })
        let attachment = root.appendingPathComponent("context/image.bin").path
        try await remote.upload(binary, to: attachment)
        let downloaded = try await remote.download(attachment); XCTAssertEqual(downloaded, binary)
        do { try await remote.upload(Data([1]), to: attachment); XCTFail("Overwrote existing transfer") } catch { }
        let files = try await remote.files(); XCTAssertEqual(Set(files), ["nested/日本語 ' file.txt", "context/image.bin"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("bad").path))
    }

    func testRemoteRepositoryAndTerminalExecuteInCapturedRemoteRoot() async throws {
        let fixture = try temporary(), root = fixture.appendingPathComponent("remote git")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let remote = try RemoteWorkspace(root: root.path, transport: boundary(in: fixture))
        _ = try await remote.git(["init", "-b", "main"])
        try await remote.write(root.appendingPathComponent("change.txt").path, content: "remote change")
        let status = try await remote.git(["status", "--porcelain"])
        XCTAssertTrue(status.contains("change.txt"))
        let terminal = try await remote.run(executable: "/bin/pwd")
        XCTAssertEqual(terminal.trimmingCharacters(in: .newlines), root.path)
        do { _ = try await remote.git(["status"], directory: fixture.path); XCTFail("Unscoped repository root") } catch { }
    }

    func testConnectionFailureIsNeverLocalFallbackAndMutationIsUncertain() async throws {
        let root = try temporary(), ssh = root.appendingPathComponent("offline-ssh")
        try "#!/bin/sh\necho 'Connection closed' >&2\nexit 255\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let transport = try SSHTransport(configuration: SSHConfiguration(name: "Offline", host: "offline-host"), executable: ssh.path)
        let remote = try RemoteWorkspace(root: root.path, transport: transport), marker = root.appendingPathComponent("must-not-exist")
        do { _ = try await remote.read(marker.path); XCTFail("Connection should fail") }
        catch { XCTAssertEqual((error as? SSHTransportError)?.kind, .connection) }
        do { try await remote.write(marker.path, content: "no fallback"); XCTFail("Mutation should fail") }
        catch { XCTAssertEqual((error as? SSHTransportError)?.kind, .uncertainMutation) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testBoundedInputCancellationAndTimeoutReleaseOnlyOwnedProcess() async throws {
        let fixture = try temporary(), transport = try boundary(in: fixture)
        let bytes = Data(repeating: 65, count: 700_000)
        let count = try await transport.run(executable: "/usr/bin/python3", arguments: ["-c", "import sys; print(len(sys.stdin.buffer.read()))"], directory: fixture.path, input: bytes)
        XCTAssertEqual(count.trimmingCharacters(in: .newlines), "700000")
        do { _ = try await transport.run(executable: "/bin/sleep", arguments: ["30"], directory: fixture.path, timeout: .milliseconds(100)); XCTFail("Timeout should stop owned SSH") }
        catch { XCTAssertEqual((error as? SSHTransportError)?.kind, .timeout) }
        let task = Task { try await transport.run(executable: "/bin/sleep", arguments: ["30"], directory: fixture.path) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled SSH continued") } catch { XCTAssertTrue(error is CancellationError) }
        let stillWorks = try await transport.run(executable: "/usr/bin/true", directory: fixture.path)
        XCTAssertEqual(stillWorks, "")
        do { _ = try await transport.run(executable: "/usr/bin/python3", arguments: ["-c", "print('a'*10000)"], directory: fixture.path, byteLimit: 1024); XCTFail("Accepted truncated output") }
        catch { XCTAssertEqual((error as? SSHTransportError)?.kind, .outputLimit) }
    }

    func testACPUsesRemoteShellWithoutAdvertisingLocalCallbacks() async throws {
        let fixture = try temporary(), transport = try boundary(in: fixture)
        let agent = try XCTUnwrap(Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures"))
        let peer = ACPConnection(onUpdates: { _ in }, onRequest: { _, _ in throw ACPError.methodNotFound("Unavailable") })
        do {
            try await peer.start(environment: .ssh(transport.configuration), executable: "/usr/bin/python3", arguments: [agent.path], directory: fixture.path, sshExecutable: transport.executable)
            let handshake = try await peer.request("initialize", params: ["protocolVersion": 1, "clientCapabilities": ExecutionEnvironment.ssh(transport.configuration).clientCapabilities])
            XCTAssertEqual(handshake["protocolVersion"].int, 1)
            XCTAssertTrue(ExecutionEnvironment.ssh(transport.configuration).clientCapabilities["fs"].isNull)
            XCTAssertTrue(ExecutionEnvironment.ssh(transport.configuration).clientCapabilities["terminal"].isNull)
            await peer.close()
        } catch { await peer.close(); throw error }
    }

    @MainActor func testRemoteChatControllerDoesNotRequireAMatchingLocalDirectory() throws {
        let host = try SSHConfiguration(name: "Remote", host: "vm")
        let chat = try ChatSession(id: UUID(), path: "/nonexistent-on-this-mac/project", transcript: SessionTranscript(), environment: .ssh(host))
        XCTAssertEqual(chat.workspace.root, "/nonexistent-on-this-mac/project")
        XCTAssertEqual(chat.workspace.environment, .ssh(host))
    }

    @MainActor func testLocalCatalogCannotMergeIntoAnSSHSessionWithTheSameProviderID() async throws {
        let root = try temporary(), catalog = root.appendingPathComponent("catalog.json")
        let rows: JSONValue = ["sessions": [["sessionId": "same-provider-id", "cwd": .string(root.path), "title": "Local title", "updatedAt": "2026-10-07T00:00:00Z"]]]
        try JSONEncoder().encode(rows).write(to: catalog)
        let store = AppStore(directory: root.appendingPathComponent("data"))
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--list-path=" + catalog.path]
        var remote = SessionInfo(projectPath: root.path, title: "Remote title")
        remote.agentExecutable = store.settings.executable; remote.agentArguments = store.settings.arguments
        remote.remoteSessionID = "same-provider-id"; remote.importedFromAgent = true; remote.agentTitle = remote.title
        remote.executionEnvironment = .ssh(try SSHConfiguration(name: "VM", host: "vm"))
        store.sessions = [remote]
        await store.refreshSessionHistory()
        XCTAssertNil(store.sessionHistoryError)
        XCTAssertEqual(store.sessions.first { $0.id == remote.id }, remote)
        XCTAssertEqual(store.sessions.filter { $0.environment.isLocal && $0.remoteSessionID == "same-provider-id" }.count, 1)
        await store.shutdown()
    }

    @MainActor func testConnectRefusesRemoteMetadataEvenIfALocalControllerWasAlreadyLoaded() async throws {
        let root = try temporary(), store = AppStore(directory: root.appendingPathComponent("data")), audit = root.appendingPathComponent("must-not-connect.jsonl")
        store.settings.executable = "/usr/bin/python3"
        store.settings.arguments = [Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path, "--audit-path=" + audit.path]
        await store.create(path: root.path, worktree: false)
        let local = try XCTUnwrap(store.selected)
        var info = try XCTUnwrap(store.sessions.first { $0.id == local.id })
        info.executionEnvironment = .ssh(try SSHConfiguration(name: "Remote", host: "vm"))
        store.sessions = [info]
        do { try await store.connect(local); XCTFail("Remote identity launched local agent") } catch { }
        XCTAssertNil(local.connection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audit.path))
        await store.shutdown()
    }

    func testExplicitCommandFailureAndExclusiveUploadRefusalAreKnownFailures() async throws {
        let fixture = try temporary(), transport = try boundary(in: fixture)
        do { _ = try await transport.run(executable: "/bin/sh", arguments: ["-c", "exit 7"], directory: fixture.path); XCTFail("Command should fail") }
        catch { XCTAssertEqual((error as? SSHTransportError)?.kind, .operation) }
        let remote = try RemoteWorkspace(root: fixture.path, transport: transport), file = fixture.appendingPathComponent("existing.bin").path
        try await remote.upload(Data([1, 2]), to: file)
        do { try await remote.upload(Data([3]), to: file); XCTFail("Upload collision must refuse") }
        catch { XCTAssertEqual((error as? SSHTransportError)?.kind, .operation) }
        let original = try await remote.download(file); XCTAssertEqual(original, Data([1, 2]))
    }

    func testMissingRemoteExecutableAndInvalidSavedConfigurationFailClosed() async throws {
        let fixture = try temporary(), transport = try boundary(in: fixture)
        let marker = fixture.appendingPathComponent("missing-agent-ran")
        do { _ = try await transport.run(executable: "/does-not-exist/claude", directory: fixture.path); XCTFail("Missing remote executable should fail") }
        catch { XCTAssertEqual((error as? SSHTransportError)?.kind, .operation) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let invalid: JSONValue = ["id": .string(UUID().uuidString), "name": "bad", "host": "host;bad"]
        XCTAssertThrowsError(try JSONDecoder().decode(SSHConfiguration.self, from: JSONEncoder().encode(invalid)))
    }

    @MainActor func testAuthenticatedDisposableSSHFileGitACPAndHostKeyRefusal() async throws {
        guard let path = ProcessInfo.processInfo.environment["CCODE_SSH_LOOPBACK_PROOF"] else { throw XCTSkip("Opt-in disposable authenticated SSH server proof.") }
        let proof = URL(fileURLWithPath: path), metadata = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: proof))
        let server = URL(fileURLWithPath: metadata["directory"].string)
        guard server.path.hasPrefix(FileManager.default.currentDirectoryPath + "/.build/ssh-loopback-"), metadata["configuration_check_exit"].exactInteger == 0 else { throw ACPError.workspace("Use the isolated loopback proof configuration.") }
        let host = try SSHConfiguration(name: "Disposable loopback", host: "ccode-disposable-loopback")
        let transport = try SSHTransport(configuration: host, executable: server.appendingPathComponent("ssh-wrapper").path)
        let root = try temporary(), remote = try RemoteWorkspace(root: root.path, transport: transport), file = root.appendingPathComponent("quoted ' 日本語.txt").path
        try await remote.write(file, content: "SSH nonce \(UUID().uuidString)")
        let original = try await remote.read(file)
        XCTAssertTrue(original.hasPrefix("SSH nonce "))
        try await remote.write(file, content: "changed", expecting: original)
        do { try await remote.write(file, content: "must not replace", expecting: original); XCTFail("Remote conflict was overwritten") } catch { XCTAssertEqual((error as? SSHTransportError)?.kind, .operation) }
        let saved = try await remote.read(file); XCTAssertEqual(saved, "changed")
        let exactBytes = Data((0..<200_000).map { UInt8($0 % 256) }), binary = root.appendingPathComponent("input.bin").path
        try await remote.upload(exactBytes, to: binary)
        let restored = try await remote.download(binary); XCTAssertEqual(restored, exactBytes)
        _ = try await remote.git(["init", "-b", "main"], mutation: true)
        let status = try await remote.git(["status", "--porcelain", "-z"]); XCTAssertTrue(status.contains("日本語.txt"))

        let agent = try XCTUnwrap(Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures"))
        let peer = ACPConnection(onUpdates: { _ in }, onRequest: { _, _ in throw ACPError.methodNotFound("Remote callback unavailable") })
        do {
            try await peer.start(environment: .ssh(host), executable: "/usr/bin/python3", arguments: [agent.path], directory: root.path, sshExecutable: transport.executable)
            let initialized = try await peer.request("initialize", params: ["protocolVersion": 1, "clientCapabilities": ExecutionEnvironment.ssh(host).clientCapabilities])
            XCTAssertEqual(initialized["protocolVersion"].int, 1)
            let created = try await peer.request("session/new", params: ["cwd": .string(root.path), "mcpServers": []])
            XCTAssertFalse(created["sessionId"].string.isEmpty)
            await peer.close()
        } catch { await peer.close(); throw error }

        // Exercise the actual app controller through encrypted OpenSSH, not the shell boundary fixture.
        let storageDirectory = root.appendingPathComponent("app-data")
        let store = AppStore(directory: storageDirectory, claudeDirectory: root.appendingPathComponent("empty-history"), sshExecutable: transport.executable)
        addTeardownBlock { await store.shutdown() }
        let sessionID = try await store.createSSHWorkspace(host: host, path: root.path, executable: "/usr/bin/python3", arguments: [agent.path, "--resume"])
        let chat = try XCTUnwrap(store.selected)
        if case .ssh(let captured) = chat.workspace.environment { XCTAssertNotNil(captured.resolvedOptionsDigest) } else { XCTFail("Lost SSH identity") }
        try await store.connect(chat)
        chat.draft = "encrypted SSH controller proof"; store.send(chat)
        for _ in 0..<300 where chat.approvals.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let approval = try XCTUnwrap(chat.approvals.first)
        store.resolveApproval(chat, id: approval.id, option: "allow")
        await chat.promptTask?.value
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "assistant" && $0.text.contains("Hello") })
        let editorKey = try await store.loadWorkspaceFile(chat, path: "quoted ' 日本語.txt")
        chat.fileDrafts[editorKey]?.text = "saved through encrypted remote editor"
        try await store.saveWorkspaceFile(chat, key: editorKey)
        try await store.stageWorkspaceFile(chat, path: "quoted ' 日本語.txt")
        _ = try await chat.workspace.repository.run(["-c", "user.name=SSH Fixture", "-c", "user.email=ssh-fixture@example.invalid", "commit", "-m", "SSH fixture"], at: root.path)
        try await store.createWorkspaceBranch(chat, name: "ssh-proof-branch")
        let contents = try await remote.read(file); XCTAssertEqual(contents, "saved through encrypted remote editor")
        let terminal = try store.openWorkspaceTerminal(chat)
        for _ in 0..<300 where !terminal.ready && !terminal.ended { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(terminal.ready, terminal.failure ?? "SSH terminal did not become ready")
        terminal.send(source: terminal.view, data: Array("/bin/pwd > encrypted-pty-cwd.txt\r".utf8)[...])
        for _ in 0..<400 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("encrypted-pty-cwd.txt").path) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("encrypted-pty-cwd.txt"), encoding: .utf8).trimmingCharacters(in: .newlines), root.path)
        await terminal.close(); chat.terminalTabs.removeAll()
        await store.shutdown()
        let restoredStore = AppStore(directory: storageDirectory, claudeDirectory: root.appendingPathComponent("empty-history"), sshExecutable: transport.executable)
        addTeardownBlock { await restoredStore.shutdown() }
        await restoredStore.restore(); await restoredStore.select(sessionID)
        let restoredChat = try XCTUnwrap(restoredStore.selected)
        try await restoredStore.connect(restoredChat)
        XCTAssertEqual(restoredChat.workspace.environment, chat.workspace.environment)
        await restoredStore.shutdown()

        let publicKey = try String(contentsOf: server.appendingPathComponent("client-key.pub"), encoding: .utf8).split(separator: " ")
        let wrongHosts = root.appendingPathComponent("wrong-known-hosts")
        try "[127.0.0.1]:\(metadata["port"].int) \(publicKey[0]) \(publicKey[1])\n".write(to: wrongHosts, atomically: true, encoding: .utf8)
        let wrapper = root.appendingPathComponent("wrong-key-ssh")
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        try "#!/bin/sh\nexec /usr/bin/ssh -o \(quote("UserKnownHostsFile=" + wrongHosts.path)) -F \(quote(server.appendingPathComponent("ssh_config").path)) \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let rejected = try SSHTransport(configuration: host, executable: wrapper.path), marker = root.appendingPathComponent("untrusted-host-write")
        do { _ = try await rejected.run(executable: "/usr/bin/touch", arguments: [marker.path], directory: root.path, mutation: true); XCTFail("Changed host key accepted") }
        catch { XCTAssertEqual((error as? SSHTransportError)?.kind, .uncertainMutation); XCTAssertTrue(error.localizedDescription.contains("HOST IDENTIFICATION HAS CHANGED")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        guard let run = testRun, run.failureCount == 0 else { return }
        let proofResult: JSONValue = ["accepted": true, "authenticatedSSH": true, "fileConflictBoundary": true, "binaryTransferBytes": .number(Double(exactBytes.count)), "git": true, "acpInitializeNew": true, "hostKeyRefused": true, "appControllerPromptEditorBranchAndPTY": true, "appRestartResume": true, "nativeAccepted": false, "differentMachineAccepted": false]
        try JSONEncoder().encode(proofResult).write(to: server.appendingPathComponent("verified-transport.json"), options: .atomic)
    }

    // Fails if Workspace or the repository facade silently reads the Mac instead of SSH.
    func testUnifiedWorkspaceRoutesEditorCatalogContextAndGitThroughSSH() async throws {
        let fixture = try temporary(), root = fixture.appendingPathComponent("remote routed")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = try boundary(in: fixture)
        let workspace = try Workspace(root: root.path, environment: .ssh(transport.configuration), sshExecutable: transport.executable)
        _ = try await transport.run(executable: "git", arguments: ["init", "-b", "main"], directory: root.path)
        let path = root.path + "/日本語.txt"
        try await workspace.write(path, content: "remote first\nsecond")
        let text = try await workspace.read(path); XCTAssertEqual(text, "remote first\nsecond")
        let files = try await workspace.files(); XCTAssertEqual(files, ["日本語.txt"])
        let candidates = try await workspace.contextCandidates(matching: "日本語")
        XCTAssertEqual(candidates.map(\.path), [path])
        let reference = try await workspace.fileReference("日本語.txt#L2")
        XCTAssertEqual(reference.line, 2)
        let status = try await workspace.repository.status(at: root.path)
        XCTAssertEqual(status.branch, "main"); XCTAssertEqual(status.files.map(\.path), ["日本語.txt"])
        let diff = try await workspace.repository.diff(at: root.path, path: "日本語.txt")
        XCTAssertTrue(diff.contains("+remote first"))
        try await workspace.repository.stage(at: root.path, path: "日本語.txt")
        let staged = try await workspace.repository.status(at: root.path); XCTAssertTrue(staged.files.first?.staged == true)
        let statistics = try await workspace.repository.changeStatistics(at: root.path)
        XCTAssertEqual(statistics["日本語.txt"]?.additions, 2)
        try await workspace.repository.unstage(at: root.path, path: "日本語.txt")
        let unstaged = try await workspace.repository.status(at: root.path); XCTAssertFalse(unstaged.files.first?.staged == true)
        try await workspace.write(path, content: "remote saved", expecting: "remote first\nsecond")
        do { try await workspace.write(path, content: "lost", expecting: "remote first\nsecond"); XCTFail("Overwrote changed file") } catch { }
        let saved = try await workspace.read(path); XCTAssertEqual(saved, "remote saved")
    }

    func testUnifiedRemoteWorkspaceNeverFallsBackWhenTransportIsOffline() async throws {
        let fixture = try temporary(), file = fixture.appendingPathComponent("local-secret.txt")
        try "local secret".write(to: file, atomically: true, encoding: .utf8)
        let ssh = fixture.appendingPathComponent("offline")
        try "#!/bin/sh\nexit 255\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let workspace = try Workspace(root: fixture.path, environment: .ssh(SSHConfiguration(name: "Offline", host: "vm")), sshExecutable: ssh.path)
        do { _ = try await workspace.read(file.path); XCTFail("Read matching local path") } catch { }
        do { _ = try await workspace.repository.status(at: fixture.path); XCTFail("Ran Git locally") } catch { }
        do { try await workspace.write(file.path, content: "bad"); XCTFail("Wrote local file") } catch { }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "local secret")
    }

    @MainActor func testRemoteChatLaunchPromptSaveAndResumeRetainSSHIdentity() async throws {
        let fixture = try temporary(), remote = fixture.appendingPathComponent("remote chat")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        let transport = try boundary(in: fixture), data = fixture.appendingPathComponent("data")
        let store = AppStore(directory: data, sshExecutable: transport.executable)
        let audit = remote.appendingPathComponent("audit.jsonl")
        let agent = try XCTUnwrap(Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures"))
        let id = try await store.createSSHWorkspace(host: transport.configuration, path: remote.path, executable: "/usr/bin/python3", arguments: [agent.path, "--resume", "--audit-path=" + audit.path])
        let chat = try XCTUnwrap(store.selected)
        XCTAssertEqual(chat.id, id)
        try await store.connect(chat)
        XCTAssertEqual(chat.state, .ready)
        chat.draft = "remote hello"; store.send(chat)
        for _ in 0..<200 where chat.approvals.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let approval = try XCTUnwrap(chat.approvals.first)
        store.resolveApproval(chat, id: approval.id, option: "allow")
        await chat.promptTask?.value
        XCTAssertTrue(chat.transcript.items.contains { $0.kind == "assistant" && $0.text.contains("Hello") })
        await store.shutdown()
        let restored = AppStore(directory: data, sshExecutable: transport.executable)
        await restored.restore(); await restored.select(id)
        let again = try XCTUnwrap(restored.selected)
        XCTAssertEqual(again.workspace.environment.identity, ExecutionEnvironment.ssh(transport.configuration).identity)
        try await restored.connect(again)
        let requests = try String(contentsOf: audit, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertTrue(requests.contains { $0["method"] == "session/resume" && $0["params"]["cwd"].string == remote.path })
        let initialize = try XCTUnwrap(requests.first { $0["method"] == "initialize" })
        XCTAssertTrue(initialize["params"]["clientCapabilities"]["fs"]["readTextFile"].bool)
        XCTAssertTrue(initialize["params"]["clientCapabilities"]["_meta"].isNull)
        await restored.shutdown()
    }

    func testRemoteContextSnapshotAndTerminalAreBoundToHost() async throws {
        let fixture = try temporary(), transport = try boundary(in: fixture)
        let workspace = try Workspace(root: fixture.path, environment: .ssh(transport.configuration), sshExecutable: transport.executable)
        let path = fixture.path + "/context.txt"
        try await workspace.write(path, content: "remote context")
        let storage = SessionStorage(directory: fixture.appendingPathComponent("data"))
        let candidate = ContextCandidate(root: fixture.path, path: path, kind: .file)
        let attachment = try await storage.importWorkspaceContext(candidate, workspace: workspace)
        let prompt = try await storage.attachmentPrompt(attachment, capabilities: [:])
        XCTAssertTrue(prompt.first?["text"].string.contains("remote context") == true)
        let terminals = TerminalService()
        let id = try await workspace.createTerminal(terminals, command: "/usr/bin/python3", arguments: ["-c", "import os; print(os.getcwd()); print(os.getenv('ONLY_REMOTE')); print(os.getenv('LOCAL_SECRET','absent'))"], directory: fixture.path, environment: ["ONLY_REMOTE": "literal ' 日本語"], localEnvironment: ["LOCAL_SECRET": "must-stay-local"])
        let exit = try await terminals.wait(id), output = try await terminals.output(id)
        XCTAssertEqual(exit["exitCode"].int, 0)
        XCTAssertEqual(output["output"].string, fixture.path + "\nliteral ' 日本語\nabsent\n")
        await terminals.close()
    }

    func testCapturedSSHOptionsRefuseAliasRebindingBeforeRemoteWrite() async throws {
        let fixture = try temporary(), wrapper = fixture.appendingPathComponent("resolved-ssh"), route = fixture.appendingPathComponent("route")
        try "host-a".write(to: route, atomically: true, encoding: .utf8)
        let script = "#!/usr/bin/python3\nimport os,sys\nif '-G' in sys.argv:\n print('hostname '+open(sys.argv[0]+'.route').read()); print('user fixture'); print('port 22')\nelse: os.execv('/bin/sh',['sh','-c',sys.argv[-1]])\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try "host-a".write(toFile: wrapper.path + ".route", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let original = try SSHTransport(configuration: SSHConfiguration(name: "Alias", host: "alias"), executable: wrapper.path)
        let captured = try await original.resolvedConfiguration()
        let transport = try SSHTransport(configuration: captured, executable: wrapper.path)
        _ = try await transport.run(executable: "/usr/bin/true", directory: fixture.path)
        try "host-b".write(toFile: wrapper.path + ".route", atomically: true, encoding: .utf8)
        let marker = fixture.path + "/must-not-write"
        do { _ = try await transport.run(executable: "touch", arguments: [marker], directory: fixture.path, mutation: true); XCTFail("Alias retargeted saved workspace") } catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testRemoteAttachmentFailureCannotReadMatchingLocalFile() async throws {
        let fixture = try temporary(), secret = fixture.appendingPathComponent("secret.txt"), ssh = fixture.appendingPathComponent("file-helper")
        try "Mac-only secret".write(to: secret, atomically: true, encoding: .utf8)
        let script = #"""
#!/usr/bin/python3
import json,sys
q=json.load(sys.stdin)
r={'version':1,'operation':q['operation'],'root':q['root']}
if q['operation']=='resolve': r.update(ok=True,path=q['path'])
else: r.update(error='Remote attachment is unavailable',ok=False)
print(json.dumps(r))
"""#
        try script.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let workspace = try Workspace(root: fixture.path, environment: .ssh(SSHConfiguration(name: "Remote", host: "vm")), sshExecutable: ssh.path)
        let storage = SessionStorage(directory: fixture.appendingPathComponent("data"))
        do { _ = try await storage.importWorkspaceContext(ContextCandidate(root: fixture.path, path: secret.path, kind: .file), workspace: workspace); XCTFail("Remote attachment read the matching local secret") } catch { }
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "Mac-only secret")
    }

    @MainActor func testRemoteEditorReviewAndInteractiveTerminalUseCapturedWorkspace() async throws {
        let fixture = try temporary(), transport = try boundary(in: fixture), root = fixture.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(directory: fixture.appendingPathComponent("data"), sshExecutable: transport.executable)
        _ = try await store.createSSHWorkspace(host: transport.configuration, path: root.path, executable: "claude-agent-acp")
        let chat = try XCTUnwrap(store.selected)
        _ = try await chat.workspace.repository.run(["init", "-b", "main"], at: root.path)
        let path = root.path + "/edit.txt"
        try await chat.workspace.write(path, content: "remote original\n")
        let key = try await store.loadWorkspaceFile(chat, path: "edit.txt")
        chat.fileDrafts[key]?.text = "remote editor save\n"
        try await store.saveWorkspaceFile(chat, key: key)
        let saved = try await chat.workspace.read(path); XCTAssertEqual(saved, "remote editor save\n")
        let diff = try await chat.workspace.repository.diff(at: root.path, path: "edit.txt")
        try await store.addReviewComment(chat, path: "edit.txt", diff: diff, baseRevision: nil, stagedOnly: false, line: nil, text: "Check this remote change")
        XCTAssertEqual(chat.reviewComments.first?.root, root.path)
        let tab = try store.openWorkspaceTerminal(chat)
        for _ in 0..<300 where !tab.ready && !tab.ended { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(tab.ready, tab.failure ?? "Remote PTY did not start")
        tab.send(source: tab.view, data: Array("printf 'REMOTE_PTY_READY\\n'; pwd > ccode-pty-cwd-proof.txt\r".utf8)[...])
        for _ in 0..<300 { if FileManager.default.fileExists(atPath: root.path + "/ccode-pty-cwd-proof.txt") { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try String(contentsOfFile: root.path + "/ccode-pty-cwd-proof.txt", encoding: .utf8).trimmingCharacters(in: .newlines), root.path)
        XCTAssertTrue(String(describing: tab.view.accessibilityValue()).contains("REMOTE_PTY_READY"), String(describing: tab.view.accessibilityValue()))
        await tab.close(); chat.terminalTabs.removeAll()
        await store.create(path: root.path, worktree: false)
        let local = try XCTUnwrap(store.selected)
        XCTAssertFalse(store.checkpointRestoreChats(chat).contains { $0.id == local.id }, "Remote write ownership blocked a matching local path")
        await store.shutdown()
    }

    func testReviewCaptureCannotFallBackToLocalRepository() async throws {
        let fixture = try temporary(), ssh = fixture.appendingPathComponent("offline-ssh")
        _ = try await Repository.run(["init", "-b", "main"], at: fixture.path)
        try "local change".write(to: fixture.appendingPathComponent("change.txt"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 255\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let workspace = try Workspace(root: fixture.path, environment: .ssh(SSHConfiguration(name: "Remote", host: "vm")), sshExecutable: ssh.path)
        do { _ = try await CodeReview.capture(at: fixture.path, workspace: workspace); XCTFail("Reviewed local changes as remote") } catch { }
    }
    func testRemoteFolderManifestRefusesMissingAndReplacedFolder() async throws {
        let fixture = try temporary(), transport = try boundary(in: fixture)
        let workspace = try Workspace(root: fixture.path, environment: .ssh(transport.configuration), sshExecutable: transport.executable)
        let file = fixture.appendingPathComponent("replaced-folder"); try "not a directory".write(to: file, atomically: true, encoding: .utf8)
        for path in [file.path, fixture.path + "/missing-folder"] {
            do { _ = try await workspace.folderManifest(ContextCandidate(root: fixture.path, path: path, kind: .folder)); XCTFail("Remote manifest accepted a missing/replaced folder") } catch { }
        }
    }
    func testRemoteArtifactSnapshotDownloadsIntoOwnedCacheAndRefusesLocalFallback() async throws {
        let fixture = try temporary(), transport = try boundary(in: fixture), file = fixture.appendingPathComponent("artifact.pdf")
        let bytes = Data("remote artifact".utf8)
        try bytes.write(to: file)
        let workspace = try Workspace(root: fixture.path, environment: .ssh(transport.configuration), sshExecutable: transport.executable)
        var snapshot: WorkspaceArtifactSnapshot? = try await workspace.artifactSnapshot(file.path)
        let cached = try XCTUnwrap(snapshot?.url)
        XCTAssertNotEqual(cached.path, file.path)
        XCTAssertEqual(try Data(contentsOf: cached), bytes)
        snapshot = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.path))
        let offline = fixture.appendingPathComponent("offline")
        try "#!/bin/sh\nexit 255\n".write(to: offline, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: offline.path)
        let unavailable = try Workspace(root: fixture.path, environment: workspace.environment, sshExecutable: offline.path)
        do { _ = try await unavailable.artifactSnapshot(file.path); XCTFail("Quick Look read the matching local artifact") } catch { }
    }
    @MainActor func testRemoteLocalOnlyActionsRefuseBeforeTouchingMacWorkspace() async throws {
        let fixture = try temporary(), transport = try boundary(in: fixture)
        let store = AppStore(directory: fixture.appendingPathComponent("data"), sshExecutable: transport.executable)
        _ = try await store.createSSHWorkspace(host: transport.configuration, path: fixture.path, executable: "agent")
        let chat = try XCTUnwrap(store.selected)
        XCTAssertFalse(store.canDiscardChanges(chat))
        XCTAssertNil(store.localRoutineSource, "Remote paths and executables cannot seed local routines")
        XCTAssertTrue(store.canMutateWorkspace(chat), "SSH editor and Git controls remain usable")
        do { try await store.setAppSessionTools(chat, enabled: true); XCTFail("Forwarded localhost MCP into remote agent") } catch { }
        let marker = fixture.appendingPathComponent("preview-must-not-run")
        let preview = PreviewServer(workspace: chat.workspace)
        do { try await preview.start(.init(executable: "/usr/bin/touch", arguments: [marker.path], directory: fixture.path, url: "http://127.0.0.1:49999"), deadline: .seconds(1)); XCTFail("Started local preview for remote path") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        await preview.stop(); await store.shutdown()
    }
    func testSamePathProjectsOnDifferentHostsRemainSeparate() throws {
        var local = SessionInfo(projectPath: "/work/project"), remote = local
        remote.executionEnvironment = .ssh(try SSHConfiguration(name: "VM", host: "vm"))
        remote = SessionInfo(projectPath: "/work/project", title: "Remote")
        remote.executionEnvironment = .ssh(try SSHConfiguration(name: "VM", host: "vm"))
        local.title = "Local"; remote.title = "Remote"
        var retargeted = remote
        if case .ssh(let old) = remote.environment { retargeted.executionEnvironment = .ssh(try SSHConfiguration(id: old.id, name: old.name, host: "different-destination")) }
        XCTAssertNotEqual(remote.projectGroupingPath, retargeted.projectGroupingPath)
        let snapshot = SidebarSnapshot(sessions: [local, remote])
        XCTAssertEqual(snapshot.projects.count, 2)
    }

    @MainActor func testSSHConnectionFormFitsAndSavedPresetsRoundTripWithoutCredentials() throws {
        let host = try SSHConfiguration(name: "Build VM", host: "dev@vm", port: 2202, identityFile: "/tmp/key")
        let preset = try SSHConnectionPreset(host: host, projectPath: "/work/project", executable: "claude-agent-acp", arguments: [])
        let encoded = try JSONEncoder().encode(preset)
        XCTAssertEqual(try JSONDecoder().decode(SSHConnectionPreset.self, from: encoded), preset)
        let store = AppStore(directory: try temporary().appendingPathComponent("data"))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = NSHostingView(rootView: SSHWorkspacesView(store: store))
            view.appearance = NSAppearance(named: appearance); view.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
            view.layoutSubtreeIfNeeded(); XCTAssertLessThanOrEqual(view.fittingSize.height, 680)
        }
    }
    func testRemoteGitHubServiceCannotInspectMatchingLocalRepository() async throws {
        let fixture = try temporary(), ssh = fixture.appendingPathComponent("offline")
        _ = try await Repository.run(["init"], at: fixture.path)
        _ = try await Repository.run(["remote", "add", "origin", "https://github.com/example/local-only.git"], at: fixture.path)
        try "#!/bin/sh\nexit 255\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        let workspace = try Workspace(root: fixture.path, environment: .ssh(SSHConfiguration(name: "Remote", host: "vm")), sshExecutable: ssh.path)
        let service = PullRequestService(workspace: workspace)
        do { _ = try await service.remotes(at: fixture.path); XCTFail("GitHub inspected local repository") } catch { }
    }

    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ccode-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try canonicalURL(root.path)
    }
    // This proves OpenSSH's remote shell boundary with actual child processes,
    // not authentication, encryption or real-host acceptance.
    private func boundary(in root: URL) throws -> SSHTransport {
        let ssh = root.appendingPathComponent("fixture-ssh")
        try "#!/usr/bin/python3\nimport os,sys\nif '-G' in sys.argv: print('hostname fixture-host\\nuser fixture\\nport 22')\nelse: os.execv('/bin/sh',['sh','-c',sys.argv[-1]])\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        return try SSHTransport(configuration: SSHConfiguration(name: "Fixture", host: "fixture-host"), executable: ssh.path)
    }
}
