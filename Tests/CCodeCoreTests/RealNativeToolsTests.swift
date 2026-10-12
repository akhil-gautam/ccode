import XCTest
import CCodeCore
@testable import CCode

final class RealNativeToolsTests:XCTestCase {
    @MainActor func testActualClaudeNegotiatesNativeMCPAndReportsSimulatorReadiness() async throws {
        guard let executable=ProcessInfo.processInfo.environment["CCODE_REAL_NATIVE_AGENT"] else { throw XCTSkip("Opt-in authenticated native MCP proof") }
        let arguments=try JSONDecoder().decode([String].self,from:Data((ProcessInfo.processInfo.environment["CCODE_REAL_NATIVE_ARGUMENTS"] ?? "[]").utf8))
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/real-native-tools-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let info=SessionInfo(projectPath:root.path,title:"Native MCP readiness proof")
        let storage=SessionStorage(directory:root.appendingPathComponent("data"),claudeDirectory:root.appendingPathComponent("no-history"))
        var transcript=SessionTranscript();transcript.simulatorToolsEnabled=true
        try await storage.save(transcript,id:info.id);try await storage.saveIndex([info])
        let store=AppStore(directory:root.appendingPathComponent("data"),claudeDirectory:root.appendingPathComponent("no-history"))
        store.settings.executable=executable;store.settings.arguments=arguments;addTeardownBlock { await store.shutdown() }
        await store.restore();await store.select(info.id);let chat=try XCTUnwrap(store.selected)
        try await store.connect(chat);XCTAssertNotNil(chat.nativeToolEndpoint)
        let model=try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let option=try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat,id:model["id"].string,value:option["value"])
        if let mode=chat.transcript.configOptions.first(where:{$0["category"] == "mode"}) { await store.setConfig(chat,id:mode["id"].string,value:"default") }
        let draft="Unsent independent native draft "+UUID().uuidString;chat.draft=draft
        store.send(chat,text:"Call only the ccode-native MCP simulator_devices tool once. Report the actual device count and setup status it returns. Do not boot, install, build, launch, control apps, use Bash/filesystem, or call other tools.")
        let until=ContinuousClock.now + .seconds(120);var permissions=0
        while chat.busy,ContinuousClock.now<until {
            for approval in chat.approvals {
                let tool=approval.toolCall,name=[PermissionPresentation(tool:tool).toolName,tool["title"].string,tool["name"].string].joined(separator:" ")
                guard name.contains("simulator_devices") else { store.resolveApproval(chat,id:approval.id,option:nil);throw ACPError.workspace("Unexpected native MCP operation: "+name) }
                permissions+=1;let option=approval.request["options"].array.first { $0["kind"] == "allow_once" };store.resolveApproval(chat,id:approval.id,option:option?["optionId"].optionalString)
            }
            XCTAssertTrue(store.nativeAccessRequests.isEmpty)
            try await Task.sleep(for:.milliseconds(25))
        }
        guard !chat.busy,chat.state == .ready,chat.lastError == nil else { store.stop(chat);throw ACPError.workspace(chat.lastError ?? "Native MCP turn did not finish") }
        let calls=chat.transcript.items.filter { $0.kind == "tool" && $0.tool.pretty.contains("simulator_devices") }
        XCTAssertFalse(calls.isEmpty);XCTAssertEqual(chat.draft,draft);XCTAssertNil(chat.simulatorWorkspace.device)
        let devices=try await chat.simulatorWorkspace.service.devices()
        let result:JSONValue=["accepted":true,"actualClaudeAgent":true,"nativeMCPNegotiated":true,"deviceCount":.number(Double(devices.count)),"setup":.string(chat.simulatorWorkspace.error ?? "Ready"),"draftPreserved":.bool(chat.draft==draft),"desktopActionsAccepted":false,"realSimulatorActionsAccepted":false,"permissions":.number(Double(permissions))]
        try JSONEncoder().encode(result).write(to:root.appendingPathComponent("verified-native-mcp.json"))
        print("Actual native MCP readiness proof: \(root.path)")
    }
}
