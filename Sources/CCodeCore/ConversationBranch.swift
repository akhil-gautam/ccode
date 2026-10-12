import Foundation

/// Client-owned navigation provenance, never authority to replay or restore code.
public struct ConversationOrigin: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case fork, edit, retry
        public var displayTitle: String {
            switch self { case .fork: "Fork"; case .edit: "Edit"; case .retry: "Retry" }
        }
    }
    public let kind: Kind
    public let sourceSessionID: UUID
    public let sourceRemoteID: String?
    public let sourceItemID: UUID?
    public let boundaryMessageID: String?
    public let startsFresh: Bool
    public let createdAt: Date
    public init(kind: Kind, sourceSessionID: UUID, sourceRemoteID: String? = nil, sourceItemID: UUID? = nil, boundaryMessageID: String? = nil, startsFresh: Bool, createdAt: Date = Date()) {
        self.kind = kind; self.sourceSessionID = sourceSessionID
        self.sourceRemoteID = sourceRemoteID; self.sourceItemID = sourceItemID
        self.boundaryMessageID = boundaryMessageID; self.startsFresh = startsFresh; self.createdAt = createdAt
    }
}

public enum ConversationBranch {
    /// Return only a complete, unambiguous local lineage in the same workspace.
    /// Missing/invalid lineage leaves the selected conversation independently usable.
    public static func related(to id: UUID, in sessions: [SessionInfo]) -> [SessionInfo] {
        guard let selected = sessions.first(where: { $0.id == id }) else { return [] }
        var byID: [UUID: SessionInfo] = [:]
        for session in sessions {
            guard byID.updateValue(session, forKey: session.id) == nil else { return [selected] }
        }
        func root(of session: SessionInfo) -> UUID? {
            var current = session, visited: Set<UUID> = []
            for _ in 0..<256 {
                guard visited.insert(current.id).inserted else { return nil }
                guard let origin = current.origin else { return current.id }
                guard let parent = byID[origin.sourceSessionID], parent.projectPath == current.projectPath else { return nil }
                current = parent
            }
            return nil
        }
        guard let rootID = root(of: selected), let original = byID[rootID] else { return [selected] }
        let versions = sessions.filter { $0.id != rootID && root(of: $0) == rootID }.sorted {
            let a = $0.origin?.createdAt ?? $0.updatedAt, b = $1.origin?.createdAt ?? $1.updatedAt
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
        return [original] + versions
    }
}
