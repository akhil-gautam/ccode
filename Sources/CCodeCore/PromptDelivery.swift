import Foundation

public enum DeliveryPolicy: String, Codable, Sendable { case steer, nextTurn }
public enum DeliveryState: String, Codable, Sendable { case queued, submitting, acknowledged, failed, uncertain, cancelled }

public struct PendingPrompt: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var text: String
    public let attachments: [PromptAttachment]
    public let createdAt: Date
    public var policy: DeliveryPolicy
    public var state: DeliveryState
    public let executable: String
    public let arguments: [String]
    public var remoteID: String?
    public var error: String?
    // App-owned review feedback retains its source receipts until actual delivery.
    // Older generic queued messages have no such metadata.
    public var peerMessage: PeerMessage?
    public var reviewContexts: [ReviewComment]?
    public var pullRequestContext: PullRequestFixContext?

    public init(id: UUID = UUID(), text: String, attachments: [PromptAttachment], policy: DeliveryPolicy, executable: String, arguments: [String], remoteID: String?) throws {
        try Self.validate(text: text, attachments: attachments)
        self.id = id; self.text = text; self.attachments = attachments; self.policy = policy
        self.executable = executable; self.arguments = arguments; self.remoteID = remoteID
        createdAt = Date(); state = .queued
    }
    public static func validate(text: String, attachments: [PromptAttachment]) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { throw ACPError.workspace("Enter a message or attach a file.") }
        guard attachments.count <= PromptAttachment.countLimit, text.utf8.count < PromptAttachment.promptLimit,
              attachments.reduce(text.utf8.count, { $0 + $1.promptBytes }) < PromptAttachment.promptLimit else { throw ACPError.workspace("Prompt exceeds the 6 MB / 10 files limit.") }
    }
}
