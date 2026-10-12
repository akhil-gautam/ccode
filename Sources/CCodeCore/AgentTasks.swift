import Foundation

/// A provider-announced child, kept separately from its parent's conversation.
/// Persistence preserves history; it never grants a new connection ownership.
public struct SubagentSession: Codable, Identifiable, Sendable {
    public var id: String
    public var parentID: String
    public var name: String
    public var task: String
    public var prompt: String?
    public var capabilities: JSONValue
    public var state: String
    public var transcript: SessionTranscript
    public var isRunning: Bool { state == "running" || state == "pending" }
    public init(id: String, parentID: String) {
        self.id = id; self.parentID = parentID; name = "Subagent"; task = ""
        capabilities = [:]; state = "running"; transcript = SessionTranscript(remoteID: id)
    }
}

extension SessionTranscript {
    public func subagent(_ id: String) -> SubagentSession? { subagents?.first { $0.id == id } }
    public func agentItems(owner: String) -> [TranscriptItem] {
        owner == remoteID ? items : subagent(owner)?.transcript.items ?? []
    }
    @discardableResult public mutating func appendAgentItem(_ item: TranscriptItem, owner: String?) -> Bool {
        if owner == nil || owner == remoteID { beginTurn(); items.append(item); return true }
        guard let index = subagents?.firstIndex(where: { $0.id == owner }) else { return false }
        subagents?[index].transcript.beginTurn(); subagents?[index].transcript.items.append(item); return true
    }
    public mutating func disconnectSubagents() {
        guard let children = subagents else { return }
        for index in children.indices {
            subagents?[index].transcript.interruptTools(.disconnected)
            if children[index].isRunning { subagents?[index].state = "disconnected" }
        }
    }
    private mutating func setSubagentState(_ state: String, at index: Int) {
        subagents?[index].state = state
        switch state {
        case "cancelled", "stopped": subagents?[index].transcript.interruptTools(.stopped)
        case "disconnected": subagents?[index].transcript.interruptTools(.disconnected)
        case "completed", "failed": subagents?[index].transcript.interruptTools(.interrupted)
        default: break
        }
    }
    /// The caller owns this set for one live connection generation. A stored ID
    /// cannot authorize output or callbacks until the current provider announces it.
    @discardableResult public mutating func applyAgentWork(_ params: JSONValue, owners: inout Set<String>) -> Bool {
        guard let rootID = remoteID, let parent = params["sessionId"].optionalString,
              parent == rootID || owners.contains(parent) else { return false }
        let update = params["update"], kind = update["sessionUpdate"].string
        if kind == "subagent_spawned" {
            guard let childID = update["subagentSessionId"].optionalString, !childID.isEmpty,
                  childID != rootID, childID != parent else { return false }
            let existing = subagents?.firstIndex { $0.id == childID }
            if let existing, subagents?[existing].parentID != parent { return false }
            if subagents == nil { subagents = [] }
            if existing == nil {
                subagents?.append(SubagentSession(id: childID, parentID: parent))
                _ = appendAgentItem(TranscriptItem(kind: "subagent", tool: ["subagentSessionId": .string(childID)]), owner: parent)
            }
            guard let index = subagents?.firstIndex(where: { $0.id == childID }) else { return false }
            if let name = update["name"].optionalString, !name.isEmpty { subagents?[index].name = name }
            if let task = update["task"].optionalString { subagents?[index].task = task }
            if let prompt = update["prompt"].optionalString { subagents?[index].prompt = prompt }
            if case .object = update["capabilities"] { subagents?[index].capabilities = update["capabilities"] }
            if let state = update["state"].optionalString, !state.isEmpty { setSubagentState(state, at: index) }
            else if !owners.contains(childID), subagents?[index].state == "disconnected" { subagents?[index].state = "running" }
            owners.insert(childID)
            return true
        }
        if kind == "subagent_state_update" {
            guard let child = update["subagentSessionId"].optionalString, owners.contains(child),
                  let index = subagents?.firstIndex(where: { $0.id == child && $0.parentID == parent }),
                  let state = update["state"].optionalString, !state.isEmpty else { return false }
            setSubagentState(state, at: index)
            return true
        }
        guard parent != rootID, let index = subagents?.firstIndex(where: { $0.id == parent }) else { return false }
        return subagents?[index].transcript.apply(params) ?? false
    }
}
