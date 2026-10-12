import Foundation

extension SessionTranscript {
    /// Reconcile the pinned provider's replay inference with a complete, freshly
    /// recognized local family. This never grants live control or replaces the
    /// provider's rendered messages. The caller must verify provider identity.
    @discardableResult public mutating func reconcileClaudeDelegatedReplay(with native: SessionTranscript) -> Bool {
        guard let root = remoteID, UUID(uuidString: root) != nil, native.remoteID == root,
              let children = subagents, !children.isEmpty, children.count <= 256 else { return false }
        let known = native.subagents ?? [], prefix = root + ":replay-subagent:"
        let terminal: Set<String> = ["completed", "failed", "cancelled", "disconnected"]
        let ids = Set(children.map(\.id)), knownIDs = Set(known.map(\.id))
        guard ids.count == children.count, knownIDs.count == known.count, knownIDs.isSubset(of: ids),
              (children + known).allSatisfy({
                  $0.id.hasPrefix(prefix) && $0.id.count > prefix.count && $0.capabilities == [:]
                      && terminal.contains($0.state) && ($0.parentID == root || knownIDs.contains($0.parentID))
              }) else { return false }
        guard (asyncTasks ?? []).allSatisfy({
            !$0.isRunning && !$0.canStop && ($0.id.owner == root || knownIDs.contains($0.id.owner))
        }) else { return false }
        let knownByID = Dictionary(uniqueKeysWithValues: known.map { ($0.id, $0) })
        // Verify lineage and its unique visible references before any mutation.
        for child in children {
            var owner = child.parentID, visited = Set([child.id])
            while owner != root {
                guard visited.count <= 16, visited.insert(owner).inserted, let parent = knownByID[owner] else { return false }
                owner = parent.parentID
            }
            guard agentItems(owner: child.parentID).filter({
                $0.kind == "subagent" && $0.tool["subagentSessionId"] == .string(child.id)
            }).count == 1 else { return false }
            if let actual = knownByID[child.id], actual.parentID != child.parentID { return false }
        }
        for owner in [root] + children.map(\.id) {
            guard agentItems(owner: owner).filter({ $0.kind == "subagent" }).allSatisfy({ row in
                children.contains { $0.id == row.tool["subagentSessionId"].string && $0.parentID == owner }
            }) else { return false }
        }
        var failures: [String: TranscriptItem] = [:]
        for child in children where knownByID[child.id] == nil {
            guard child.transcript.items.isEmpty, ["failed", "cancelled"].contains(child.state) else { return false }
            let toolID = String(child.id.dropFirst(prefix.count))
            let rows = native.agentItems(owner: child.parentID).filter {
                $0.kind == "tool" && $0.tool["toolCallId"] == .string(toolID)
                    && ["Agent", "Task"].contains($0.tool["title"].string) && $0.tool["status"] == "failed"
            }
            guard rows.count == 1 else { return false }
            failures[child.id] = rows[0]
        }
        var result = self
        for child in children {
            if let actual = knownByID[child.id], let index = result.subagents?.firstIndex(where: { $0.id == child.id }) {
                result.subagents?[index].state = actual.state
            } else if let failed = failures[child.id] {
                if child.parentID == root {
                    let row = result.items.firstIndex { $0.kind == "subagent" && $0.tool["subagentSessionId"] == .string(child.id) }!
                    result.items[row] = failed
                } else {
                    let parent = result.subagents!.firstIndex { $0.id == child.parentID }!
                    let row = result.subagents![parent].transcript.items.firstIndex { $0.kind == "subagent" && $0.tool["subagentSessionId"] == .string(child.id) }!
                    result.subagents?[parent].transcript.items[row] = failed
                }
            }
        }
        result.subagents?.removeAll { failures[$0.id] != nil }
        if result.subagents?.isEmpty == true { result.subagents = nil }
        self = result
        return true
    }
}
