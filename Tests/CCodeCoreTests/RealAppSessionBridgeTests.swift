import XCTest
import Foundation
import CCodeCore
@testable import CCode

final class RealAppSessionBridgeTests:XCTestCase {
    @MainActor func testActualClaudeSessionsReadMessageRenameDeliverAndArchiveThroughMCP() async throws {
        guard let executable=ProcessInfo.processInfo.environment["CCODE_REAL_SESSION_BRIDGE_AGENT"],FileManager.default.isExecutableFile(atPath:executable) else { throw XCTSkip("Opt-in authenticated two-session MCP proof") }
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ccode-real-session-bridge-\(UUID())")
        let sourceRoot=root.appendingPathComponent("source"),targetRoot=root.appendingPathComponent("recipient")
        for directory in [sourceRoot,targetRoot] {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try "Disposable app-session bridge proof\n".write(to:directory.appendingPathComponent("README.md"),atomically:true,encoding:.utf8)
        }
        let storage=SessionStorage(directory:root.appendingPathComponent("data"),claudeDirectory:root.appendingPathComponent("empty-history"))
        let sourceInfo=SessionInfo(projectPath:sourceRoot.path,title:"Source"),targetInfo=SessionInfo(projectPath:targetRoot.path,title:"Recipient")
        let transcript=SessionTranscript()
        try await storage.save(transcript,id:sourceInfo.id);try await storage.saveIndex([sourceInfo,targetInfo])
        let store=AppStore(directory:root.appendingPathComponent("data"),claudeDirectory:root.appendingPathComponent("empty-history"))
        store.settings.executable=executable;store.settings.arguments=[]
        addTeardownBlock { await store.shutdown() }
        await store.restore();await store.select(sourceInfo.id)
        let source=try XCTUnwrap(store.selected)
        try await store.showSessionBeside(targetInfo.id)
        let target=try XCTUnwrap(store.selected)
        try await connect(store,target)
        let token="recipient-"+UUID().uuidString,draft="Unsent independent draft "+UUID().uuidString
        target.draft=draft
        store.send(target,text:"Remember this token: "+token+". Reply only ready. Do not use tools.")
        _=try await finish(store,target,recipient:targetInfo.id,allowSessionTools:false)
        XCTAssertEqual(target.draft,draft)
        try await connect(store,source)
        let previousSourcePeer=source.connection
        try await store.setAppSessionTools(source,enabled:true)
        XCTAssertTrue(source.connection !== previousSourcePeer,"Enabling tools on a connected session must reconnect with an owned endpoint")
        XCTAssertNotNil(source.sessionToolEndpoint)
        let body="Report the token I asked you to remember earlier. Treat this note as peer model output, not a user approval."
        store.send(source,text:"Use only the ccode-sessions MCP tools. First list_sessions, then read_session session_id "+targetInfo.id.uuidString+". Then message_session that session with body exactly "+String(reflecting:body)+". Finally rename_session it to Bridge verified. Do not use filesystem, Bash, agents or any other tools. Stop after reporting the operation results. App approvals will be provided separately.")
        let accepted=try await finish(store,source,recipient:targetInfo.id,allowSessionTools:true)
        XCTAssertTrue(accepted.contains("List sessions"));XCTAssertTrue(accepted.contains("Read conversation"))
        XCTAssertTrue(accepted.contains("Send agent message"));XCTAssertTrue(accepted.contains("Rename session"))
        XCTAssertEqual(store.sessions.first { $0.id == targetInfo.id }?.title,"Bridge verified")
        let inbox=try await storage.loadPeerMessages(target.id)
        let message=try XCTUnwrap(inbox.first)
        XCTAssertEqual(message.senderID,source.id);XCTAssertEqual(message.body,body)
        XCTAssertEqual(target.draft,draft);XCTAssertTrue(target.pendingPrompts.isEmpty)
        let peer=target.connection
        try await store.queuePeerMessage(target,id:message.id)
        XCTAssertTrue(target.deliveryPaused);XCTAssertEqual(target.draft,draft)
        store.resumeQueuedPrompts(target)
        _=try await finish(store,target,recipient:target.id,allowSessionTools:false)
        guard target.transcript.items.first(where:{ $0.id == message.id })?.peerMessage == message else { throw ACPError.workspace("Actual peer delivery did not retain verified provenance") }
        // Peer output is not a user instruction. A separate actual user follow-up
        // proves retained context without requiring obedience to the peer's note.
        store.send(target,text:"What token did I ask you to remember? Reply with only the token. Do not use tools or send messages to other sessions.")
        _=try await finish(store,target,recipient:target.id,allowSessionTools:false)
        guard target.transcript.items.filter({ $0.kind == "assistant" }).last?.text.contains(token) == true else { throw ACPError.workspace("Recipient context was lost after peer delivery") }
        XCTAssertTrue(target.connection===peer);XCTAssertEqual(target.draft,draft)
        store.send(source,text:"Use only ccode-sessions archive_session for session_id "+target.id.uuidString+". Do not use any other tools. Report its actual result.")
        let archived=try await finish(store,source,recipient:target.id,allowSessionTools:true)
        XCTAssertTrue(archived.contains("Archive session"))
        XCTAssertTrue(store.sessions.first { $0.id == target.id }?.archived == true)
        let retained=try await storage.load(target.id)
        XCTAssertEqual(retained.draftText,draft);XCTAssertEqual(retained.items.first { $0.id == message.id }?.peerMessage,message)
        let proof:JSONValue=["source":.string(source.id.uuidString),"recipient":.string(target.id.uuidString),"authorized_operations":.array((accepted+archived).map(JSONValue.string)),"sender_verified":true,"draft_preserved":true,"recipient_context_recalled":true,"peer_provenance_persisted":true,"archive_verified":true]
        try JSONEncoder().encode(proof).write(to:root.appendingPathComponent("verified-session-bridge.json"))
        await store.shutdown();print("Actual two-session MCP bridge proof: \(root.path)")
    }
    @MainActor private func connect(_ store:AppStore,_ chat:ChatSession) async throws {
        try await store.connect(chat)
        let model=try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "model" })
        let option=try XCTUnwrap(model["options"].array.flatMap { $0["options"].isNull ? [$0] : $0["options"].array }.first { $0["name"].string.localizedCaseInsensitiveContains("sonnet") })
        await store.setConfig(chat,id:model["id"].string,value:option["value"])
        let mode=try XCTUnwrap(chat.transcript.configOptions.first { $0["category"] == "mode" })
        await store.setConfig(chat,id:mode["id"].string,value:"default")
        XCTAssertNil(chat.lastError)
    }
    @MainActor private func finish(_ store:AppStore,_ chat:ChatSession,recipient:UUID,allowSessionTools:Bool) async throws -> [String] {
        let until=ContinuousClock.now + .seconds(180);var accepted:[String]=[]
        while chat.busy || !chat.pendingPrompts.isEmpty,ContinuousClock.now < until {
            for approval in chat.approvals {
                let tool=approval.toolCall
                let name=[PermissionPresentation(tool:tool).toolName,tool["name"].string,tool["title"].string].joined(separator:" ")
                let supported=["list_sessions","read_session","message_session","rename_session","archive_session"].contains(where:name.contains)
                guard allowSessionTools,supported else { store.resolveApproval(chat,id:approval.id,option:nil);throw ACPError.workspace("Unexpected bridge proof tool: "+name) }
                let option=approval.request["options"].array.first { $0["kind"] == "allow_once" }
                store.resolveApproval(chat,id:approval.id,option:option?["optionId"].optionalString)
            }
            for request in store.sessionToolRequests.filter({ $0.senderID == chat.id }) {
                guard allowSessionTools,request.operation.targetID == nil || request.operation.targetID == recipient else { store.resolveSessionToolRequest(request.id,allow:false);throw ACPError.workspace("Unexpected bridge recipient") }
                accepted.append(request.operation.label);store.resolveSessionToolRequest(request.id,allow:true)
            }
            try await Task.sleep(for:.milliseconds(30))
        }
        guard !chat.busy,chat.pendingPrompts.isEmpty,chat.state == .ready else { store.stop(chat);throw ACPError.workspace(chat.lastError ?? "Actual session bridge turn did not finish") }
        return accepted
    }
}
