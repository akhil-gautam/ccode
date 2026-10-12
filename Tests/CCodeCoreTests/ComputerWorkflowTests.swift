import XCTest
import CCodeCore
@testable import CCode

@MainActor private final class TestComputerEngine: ComputerEngine {
    var readiness: ComputerReadiness { .init(accessibility: true, screenRecording: true) }
    func applications() -> [ComputerApplication] { [.init(id: "dev.fixture", name: "Fixture", path: "/Fixture.app", pid: 12)] }
    func perform(_ action: ComputerAction, app: ComputerApplication) async throws -> JSONValue { ["result": "owned fixture result"] }
}
final class ComputerWorkflowTests: XCTestCase {
    func testToolArgumentsAndFixedTiersRejectBroadControl() throws {
        XCTAssertThrowsError(try ComputerAction(tool:"computer_inspect",arguments:["app":"dev.fixture","approved":true]))
        XCTAssertThrowsError(try ComputerAction(tool:"computer_key",arguments:["app":"dev.fixture","key":"a","modifiers":"command"]))
        XCTAssertThrowsError(try ComputerAction(tool: "computer_type", arguments: ["app": "com.apple.Terminal", "text": "rm -rf /"]))
        XCTAssertThrowsError(try ComputerAction(tool: "computer_click", arguments: ["app": "com.google.Chrome", "element": "1", "snapshot": "x"]))
        XCTAssertThrowsError(try ComputerAction(tool: "computer_key", arguments: ["app": "dev.fixture", "key": "unknown-key"]))
        XCTAssertThrowsError(try ComputerAction(tool: "computer_type", arguments: ["app": "dev.ccode.native", "text": "Allow"]))
    }
    @MainActor func testPerAppGrantIsRequiredAndStopRevokesIt() async throws {
        let workspace = ComputerWorkspace(engine: TestComputerEngine())
        let action = try ComputerAction(tool: "computer_inspect", arguments: ["app": "dev.fixture"])
        do { _ = try await workspace.perform(action); XCTFail("Unapproved app returned data") } catch {}
        workspace.allow("dev.fixture")
        let result = try await workspace.perform(action)
        XCTAssertEqual(result["result"].string, "owned fixture result")
        workspace.stop()
        do { _ = try await workspace.perform(action); XCTFail("Stop retained access") } catch {}
    }
    @MainActor func testStoppedWorkspaceDoesNotAcceptLateOperationResult() async throws {
        let engine = SuspendedComputerEngine(), workspace = ComputerWorkspace(engine: engine)
        workspace.allow("dev.fixture")
        let action = try ComputerAction(tool: "computer_inspect", arguments: ["app": "dev.fixture"])
        let operation = Task { try await workspace.perform(action) }
        for _ in 0..<20 { if engine.gate != nil { break }; await Task.yield() }
        workspace.stop(); engine.gate?.resume(returning: ["secret": "late"])
        do { _ = try await operation.value; XCTFail("Late screen result escaped Stop") } catch {}
        XCTAssertFalse(workspace.active)
    }
    @MainActor func testEngineFailureIsVisibleAndReleasesActiveControl() async throws {
        let engine = SuspendedComputerEngine(), workspace = ComputerWorkspace(engine: engine)
        workspace.allow("dev.fixture")
        let action = try ComputerAction(tool: "computer_inspect", arguments: ["app": "dev.fixture"])
        let operation = Task { try await workspace.perform(action) }
        for _ in 0..<20 { if engine.gate != nil { break }; await Task.yield() }
        let gate = try XCTUnwrap(engine.gate)
        XCTAssertTrue(workspace.active)
        let failure = ACPError.workspace("Fixture app window closed during inspection.")
        gate.resume(throwing: failure)
        do { _ = try await operation.value; XCTFail("Failed inspection returned success") } catch {}
        XCTAssertEqual(workspace.error, failure.localizedDescription)
        XCTAssertFalse(workspace.active)
        XCTAssertTrue(workspace.activity.isEmpty)
    }
}
@MainActor private final class SuspendedComputerEngine: ComputerEngine {
    var gate: CheckedContinuation<JSONValue, any Error>?
    var readiness: ComputerReadiness { .init(accessibility: true, screenRecording: true) }
    func applications() -> [ComputerApplication] { [.init(id: "dev.fixture", name: "Fixture", path: "/Fixture.app", pid: 12)] }
    func perform(_ action: ComputerAction, app: ComputerApplication) async throws -> JSONValue { try await withCheckedThrowingContinuation { gate = $0 } }
}

extension ComputerWorkflowTests {
    @MainActor func testNativeToolEnablementDoesNotSubmitPromptAndDisconnectRevokesAccess() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("ccode-native-tools-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=AppStore(directory:root.appendingPathComponent("data"))
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        await store.create(path:root.path,worktree:false)
        let chat=try XCTUnwrap(store.selected)
        chat.draft="Independent draft"
        try await store.setNativeTools(chat,kind:"computer",enabled:true)
        XCTAssertTrue(chat.transcript.computerToolsEnabled == true)
        XCTAssertNil(chat.connection);XCTAssertTrue(chat.transcript.items.isEmpty);XCTAssertEqual(chat.draft,"Independent draft")
        chat.computerWorkspace=ComputerWorkspace(engine:TestComputerEngine());chat.computerWorkspace.allow("dev.fixture")
        await store.disconnect(chat)
        XCTAssertTrue(chat.computerWorkspace.grants.isEmpty)
    }
    @MainActor func testMissingHTTPRefusesEnablementWithoutChangingExistingTools() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("ccode-native-unsupported-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=AppStore(directory:root.appendingPathComponent("data"));addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        await store.create(path:root.path,worktree:false);let chat=try XCTUnwrap(store.selected)
        chat.connection=ACPConnection(onUpdates:{ _ in },onRequest:{ _,_ in [:] })
        do { try await store.setNativeTools(chat,kind:"simulator",enabled:true);XCTFail("Unsupported native MCP was enabled") } catch {}
        XCTAssertNil(chat.transcript.simulatorToolsEnabled);XCTAssertNotNil(chat.connection)
    }
}

extension ComputerWorkflowTests {
    @MainActor func testStaleConnectionCannotApproveAppAndStopReleasesPendingDecision() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("ccode-native-consent-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=AppStore(directory:root.appendingPathComponent("data"));addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        await store.create(path:root.path,worktree:false);let chat=try XCTUnwrap(store.selected)
        chat.computerWorkspace=ComputerWorkspace(engine:TestComputerEngine());chat.transcript.computerToolsEnabled=true
        chat.connection=ACPConnection(onUpdates:{ _ in },onRequest:{ _,_ in [:] })
        let old=chat.connectionGeneration
        let request=Task { try await store.performNativeTool(chat,generation:old,name:"computer_inspect",arguments:["app":"dev.fixture"]) }
        for _ in 0..<50 { if !store.nativeAccessRequests.isEmpty { break };try await Task.sleep(for:.milliseconds(5)) }
        let pending=try XCTUnwrap(store.nativeAccessRequests.first)
        store.resolveNativeAccess(UUID(),allow:true);XCTAssertEqual(store.nativeAccessRequests.count,1)
        chat.connectionGeneration=UUID();store.resolveNativeAccess(pending.id,allow:true)
        do { _=try await request.value;XCTFail("Old connection obtained app access") } catch {}
        XCTAssertTrue(chat.computerWorkspace.grants.isEmpty)
        let next=Task { try await store.performNativeTool(chat,generation:chat.connectionGeneration,name:"computer_inspect",arguments:["app":"dev.fixture"]) }
        for _ in 0..<50 { if !store.nativeAccessRequests.isEmpty { break };try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertEqual(chat.sessionToolApprovalCount,1);store.stop(chat)
        do { _=try await next.value;XCTFail("Stopped app request escaped") } catch {}
        XCTAssertTrue(store.nativeAccessRequests.isEmpty);XCTAssertEqual(chat.sessionToolApprovalCount,0)
    }
}
