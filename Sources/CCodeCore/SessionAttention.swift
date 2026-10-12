import Foundation

public enum SessionActivity: String, CaseIterable, Sendable {
    case idle, working, needsAttention, completed
    public var title: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .needsAttention: "Needs attention"
        case .completed: "Completed"
        }
    }
}

public extension SessionInfo {
    var persistedActivity: SessionActivity {
        if lastError != nil || attention?.kind == .failed { return .needsAttention }
        return attention?.kind == .completed ? .completed : .idle
    }
}

public struct SessionAttentionReceipt: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case completed, needsInput, failed }
    public let id: UUID
    public let kind: Kind
    public init(kind: Kind) { id = UUID(); self.kind = kind }
}

public struct SessionNotice: Sendable {
    public let sessionID: UUID
    public let receipt: SessionAttentionReceipt
    public var body: String {
        switch receipt.kind {
        case .completed: "Response finished"
        case .needsInput: "A session needs your input"
        case .failed: "A session needs attention"
        }
    }
    public init(sessionID: UUID, receipt: SessionAttentionReceipt) { self.sessionID = sessionID; self.receipt = receipt }
}
