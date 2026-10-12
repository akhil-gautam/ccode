import Foundation

public struct HostedRoutineDefinition: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let triggerID: String
    public init(id: UUID = UUID(), name: String, triggerID: String) throws {
        self.id = id; self.name = name; self.triggerID = triggerID; try validate()
    }
    private enum CodingKeys: String, CodingKey { case id, name, triggerID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name); triggerID = try values.decode(String.self, forKey: .triggerID); try validate()
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128, Self.validIdentity(triggerID, prefix: "trig_") else { throw HostedServiceError.configuration("Enter a name and the trig_ identifier from the routine's API trigger.") }
    }
    static func validIdentity(_ value: String, prefix: String) -> Bool {
        value.hasPrefix(prefix) && value.count > prefix.count && value.utf8.count <= 200 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    public var endpoint: URL { URL(string: "https://api.anthropic.com/v1/claude_code/routines/\(triggerID)/fire")! }
}
public struct HostedRoutineReceipt: Sendable, Equatable {
    public let sessionID: String
    public let sessionURL: URL
}
public struct HostedHTTPResponse: Sendable {
    public let status: Int
    public let data: Data
    public init(status: Int, data: Data) { self.status = status; self.data = data }
}
public protocol HostedHTTPTransport: Sendable {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> HostedHTTPResponse
}
public enum HostedServiceError: Error, LocalizedError, Sendable, Equatable {
    case configuration(String), rejected(Int), uncertainDelivery
    public var uncertain: Bool { self == .uncertainDelivery }
    public var errorDescription: String? {
        switch self {
        case .configuration(let reason): reason
        case .uncertainDelivery: "Delivery could not be confirmed. Inspect the routine on Claude before starting another run. This request will not be retried automatically."
        case .rejected(let status):
            switch status {
            case 400: "The routine request was rejected. Check the context and whether the routine is paused."
            case 401: "The token was rejected for this routine."
            case 403: "This account or organization cannot trigger this routine."
            case 404: "The hosted routine was not found."
            case 429: "The hosted routine's rate limit was reached."
            default: "The hosted routine request was rejected (HTTP \(status))."
            }
        }
    }
}

public struct HostedRoutineService: Sendable {
    private let transport: any HostedHTTPTransport
    public init(transport: any HostedHTTPTransport = URLSessionHostedTransport()) { self.transport = transport }
    public func fire(_ routine: HostedRoutineDefinition, token: String, context: String) async throws -> HostedRoutineReceipt {
        try Task.checkCancellation(); try routine.validate()
        guard token.hasPrefix("sk-ant-oat01-"), token.utf8.count > 13, token.utf8.count <= 2048,
              token.utf8.allSatisfy({ (33...126).contains($0) }) else { throw HostedServiceError.configuration("Use the dedicated bearer token generated for this routine, rather than a general API key.") }
        guard context.unicodeScalars.count <= 65536, context.utf8.count <= 256 * 1024 else { throw HostedServiceError.configuration("Routine context exceeds the 65,536-character limit.") }
        var request = URLRequest(url: routine.endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(context.isEmpty ? JSONValue.object([:]) : ["text": .string(context)])
        let response: HostedHTTPResponse
        // Exactly one client dispatch. A disconnected/cancelled/ambiguous POST
        // may already have created a remote session; never retry it here.
        do { response = try await transport.send(request, maximumBytes: 256 * 1024) }
        catch { throw HostedServiceError.uncertainDelivery }
        guard response.data.count <= 256 * 1024 else { throw HostedServiceError.uncertainDelivery }
        if [400, 401, 403, 404, 429].contains(response.status) { throw HostedServiceError.rejected(response.status) }
        guard response.status == 200, let body = try? JSONDecoder().decode(JSONValue.self, from: response.data), body["type"] == "routine_fire" else { throw HostedServiceError.uncertainDelivery }
        let id = body["claude_code_session_id"].string
        guard HostedRoutineDefinition.validIdentity(id, prefix: "session_"),
              body["claude_code_session_url"].string == "https://claude.ai/code/" + id,
              let url = URL(string: body["claude_code_session_url"].string) else { throw HostedServiceError.uncertainDelivery }
        return HostedRoutineReceipt(sessionID: id, sessionURL: url)
    }
}

private final class RefuseHostedRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
public struct URLSessionHostedTransport: HostedHTTPTransport {
    private let configuration: @Sendable () -> URLSessionConfiguration
    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) { self.configuration = configuration }
    public func send(_ request: URLRequest, maximumBytes: Int) async throws -> HostedHTTPResponse {
        guard let url = request.url, url.scheme == "https", url.host == "api.anthropic.com", url.user == nil, url.password == nil, url.port == nil,
              maximumBytes > 0, maximumBytes <= 256 * 1024 else { throw HostedServiceError.configuration("Invalid hosted routine transport target.") }
        let options = configuration()
        options.httpCookieStorage = nil; options.httpShouldSetCookies = false; options.urlCache = nil; options.urlCredentialStorage = nil
        options.waitsForConnectivity = false; options.timeoutIntervalForRequest = 30; options.timeoutIntervalForResource = 60
        let session = URLSession(configuration: options, delegate: RefuseHostedRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse, response.url == url else { throw HostedServiceError.uncertainDelivery }
        var data = Data(); data.reserveCapacity(min(maximumBytes, 16 * 1024))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw HostedServiceError.uncertainDelivery }
            data.append(byte)
        }
        return HostedHTTPResponse(status: response.statusCode, data: data)
    }
}
