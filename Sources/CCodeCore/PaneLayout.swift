import Foundation

public struct PaneWindowFrame: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public var isUsable: Bool { [x, y, width, height].allSatisfy(\.isFinite) && width >= 600 && height >= 500 && width <= 10000 && height <= 10000 }
}

public enum PaneArrangement: String, Codable, Sendable { case horizontal, vertical }

public struct ChatPane: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var sessionID: UUID?
    public init(id: UUID = UUID(), sessionID: UUID? = nil) { self.id = id; self.sessionID = sessionID }
}

public struct DetachedWorkspacePane: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let kind: String
    public static let kinds: Set<String> = ["diff", "files", "terminal", "browser", "plan", "artifacts", "tasks", "computer", "simulator"]
    public init(id: UUID = UUID(), sessionID: UUID, kind: String) { self.id=id;self.sessionID=sessionID;self.kind=kind }
}

/// Each native chat view has exactly one placement, including detached windows.
public struct PaneLayout: Codable, Equatable, Sendable {
    public private(set) var panes: [ChatPane]
    public private(set) var detachedPanes: [ChatPane] = []
    public private(set) var detachedWorkspacePanes: [DetachedWorkspacePane] = []
    public private(set) var windowFrames: [UUID: PaneWindowFrame] = [:]
    public private(set) var focusedPaneID: UUID
    public var arrangement: PaneArrangement = .horizontal
    private let version = 3
    public var allPanes: [ChatPane] { panes + detachedPanes }
    public var focusablePaneIDs: [UUID] { allPanes.map(\.id) + detachedWorkspacePanes.map(\.id) }
    public func sessionID(for paneID: UUID) -> UUID? { allPanes.first { $0.id == paneID }?.sessionID ?? detachedWorkspacePanes.first { $0.id == paneID }?.sessionID }
    public var focusedSessionID: UUID? { sessionID(for: focusedPaneID) }
    public var visibleSessionIDs: Set<UUID> { Set(allPanes.compactMap(\.sessionID) + detachedWorkspacePanes.map(\.sessionID)) }
    public init() {
        let pane = ChatPane(); panes = [pane]; focusedPaneID = pane.id
    }
    public mutating func focus(_ paneID: UUID) {
        if focusablePaneIDs.contains(paneID) { focusedPaneID = paneID }
    }
    public mutating func show(_ sessionID: UUID?) {
        if let existing = allPanes.first(where: { $0.sessionID == sessionID }) { focusedPaneID = existing.id; return }
        // A new selection from a detached window opens in the main window; detached views never swap owners.
        let index = panes.firstIndex(where: { $0.id == focusedPaneID }) ?? 0
        panes[index].sessionID = sessionID; focusedPaneID = panes[index].id
    }
    public mutating func showBeside(_ sessionID: UUID) throws {
        if let existing = allPanes.first(where: { $0.sessionID == sessionID }) { focusedPaneID = existing.id; return }
        if let home = panes.firstIndex(where: { $0.sessionID == nil }) {
            panes[home].sessionID = sessionID; focusedPaneID = panes[home].id; return
        }
        guard panes.count < 2 else { throw ACPError.workspace("Close a chat pane before opening another alongside it.") }
        let pane = ChatPane(sessionID: sessionID); panes.append(pane); focusedPaneID = pane.id
    }
    public mutating func detach(_ paneID: UUID) throws {
        if detachedPanes.contains(where: { $0.id == paneID }) { focusedPaneID = paneID; return }
        guard let index = panes.firstIndex(where: { $0.id == paneID }), panes[index].sessionID != nil else {
            throw ACPError.workspace("Open a chat before moving it to a window.")
        }
        let pane = panes.remove(at: index); detachedPanes.append(pane); focusedPaneID = pane.id
        if panes.isEmpty { panes = [ChatPane()] }
    }
    public func canDock(_ paneID: UUID) -> Bool {
        detachedPanes.contains(where: { $0.id == paneID }) && (panes.count < 2 || panes.contains { $0.sessionID == nil })
    }
    public mutating func dock(_ paneID: UUID) throws {
        guard let index = detachedPanes.firstIndex(where: { $0.id == paneID }) else { return }
        guard canDock(paneID) else { throw ACPError.workspace("Close a main-window chat pane before docking this window.") }
        let pane = detachedPanes.remove(at: index)
        if let home = panes.firstIndex(where: { $0.sessionID == nil }) { panes[home] = pane }
        else { panes.append(pane) }
        windowFrames.removeValue(forKey: paneID); focusedPaneID = paneID
    }
    public mutating func setWindowFrame(_ frame: PaneWindowFrame, for paneID: UUID) {
        guard frame.isUsable, detachedPanes.contains(where: { $0.id == paneID }) || detachedWorkspacePanes.contains(where: { $0.id == paneID }) else { return }
        windowFrames[paneID] = frame
    }
    public mutating func detachWorkspace(sessionID: UUID, kind: String) throws -> UUID {
        guard DetachedWorkspacePane.kinds.contains(kind), visibleSessionIDs.contains(sessionID) else { throw ACPError.workspace("Open this session and choose a supported workspace pane first.") }
        if let pane=detachedWorkspacePanes.first(where: { $0.sessionID == sessionID && $0.kind == kind }) { focus(pane.id);return pane.id }
        guard detachedWorkspacePanes.count < 16 else { throw ACPError.workspace("Dock or close a workspace window before opening another.") }
        let pane=DetachedWorkspacePane(sessionID:sessionID,kind:kind)
        detachedWorkspacePanes.append(pane);focus(pane.id);return pane.id
    }
    public mutating func closeWorkspace(_ paneID: UUID) {
        guard let pane=detachedWorkspacePanes.first(where: { $0.id == paneID }) else { return }
        detachedWorkspacePanes.removeAll { $0.id == paneID };windowFrames.removeValue(forKey:paneID)
        if focusedPaneID == paneID { focusedPaneID=allPanes.first(where: { $0.sessionID == pane.sessionID })?.id ?? panes[0].id }
    }
    public mutating func close(_ paneID: UUID) {
        if let index = detachedPanes.firstIndex(where: { $0.id == paneID }) {
            detachedPanes.remove(at: index); windowFrames.removeValue(forKey: paneID)
            if focusedPaneID == paneID { focusedPaneID = panes[0].id }
            return
        }
        guard let index = panes.firstIndex(where: { $0.id == paneID }) else { return }
        if panes.count == 1 { panes[index].sessionID = nil; return }
        panes.remove(at: index)
        if focusedPaneID == paneID { focusedPaneID = panes[min(index, panes.count - 1)].id }
    }
    public mutating func reconcile(available: Set<UUID>) {
        panes.removeAll { $0.sessionID.map { !available.contains($0) } ?? false }
        detachedPanes.removeAll { $0.sessionID.map { !available.contains($0) } ?? true }
        detachedWorkspacePanes.removeAll { !available.contains($0.sessionID) }
        if panes.isEmpty { panes = [ChatPane()] }
        windowFrames = windowFrames.filter { id, frame in (detachedPanes.contains { $0.id == id } || detachedWorkspacePanes.contains { $0.id == id }) && frame.isUsable }
        if !focusablePaneIDs.contains(focusedPaneID) { focusedPaneID = panes[0].id }
    }
    private enum CodingKeys: String, CodingKey { case version, panes, detachedPanes, detachedWorkspacePanes, windowFrames, focusedPaneID, arrangement }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        panes = try values.decode([ChatPane].self, forKey: .panes)
        detachedPanes = try values.decodeIfPresent([ChatPane].self, forKey: .detachedPanes) ?? []
        detachedWorkspacePanes = try values.decodeIfPresent([DetachedWorkspacePane].self, forKey: .detachedWorkspacePanes) ?? []
        windowFrames = try values.decodeIfPresent([UUID: PaneWindowFrame].self, forKey: .windowFrames) ?? [:]
        focusedPaneID = try values.decode(UUID.self, forKey: .focusedPaneID)
        arrangement = try values.decode(PaneArrangement.self, forKey: .arrangement)
        let sessions = allPanes.compactMap(\.sessionID)
        let workspaceOwners=detachedWorkspacePanes.map { "\($0.sessionID)/\($0.kind)" }
        guard (1...3).contains(version), (1...2).contains(panes.count),
              Set(allPanes.map(\.id)).count == allPanes.count, Set(sessions).count == sessions.count,
              detachedWorkspacePanes.count <= 16, Set(focusablePaneIDs).count == focusablePaneIDs.count,
              Set(workspaceOwners).count == workspaceOwners.count, detachedWorkspacePanes.allSatisfy({ DetachedWorkspacePane.kinds.contains($0.kind) }),
              panes.filter({ $0.sessionID == nil }).count <= 1, detachedPanes.allSatisfy({ $0.sessionID != nil }),
              focusablePaneIDs.contains(focusedPaneID),
              windowFrames.allSatisfy({ id, frame in (detachedPanes.contains { $0.id == id } || detachedWorkspacePanes.contains { $0.id == id }) && frame.isUsable }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid chat pane ownership."))
        }
    }
}
