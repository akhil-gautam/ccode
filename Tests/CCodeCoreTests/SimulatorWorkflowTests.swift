import XCTest
import CCodeCore
final class SimulatorWorkflowTests: XCTestCase {
    func testAvailableIOSDevicesAndExplicitIdentity() throws {
        let data: JSONValue = ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-26-0": [["udid": "ED2351B4-721C-4C99-B849-0C44BD97F655", "name": "iPhone", "state": "Shutdown", "isAvailable": true], ["udid": "unknown", "name": "broken", "isAvailable": true]], "com.apple.CoreSimulator.SimRuntime.watchOS-26-0": [["udid": "ED2351B4-721C-4C99-B849-0C44BD97F654", "name": "Watch", "isAvailable": true]]]]
        let devices = SimulatorDevice.parse(data)
        XCTAssertEqual(devices.count, 1); XCTAssertEqual(devices.first?.name, "iPhone")
        XCTAssertThrowsError(try SimulatorAction(tool: "simulator_attach", arguments: ["device": "booted"]))
    }
    func testInputBoundsAndBuildArgumentsAreValidated() throws {
        XCTAssertThrowsError(try SimulatorAction(tool:"simulator_button",arguments:["button":"lock"]))
        XCTAssertThrowsError(try SimulatorAction(tool:"simulator_button",arguments:["button":"volumeUp"]))
        XCTAssertThrowsError(try SimulatorAction(tool:"simulator_button",arguments:["button":"volumeDown"]))
        XCTAssertThrowsError(try SimulatorAction(tool:"simulator_devices",arguments:["approved":true]))
        XCTAssertThrowsError(try SimulatorAction(tool: "simulator_tap", arguments: ["x": -1, "y": .number(0.3)]))
        XCTAssertThrowsError(try SimulatorAction(tool: "simulator_open_url", arguments: ["url": "file:///etc/passwd"]))
        XCTAssertThrowsError(try SimulatorAction(tool: "simulator_build", arguments: ["project": "../Other.xcodeproj", "scheme": "App"]))
        let action = try SimulatorAction(tool: "simulator_type", arguments: ["text": "literal $(touch /tmp/evil)"])
        XCTAssertEqual(action.arguments["text"].string, "literal $(touch /tmp/evil)")
    }
}

import Foundation
@testable import CCode
extension SimulatorWorkflowTests {
    @MainActor func testDevicesAreLeasedByChatAndOwnedShutdownPreservesExternalBoots() async throws {
        let(root,service)=try fixture();let store=AppStore(directory:root.appendingPathComponent("data"))
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        await store.create(path:root.path,worktree:false);let a=try XCTUnwrap(store.selected)
        await store.create(path:root.path,worktree:false);let b=try XCTUnwrap(store.selected)
        a.simulatorWorkspace=SimulatorWorkspace(service:service);b.simulatorWorkspace=SimulatorWorkspace(service:service)
        try await store.attachSimulator(a,id:deviceID)
        do { try await store.attachSimulator(b,id:deviceID);XCTFail("Another chat took the device") } catch {}
        XCTAssertEqual(a.simulatorWorkspace.device?.id,deviceID)
        await store.detachSimulator(a)
        let shutdown=try await service.devices();XCTAssertFalse(try XCTUnwrap(shutdown.first).booted)
        _=try await service.command(["boot",deviceID]) // external owner
        try await store.attachSimulator(b,id:deviceID)
        XCTAssertFalse(b.simulatorWorkspace.bootedByApp)
        await store.detachSimulator(b)
        let preserved=try await service.devices();XCTAssertTrue(try XCTUnwrap(preserved.first).booted)
    }
    @MainActor func testCancellationDuringBootShutsDownOnlyNewlyOwnedDevice() async throws {
        let(root,service)=try fixture(blockBoot:true),store=AppStore(directory:root.appendingPathComponent("data"))
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        await store.create(path:root.path,worktree:false);let chat=try XCTUnwrap(store.selected)
        chat.simulatorWorkspace=SimulatorWorkspace(service:service)
        let task=Task { try await store.attachSimulator(chat,id:deviceID) }
        let marker=root.appendingPathComponent("waiting")
        for _ in 0..<200 { if FileManager.default.fileExists(atPath:marker.path) { break };try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
        store.stop(chat)
        do { try await task.value;XCTFail("Cancelled boot attached a device") } catch {}
        let devices=try await service.devices();XCTAssertFalse(try XCTUnwrap(devices.first).booted,"Cancelled owned boot leaked a running simulator")
        XCTAssertTrue(store.simulatorLeases.isEmpty)
    }
    @MainActor func testStopDuringFinalDeviceValidationCannotAttachOrLeakOwnedBoot() async throws {
        let(root,service)=try fixture(blockValidation:true),store=AppStore(directory:root.appendingPathComponent("data"))
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        await store.create(path:root.path,worktree:false);let chat=try XCTUnwrap(store.selected)
        chat.simulatorWorkspace=SimulatorWorkspace(service:service)
        let task=Task { try await store.attachSimulator(chat,id:deviceID) }
        let marker=root.appendingPathComponent("validating")
        for _ in 0..<200 { if FileManager.default.fileExists(atPath:marker.path) { break };try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
        store.stop(chat)
        try Data().write(to:root.appendingPathComponent("release-validation"))
        do { try await task.value;XCTFail("Stopped validation attached a device") } catch {}
        XCTAssertNil(chat.simulatorWorkspace.device)
        let devices=try await service.devices();XCTAssertFalse(try XCTUnwrap(devices.first).booted)
        XCTAssertTrue(store.simulatorLeases.isEmpty)
    }
    func testScreenshotTransfersLiteralBytesAndInstallNeverEscapesWorkspace() async throws {
        let(root,service)=try fixture();addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        let workspace=try Workspace(root:root.path)
        let picture=try await service.screenshot(deviceID);XCTAssertEqual(picture,Data([255,216,255,217]))
        do { _=try await service.install(deviceID,app:root.deletingLastPathComponent().appendingPathComponent("foreign.app").path,workspace:workspace);XCTFail("Install escaped workspace") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("installed").path))
    }
    private var deviceID:String { "ED2351B4-721C-4C99-B849-0C44BD97F655" }
    private func fixture(blockBoot:Bool=false,blockValidation:Bool=false) throws -> (URL,SimulatorService) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("ccode-sim-fixture-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let state:JSONValue=["booted":false,"block_boot":.bool(blockBoot),"block_validation":.bool(blockValidation)]
        try JSONEncoder().encode(state).write(to:root.appendingPathComponent("state.json"))
        let script=root.appendingPathComponent("xcrun")
        try """
        #!/usr/bin/python3
        import pathlib,json,sys,time
        root=pathlib.Path(__file__).parent
        args=sys.argv[1:];assert args.pop(0)=='simctl'
        state=json.loads((root/'state.json').read_text());op=args[0]
        if op=='list':
            if state['booted'] and state['block_validation']:
                (root/'validating').touch()
                while not (root/'release-validation').exists(): time.sleep(0.01)
            print(json.dumps({'devices':{'com.apple.CoreSimulator.SimRuntime.iOS-26-0':[{'udid':'ED2351B4-721C-4C99-B849-0C44BD97F655','name':'Owned fixture','state':'Booted' if state['booted'] else 'Shutdown','isAvailable':True}]}}))
        elif op=='boot': state['booted']=True;(root/'state.json').write_text(json.dumps(state))
        elif op=='shutdown': state['booted']=False;(root/'state.json').write_text(json.dumps(state))
        elif op=='bootstatus':
            if state['block_boot']: (root/'waiting').touch();time.sleep(100)
        elif op=='io': pathlib.Path(args[-1]).write_bytes(bytes([255,216,255,217]))
        elif op=='install': (root/'installed').write_text(args[-1])
        else: raise RuntimeError('unexpected command')
        """.write(to:script,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:script.path)
        return(root,SimulatorService(cache:root.appendingPathComponent("cache"),helper:root.appendingPathComponent("unused-helper.py"),xcrun:script.path))
    }
}
