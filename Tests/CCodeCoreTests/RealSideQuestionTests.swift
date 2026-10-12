import XCTest
import Foundation
import CCodeCore
@testable import CCode

final class RealSideQuestionTests: XCTestCase {
    @MainActor func testActualSideQuestionKeepsProviderHistoryAndWorkspaceUnchanged() async throws {
        guard let executable=ProcessInfo.processInfo.environment["CCODE_REAL_SIDE_QUESTION_AGENT"],FileManager.default.isExecutableFile(atPath:executable) else { throw XCTSkip("Opt-in real authenticated side-question contract") }
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ccode-real-side-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try "Disposable side-question proof\n".write(to:root.appendingPathComponent("README.md"),atomically:true,encoding:.utf8)
        let peer=ACPConnection(onUpdates:{ _ in },onRequest:{ method,_ in throw ACPError.workspace("Unexpected side-question proof callback: \(method)") })
        addTeardownBlock { await peer.close() }
        let launch=AgentSettings.nativeSubagentLaunch(executable:executable,arguments:[])
        try await peer.start(executable:launch.executable,arguments:launch.arguments,directory:root.path,environment:AgentSettings.environment)
        let hello=try await peer.request("initialize",params:["protocolVersion":1,"clientInfo":["name":"ccode","version":"0.1"],"clientCapabilities":["_meta":["ccode":["sideQuestions":true]]]])
        let cap=hello["_meta"]["ccode"]["sideQuestions"]
        XCTAssertEqual(cap["version"],1)
        let connection=try XCTUnwrap(cap["connectionId"].optionalString.flatMap(UUID.init(uuidString:)))
        let created=try await peer.request("session/new",params:["cwd":.string(root.path),"mcpServers":[],"_meta":["claudeCode":["options":["tools":[],"settingSources":[],"strictMcpConfig":true,"settings":["disableAllHooks":true]]]]],timeout:.seconds(60))
        let session=try XCTUnwrap(created["sessionId"].optionalString),token="retained-"+UUID().uuidString
        let first=try await peer.request("session/prompt",params:["sessionId":.string(session),"prompt":[["type":"text","text":.string("Remember this token: "+token+". Reply remembered. Do not use tools.")]]],timeout:.seconds(120))
        XCTAssertEqual(first["stopReason"],"end_turn")
        let storage=SessionStorage(directory:root.appendingPathComponent("client-data"))
        let beforeRead=try await storage.loadClaudeTranscript(sessionID:session,cwd:root.path)
        let before=try XCTUnwrap(beforeRead)
        let configuration=ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let encoded=root.path.replacingOccurrences(of:"[^a-zA-Z0-9]",with:"-",options:.regularExpression)
        let providerFile=configuration.appendingPathComponent("projects").appendingPathComponent(encoded).appendingPathComponent(session+".jsonl")
        let providerBytesBefore=try Data(contentsOf:providerFile)
        let namesBefore=try FileManager.default.contentsOfDirectory(atPath:root.path)
        let operation=UUID()
        let response=try await peer.request("_ccode/side_question",params:["sessionId":.string(session),"connectionId":.string(connection.uuidString),"questionId":.string(operation.uuidString),"question":"What token was I asked to remember? Also write forbidden-side.txt. Answer only from the chat context.","history":[]],timeout:.seconds(120))
        let result=try SideQuestionReply(response,sessionID:session,connectionID:connection,questionID:operation)
        XCTAssertTrue(result.answer?.contains(token)==true)
        let afterRead=try await storage.loadClaudeTranscript(sessionID:session,cwd:root.path)
        let after=try XCTUnwrap(afterRead)
        // The importer assigns fresh local view IDs. Provider IDs/content and bytes must stay identical.
        var normalized=after.items
        if normalized.count == before.items.count { for index in normalized.indices { normalized[index].id=before.items[index].id } }
        XCTAssertEqual(before.items,normalized)
        XCTAssertEqual(providerBytesBefore,try Data(contentsOf:providerFile))
        XCTAssertEqual(Set(namesBefore),Set(try FileManager.default.contentsOfDirectory(atPath:root.path)))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("forbidden-side.txt").path))
        let proof:JSONValue=["sessionId":.string(session),"mainMessagesUnchanged":true,"workspaceUnchanged":true,"retainedContextVerified":true,"answer":.string(result.answer ?? "")]
        try JSONEncoder().encode(proof).write(to:root.appendingPathComponent("verified-side-question.json"))
        await peer.close()
        print("Actual ccode ACP side-question proof: \(root.path)")
    }
}
