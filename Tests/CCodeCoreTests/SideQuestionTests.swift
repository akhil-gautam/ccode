import XCTest
import SwiftUI
import AppKit
@testable import CCodeCore
@testable import CCode

final class SideQuestionTests: XCTestCase {
    func testReplyRequiresExactConnectionSessionAndQuestionReceipt() throws {
        let connection=UUID(), question=UUID(), session=UUID().uuidString
        let response: JSONValue=["version":1,"sessionId":.string(session),"connectionId":.string(connection.uuidString),"questionId":.string(question.uuidString),"answer":"Context answer","synthetic":false]
        XCTAssertEqual(try SideQuestionReply(response, sessionID:session, connectionID:connection, questionID:question).answer,"Context answer")
        var malformed=response;malformed["sessionId"]="foreign"
        XCTAssertThrowsError(try SideQuestionReply(malformed,sessionID:session,connectionID:connection,questionID:question))
        malformed=response;malformed["version"]=2
        XCTAssertThrowsError(try SideQuestionReply(malformed,sessionID:session,connectionID:connection,questionID:question))
        XCTAssertThrowsError(try SideQuestionReply(response,sessionID:session,connectionID:UUID(),questionID:question))
        XCTAssertThrowsError(try SideQuestionReply(response,sessionID:session,connectionID:connection,questionID:UUID()))
    }
    @MainActor func testSideQuestionDuringMainApprovalDoesNotChangeDraftTranscriptOrDecision() async throws {
        let(root,store,chat)=try await fixture()
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        store.send(chat,text:"Main prompt")
        try await wait { chat.approvals.count==1 }
        let peer=try XCTUnwrap(chat.connection), remote=try XCTUnwrap(chat.transcript.remoteID)
        chat.draft="Main unsent draft";let transcript=chat.transcript.items;let approval=try XCTUnwrap(chat.approvals.first).id
        chat.sideQuestionDraft="Context only"
        store.askSideQuestion(chat)
        try await wait { chat.sideQuestionTask==nil }
        XCTAssertEqual(chat.sideQuestionHistory.last?.response,"Answer: Context only")
        XCTAssertEqual(chat.draft,"Main unsent draft")
        XCTAssertEqual(chat.transcript.items,transcript)
        XCTAssertEqual(chat.approvals.first?.id,approval)
        XCTAssertEqual(chat.transcript.remoteID,remote);XCTAssertTrue(chat.connection===peer)
        let counts=try await peer.request("fixture/counts",params:[:])
        XCTAssertEqual(counts["prompts"],1);XCTAssertEqual(counts["sideQuestions"],1);XCTAssertEqual(counts["cancels"],0)
        store.closeSideQuestion(chat)
        XCTAssertTrue(chat.sideQuestionHistory.isEmpty)
        store.resolveApproval(chat,id:approval,option:nil)
        try await wait { !chat.busy }
        await store.save(chat)
        let saved=try await SessionStorage(directory:root.appendingPathComponent("data"),claudeDirectory:root.appendingPathComponent("empty")).load(chat.id)
        XCTAssertFalse(saved.items.contains { $0.text.contains("Context only") })
    }
    @MainActor func testClosingSideQuestionDiscardsLateAnswerWithoutStoppingMainResponse() async throws {
        let(root,store,chat)=try await fixture()
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        store.send(chat,text:"Main prompt")
        try await wait { chat.approvals.count==1 }
        let peer=try XCTUnwrap(chat.connection)
        chat.sideQuestionDraft="Delayed"
        store.askSideQuestion(chat)
        try await Task.sleep(for:.milliseconds(80))
        store.closeSideQuestion(chat)
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertTrue(chat.sideQuestionHistory.isEmpty)
        XCTAssertEqual(chat.approvals.count,1)
        XCTAssertEqual(chat.state,.running)
        let counts=try await peer.request("fixture/counts",params:[:]);XCTAssertEqual(counts["cancels"],0)
        store.resolveApproval(chat,id:try XCTUnwrap(chat.approvals.first).id,option:nil)
        try await wait { !chat.busy }
    }
    @MainActor func testBtwUsesSideChannelAndKeepsMainQueueAndTranscriptEmpty() async throws {
        let(root,store,chat)=try await fixture()
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        try await store.connect(chat)
        let peer=try XCTUnwrap(chat.connection)
        chat.draft="/btw Context command"
        store.send(chat)
        try await wait { !chat.busy && chat.sideQuestionTask==nil }
        XCTAssertEqual(chat.sideQuestionHistory.last?.response,"Answer: Context command")
        XCTAssertTrue(chat.transcript.items.isEmpty)
        XCTAssertTrue(chat.pendingPrompts.isEmpty)
        let counts=try await peer.request("fixture/counts",params:[:]);XCTAssertEqual(counts["prompts"],0)
    }
    @MainActor func testSideQuestionViewFitsCompactLightAndDarkChats() async throws {
        let(root,store,chat)=try await fixture()
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        chat.sideQuestionHistory=[SideQuestionExchange(question:"Context question",response:"**Answer** with `code`.\n\nA short paragraph.")]
        chat.sideQuestionError="A deliberately long notice that must wrap inside its own chat without widening the window."
        for width in [CGFloat(360),600] {
            for appearance in [NSAppearance.Name.aqua,.darkAqua] {
                let host=NSHostingView(rootView:SideQuestionView(chat:chat,store:store).frame(width:width))
                host.appearance=NSAppearance(named:appearance);host.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(host.fittingSize.width,width+2)
                XCTAssertLessThanOrEqual(host.fittingSize.height,400)
            }
        }
    }

    @MainActor func testUnsupportedSideQuestionPreservesQuestionAndNeverBecomesMainPrompt() async throws {
        let(root,store,chat)=try await fixture()
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        try await store.connect(chat)
        let peer=try XCTUnwrap(chat.connection)
        chat.handshake["_meta"]["ccode"]["sideQuestions"]["version"]=2
        chat.sideQuestionDraft="Unsupported request";chat.draft="Main draft"
        store.askSideQuestion(chat)
        try await wait { chat.sideQuestionTask==nil }
        XCTAssertEqual(chat.sideQuestionDraft,"Unsupported request");XCTAssertEqual(chat.draft,"Main draft")
        XCTAssertNotNil(chat.sideQuestionError);XCTAssertNil(chat.lastError)
        let counts=try await peer.request("fixture/counts",params:[:]);XCTAssertEqual(counts["prompts"],0);XCTAssertEqual(counts["sideQuestions"],0)
    }

    @MainActor func testFailedSideRequestCancelsOnlyItsProviderWorkerAndPreservesQuestion() async throws {
        let(root,store,chat)=try await fixture()
        addTeardownBlock { await store.shutdown();try? FileManager.default.removeItem(at:root) }
        try await store.connect(chat)
        let peer=try XCTUnwrap(chat.connection)
        chat.sideQuestionDraft="Failure"
        store.askSideQuestion(chat)
        try await wait { chat.sideQuestionTask==nil }
        try await Task.sleep(for:.milliseconds(80))
        let counts=try await peer.request("fixture/counts",params:[:])
        XCTAssertEqual(counts["sideCancels"],1)
        XCTAssertEqual(counts["cancels"],0);XCTAssertEqual(counts["prompts"],0)
        XCTAssertEqual(chat.sideQuestionDraft,"Failure");XCTAssertNotNil(chat.sideQuestionError)
    }

    @MainActor private func fixture() async throws -> (URL,AppStore,ChatSession) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("ccode-side-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let store=AppStore(directory:root.appendingPathComponent("data"),claudeDirectory:root.appendingPathComponent("empty"))
        store.settings.executable="/usr/bin/python3";store.settings.arguments=[try XCTUnwrap(Bundle.module.url(forResource:"side_question",withExtension:"py",subdirectory:"Fixtures")).path]
        await store.create(path:root.path,worktree:false)
        return(root,store,try XCTUnwrap(store.selected))
    }
    @MainActor private func wait(_ predicate:()->Bool) async throws {
        for _ in 0..<500 { if predicate(){return};try await Task.sleep(for:.milliseconds(10)) }
        XCTFail("Owned side-question transition timed out");throw ACPError.workspace("Fixture timed out")
    }
}
