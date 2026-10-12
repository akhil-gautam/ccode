import XCTest
import CCodeCore

final class LiveConfigurationTests: XCTestCase {
    let connection = "76659112-0d94-4a67-8235-48032b7f8601"
    let session = "b61a1450-0838-4976-bcfe-1ce982df9a69"
    var capability: JSONValue { ["version": 1, "connectionId": .string(connection), "method": "_ccode/configuration"] }
    var status: JSONValue { ["version": 1, "connectionId": .string(connection), "sessionId": .string(session), "operation": "status", "servers": [["name": "project-tools", "status": "connected", "source": "project", "scope": "project", "tools": ["read_fixture"]]]] }
    func testNegotiatedStatusKeepsOwnershipAndRejectsMalformedOrForeignResults() throws {
        let cap = try XCTUnwrap(LiveConfigurationCapability(capability))
        let result = try LiveConfigurationResult(status, capability: cap, sessionID: session, operation: .status)
        XCTAssertEqual(result.servers.first?.name, "project-tools")
        XCTAssertEqual(result.servers.first?.status, .connected)
        XCTAssertEqual(result.servers.first?.tools, ["read_fixture"])
        for key in ["connectionId", "sessionId"] { var wrong = status; wrong[key] = .string("a8bcb97d-5f8a-4b67-bba2-d349989fb59a"); XCTAssertThrowsError(try LiveConfigurationResult(wrong, capability: cap, sessionID: session, operation: .status)) }
        for value in [JSONValue.string("false"), .number(2), .null] { var wrong = capability; wrong["version"] = value; XCTAssertNil(LiveConfigurationCapability(wrong)) }
        var unknown = capability; unknown["method"] = "arbitrary/method"; XCTAssertNil(LiveConfigurationCapability(unknown))
        var malformed = status; var server = status["servers"].array[0]; server["status"] = "unknown"; malformed["servers"] = .array([server]); XCTAssertThrowsError(try LiveConfigurationResult(malformed, capability: cap, sessionID: session, operation: .status))
        malformed = status; malformed["servers"] = .array([status["servers"].array[0], status["servers"].array[0]]); XCTAssertThrowsError(try LiveConfigurationResult(malformed, capability: cap, sessionID: session, operation: .status))
    }
    func testControlsUseLiteralServerIdentityAndRequireBooleanToggle() throws {
        let cap = try XCTUnwrap(LiveConfigurationCapability(capability))
        let params = try cap.parameters(sessionID: session, operation: .toggle(name: "project-tools", enabled: false))
        XCTAssertEqual(params, ["connectionId": .string(connection), "sessionId": .string(session), "operation": "toggle", "name": "project-tools", "enabled": false])
        XCTAssertThrowsError(try cap.parameters(sessionID: "foreign", operation: .status))
        XCTAssertThrowsError(try cap.parameters(sessionID: session, operation: .reconnect(name: "")))
        XCTAssertThrowsError(try cap.parameters(sessionID: session, operation: .reconnect(name: "bad\nname")))
    }
    func testAuthenticationFlowIsTransientBoundedAndExplicitlyNegotiated() throws {
        var negotiated = capability; negotiated["authenticationVersion"] = 1
        let cap = try XCTUnwrap(LiveConfigurationCapability(negotiated))
        let flow = "0bf71c25-8ea5-4449-8ab4-df6fbd14f181"
        XCTAssertTrue(cap.supportsAuthentication)
        XCTAssertFalse(try XCTUnwrap(LiveConfigurationCapability(capability)).supportsAuthentication)
        XCTAssertThrowsError(try XCTUnwrap(LiveConfigurationCapability(capability)).parameters(sessionID: session, operation: .beginAuthentication(name: "project-tools")))
        let params = try cap.parameters(sessionID: session, operation: .authenticationStatus(name: "project-tools", flowID: flow))
        XCTAssertEqual(params["flowId"], .string(flow)); XCTAssertEqual(params["operation"], "authenticationStatus")
        XCTAssertThrowsError(try cap.parameters(sessionID: session, operation: .cancelAuthentication(name: "project-tools", flowID: "bad")))
        var response = status; response["operation"] = "beginAuthentication"
        response["authentication"] = ["id": .string(flow), "name": "project-tools", "state": "pending", "url": "https://issuer.example/authorize?state=private"]
        let result = try LiveConfigurationResult(response, capability: cap, sessionID: session, operation: .beginAuthentication(name: "project-tools"))
        XCTAssertEqual(result.authentication?.state, .pending); XCTAssertEqual(result.authentication?.url?.host, "issuer.example")
        for url in ["javascript:alert(1)", "http://issuer.example/login", "https://user:pass@issuer.example/login", "https://issuer.example/\nlogin"] {
            var wrong = response; wrong["authentication"]["url"] = .string(url)
            XCTAssertThrowsError(try LiveConfigurationResult(wrong, capability: cap, sessionID: session, operation: .beginAuthentication(name: "project-tools")))
        }
        var foreign = response; foreign["authentication"]["name"] = "foreign"
        XCTAssertThrowsError(try LiveConfigurationResult(foreign, capability: cap, sessionID: session, operation: .beginAuthentication(name: "project-tools")))
        var stale = response; stale["authentication"]["state"] = "connected"; stale["authentication"]["url"] = .null; var staleServer = stale["servers"].array[0]; staleServer["status"] = "needs-auth"; stale["servers"] = .array([staleServer])
        XCTAssertThrowsError(try LiveConfigurationResult(stale, capability: cap, sessionID: session, operation: .beginAuthentication(name: "project-tools")), "Success must match the actual server's status")
        var complete = response; complete["authentication"]["state"] = "connected"
        XCTAssertThrowsError(try LiveConfigurationResult(complete, capability: cap, sessionID: session, operation: .beginAuthentication(name: "project-tools")), "Terminal results must not retain authorization URLs")
    }

}
