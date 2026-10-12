import XCTest
import Foundation
@testable import CCodeCore

private actor FixtureHostedTransport: HostedHTTPTransport {
    var requests: [URLRequest] = []
    let response: HostedHTTPResponse?
    let failure: Bool
    init(status: Int = 200, body: String = "{\"type\":\"routine_fire\",\"claude_code_session_id\":\"session_proof123\",\"claude_code_session_url\":\"https://claude.ai/code/session_proof123\"}", failure: Bool = false) {
        response = HostedHTTPResponse(status: status, data: Data(body.utf8)); self.failure = failure
    }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> HostedHTTPResponse {
        requests.append(request)
        if failure { throw URLError(.networkConnectionLost) }
        return response!
    }
    var count: Int { requests.count }
    var first: URLRequest? { requests.first }
}

private final class HostedURLProtocolFixture: URLProtocol, @unchecked Sendable {
    enum Reply { case body(Data), redirect }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var reply: Reply = .body(Data())
        var seen: [URL] = []
        func reset(_ reply: Reply) { lock.withLock { self.reply = reply; seen = [] } }
        func record(_ url: URL) -> Reply { lock.withLock { seen.append(url); return reply } }
        var requests: [URL] { lock.withLock { seen } }
    }
    private static let state = State()
    static func reset(_ reply: Reply) { state.reset(reply) }
    static var requests: [URL] { state.requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        switch Self.state.record(url) {
        case .body(let data):
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect:
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://untrusted.invalid/receiver")!), redirectResponse: HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://untrusted.invalid/receiver"])!)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class HostedServiceTests: XCTestCase, @unchecked Sendable {
    func testProductionURLSessionBoundsStreamAndRefusesRedirectsWithoutSecondRequest() async throws {
        let transport = URLSessionHostedTransport(configuration: { let value = URLSessionConfiguration.ephemeral; value.protocolClasses = [HostedURLProtocolFixture.self]; return value })
        let service = HostedRoutineService(transport: transport), routine = try HostedRoutineDefinition(name: "Owned", triggerID: "trig_proof123")
        HostedURLProtocolFixture.reset(.body(Data(repeating: 97, count: 256 * 1024 + 1)))
        do { _ = try await service.fire(routine, token: "sk-ant-oat01-fixture", context: ""); XCTFail("Unbounded response accepted") }
        catch let error as HostedServiceError { XCTAssertTrue(error.uncertain) }
        XCTAssertEqual(HostedURLProtocolFixture.requests, [routine.endpoint])
        HostedURLProtocolFixture.reset(.redirect)
        do { _ = try await service.fire(routine, token: "sk-ant-oat01-fixture", context: ""); XCTFail("Redirect accepted") }
        catch let error as HostedServiceError { XCTAssertTrue(error.uncertain) }
        XCTAssertEqual(HostedURLProtocolFixture.requests, [routine.endpoint], "Bearer request was redirected")
    }
    func testDecodedDefinitionsValidateAndCancelledWorkDoesNotDispatch() async throws {
        let invalid: JSONValue = ["id": .string(UUID().uuidString), "name": "Imported", "triggerID": "trig_invalid/path"]
        XCTAssertThrowsError(try JSONDecoder().decode(HostedRoutineDefinition.self, from: JSONEncoder().encode(invalid)))
        let transport = FixtureHostedTransport(), service = HostedRoutineService(transport: transport), routine = try HostedRoutineDefinition(name: "Owned", triggerID: "trig_proof123")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.fire(routine, token: "sk-ant-oat01-fixture", context: "")
        }
        do { _ = try await task.value; XCTFail("Cancelled work sent") } catch is CancellationError { }
        let count = await transport.count; XCTAssertEqual(count, 0)
    }
    func testExactRoutineIdentityHeadersLiteralContextAndAcceptedProviderReceipt() async throws {
        let transport = FixtureHostedTransport(), service = HostedRoutineService(transport: transport)
        let routine = try HostedRoutineDefinition(name: "Owned routine", triggerID: "trig_proof123")
        let receipt = try await service.fire(routine, token: "sk-ant-oat01-owned-fixture", context: "Literal context\n$(not a command)")
        XCTAssertEqual(receipt.sessionID, "session_proof123"); XCTAssertEqual(receipt.sessionURL.absoluteString, "https://claude.ai/code/session_proof123")
        let captured = await transport.first
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/claude_code/routines/trig_proof123/fire")
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-owned-fixture")
        let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody)); XCTAssertEqual(body["text"], "Literal context\n$(not a command)")
        let encoded = try JSONEncoder().encode(routine); XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("sk-ant"))
    }
    func testInvalidIdentityCredentialAndContextRefuseBeforeDispatch() async throws {
        for id in ["routine_wrong", "trig_../../escape", "trig_x?token=1", "trig_"] { XCTAssertThrowsError(try HostedRoutineDefinition(name: "Invalid", triggerID: id)) }
        let transport = FixtureHostedTransport(), service = HostedRoutineService(transport: transport), routine = try HostedRoutineDefinition(name: "Owned", triggerID: "trig_proof123")
        for token in ["", "sk-ant-api01-wrong", "sk-ant-oat01-bad\nInjected: header"] {
            do { _ = try await service.fire(routine, token: token, context: ""); XCTFail("Invalid token dispatched") } catch { }
        }
        do { _ = try await service.fire(routine, token: "sk-ant-oat01-owned", context: String(repeating: "a", count: 65537)); XCTFail("Oversized context dispatched") } catch { }
        let count = await transport.count; XCTAssertEqual(count, 0)
    }
    func testAmbiguousFailuresAndMalformedReceiptsNeverRetryOrLeakToken() async throws {
        let cases: [(Int, String, Bool)] = [(500, "echo sk-ant-oat01-secret", false), (302, "redirect", false), (200, "{}", false), (200, "{\"type\":\"routine_fire\",\"claude_code_session_id\":\"session_proof123\",\"claude_code_session_url\":\"https://evil.example/session_proof123\"}", false), (200, String(repeating: "x", count: 256 * 1024 + 1), false), (200, "", true)]
        for (status, body, failure) in cases {
            let transport = FixtureHostedTransport(status: status, body: body, failure: failure), service = HostedRoutineService(transport: transport), routine = try HostedRoutineDefinition(name: "Owned", triggerID: "trig_proof123")
            do { _ = try await service.fire(routine, token: "sk-ant-oat01-secret", context: ""); XCTFail("Ambiguous result accepted") }
            catch let error as HostedServiceError { XCTAssertTrue(error.uncertain); XCTAssertFalse(error.localizedDescription.contains("sk-ant")) }
            let count = await transport.count; XCTAssertEqual(count, 1)
        }
    }
    func testExplicitRejectionsAreDistinctFromUnknownDelivery() async throws {
        for status in [400, 401, 403, 404, 429] {
            let transport = FixtureHostedTransport(status: status), service = HostedRoutineService(transport: transport), routine = try HostedRoutineDefinition(name: "Owned", triggerID: "trig_proof123")
            do { _ = try await service.fire(routine, token: "sk-ant-oat01-owned", context: ""); XCTFail("Rejection accepted") }
            catch let error as HostedServiceError { XCTAssertFalse(error.uncertain) }
            let count = await transport.count; XCTAssertEqual(count, 1)
        }
    }
}
