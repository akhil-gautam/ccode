import Foundation
import XCTest
@testable import CCodeCore

actor Received {
    var values: [JSONValue] = []
    func append(_ batch: [JSONValue]) { values += batch }
    func all() -> [JSONValue] { values }
}

final class ProtocolTests: XCTestCase, @unchecked Sendable {
    func testOwnedMutationCanWaitForActualOutcomeAndStillEndsOnCancellationOrDisconnect() async throws {
        for cancel in [false, true] {
            let peer = try await connection()
            let task = Task { try await peer.request("fixture/hang", params: [:], timeout: nil) }
            let deadline = ContinuousClock.now + .seconds(2)
            while !(await peer.hasPendingRequest(1)), ContinuousClock.now < deadline { await Task.yield() }
            let pending = await peer.hasPendingRequest(1)
            XCTAssertTrue(pending)
            if cancel { task.cancel() } else { await peer.close() }
            do { _ = try await task.value; XCTFail("Request must end") }
            catch { if cancel { XCTAssertTrue(error is CancellationError) } }
            await peer.close()
        }
    }
    func testClosedConnectionCannotStartProcess() async throws {
        let peer = ACPConnection(onUpdates: { _ in }, onRequest: { _, _ in [:] })
        await peer.close()
        do {
            try await peer.start(executable: "/usr/bin/true", arguments: [], directory: "/tmp")
            XCTFail("Closed connection started a process")
        } catch { }
        await peer.close()
    }
    func testFinalResponseWaitsForSlowUpdatesBeforeProcessExit() async throws {
        let received = Received()
        let peer = ACPConnection(onUpdates: { batch in
            await Task.detached { try? await Task.sleep(for: .milliseconds(500)) }.value
            await received.append(batch)
        }, onRequest: { _, _ in [:] })
        let path = Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path
        try await peer.start(executable: "/usr/bin/python3", arguments: [path], directory: "/tmp")
        let result = try await peer.request("fixture/final-exit", params: [:])
        XCTAssertTrue(result["ok"].bool)
        let events = await received.all()
        XCTAssertEqual(events.count, 1)
        await peer.close()
    }
    func testFractionalIDCannotResolveIntegerRequest() async throws {
        let peer = try await connection()
        do { _ = try await peer.request("fixture/fractional", params: [:], timeout: .milliseconds(300)); XCTFail("Fractional response accepted") } catch { }
        await peer.close()
    }
    func testBackpressureTimeoutAndParentExitWithInheritedPipes() async throws {
        for name in ["stall", "inherited", "streaming-inherited"] {
            let peer = ACPConnection(onUpdates: { _ in }, onRequest: { _, _ in [:] })
            let fixture = Bundle.module.url(forResource: name == "streaming-inherited" ? "inherited" : name, withExtension: "py", subdirectory: "Fixtures")!.path
            try await peer.start(executable: "/usr/bin/python3", arguments: [fixture] + (name == "streaming-inherited" ? ["--stream"] : []), directory: "/tmp")
            let start = Date()
            do {
                _ = try await peer.request("initialize", params: ["data": .string(name == "stall" ? String(repeating: "a", count: 512 * 1024) : "")], timeout: name == "stall" ? .milliseconds(50) : .seconds(2))
                XCTFail("Expected failed request")
            } catch { XCTAssertLessThan(Date().timeIntervalSince(start), name == "stall" ? 0.5 : 1.0) }
            await peer.close()
        }
    }
    func connection(_ received: Received = Received()) async throws -> ACPConnection {
        let peer = ACPConnection(onUpdates: { await received.append($0) }, onRequest: { method, params in
            guard method == "session/request_permission", params["options"].array.count == 2 else { throw ACPError.methodNotFound(method) }
            return ["outcome": ["outcome": "selected", "optionId": "allow"]]
        })
        let path = Bundle.module.url(forResource: "agent", withExtension: "py", subdirectory: "Fixtures")!.path
        try await peer.start(executable: "/usr/bin/python3", arguments: [path], directory: "/tmp")
        return peer
    }

    func testFragmentedUTF8AndFrameLimit() throws {
        var framer = LineFramer(maximumBytes: 20)
        let bytes = Data("{\"x\":\"🦉\"}\n{}\r\n".utf8)
        var lines: [Data] = []
        for byte in bytes { lines += try framer.append(Data([byte])) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(data: lines[0], encoding: .utf8), "{\"x\":\"🦉\"}")
        XCTAssertThrowsError(try framer.append(Data(repeating: 120, count: 21)))
    }

    func testRealProcessHandshakeStreamingPermissionAndStderr() async throws {
        let received = Received()
        let peer = try await connection(received)
        let result = try await peer.request("initialize", params: ["protocolVersion": 1])
        XCTAssertEqual(result["protocolVersion"].int, 1)
        let session = try await peer.request("session/new", params: ["cwd": "/tmp", "mcpServers": []])
        XCTAssertEqual(session["sessionId"].string, "fixture-session")
        let done = try await peer.request("session/prompt", params: ["sessionId": "fixture-session", "prompt": [["type": "text", "text": "Hello"]]])
        XCTAssertEqual(done["stopReason"].string, "end_turn")
        let events = await received.all()
        XCTAssertEqual(events.filter { $0["update"]["sessionUpdate"].string == "agent_message_chunk" }.count, 2)
        let flood = try await peer.request("fixture/flood", params: [:])
        XCTAssertEqual(flood["ok"].bool, true)
        await peer.close()
    }

    func testExitTimeoutMalformedAndTaskCancellation() async throws {
        for method in ["fixture/exit", "fixture/hang", "fixture/bad"] {
            let peer = try await connection()
            do { _ = try await peer.request(method, params: [:], timeout: .milliseconds(150)); XCTFail("Expected \(method) failure") }
            catch { }
            await peer.close()
        }
        let peer = try await connection()
        let task = Task { try await peer.request("fixture/hang", params: [:], timeout: .seconds(10)) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        await peer.close()
    }
}
