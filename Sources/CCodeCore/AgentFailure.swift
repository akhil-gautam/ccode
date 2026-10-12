import Foundation

/// Provider/transport failure presentation. This never treats a rejection as
/// proof that earlier tool actions did not execute, and never authorizes replay.
public struct AgentFailure: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case authentication, access, quota, rateLimit, overloaded, context, budget, connection, request, provider
    }
    public let kind: Kind
    public let details: String
    public let deliveryID: UUID?
    public init(error: any Error, deliveryID: UUID? = nil, providerMetadata: Bool = true) {
        self.deliveryID = deliveryID
        details = String(error.localizedDescription.prefix(16_384))
        let rpc = error as? ACPError
        if providerMetadata, rpc?.rpcData["reason"].string == "claude_subscription_not_supported" {
            kind = .access
            return
        }
        let errorKind = providerMetadata ? rpc?.rpcData["errorKind"].string ?? "" : ""
        switch errorKind {
        case "authentication_failed", "oauth_org_not_allowed": kind = .authentication
        case "verification_required", "cloud_credential_error": kind = .access
        case "billing_error", "account_on_hold": kind = .quota
        case "rate_limit": kind = .rateLimit
        case "overloaded": kind = .overloaded
        case "max_output_tokens", "error_max_turns": kind = .context
        case "budget_exhausted": kind = .budget
        case "transport_lost", "worker_shutdown": kind = .connection
        case "invalid_request", "model_not_found": kind = .request
        default:
            if rpc?.rpcCode == -32000, rpc?.rpcMessage == "Authentication required" || rpc?.rpcMessage?.hasPrefix("Authentication required:") == true {
                kind = .authentication
            } else if case ACPError.disconnected = error { kind = .connection }
            else if case ACPError.timeout = error { kind = .connection }
            else { kind = .provider }
        }
    }
    public var title: String {
        switch kind {
        case .authentication: "Sign in to continue"
        case .access: "Provider access needs attention"
        case .quota: "Account quota unavailable"
        case .rateLimit: "Rate limit reached"
        case .overloaded: "Provider temporarily overloaded"
        case .context: "Turn or context limit reached"
        case .budget: "Session budget reached"
        case .connection: "Agent connection interrupted"
        case .request: "Provider could not process the request"
        case .provider: "Work needs attention"
        }
    }
    public var guidance: String {
        switch kind {
        case .authentication: "Sign in using an offered method or your agent's login command, then reconnect. Your draft is retained."
        case .access: "Check the account, organization verification or provider credentials in the reported details. Signing in may not resolve this condition."
        case .quota: "Check your provider's account limits or billing. Reconnecting does not reset quota."
        case .rateLimit, .overloaded: "Wait for the provider to recover, then review the interrupted request before sending again."
        case .context, .budget: "Review the completed work and continue in a new session, or use a supported compaction command."
        case .connection: "Reconnect to inspect the latest session history. Pending work remains paused."
        case .request: "Review the request and selected model using the reported details."
        case .provider: "Review the reported details and completed work before continuing."
        }
    }
}
